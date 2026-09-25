import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/data/database_service.dart';
import 'package:fatoora_lens/models/invoice.dart';
import 'package:fatoora_lens/models/shop.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Creates a database file with the pre-6 schema (shops keyed by the exact
/// seller name) and version 5, as stored by older releases.
Future<String> _createLegacyDatabase(String directoryPath) async {
  final path = '$directoryPath/zakat_invoices.db';
  final database = await databaseFactoryFfi.openDatabase(path);
  await database.execute('''
    CREATE TABLE invoices (
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

  var sequence = 0;
  Future<void> insertInvoice(Map<String, Object?> values) {
    sequence++;
    return database.insert(
      'invoices',
      {
        'issued_at': '2026-09-01T10:00:00.000',
        'total_amount': 115.0,
        'vat_amount': 15.0,
        'raw_payload': 'payload',
        'created_at': '2026-09-01T10:00:0$sequence.000',
      }..addAll(values),
    );
  }

  // Same shop, two different seller-name spellings sharing one VAT number.
  await insertInvoice({
    'seller_name': 'شركة بندة للتجزئة\nPanda Retail Company',
    'vat_number': '300056521610003',
  });
  await insertInvoice({
    'seller_name': 'Panda',
    'seller_name_en': 'Panda Retail Co.',
    'vat_number': '300056521610003',
  });
  // A shop without a VAT number falls back to name identity.
  await insertInvoice({
    'seller_name': 'محل بلا رقم ضريبي',
    'vat_number': '',
  });

  await database.insert('shops', {
    'seller_name': 'شركة بندة للتجزئة\nPanda Retail Company',
    'vat_number': '300056521610003',
    'note': 'ملاحظة البندة',
    'created_at': '2026-09-01T10:00:00.000',
  });
  await database.insert('shops', {
    'seller_name': 'Panda',
    'vat_number': '300056521610003',
    'note': '',
    'created_at': '2026-09-01T10:00:00.000',
  });
  await database.insert('shops', {
    'seller_name': 'محل بلا رقم ضريبي',
    'vat_number': '',
    'note': 'ملاحظة المحل الثاني',
    'created_at': '2026-09-01T10:00:00.000',
  });

  await database.setVersion(5);
  await database.close();
  return path;
}

void main() {
  test('migrates v5 data: VAT becomes the shop identity and names are split',
      () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('fatoora_migration_');
    try {
      final path = await _createLegacyDatabase(directory.path);
      final database = DatabaseService(
        databasePath: path,
        databaseFactory: databaseFactoryFfi,
      );
      await database.initialize();

      // The combined tag-1 name is separated into its two fields, and the
      // integer id is replaced by a generated UUID.
      final invoices = await database.getInvoices();
      final pandaArabic = invoices.singleWhere(
        (invoice) => invoice.sellerName == 'شركة بندة للتجزئة',
      );
      expect(pandaArabic.id, isA<String>());
      expect(pandaArabic.id!.length, greaterThan(30));
      expect(pandaArabic.deviceId, isNotEmpty);
      expect(pandaArabic.payloadSha256, isNotEmpty);
      expect(pandaArabic.isSynced, isFalse);
      expect(pandaArabic.sellerNameEn, 'Panda Retail Company');
      final pandaLatin = invoices.singleWhere(
        (invoice) => invoice.sellerName == 'Panda',
      );
      expect(pandaLatin.sellerName, 'Panda');
      expect(pandaLatin.sellerNameEn, 'Panda Retail Co.');

      // Both spellings merge into one shop keyed by the VAT number, with
      // the legacy note and the English name carried over.
      final shops = await database.getShops();
      expect(shops.length, 2);
      final pandaShop = shops.singleWhere(
        (shop) => shop.vatNumber == '300056521610003',
      );
      expect(pandaShop.invoices.length, 2);
      expect(pandaShop.nameAr, 'شركة بندة للتجزئة');
      expect(pandaShop.nameEn, 'Panda Retail Company');
      expect(pandaShop.note, 'ملاحظة البندة');

      // Shops without a VAT number keep grouping by name.
      final nameShop = shops.singleWhere((shop) => shop.vatNumber.isEmpty);
      expect(nameShop.nameAr, 'محل بلا رقم ضريبي');
      expect(nameShop.invoices.length, 1);
      expect(nameShop.note, 'ملاحظة المحل الثاني');

      await database.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('invoices sharing a VAT number form one shop', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('fatoora_vat_');
    final database = DatabaseService(
      databasePath: '${directory.path}/database.db',
      databaseFactory: databaseFactoryFfi,
    );
    try {
      await database.initialize();

      Invoice invoice(String name, String vat, DateTime date) => Invoice(
            sellerName: name,
            vatNumber: vat,
            issuedAt: date,
            totalAmount: 100,
            vatAmount: 15,
            rawPayload: 'payload',
          );

      await database.insertInvoice(
        invoice('متجر أول', '300000000000003', DateTime(2026, 1, 1)),
      );
      await database.insertInvoice(
        invoice('Store One', '300000000000003', DateTime(2026, 1, 2)),
      );
      await database.insertInvoice(
        invoice('متجر آخر', '300999999999993', DateTime(2026, 1, 3)),
      );

      final shops = await database.getShops();
      expect(shops.length, 2);
      final merged = shops.singleWhere(
        (shop) => shop.vatNumber == '300000000000003',
      );
      expect(merged.invoices.length, 2);
      expect(merged.nameAr, 'متجر أول');
      expect(merged.nameEn, 'Store One');
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });

  test('custom display name overrides the QR name everywhere', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('fatoora_name_');
    final database = DatabaseService(
      databasePath: '${directory.path}/database.db',
      databaseFactory: databaseFactoryFfi,
    );
    try {
      await database.initialize();

      await database.insertInvoice(
        Invoice(
          sellerName: 'شركة بندة للتجزئة',
          sellerNameEn: 'Panda Retail Company',
          vatNumber: '300056521610003',
          issuedAt: DateTime(2026, 2, 1),
          totalAmount: 32.99,
          vatAmount: 4.3,
          rawPayload: 'payload',
        ),
      );

      var shops = await database.getShops();
      expect(shops.single.name, 'شركة بندة للتجزئة');

      await database.updateShopProfile(
        shopId: shops.single.id!,
        displayName: 'بندة',
        note: 'بقالة',
      );

      shops = await database.getShops();
      expect(shops.single.name, 'بندة');
      expect(shops.single.hasCustomName, isTrue);
      expect(shops.single.nameAr, 'شركة بندة للتجزئة');
      expect(shops.single.note, 'بقالة');

      // The custom name is also resolved for the shop's invoices.
      final invoices = await database.getInvoices();
      expect(
        Shop.displayNameForInvoice(shops, invoices.single),
        'بندة',
      );
      expect(
        Shop.displayNameForInvoice(const [], invoices.single),
        isNull,
      );
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });

  test('deleting the last invoice of a shop removes the shop', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('fatoora_prune_');
    final database = DatabaseService(
      databasePath: '${directory.path}/database.db',
      databaseFactory: databaseFactoryFfi,
    );
    try {
      await database.initialize();

      final id = await database.insertInvoice(
        Invoice(
          sellerName: 'محل وحيد',
          vatNumber: '300000000000003',
          issuedAt: DateTime(2026, 3, 1),
          totalAmount: 50,
          vatAmount: 5,
          rawPayload: 'payload',
        ),
      );
      expect((await database.getShops()).length, 1);

      await database.deleteInvoice(id);
      expect(await database.getShops(), isEmpty);
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });
}
