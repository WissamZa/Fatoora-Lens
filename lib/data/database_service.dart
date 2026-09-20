import 'dart:convert';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/invoice.dart';
import '../models/shop.dart';

class DatabaseService {
  Database? _database;

  Future<void> initialize() async {
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/zakat_invoices.db';
    _database = await openDatabase(
      path,
      version: 2,
      onCreate: (database, version) async => _createSchema(database),
      onUpgrade: (database, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await database.execute("ALTER TABLE invoices ADD COLUMN note TEXT NOT NULL DEFAULT ''");
          await database.execute('''
            CREATE TABLE shops (
              seller_name TEXT PRIMARY KEY,
              vat_number TEXT NOT NULL DEFAULT '',
              note TEXT NOT NULL DEFAULT '',
              created_at TEXT NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE settings (
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
      },
    );
  }

  Future<void> _createSchema(Database database) async {
    await database.execute('''
      CREATE TABLE invoices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        seller_name TEXT NOT NULL,
        vat_number TEXT NOT NULL DEFAULT '',
        issued_at TEXT NOT NULL,
        total_amount REAL NOT NULL,
        vat_amount REAL NOT NULL,
        raw_payload TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL
      )
    ''');
    await database.execute(
      'CREATE INDEX idx_invoices_seller ON invoices(seller_name)',
    );
    await database.execute('''
      CREATE TABLE shops (
        seller_name TEXT PRIMARY KEY,
        vat_number TEXT NOT NULL DEFAULT '',
        note TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  Database get _db => _database!;

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
    final rows = await _db.query('shops', orderBy: 'seller_name COLLATE NOCASE');
    final invoices = await getInvoices();
    return rows.map((row) {
      final name = row['seller_name'] as String;
      final shopInvoices = invoices
          .where((invoice) => invoice.sellerName == name)
          .toList()
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
    await _db.update(
      'invoices',
      invoice.toMap()..remove('id'),
      where: 'id = ?',
      whereArgs: [invoice.id],
    );
    await _upsertShop(
      _db,
      sellerName: invoice.sellerName,
      vatNumber: invoice.vatNumber,
    );
  }

  Future<void> deleteInvoice(int id) async {
    await _db.delete('invoices', where: 'id = ?', whereArgs: [id]);
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
    final rows = await _db.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) async {
    await _db.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String> createBackupJson() async {
    final invoices = await getInvoices();
    final shops = await _db.query('shops');
    return jsonEncode({
      'schemaVersion': 2,
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
