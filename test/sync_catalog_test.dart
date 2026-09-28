import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/data/database_service.dart';
import 'package:fatoora_lens/models/payment_method.dart';
import 'package:fatoora_lens/models/shop_category.dart';
import 'package:fatoora_lens/sync/sync_preferences.dart';
import 'package:fatoora_lens/sync/sync_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'sync_repository_test.dart' show openSyncTestDb;

const _deviceB = 'device-bbbb';

void main() {
  late Directory directory;
  late DatabaseService databaseService;
  late SyncRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fatoora_syncv2_');
    databaseService = await openSyncTestDb(directory);
    repository = SyncRepository(databaseService.syncDatabase);
  });

  tearDown(() async {
    await databaseService.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  group('outbound payload and peer protocol version', () {
    test('legacy peers get v7-shaped rows and no catalog tables', () async {
      await databaseService.upsertPaymentCard(
        PaymentCard(id: const Uuid().v4(), name: 'بطاقة', last4: '1111'),
      );
      await databaseService.setShopCategory(
        vatNumber: '300000000000003',
        nameAr: 'متجر',
        categoryId: ShopCategory.seeds.first.id,
      );

      final payload = await repository.buildOutboundPayload(
        _deviceB,
        const SyncPreferences(),
        peerProto: 1,
      );

      expect(payload.categories, isEmpty);
      expect(payload.paymentMethods, isEmpty);
      expect(payload.cards, isEmpty,
          reason: 'legacy peers would crash on or mis-merge the new tables');
      for (final row in payload.profiles) {
        expect(row.containsKey('category_id'), isFalse,
            reason: 'legacy INSERT would fail on the unknown column');
      }
    });

    test('v2 peers get the full rows and the catalog tables', () async {
      final cardId = const Uuid().v4();
      await databaseService.upsertPaymentCard(
        PaymentCard(id: cardId, name: 'بطاقة', last4: '2222'),
      );
      await databaseService.setShopCategory(
        vatNumber: '300000000000003',
        nameAr: 'متجر',
        categoryId: ShopCategory.seeds.first.id,
      );

      final payload = await repository.buildOutboundPayload(
        _deviceB,
        const SyncPreferences(),
        peerProto: 2,
      );

      // The seeds plus the local writes are all outbound to a v2 peer.
      expect(payload.categories, isNotEmpty);
      expect(payload.paymentMethods, isNotEmpty);
      expect(payload.cards.map((row) => row['id']), contains(cardId));
      expect(
        payload.profiles.single['category_id'],
        ShopCategory.seeds.first.id,
      );
    });

    test('catalog cursors make repeated payloads empty and always ship '
        'tombstones', () async {
      final categoryId = const Uuid().v4();
      await databaseService.upsertShopCategory(
        ShopCategory(id: categoryId, name: 'محل ورد'),
      );

      final first = await repository.buildOutboundPayload(
        _deviceB,
        const SyncPreferences(),
      );
      expect(first.categories.map((row) => row['id']), contains(categoryId));

      // Advance past every stamped row, like the session does after an
      // acknowledged round.
      await repository.advanceCursors(
        _deviceB,
        DateTime.now().millisecondsSinceEpoch + 1,
      );
      final second = await repository.buildOutboundPayload(
        _deviceB,
        const SyncPreferences(),
      );
      expect(second.categories, isEmpty);

      // The tombstone is stamped later than the cursor, so it travels.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await databaseService.deleteShopCategory(categoryId);
      final third = await repository.buildOutboundPayload(
        _deviceB,
        const SyncPreferences(),
      );
      expect(third.categories.map((row) => row['id']), contains(categoryId),
          reason: 'the tombstone must travel so peers delete too');
    });

    test('resetCursors re-sends everything once', () async {
      final categoryId = const Uuid().v4();
      await databaseService.upsertShopCategory(
        ShopCategory(id: categoryId, name: 'ورود'),
      );
      await repository.advanceCursors(
        _deviceB,
        DateTime.now().millisecondsSinceEpoch + 1,
      );
      var payload = await repository.buildOutboundPayload(
        _deviceB,
        const SyncPreferences(),
      );
      expect(payload.categories, isEmpty);

      await repository.resetCursors(_deviceB);
      payload = await repository.buildOutboundPayload(
        _deviceB,
        const SyncPreferences(),
      );
      expect(payload.categories.map((row) => row['id']), contains(categoryId));
    });
  });

  group('inbound catalog merges', () {
    test('applies new rows and ignores malformed ones', () async {
      final result = await repository.mergeShopCategories([
        {
          'id': const Uuid().v4(),
          'name': 'مطاعم بحرية',
          'updated_at': 100,
        },
        {'name': 'no id row', 'updated_at': 100},
        {'id': '', 'updated_at': 100},
      ]);
      expect(result.applied, 1);
      final names =
          (await databaseService.getShopCategories()).map((c) => c.name);
      expect(names, contains('مطاعم بحرية'));
    });

    test('last-write-wins with a device-id tiebreak', () async {
      final id = const Uuid().v4();
      final older = {
        'id': id,
        'name': 'قديم',
        'updated_at': 100,
        'device_id': 'device-aaaa',
      };
      final newer = {
        'id': id,
        'name': 'جديد',
        'updated_at': 200,
        'device_id': 'device-aaaa',
      };

      await repository.mergeShopCategories([older]);
      await repository.mergeShopCategories([newer]);
      var names = (await databaseService.getShopCategories())
          .where((c) => c.id == id)
          .map((c) => c.name);
      expect(names, ['جديد']);

      // Same timestamp: the higher device id wins deterministically.
      final tie = {
        'id': id,
        'name': 'تعادل',
        'updated_at': 200,
        'device_id': 'device-zzzz',
      };
      await repository.mergeShopCategories([tie]);
      names = (await databaseService.getShopCategories())
          .where((c) => c.id == id)
          .map((c) => c.name);
      expect(names, ['تعادل']);
    });

    test('inbound rows are filtered to the local columns', () async {
      final id = const Uuid().v4();
      final result = await repository.mergePaymentCards([
        {
          'id': id,
          'name': 'بطاقة مستقبلية',
          'last4': '3131',
          'updated_at': 100,
          'column_from_the_future': 'x',
        },
      ]);
      expect(result.applied, 1);
      final card = (await databaseService.getPaymentCards())
          .singleWhere((c) => c.id == id);
      expect(card.last4, '3131');
    });

    test('deleted catalog rows arrive as tombstones and stay deleted',
        () async {
      final id = const Uuid().v4();
      await repository.mergePaymentMethods([
        {'id': id, 'name': 'شبكة دولية', 'updated_at': 100, 'device_id': 'd1'},
      ]);
      expect(
        (await databaseService.getPaymentMethods())
            .where((m) => m.id == id),
        hasLength(1),
      );

      final tombstone = {
        'id': id,
        'name': 'شبكة دولية',
        'updated_at': 300,
        'device_id': 'd1',
        'is_deleted': 1,
      };
      await repository.mergePaymentMethods([tombstone]);
      expect(
        (await databaseService.getPaymentMethods())
            .where((m) => m.id == id),
        isEmpty,
      );
      final raw = await databaseService.syncDatabase.query(
        'payment_methods',
        where: 'id = ?',
        whereArgs: [id],
      );
      expect(raw.single['is_deleted'], 1);
    });
  });
}
