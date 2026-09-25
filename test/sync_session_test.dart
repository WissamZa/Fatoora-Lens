import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/data/database_service.dart';
import 'package:fatoora_lens/models/invoice.dart';
import 'package:fatoora_lens/sync/security/sync_secure_channel.dart';
import 'package:fatoora_lens/sync/sync_preferences.dart';
import 'package:fatoora_lens/sync/sync_session.dart';
import 'package:fatoora_lens/sync/transport/sync_transport.dart';
import 'package:cryptography/cryptography.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<DatabaseService> _openDb(Directory dir) async {
  final database = DatabaseService(
    databasePath: '${dir.path}/database.db',
    databaseFactory: databaseFactoryFfi,
  );
  await database.initialize();
  return database;
}

Invoice _invoice(String payload, {String name = 'متجر الأصيل'}) => Invoice(
      sellerName: name,
      sellerNameEn: 'Al Aseel Store',
      vatNumber: '300000000000003',
      issuedAt: DateTime(2026, 9, 1),
      totalAmount: 115,
      vatAmount: 15,
      rawPayload: payload,
    );

void main() {
  late Directory dirA;
  late Directory dirB;
  late DatabaseService deviceA;
  late DatabaseService deviceB;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    dirA = await Directory.systemTemp.createTemp('fatoora_sess_a_');
    dirB = await Directory.systemTemp.createTemp('fatoora_sess_b_');
    deviceA = await _openDb(dirA);
    deviceB = await _openDb(dirB);
  });

  tearDown(() async {
    await deviceA.close();
    await deviceB.close();
    await dirA.delete(recursive: true);
    await dirB.delete(recursive: true);
  });

  /// Establishes secure channels between the two devices; device A hosts.
  Future<(SyncSecureChannel, SyncSecureChannel)> pairDevices() async {
    final (hostInner, guestInner) = LoopbackTransport.pair();
    final hostKeys = await X25519().newKeyPair();
    final hostPublic = await hostKeys.extractPublicKey();
    final hostFuture = SyncSecureChannel.establish(
      transport: hostInner,
      side: SyncSide.host,
      sessionId: 'session-test',
      hostStaticKeyPair: hostKeys,
    );
    final guestFuture = SyncSecureChannel.establish(
      transport: guestInner,
      side: SyncSide.guest,
      sessionId: 'session-test',
      hostPublicKey: Uint8List.fromList(hostPublic.bytes),
    );
    final channels = await Future.wait([hostFuture, guestFuture]);
    return (channels[0], channels[1]);
  }

  Future<(SyncSessionResult, SyncSessionResult)> runBoth(
    SyncSecureChannel host,
    SyncSecureChannel guest,
  ) async {
    final engineA = SyncSessionEngine(
      channel: host,
      database: deviceA,
      preferences: const SyncPreferences(),
    );
    final engineB = SyncSessionEngine(
      channel: guest,
      database: deviceB,
      preferences: const SyncPreferences(),
    );
    final results = await Future.wait([engineA.run(), engineB.run()]);
    return (results[0], results[1]);
  }

  test('invoices sync bidirectionally and double scans deduplicate',
      () async {
    await deviceA.insertInvoice(_invoice('receipt-1'));
    await deviceA.insertInvoice(_invoice('receipt-2', name: 'متجر ثانٍ'));
    // Device B scanned the same paper receipt as device A's receipt-1.
    await deviceB.insertInvoice(_invoice('receipt-1'));
    await deviceB.insertInvoice(_invoice('receipt-B-only'));

    final (host, guest) = await pairDevices();
    final (resultA, resultB) = await runBoth(host, guest);

    expect(resultA.success, isTrue, reason: 'A: ${resultA.error}');
    expect(resultB.success, isTrue, reason: 'B: ${resultB.error}');

    final aInvoices = await deviceA.getInvoices();
    final bInvoices = await deviceB.getInvoices();
    final aPayloads = aInvoices.map((invoice) => invoice.rawPayload).toSet();
    final bPayloads = bInvoices.map((invoice) => invoice.rawPayload).toSet();
    expect(aPayloads, containsAll(['receipt-1', 'receipt-2', 'receipt-B-only']));
    expect(bPayloads, containsAll(['receipt-1', 'receipt-2', 'receipt-B-only']));
    // Both databases must hold exactly one row per physical receipt.
    expect(aInvoices, hasLength(3));
    expect(bInvoices, hasLength(3));
    expect(resultB.duplicatesSkipped, 1,
        reason: 'B already had receipt-1 from its own scan');
  });

  test('a second session exchanges nothing new', () async {
    await deviceA.insertInvoice(_invoice('receipt-1'));

    final (host, guest) = await pairDevices();
    final (firstA, _) = await runBoth(host, guest);
    expect(firstA.success, isTrue);
    expect(firstA.sentInvoices, 1);
    await host.close();
    await guest.close();

    final (host2, guest2) = await pairDevices();
    final (secondA, secondB) = await runBoth(host2, guest2);
    expect(secondA.success, isTrue);
    expect(secondA.sentInvoices, 0, reason: 'cursor already covers it');
    expect(secondB.sentInvoices, 0);
    expect(secondA.receivedInvoices, 0);
    expect(secondB.receivedInvoices, 0);
    await host2.close();
    await guest2.close();
  });

  test('tombstones propagate so both sides forget the deleted invoice',
      () async {
    final id = await deviceA.insertInvoice(_invoice('receipt-1'));
    final (host, guest) = await pairDevices();
    await runBoth(host, guest);
    await host.close();
    await guest.close();

    await deviceA.deleteInvoice(id);

    final (host2, guest2) = await pairDevices();
    final (resultA, _) = await runBoth(host2, guest2);
    expect(resultA.success, isTrue);
    expect(resultA.sentInvoices, 1,
        reason: 'the tombstone must travel even though lists are empty');
    expect(await deviceB.getInvoices(), isEmpty);
    await host2.close();
    await guest2.close();
  });

  test('custom shop names propagate to the other device', () async {
    await deviceA.insertInvoice(_invoice('receipt-1'));
    final shops = await deviceA.getShops();
    await deviceA.updateShopProfile(
      shopId: shops.single.id!,
      displayName: 'اسم مخصص',
      note: 'ملاحظة مشتركة',
    );

    final (host, guest) = await pairDevices();
    final (resultA, resultB) = await runBoth(host, guest);
    expect(resultA.success, isTrue);
    expect(resultB.success, isTrue);

    final bShops = await deviceB.getShops();
    expect(bShops.single.name, 'اسم مخصص');
    expect(bShops.single.note, 'ملاحظة مشتركة');
    await host.close();
    await guest.close();
  });
}
