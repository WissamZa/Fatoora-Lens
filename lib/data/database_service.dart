import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/invoice.dart';
import '../models/shop.dart';
import '../services/seller_name_splitter.dart';

class DatabaseService {
  DatabaseService({this.databasePath, this.databaseFactory});

  final String? databasePath;
  final DatabaseFactory? databaseFactory;
  Database? _database;

  /// Schema 6 re-keyed the shops table on the VAT number (previously the
  /// exact seller-name string) and added name/display columns.
  static const int _schemaVersion = 6;

  Future<void> initialize() async {
    if (_database != null) return;

    final directory = databasePath == null
        ? await getApplicationDocumentsDirectory()
        : null;
    final path = databasePath ?? '${directory!.path}/zakat_invoices.db';
    try {
      final options = OpenDatabaseOptions(
        version: _schemaVersion,
        onCreate: (database, version) => _ensureSchema(database),
        onUpgrade: (database, oldVersion, newVersion) =>
            _ensureSchema(database),
      );
      _database = databaseFactory == null
          ? await openDatabase(
              path,
              version: options.version,
              onCreate: options.onCreate,
              onUpgrade: options.onUpgrade,
            )
          : await databaseFactory!.openDatabase(path, options: options);
      await _ensureSchema(_database!);
    } catch (_) {
      _database = null;
      rethrow;
    }
  }

  Future<void> _ensureSchema(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS invoices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        seller_name TEXT NOT NULL,
        seller_name_en TEXT NOT NULL DEFAULT '',
        vat_number TEXT NOT NULL DEFAULT '',
        issued_at TEXT NOT NULL,
        total_amount REAL NOT NULL,
        vat_amount REAL NOT NULL,
        raw_payload TEXT NOT NULL,
        invoice_number TEXT NOT NULL DEFAULT '',
        note TEXT NOT NULL DEFAULT '',
        image_path TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    final columns = await database.rawQuery('PRAGMA table_info(invoices)');
    final hasNote = columns.any((row) => row['name'] == 'note');
    if (!hasNote) {
      await database.execute(
        "ALTER TABLE invoices ADD COLUMN note TEXT NOT NULL DEFAULT ''",
      );
    }
    final hasImagePath = columns.any((row) => row['name'] == 'image_path');
    if (!hasImagePath) {
      await database.execute('ALTER TABLE invoices ADD COLUMN image_path TEXT');
    }
    final hasInvoiceNumber = columns.any((row) => row['name'] == 'invoice_number');
    if (!hasInvoiceNumber) {
      await database.execute(
        "ALTER TABLE invoices ADD COLUMN invoice_number TEXT NOT NULL DEFAULT ''",
      );
    }
    final hasSellerNameEn = columns.any((row) => row['name'] == 'seller_name_en');
    if (!hasSellerNameEn) {
      await database.execute(
        "ALTER TABLE invoices ADD COLUMN seller_name_en TEXT NOT NULL DEFAULT ''",
      );
    }
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_invoices_seller ON invoices(seller_name)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_invoices_vat ON invoices(vat_number)',
    );

    final legacyNotes = await _migrateShopsTable(database);

    await database.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    // Shops are derived from invoices; this also separates mixed-script
    // seller names stored by older versions and re-links shops by VAT.
    await _syncShops(database, carryOver: _carryOverFromNotes(legacyNotes));
  }

  /// The shops table changed shape in schema 6: identity moved from the
  /// exact seller-name string to the VAT number. Old rows are derived data
  /// (rebuildable from invoices), so only their notes need carrying over;
  /// the table is dropped and recreated, then [_syncShops] repopulates it.
  Future<Map<String, String>> _migrateShopsTable(
    DatabaseExecutor database,
  ) async {
    final columns = await database.rawQuery('PRAGMA table_info(shops)');
    if (columns.isEmpty) {
      await database.execute(_createShopsTableSql);
      return const {};
    }
    final isNewSchema = columns.any((row) => row['name'] == 'display_name');
    if (isNewSchema) return const {};

    final legacyRows = await database.query('shops');
    await database.execute('DROP TABLE shops');
    await database.execute(_createShopsTableSql);
    return {
      for (final row in legacyRows)
        ((row['seller_name'] as String?) ?? '').trim():
            ((row['note'] as String?) ?? '').trim(),
    };
  }

  static const String _createShopsTableSql = '''
    CREATE TABLE IF NOT EXISTS shops (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      vat_number TEXT UNIQUE,
      name_ar TEXT NOT NULL DEFAULT '',
      name_en TEXT NOT NULL DEFAULT '',
      display_name TEXT NOT NULL DEFAULT '',
      note TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL
    )
  ''';

  Database get _db {
    final database = _database;
    if (database == null) {
      throw StateError('Database is not initialized');
    }
    return database;
  }

  Future<List<Invoice>> getInvoices({String? search}) async {
    final rows = await _db.query(
      'invoices',
      where: search == null || search.trim().isEmpty
          ? null
          : 'seller_name LIKE ? OR seller_name_en LIKE ? OR vat_number LIKE ? OR invoice_number LIKE ?',
      whereArgs: search == null || search.trim().isEmpty
          ? null
          : List.filled(4, '%${search.trim()}%'),
      orderBy: 'issued_at DESC, id DESC',
    );
    return rows.map(Invoice.fromMap).toList();
  }

  Future<List<Shop>> getShops() async {
    final rows = await _db.query('shops');
    final invoices = await getInvoices();
    final shops = <Shop>[];
    for (final row in rows) {
      final vat = ((row['vat_number'] as String?) ?? '').trim();
      final nameAr = ((row['name_ar'] as String?) ?? '').trim();
      final shopInvoices = invoices.where((invoice) {
        final invoiceVat = invoice.vatNumber.trim();
        if (vat.isNotEmpty) return invoiceVat == vat;
        return invoiceVat.isEmpty && invoice.sellerName.trim() == nameAr;
      }).toList()
        ..sort((a, b) {
          final date = a.issuedAt.compareTo(b.issuedAt);
          return date == 0 ? (a.id ?? 0).compareTo(b.id ?? 0) : date;
        });
      if (shopInvoices.isEmpty) continue;
      shops.add(
        Shop(
          id: row['id'] as int,
          nameAr: nameAr,
          nameEn: ((row['name_en'] as String?) ?? '').trim(),
          displayName: ((row['display_name'] as String?) ?? '').trim(),
          vatNumber: vat,
          note: ((row['note'] as String?) ?? '').trim(),
          invoices: shopInvoices,
        ),
      );
    }
    shops.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return shops;
  }

  Future<int> insertInvoice(Invoice invoice) async {
    return _db.transaction((transaction) async {
      final row = _normalizedInvoiceRow(invoice);
      final id = await transaction.insert(
        'invoices',
        row,
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      await _upsertShop(transaction, row: row);
      return id;
    });
  }

  Future<void> updateInvoice(Invoice invoice) async {
    await _db.transaction((transaction) async {
      final row = _normalizedInvoiceRow(invoice);
      await transaction.update(
        'invoices',
        row,
        where: 'id = ?',
        whereArgs: [invoice.id],
      );
      // Re-linking by the invoice's own VAT number/name automatically moves
      // it between shops; pruning then removes a shop left without invoices.
      await _upsertShop(transaction, row: row);
      await _pruneOrphanShops(transaction);
    });
  }

  Future<void> deleteInvoice(int id) async {
    final rows = await _db.query(
      'invoices',
      columns: ['image_path'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final imagePath = rows.isEmpty ? null : rows.first['image_path'] as String?;
    if (imagePath != null && imagePath.isNotEmpty) {
      try {
        await File(imagePath).delete();
      } catch (_) {
        // The database row should still be deleted if the image is already gone.
      }
    }
    await _db.transaction((transaction) async {
      await transaction.delete('invoices', where: 'id = ?', whereArgs: [id]);
      await _pruneOrphanShops(transaction);
    });
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    await database?.close();
  }

  Future<void> updateShopProfile({
    required int shopId,
    String? displayName,
    String? note,
  }) async {
    final updates = <String, Object?>{
      if (displayName != null) 'display_name': displayName.trim(),
      if (note != null) 'note': note.trim(),
    };
    if (updates.isEmpty) return;
    await _db.update('shops', updates, where: 'id = ?', whereArgs: [shopId]);
  }

  Future<String?> getSetting(String key) async {
    final rows = await _db.query(
      'settings',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) async {
    await _db.insert('settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String> createBackupJson() async {
    final invoices = await getInvoices();
    final shops = await _db.query('shops');
    return jsonEncode({
      'schemaVersion': _schemaVersion,
      'createdAt': DateTime.now().toIso8601String(),
      'invoices': invoices.map((invoice) => invoice.toMap()).toList(),
      'shops': shops,
    });
  }

  Future<void> restoreBackupJson(String value) async {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic> || decoded['invoices'] is! List) {
      throw const FormatException('Invalid backup format');
    }
    final invoiceMaps = (decoded['invoices'] as List)
        .whereType<Map>()
        .map((row) => Map<String, Object?>.from(row))
        .map(Invoice.fromMap)
        .toList();
    final shopMaps = (decoded['shops'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, Object?>.from(row))
        .map(_shopCarryFromMap)
        .whereType<_ShopCarry>()
        .toList();

    await _db.transaction((transaction) async {
      await transaction.delete('invoices');
      await transaction.delete('shops');
      for (final invoice in invoiceMaps) {
        await transaction.insert('invoices', invoice.toMap()..remove('id'));
      }
      await _syncShops(transaction, carryOver: shopMaps);
    });
  }

  /// Backups may contain pre-6 shops (keyed by `seller_name`) or current
  /// ones (keyed by VAT); both are turned into carry-over records so the
  /// user's notes and custom names survive a restore.
  static _ShopCarry? _shopCarryFromMap(Map<String, Object?> row) {
    final sellerName = row['seller_name'];
    final nameAr = row['name_ar'];
    final note = ((row['note'] as String?) ?? '').trim();
    if (sellerName is String && sellerName.trim().isNotEmpty) {
      return _ShopCarry(
        vat: ((row['vat_number'] as String?) ?? '').trim(),
        nameAr: sellerName.trim(),
        note: note,
      );
    }
    if (nameAr is String && nameAr.trim().isNotEmpty) {
      return _ShopCarry(
        vat: ((row['vat_number'] as String?) ?? '').trim(),
        nameAr: nameAr.trim(),
        note: note,
        displayName: ((row['display_name'] as String?) ?? '').trim(),
      );
    }
    return null;
  }

  static List<_ShopCarry> _carryOverFromNotes(Map<String, String> notes) =>
      notes.entries
          .where((entry) => entry.key.isNotEmpty)
          .map((entry) => _ShopCarry(nameAr: entry.key, note: entry.value))
          .toList();

  /// Rebuilds the shops table from the invoices. Shops are identified by
  /// their VAT number; invoices without one fall back to the exact seller
  /// name. Mixed-script seller names are separated here too, so data saved
  /// by older versions (or typed manually) is cleaned up on open.
  Future<void> _syncShops(
    DatabaseExecutor database, {
    List<_ShopCarry> carryOver = const [],
  }) async {
    final rows = await database.query('invoices', orderBy: 'id');
    final seeds = <String, _ShopSeed>{};
    for (final row in rows) {
      final invoice = Invoice.fromMap(Map<String, Object?>.from(row));
      final originalName = invoice.sellerName.trim();
      final originalEnglish = invoice.sellerNameEn.trim();
      var (nameAr, nameEn) = _separateNames(originalName, originalEnglish);
      if (nameAr != originalName || nameEn != originalEnglish) {
        await database.update(
          'invoices',
          {'seller_name': nameAr, 'seller_name_en': nameEn},
          where: 'id = ?',
          whereArgs: [invoice.id],
        );
      }

      final vat = invoice.vatNumber.trim();
      if (nameEn.isEmpty &&
          nameAr.isNotEmpty &&
          !SellerNameSplitter.containsArabic(nameAr)) {
        // A Latin-only seller name doubles as the shop's English name.
        nameEn = nameAr;
      }
      final key = vat.isNotEmpty ? 'v:$vat' : 'n:$nameAr';
      final seed = seeds.putIfAbsent(
        key,
        () => _ShopSeed(vatNumber: vat, nameAr: nameAr),
      );
      if (nameEn.isNotEmpty && seed.nameEn.isEmpty) seed.nameEn = nameEn;
      seed.legacyName ??= originalName;
    }

    for (final seed in seeds.values) {
      final carry = _carryFor(seed, carryOver);
      final existing = await _findShopRow(database, seed);
      if (existing == null) {
        await database.insert('shops', {
          'vat_number': seed.vatNumber.isEmpty ? null : seed.vatNumber,
          'name_ar': seed.nameAr,
          'name_en': seed.nameEn == seed.nameAr ? '' : seed.nameEn,
          'display_name': carry?.displayName ?? '',
          'note': carry?.note ?? '',
          'created_at': DateTime.now().toIso8601String(),
        });
        continue;
      }
      final shopId = existing['id'] as int;
      final existingNameAr = ((existing['name_ar'] as String?) ?? '').trim();
      if (seed.nameEn.isNotEmpty &&
          seed.nameEn != existingNameAr &&
          ((existing['name_en'] as String?) ?? '').trim().isEmpty) {
        await database.update(
          'shops',
          {'name_en': seed.nameEn},
          where: 'id = ?',
          whereArgs: [shopId],
        );
      }
      if (seed.nameAr.isNotEmpty && existingNameAr.isEmpty) {
        await database.update(
          'shops',
          {'name_ar': seed.nameAr},
          where: 'id = ?',
          whereArgs: [shopId],
        );
      }
    }

    await _pruneOrphanShops(database);
  }

  static _ShopCarry? _carryFor(_ShopSeed seed, List<_ShopCarry> carryOver) {
    if (seed.vatNumber.isNotEmpty) {
      for (final carry in carryOver) {
        if (carry.vat.isNotEmpty && carry.vat == seed.vatNumber) return carry;
      }
    }
    final legacyName = seed.legacyName;
    for (final carry in carryOver) {
      if (carry.vat.isEmpty &&
          (carry.nameAr == seed.nameAr ||
              (legacyName != null && carry.nameAr == legacyName))) {
        return carry;
      }
    }
    return null;
  }

  Future<Map<String, Object?>?> _findShopRow(
    DatabaseExecutor database,
    _ShopSeed seed,
  ) async {
    if (seed.vatNumber.isNotEmpty) {
      final rows = await database.query(
        'shops',
        where: 'vat_number = ?',
        whereArgs: [seed.vatNumber],
        limit: 1,
      );
      return rows.isEmpty ? null : rows.first;
    }
    final rows = await database.query(
      'shops',
      where: 'vat_number IS NULL AND name_ar = ?',
      whereArgs: [seed.nameAr],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Separates a mixed-script seller name into its Arabic and English
  /// parts. An English name provided by the user always wins over the
  /// automatically extracted one.
  static (String, String) _separateNames(String name, String english) {
    if (!SellerNameSplitter.isMixedScript(name)) {
      return (name, english);
    }
    final parts = SellerNameSplitter.split(name);
    return (
      parts.arabic.isNotEmpty ? parts.arabic : name,
      english.isNotEmpty ? english : parts.english,
    );
  }

  /// The invoice's database row with a mixed-script seller name already
  /// separated, so combined names are never stored from any source.
  static Map<String, Object?> _normalizedInvoiceRow(Invoice invoice) {
    final row = invoice.toMap()..remove('id');
    final (name, english) = _separateNames(
      (row['seller_name'] as String?)?.trim() ?? '',
      ((row['seller_name_en'] as String?) ?? '').trim(),
    );
    row['seller_name'] = name;
    row['seller_name_en'] = english;
    return row;
  }

  /// Links the invoice to its shop: the VAT number is the shop identity
  /// when present; invoices without one fall back to the exact seller name.
  /// Only missing shop fields are filled, so user edits on the shop survive.
  Future<void> _upsertShop(
    DatabaseExecutor executor, {
    required Map<String, Object?> row,
  }) async {
    final nameAr = ((row['seller_name'] as String?) ?? '').trim();
    var nameEn = ((row['seller_name_en'] as String?) ?? '').trim();
    final vat = ((row['vat_number'] as String?) ?? '').trim();
    if (nameEn.isEmpty &&
        nameAr.isNotEmpty &&
        !SellerNameSplitter.containsArabic(nameAr)) {
      // A Latin-only seller name doubles as the shop's English name.
      nameEn = nameAr;
    }
    if (nameAr.isEmpty && nameEn.isEmpty && vat.isEmpty) return;

    final existing = await _findShopRow(
      executor,
      _ShopSeed(vatNumber: vat, nameAr: nameAr),
    );
    if (existing == null) {
      await executor.insert('shops', {
        'vat_number': vat.isEmpty ? null : vat,
        'name_ar': nameAr,
        'name_en': nameEn == nameAr ? '' : nameEn,
        'display_name': '',
        'note': '',
        'created_at': DateTime.now().toIso8601String(),
      });
      return;
    }
    final shopId = existing['id'] as int;
    final existingNameAr = ((existing['name_ar'] as String?) ?? '').trim();
    final fillNameEn = nameEn.isNotEmpty &&
        nameEn != existingNameAr &&
        ((existing['name_en'] as String?) ?? '').trim().isEmpty;
    if (fillNameEn) {
      await executor.update(
        'shops',
        {'name_en': nameEn},
        where: 'id = ?',
        whereArgs: [shopId],
      );
    }
    if (nameAr.isNotEmpty && existingNameAr.isEmpty) {
      await executor.update(
        'shops',
        {'name_ar': nameAr},
        where: 'id = ?',
        whereArgs: [shopId],
      );
    }
  }

  Future<void> _pruneOrphanShops(DatabaseExecutor database) async {
    await database.rawDelete('''
      DELETE FROM shops WHERE NOT EXISTS (
        SELECT 1 FROM invoices i WHERE
          (shops.vat_number IS NOT NULL AND i.vat_number = shops.vat_number)
          OR (
            shops.vat_number IS NULL
            AND i.vat_number = ''
            AND i.seller_name = shops.name_ar
          )
      )
    ''');
  }
}

/// Invoice data used to create or complete one shop row while syncing.
class _ShopSeed {
  _ShopSeed({required this.vatNumber, required this.nameAr});

  final String vatNumber;
  final String nameAr;
  String nameEn = '';

  /// The seller name as stored before this sync, used to match notes from
  /// the pre-6 shops table that were keyed by the (possibly combined) name.
  String? legacyName;
}

/// Shop metadata carried over a migration or restore, matched either by
/// VAT number or, for VAT-less shops, by the exact seller name.
class _ShopCarry {
  _ShopCarry({
    this.vat = '',
    required this.nameAr,
    this.note = '',
    this.displayName = '',
  });

  final String vat;
  final String nameAr;
  final String note;
  final String displayName;
}
