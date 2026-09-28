import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/data/database_service.dart';
import 'package:fatoora_lens/models/invoice.dart';
import 'package:fatoora_lens/models/payment_method.dart';
import 'package:fatoora_lens/models/shop_category.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

void main() {
  late Directory directory;
  late DatabaseService database;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fatoora_bkp8_');
    database = DatabaseService(
      databasePath: '${directory.path}/source.db',
      databaseFactory: databaseFactoryFfi,
    );
    await database.initialize();
  });

  tearDown(() async {
    await database.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  test('backup and restore round-trips invoices, profiles and the catalog',
      () async {
    final category = ShopCategory(id: const Uuid().v4(), name: 'مغسلة سيارات');
    await database.upsertShopCategory(category);
    final method = PaymentMethod(
      id: const Uuid().v4(),
      name: 'شبكة',
      requiresCard: true,
    );
    await database.upsertPaymentMethod(method);
    final card = PaymentCard(
      id: const Uuid().v4(),
      name: 'بطاقة الراجحي',
      description: 'الراتب',
      last4: '4321',
    );
    await database.upsertPaymentCard(card);

    await database.insertInvoice(Invoice(
      sellerName: 'سوبرماركت الحي',
      vatNumber: '300555444333003',
      issuedAt: DateTime(2026, 9, 12),
      totalAmount: 92,
      vatAmount: 12,
      rawPayload: 'backup-payload',
      paymentMethodId: method.id,
      cardId: card.id,
      cardLast4: '4321',
    ));
    await database.setShopCategory(
      vatNumber: '300555444333003',
      nameAr: 'سوبرماركت الحي',
      categoryId: category.id,
    );

    final json = await database.createBackupJson();
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    expect(decoded['schemaVersion'], 8);
    expect(decoded['shopCategories'], isA<List>());
    expect(decoded['paymentMethods'], isA<List>());
    expect(decoded['paymentCards'], isA<List>());

    // Restore into a fresh database.
    final targetDirectory = await Directory.systemTemp.createTemp('fatoora_rst8_');
    final target = DatabaseService(
      databasePath: '${targetDirectory.path}/target.db',
      databaseFactory: databaseFactoryFfi,
    );
    try {
      await target.initialize();
      await target.restoreBackupJson(json);

      final invoices = await target.getInvoices();
      expect(invoices.single.paymentMethodId, method.id);
      expect(invoices.single.cardId, card.id);
      expect(invoices.single.cardLast4, '4321');

      final shops = await target.getShops();
      expect(shops.single.categoryId, category.id);

      final categories = await target.getShopCategories();
      expect(
        categories.map((c) => c.id),
        contains(category.id),
        reason: 'the user category from the backup is restored',
      );
      final methods = await target.getPaymentMethods();
      expect(methods.map((m) => m.name), contains('شبكة'));
      final cards = await target.getPaymentCards();
      expect(cards.single.last4, '4321');
    } finally {
      await target.close();
      await targetDirectory.delete(recursive: true);
    }
  });

  test('restoring a v7 backup (no catalog sections) keeps the local catalog',
      () async {
    await database.upsertPaymentCard(PaymentCard(
      id: const Uuid().v4(),
      name: 'بطاقة قديمة',
      last4: '9999',
    ));

    // Build a v7-style backup: invoices/shopProfiles only.
    final invoice = Invoice(
      sellerName: 'محل قديم',
      vatNumber: '300777666555003',
      issuedAt: DateTime(2026, 5, 1),
      totalAmount: 60,
      vatAmount: 9,
      rawPayload: 'v7-backup-payload',
    );
    final v7Backup = jsonEncode({
      'schemaVersion': 7,
      'createdAt': DateTime.now().toIso8601String(),
      'invoices': [invoice.toMap()],
      'shopProfiles': <Object?>[],
      'media': <Object?>[],
      'settings': <Object?>[],
    });

    await database.restoreBackupJson(v7Backup);
    expect((await database.getInvoices()).single.sellerName, 'محل قديم');
    final cards = await database.getPaymentCards();
    expect(cards.map((c) => c.name), contains('بطاقة قديمة'),
        reason: 'a legacy backup must not wipe the v8 catalog');
  });
}
