import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/data/database_service.dart';
import 'package:fatoora_lens/sync/sync_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  late DatabaseService database;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fatoora_prefs_');
    database = DatabaseService(
      databasePath: '${directory.path}/database.db',
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

  test('preferences default when nothing is stored', () async {
    final prefs = await SyncPreferences.load(database.getSetting);
    expect(prefs.syncInvoices, isTrue);
    expect(prefs.syncShopProfiles, isTrue);
    expect(prefs.syncImages, isTrue);
    expect(prefs.allowCloudFallback, isTrue);
    expect(prefs.issuedAtFrom, isNull);
  });

  test('preferences round-trip through the settings table', () async {
    const prefs = SyncPreferences(
      syncInvoices: false,
      syncShopProfiles: false,
      syncImages: false,
      allowCloudFallback: false,
      issuedAtFrom: null,
    );
    await prefs.save(database.setSetting);
    final loaded = await SyncPreferences.load(database.getSetting);
    expect(loaded.syncInvoices, isFalse);
    expect(loaded.syncShopProfiles, isFalse);
    expect(loaded.syncImages, isFalse);
    expect(loaded.allowCloudFallback, isFalse);
  });

  test('the date scope survives a save/load round-trip', () async {
    final prefs = SyncPreferences(
      issuedAtFrom: DateTime(2026, 1, 1),
    );
    await prefs.save(database.setSetting);
    final loaded = await SyncPreferences.load(database.getSetting);
    expect(loaded.issuedAtFrom, DateTime(2026, 1, 1));
  });

  test('corrupted stored JSON falls back to defaults', () async {
    await database.setSetting('sync_preferences', '{not json');
    final prefs = await SyncPreferences.load(database.getSetting);
    expect(prefs.syncInvoices, isTrue);
  });
}
