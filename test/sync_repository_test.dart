import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/data/database_service.dart';
import 'package:fatoora_lens/models/invoice.dart';
import 'package:fatoora_lens/sync/sync_preferences.dart';
import 'package:fatoora_lens/sync/sync_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _deviceA = 'device-aaaa';
const _deviceB = 'device-bbbb';

Invoice _row({
  required String id,
  required String deviceId,
  required int updatedAt,
  String name = 'متجر الأصيل',
  String payload = 'raw-payload',
  bool deleted = false,
  String? imageSha,
  DateTime? issuedAt,
}) => Invoice(
      id: id,
      deviceId: deviceId,
      sellerName: name,
      sellerNameEn: 'Al Aseel Store',
      vatNumber: '300000000000003',
      issuedAt: issuedAt ?? DateTime(2026, 9, 1),
      totalAmount: 115,
      vatAmount: 15,
      rawPayload: payload,
      payloadSha256: payload.isEmpty
          ? ''
          : crypto.sha256.convert(utf8.encode(payload)).toString(),
      updatedAt: updatedAt,
      isSynced: true,
      isDeleted: deleted,
      imageSha256: imageSha,
    );

Future<DatabaseService> openSyncTestDb(Directory dir) async {
  final database = DatabaseService(
    databasePath: '${dir.path}/database.db',
    databaseFactory: databaseFactoryFfi,
  );
  await database.initialize();
  return database;
}

void main() {
  late Directory directory;
  late DatabaseService databaseService;
  late SyncRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fatoora_sync_');
    databaseService = await openSyncTestDb(directory);
    repository = SyncRepository(databaseService.syncDatabase);
  });

  tearDown(() async {
    await databaseService.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  group('outbound payload scope', () {
    test('honors table toggles, date filter, and always sends tombstones',
        () async {
      final old = _row(
        id: 'inv-old',
        deviceId: _deviceA,
        updatedAt: 100,
        issuedAt: DateTime(2025, 1, 1),
      );
      final recent = _row(
        id: 'inv-new',
        deviceId: _deviceA,
        updatedAt: 200,
        issuedAt: DateTime(2026, 9, 1),
      );
      final removed = _row(
        id: 'inv-del',
        deviceId: _deviceA,
        updatedAt: 300,
        deleted: true,
        issuedAt: DateTime(2025, 1, 1),
      );
      await databaseService.syncDatabase.insert('invoices', old.toMap());
      await databaseService.syncDatabase.insert('invoices', recent.toMap());
      await databaseService.syncDatabase.insert('invoices', removed.toMap());

      final prefs = SyncPreferences(
        syncShopProfiles: false,
        issuedAtFrom: DateTime(2026, 1, 1),
      );
      final payload = await repository.buildOutboundPayload(_deviceB, prefs);

      final ids = payload.invoices.map((row) => row['id']).toList();
      expect(ids, containsAll(['inv-new', 'inv-del']),
          reason: 'tombstones bypass the date filter');
      expect(ids, isNot(contains('inv-old')),
          reason: 'live rows outside the date scope stay home');
      expect(payload.profiles, isEmpty,
          reason: 'shop profiles disabled for this session');
    });

    test('the cursor makes repeated payloads empty', () async {
      await databaseService.syncDatabase.insert(
        'invoices',
        _row(id: 'inv-1', deviceId: _deviceA, updatedAt: 500).toMap(),
      );
      final first =
          await repository.buildOutboundPayload(_deviceB, const SyncPreferences());
      expect(first.invoices, hasLength(1));

      await repository.advanceCursors(_deviceB, 500);
      final second =
          await repository.buildOutboundPayload(_deviceB, const SyncPreferences());
      expect(second.invoices, isEmpty);
    });

    test('lists media hashes referenced by outbound invoices', () async {
      await databaseService.syncDatabase.insert(
        'invoices',
        _row(id: 'inv-1', deviceId: _deviceA, updatedAt: 10, imageSha: 'a' * 64)
            .toMap(),
      );
      final payload =
          await repository.buildOutboundPayload(_deviceB, const SyncPreferences());
      expect(payload.mediaHashes, ['a' * 64]);
    });
  });

  group('inbound merge (last-write-wins)', () {
    test('applies a newer remote row and keeps its identity', () async {
      await databaseService.syncDatabase.insert(
        'invoices',
        _row(id: 'inv-1', deviceId: _deviceA, updatedAt: 100, name: 'القديم')
            .toMap(),
      );

      final result = await repository.mergeInvoices([
        _row(id: 'inv-1', deviceId: _deviceB, updatedAt: 200, name: 'الأحدث')
            .toMap(),
      ]);

      expect(result.overwritten, 1);
      final stored = await databaseService.getInvoices();
      expect(stored.single.sellerName, 'الأحدث');
      expect(stored.single.deviceId, _deviceB);
    });

    test('keeps the local row when the incoming one is older', () async {
      await databaseService.syncDatabase.insert(
        'invoices',
        _row(id: 'inv-1', deviceId: _deviceB, updatedAt: 500, name: 'المحلي')
            .toMap(),
      );

      final result = await repository.mergeInvoices([
        _row(id: 'inv-1', deviceId: _deviceA, updatedAt: 100, name: 'القديم')
            .toMap(),
      ]);

      expect(result.keptLocal, 1);
      expect((await databaseService.getInvoices()).single.sellerName, 'المحلي');
    });

    test('breaks equal-timestamp ties deterministically by device id',
        () async {
      await databaseService.syncDatabase.insert(
        'invoices',
        _row(id: 'inv-1', deviceId: _deviceA, updatedAt: 100, name: 'من A')
            .toMap(),
      );

      // device-b > device-a lexicographically, so B wins the tie.
      await repository.mergeInvoices([
        _row(id: 'inv-1', deviceId: _deviceB, updatedAt: 100, name: 'من B')
            .toMap(),
      ]);
      expect(
        (await databaseService.getInvoices()).single.sellerName,
        'من B',
      );

      // A row from device-a at the same timestamp must not flip it back.
      await repository.mergeInvoices([
        _row(id: 'inv-1', deviceId: _deviceA, updatedAt: 100, name: 'من A')
            .toMap(),
      ]);
      expect(
        (await databaseService.getInvoices()).single.sellerName,
        'من B',
      );
    });

    test('skips a different row carrying the same QR payload (double scan)',
        () async {
      await databaseService.syncDatabase.insert(
        'invoices',
        _row(id: 'inv-local', deviceId: _deviceA, updatedAt: 100)
            .toMap(),
      );

      final result = await repository.mergeInvoices([
        _row(
          id: 'inv-remote',
          deviceId: _deviceB,
          updatedAt: 999,
          payload: 'raw-payload',
        ).toMap(),
      ]);

      expect(result.duplicatesSkipped, 1);
      final all = await databaseService.syncDatabase.query('invoices');
      expect(all, hasLength(1), reason: 'the duplicate must not be inserted');
      expect(all.single['id'], 'inv-local');
    });

    test('applies tombstones and hides the invoice everywhere', () async {
      await databaseService.syncDatabase.insert(
        'invoices',
        _row(id: 'inv-1', deviceId: _deviceA, updatedAt: 100).toMap(),
      );

      final result = await repository.mergeInvoices([
        _row(id: 'inv-1', deviceId: _deviceB, updatedAt: 200, deleted: true)
            .toMap(),
      ]);

      expect(result.overwritten, 1);
      expect(await databaseService.getInvoices(), isEmpty);
    });

    test('stores a tombstone for an unknown id so the deletion persists',
        () async {
      final result = await repository.mergeInvoices([
        _row(id: 'inv-ghost', deviceId: _deviceB, updatedAt: 5, deleted: true)
            .toMap(),
      ]);

      expect(result.applied, 1);
      final raw = await databaseService.syncDatabase.query('invoices');
      expect(raw.single['is_deleted'], 1);
      expect(await databaseService.getInvoices(), isEmpty);
    });

    test('reports media that is missing locally', () async {
      final result = await repository.mergeInvoices([
        _row(
          id: 'inv-1',
          deviceId: _deviceB,
          updatedAt: 10,
          imageSha: 'f' * 64,
        ).toMap(),
      ]);

      expect(result.mediaNeeded, ['f' * 64]);
    });

    test('wires the local image path when the media already exists', () async {
      final imageFile = File('${directory.path}/media-image.jpg');
      await imageFile.writeAsBytes([1, 2, 3, 4]);
      final sha = crypto.sha256.convert(imageFile.readAsBytesSync()).toString();
      await databaseService.syncDatabase.insert('media', {
        'sha256': sha,
        'bytes': 4,
        'local_path': imageFile.path,
        'updated_at': 1,
        'is_synced': 1,
      });

      final result = await repository.mergeInvoices([
        _row(
          id: 'inv-1',
          deviceId: _deviceB,
          updatedAt: 10,
          imageSha: sha,
        ).toMap(),
      ]);

      expect(result.mediaNeeded, isEmpty);
      final stored = await databaseService.getInvoices();
      expect(stored.single.imagePath, imageFile.path);
    });
  });

  group('shop profile merge', () {
    test('newer profile wins, older profile loses', () async {
      await databaseService.syncDatabase.insert('shop_profiles', {
        'key': 'v:300000000000003',
        'display_name': 'الاسم المحلي',
        'note': '',
        'updated_at': 500,
        'is_synced': 1,
        'is_deleted': 0,
      });

      final newer = await repository.mergeShopProfiles([
        {
          'key': 'v:300000000000003',
          'display_name': 'الاسم الأحدث',
          'note': 'ملاحظة',
          'updated_at': 900,
          'is_synced': 1,
          'is_deleted': 0,
        },
      ]);
      expect(newer.overwritten, 1);
      expect(
        await databaseService.syncDatabase.query('shop_profiles'),
        everyElement(
          predicate(
            (Map row) => row['display_name'] == 'الاسم الأحدث',
          ),
        ),
      );

      final older = await repository.mergeShopProfiles([
        {
          'key': 'v:300000000000003',
          'display_name': 'الاسم القديم',
          'note': '',
          'updated_at': 100,
          'is_synced': 1,
          'is_deleted': 0,
        },
      ]);
      expect(older.keptLocal, 1);
      expect(
        await databaseService.syncDatabase.query('shop_profiles'),
        everyElement(
          predicate((Map row) => row['display_name'] == 'الاسم الأحدث'),
        ),
      );
    });
  });
}
