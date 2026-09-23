import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/invoice.dart';
import '../models/shop.dart';

class DatabaseService {
  DatabaseService({this.databasePath, this.databaseFactory});

  final String? databasePath;
  final DatabaseFactory? databaseFactory;
  Database? _database;

  Future<void> initialize() async {
    if (_database != null) return;

    final directory = databasePath == null
        ? await getApplicationDocumentsDirectory()
        : null;
    final path = databasePath ?? '${directory!.path}/zakat_invoices.db';
    try {
      final options = OpenDatabaseOptions(
        version: 4,
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
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_invoices_seller ON invoices(seller_name)',
    );
    await database.execute('''
      CREATE TABLE IF NOT EXISTS shops (
        seller_name TEXT PRIMARY KEY,
        vat_number TEXT NOT NULL DEFAULT '',
        note TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    final invoices = await database.query('invoices');
    for (final row in invoices) {
      await _upsertShop(
        database,
        sellerName: row['seller_name'] as String,
        vatNumber: (row['vat_number'] as String?) ?? '',
      );
    }
  }

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
          : 'seller_name LIKE ? OR vat_number LIKE ?',
      whereArgs: search == null || search.trim().isEmpty
          ? null
          : ['%${search.trim()}%', '%${search.trim()}%'],
      orderBy: 'issued_at DESC, id DESC',
    );
    return rows.map(Invoice.fromMap).toList();
  }

  Future<List<Shop>> getShops() async {
    final rows = await _db.query(
      'shops',
      orderBy: 'seller_name COLLATE NOCASE',
    );
    final invoices = await getInvoices();
    return rows.map((row) {
      final name = row['seller_name'] as String;
      final shopInvoices =
          invoices.where((invoice) => invoice.sellerName == name).toList()
            ..sort((a, b) {
              final date = a.issuedAt.compareTo(b.issuedAt);
              return date == 0 ? (a.id ?? 0).compareTo(b.id ?? 0) : date;
            });
      return Shop(
        name: name,
        vatNumber: (row['vat_number'] as String?) ?? '',
        note: (row['note'] as String?) ?? '',
        invoices: shopInvoices,
      );
    }).toList();
  }

  Future<int> insertInvoice(Invoice invoice) async {
    return _db.transaction((transaction) async {
      final id = await transaction.insert(
        'invoices',
        invoice.toMap()..remove('id'),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      await _upsertShop(
        transaction,
        sellerName: invoice.sellerName,
        vatNumber: invoice.vatNumber,
      );
      return id;
    });
  }

  Future<void> updateInvoice(Invoice invoice) async {
    await _db.transaction((transaction) async {
      final previous = await transaction.query(
        'invoices',
        columns: ['seller_name'],
        where: 'id = ?',
        whereArgs: [invoice.id],
        limit: 1,
      );
      final oldSeller = previous.isEmpty
          ? null
          : previous.first['seller_name'] as String?;
      await transaction.update(
        'invoices',
        invoice.toMap()..remove('id'),
        where: 'id = ?',
        whereArgs: [invoice.id],
      );
      await _upsertShop(
        transaction,
        sellerName: invoice.sellerName,
        vatNumber: invoice.vatNumber,
      );
      if (oldSeller != null && oldSeller != invoice.sellerName) {
        await transaction.rawDelete(
          'DELETE FROM shops WHERE seller_name = ? AND NOT EXISTS (SELECT 1 FROM invoices WHERE seller_name = ?)',
          [oldSeller, oldSeller],
        );
      }
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
    await _db.delete('invoices', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    await database?.close();
  }

  Future<void> updateShopNote(String sellerName, String note) async {
    await _db.update(
      'shops',
      {'note': note.trim()},
      where: 'seller_name = ?',
      whereArgs: [sellerName],
    );
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
      'schemaVersion': 4,
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
        .toList();

    await _db.transaction((transaction) async {
      await transaction.delete('invoices');
      await transaction.delete('shops');
      for (final invoice in invoiceMaps) {
        await transaction.insert('invoices', invoice.toMap()..remove('id'));
      }
      for (final shop in shopMaps) {
        await transaction.insert('shops', {
          'seller_name': shop['seller_name'],
          'vat_number': shop['vat_number'] ?? '',
          'note': shop['note'] ?? '',
          'created_at': shop['created_at'] ?? DateTime.now().toIso8601String(),
        });
      }
      for (final invoice in invoiceMaps) {
        await _upsertShop(
          transaction,
          sellerName: invoice.sellerName,
          vatNumber: invoice.vatNumber,
        );
      }
    });
  }

  Future<void> _upsertShop(
    DatabaseExecutor executor, {
    required String sellerName,
    required String vatNumber,
  }) async {
    await executor.rawInsert(
      '''INSERT INTO shops (seller_name, vat_number, note, created_at)
         VALUES (?, ?, '', ?)
         ON CONFLICT(seller_name) DO UPDATE SET vat_number = excluded.vat_number''',
      [sellerName, vatNumber, DateTime.now().toIso8601String()],
    );
  }
}
