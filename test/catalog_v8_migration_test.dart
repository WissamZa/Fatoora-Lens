import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/data/database_service.dart';
import 'package:fatoora_lens/models/payment_method.dart';
import 'package:fatoora_lens/models/shop_category.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Creates a database file with the exact schema-7 layout (no v8 catalog
/// tables, no v8 columns) and version 7, as stored by v1.1.x releases.
Future<String> _createV7Database(String directoryPath) async {
  final path = '$directoryPath/zakat_invoices.db';
  final database = await databaseFactoryFfi.openDatabase(path);
  await database.execute('''
    CREATE TABLE invoices (
      id TEXT PRIMARY KEY,
      device_id TEXT NOT NULL DEFAULT '',
      seller_name TEXT NOT NULL,
      seller_name_en TEXT NOT NULL DEFAULT '',
      vat_number TEXT NOT NULL DEFAULT '',
      issued_at TEXT NOT NULL,
      total_amount REAL NOT NULL,
      vat_amount REAL NOT NULL,
      raw_payload TEXT NOT NULL,
      payload_sha256 TEXT NOT NULL DEFAULT '',
      invoice_number TEXT NOT NULL DEFAULT '',
      note TEXT NOT NULL DEFAULT '',
      image_path TEXT,
      image_sha256 TEXT,
      updated_at INTEGER NOT NULL DEFAULT 0,
      is_synced INTEGER NOT NULL DEFAULT 0,
      is_deleted INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL
    )
  ''');
  await database.execute('''
    CREATE TABLE shops (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      vat_number TEXT UNIQUE,
      name_ar TEXT NOT NULL DEFAULT '',
      name_en TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL
    )
  ''');
  await database.execute('''
    CREATE TABLE shop_profiles (
      key TEXT PRIMARY KEY,
      name_ar TEXT NOT NULL DEFAULT '',
      name_en TEXT NOT NULL DEFAULT '',
      display_name TEXT NOT NULL DEFAULT '',
      note TEXT NOT NULL DEFAULT '',
      updated_at INTEGER NOT NULL DEFAULT 0,
      is_synced INTEGER NOT NULL DEFAULT 0,
      is_deleted INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await database.execute('''
    CREATE TABLE settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');

  await database.insert('invoices', {
    'id': '11111111-2222-3333-4444-555555555555',
    'device_id': 'legacy-device',
    'seller_name': 'سوبرماركت النخبة',
    'seller_name_en': 'Elite Supermarket',
    'vat_number': '300111222333003',
    'issued_at': '2026-08-15T18:30:00.000',
    'total_amount': 230.0,
    'vat_amount': 30.0,
    'raw_payload': 'v7-payload',
    'payload_sha256': 'hash-v7-payload',
    'invoice_number': 'INV-7',
    'note': 'مشتريات الشهر',
    'updated_at': 1000,
    'is_synced': 0,
    'is_deleted': 0,
    'created_at': '2026-08-15T18:31:00.000',
  });
  await database.insert('shop_profiles', {
    'key': 'v:300111222333003',
    'name_ar': 'سوبرماركت النخبة',
    'display_name': 'النخبة',
    'note': 'بقالة العائلة',
    'updated_at': 900,
    'is_synced': 0,
    'is_deleted': 0,
  });

  await database.setVersion(7);
  await database.close();
  return path;
}

void main() {
  test('upgrades v7 to v8 keeping every row, adding catalog tables and seeds',
      () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('fatoora_v8_');
    try {
      final path = await _createV7Database(directory.path);
      final database = DatabaseService(
        databasePath: path,
        databaseFactory: databaseFactoryFfi,
      );
      await database.initialize();

      // The v7 invoice row survives untouched, including its id.
      final invoices = await database.getInvoices();
      expect(invoices, hasLength(1));
      final invoice = invoices.single;
      expect(invoice.id, '11111111-2222-3333-4444-555555555555');
      expect(invoice.sellerName, 'سوبرماركت النخبة');
      expect(invoice.sellerNameEn, 'Elite Supermarket');
      expect(invoice.note, 'مشتريات الشهر');
      expect(invoice.totalAmount, 230.0);
      expect(invoice.createdAt, DateTime.parse('2026-08-15T18:31:00.000'));

      // The v8 columns exist and are empty for the legacy row.
      final columns = await database.syncDatabase
          .rawQuery('PRAGMA table_info(invoices)');
      final names = columns.map((row) => row['name']).toSet();
      expect(names, containsAll(['payment_method_id', 'card_id', 'card_last4']));
      expect(invoice.paymentMethodId, isNull);
      expect(invoice.cardId, isNull);

      // The shop profile survives, gains category support, and the seeds
      // are installed on first open.
      final profiles =
          await database.syncDatabase.query('shop_profiles');
      expect(profiles, hasLength(1));
      expect(profiles.single['display_name'], 'النخبة');
      expect(profiles.single['note'], 'بقالة العائلة');
      final profileColumns = await database.syncDatabase
          .rawQuery('PRAGMA table_info(shop_profiles)');
      expect(
        profileColumns.map((row) => row['name']),
        contains('category_id'),
      );

      final categories = await database.getShopCategories();
      expect(categories.map((c) => c.id),
          containsAll(ShopCategory.seedIds));
      expect(categories.map((c) => c.name), contains('سوبرماركت'));
      expect(categories.map((c) => c.name), contains('حلاق'));
      expect(categories.map((c) => c.name), contains('مكتبة'));

      final methods = await database.getPaymentMethods();
      expect(methods.map((m) => m.id), containsAll(PaymentMethod.seedIds));
      final mada = methods.singleWhere((m) => m.name == 'شبكة');
      expect(mada.requiresCard, isTrue);
      final cash = methods.singleWhere((m) => m.name == 'نقدي');
      expect(cash.requiresCard, isFalse);

      // Shops derived from the legacy invoice keep working.
      final shops = await database.getShops();
      expect(shops.single.nameAr, 'سوبرماركت النخبة');

      await database.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('seeds deleted locally stay deleted across a reopen', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('fatoora_seed_');
    final database = DatabaseService(
      databasePath: '${directory.path}/database.db',
      databaseFactory: databaseFactoryFfi,
    );
    try {
      await database.initialize();
      final barber = (await database.getShopCategories())
          .singleWhere((category) => category.name == 'حلاق');
      await database.deleteShopCategory(barber.id);

      // Reopen: the seed must not resurrect.
      await database.close();
      final reopened = DatabaseService(
        databasePath: '${directory.path}/database.db',
        databaseFactory: databaseFactoryFfi,
      );
      await reopened.initialize();
      final names =
          (await reopened.getShopCategories()).map((category) => category.name);
      expect(names, isNot(contains('حلاق')));
      expect(names, contains('مكتبة'));
      await reopened.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
