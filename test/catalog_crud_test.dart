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
    directory = await Directory.systemTemp.createTemp('fatoora_crud_');
    database = DatabaseService(
      databasePath: '${directory.path}/database.db',
      databaseFactory: databaseFactoryFfi,
    );
    await database.initialize();
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  group('shop categories', () {
    test('fresh installs start with the ten seeded categories', () async {
      final categories = await database.getShopCategories();
      expect(categories.length, ShopCategory.seeds.length);
      // Seeds sort first, in their designed order.
      expect(categories.first.name, 'سوبرماركت');
    });

    test('user categories are added, updated and tombstone-deleted',
        () async {
      final category = ShopCategory(id: const Uuid().v4(), name: 'ورشة سيارات');
      await database.upsertShopCategory(category);

      final afterAdd = await database.getShopCategories();
      final added = afterAdd.singleWhere((c) => c.id == category.id);
      expect(added.name, 'ورشة سيارات');
      // Custom rows sort after the seeds.
      expect(
        afterAdd.indexOf(added),
        greaterThan(ShopCategory.seeds.length - 1),
      );

      await database.upsertShopCategory(added.copyWith(name: 'ورشة'));
      final afterUpdate = await database.getShopCategories();
      expect(
        afterUpdate.singleWhere((c) => c.id == category.id).name,
        'ورشة',
      );

      await database.deleteShopCategory(category.id);
      final ids =
          (await database.getShopCategories()).map((c) => c.id);
      expect(ids, isNot(contains(category.id)));

      final rawRow = await database.syncDatabase.query(
        'shop_categories',
        where: 'id = ?',
        whereArgs: [category.id],
      );
      expect(rawRow.single['is_deleted'], 1,
          reason: 'the tombstone stays so it can sync to peers');
    });

    test('assigning a category to a shop stores it on the profile and shows '
        'in getShops; renaming the shop keeps the category', () async {
      final id = await database.insertInvoice(Invoice(
        sellerName: 'مكتبة المعرفة',
        vatNumber: '300999888777003',
        issuedAt: DateTime(2026, 9, 1),
        totalAmount: 85,
        vatAmount: 11.05,
        rawPayload: 'payload',
      ));
      expect(id, isNotEmpty);

      final bookstore = (await database.getShopCategories())
          .singleWhere((category) => category.name == 'مكتبة');
      await database.setShopCategory(
        vatNumber: '300999888777003',
        nameAr: 'مكتبة المعرفة',
        categoryId: bookstore.id,
      );

      var shops = await database.getShops();
      expect(shops.single.categoryId, bookstore.id);

      // The display name edit must not wipe the category.
      await database.updateShopProfile(
        shopId: shops.single.id!,
        displayName: 'المعرفة',
        note: 'كتب وأدوات مدرسية',
      );
      shops = await database.getShops();
      expect(shops.single.categoryId, bookstore.id);
      expect(shops.single.displayName, 'المعرفة');
      expect(shops.single.note, 'كتب وأدوات مدرسية');

      // Clearing the category removes it from the profile.
      await database.setShopCategory(
        vatNumber: '300999888777003',
        nameAr: 'مكتبة المعرفة',
        categoryId: null,
      );
      shops = await database.getShops();
      expect(shops.single.categoryId, isNull);
    });
  });

  group('payment methods and cards', () {
    test('fresh installs start with the five seeded methods', () async {
      final methods = await database.getPaymentMethods();
      expect(methods.length, PaymentMethod.seeds.length);
      expect(methods.first.name, 'نقدي');
      expect(
        methods.where((m) => m.requiresCard).map((m) => m.name),
        unorderedEquals(['شبكة', 'بطاقة ائتمانية']),
      );
    });

    test('user methods round-trip through add/edit/delete', () async {
      final method = PaymentMethod(id: const Uuid().v4(), name: 'أبل باي');
      await database.upsertPaymentMethod(method);
      await database.upsertPaymentMethod(method.copyWith(name: 'Apple Pay'));
      await database.deletePaymentMethod(method.id);

      final names =
          (await database.getPaymentMethods()).map((m) => m.name);
      expect(names, isNot(contains('Apple Pay')));
    });

    test('cards store name, description and last4 only', () async {
      final card = PaymentCard(
        id: const Uuid().v4(),
        name: 'بطاقة الراجحي',
        description: 'بطاقة الراتب',
        last4: '1234',
      );
      await database.upsertPaymentCard(card);

      final cards = await database.getPaymentCards();
      expect(cards.single.name, 'بطاقة الراجحي');
      expect(cards.single.description, 'بطاقة الراتب');
      expect(cards.single.last4, '1234');

      await database.deletePaymentCard(card.id);
      expect(await database.getPaymentCards(), isEmpty);
    });

    test('invoice payment fields round-trip through the database', () async {
      final method = PaymentMethod(id: const Uuid().v4(), name: 'شبكة');
      await database.upsertPaymentMethod(method);
      final card = PaymentCard(
        id: const Uuid().v4(),
        name: 'بطاقة مدى',
        last4: '5678',
      );
      await database.upsertPaymentCard(card);

      final id = await database.insertInvoice(Invoice(
        sellerName: 'سوبرماركت الحي',
        vatNumber: '300555444333003',
        issuedAt: DateTime(2026, 9, 10),
        totalAmount: 115,
        vatAmount: 15,
        rawPayload: 'paid-payload',
        paymentMethodId: method.id,
        cardId: card.id,
        cardLast4: '5678',
      ));
      final stored = (await database.getInvoices()).single;
      expect(stored.id, id);
      expect(stored.paymentMethodId, method.id);
      expect(stored.cardId, card.id);
      expect(stored.cardLast4, '5678');

      // Paying cash later drops the card reference entirely.
      final cash = (await database.getPaymentMethods())
          .singleWhere((m) => m.name == 'نقدي');
      await database.updateInvoice(stored.copyWith(
        paymentMethodId: cash.id,
        clearCard: true,
      ));
      final updated = (await database.getInvoices()).single;
      expect(updated.paymentMethodId, cash.id);
      expect(updated.cardId, isNull);
      expect(updated.cardLast4, isNull);
    });
  });
}
