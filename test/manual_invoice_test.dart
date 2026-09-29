import 'dart:io';

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/data/database_service.dart';
import 'package:fatoora_lens/models/invoice.dart';
import 'package:fatoora_lens/sync/sync_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

void main() {
  late Directory directory;
  late DatabaseService database;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fatoora_manual_');
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

  Invoice manualInvoice({required DateTime issuedAt, String? rawPayload}) =>
      Invoice(
        sellerName: 'محل بدون باركود',
        vatNumber: '300999999999993',
        issuedAt: issuedAt,
        totalAmount: 57.5,
        vatAmount: 7.5,
        rawPayload: rawPayload ?? 'manual:${const Uuid().v4()}',
      );

  test('manual invoices get a unique, non-empty payload hash each', () async {
    await database.insertInvoice(
      manualInvoice(issuedAt: DateTime(2026, 9, 20, 14)),
    );
    // Small delay so created_at ordering is stable, then a second one.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await database.insertInvoice(
      manualInvoice(issuedAt: DateTime(2026, 9, 20, 19)),
    );

    final invoices = await database.getInvoices();
    expect(invoices, hasLength(2));
    final hashes = invoices.map((invoice) => invoice.payloadSha256).toSet();
    expect(hashes, hasLength(2), reason: 'each manual invoice is its own '
        'sync identity; identical hashes would collapse as duplicates');
    for (final hash in hashes) {
      expect(hash, hasLength(64));
    }
    expect(
      invoices.every((invoice) => invoice.rawPayload.startsWith('manual:')),
      isTrue,
    );
  });

  test('sync merge keeps every distinct manual invoice without flagging '
      'duplicates', () async {
    final repository = SyncRepository(database.syncDatabase);
    final first = manualInvoice(issuedAt: DateTime(2026, 9, 20, 14));
    final second = manualInvoice(issuedAt: DateTime(2026, 9, 21, 9));

    final result = await repository.mergeInvoices([
      _wireRow(first),
      _wireRow(second),
    ]);
    expect(result.applied, 2);
    expect(result.duplicatesSkipped, 0);
    expect(await database.getInvoices(), hasLength(2));

    // Control: the SAME synthetic payload twice is still one receipt.
    final twin = manualInvoice(
      issuedAt: DateTime(2026, 9, 22),
      rawPayload: first.rawPayload,
    );
    final duplicate = await repository.mergeInvoices([_wireRow(twin)]);
    expect(duplicate.duplicatesSkipped, 1);
  });

  test('copyWith can move the invoice to another date and time', () {
    final invoice = manualInvoice(issuedAt: DateTime(2026, 9, 20, 14, 30));
    final moved = invoice.copyWith(
      issuedAt: DateTime(2026, 10, 1, 8, 15),
    );
    expect(moved.issuedAt, DateTime(2026, 10, 1, 8, 15));
    // Everything else is untouched.
    expect(moved.rawPayload, invoice.rawPayload);
    expect(moved.totalAmount, invoice.totalAmount);
  });

  test('a manual draft row round-trips through the database with its date',
      () async {
    final date = DateTime(2026, 9, 20, 14, 30);
    final id = await database.insertInvoice(manualInvoice(issuedAt: date));
    final stored = (await database.getInvoices()).single;
    expect(stored.id, id);
    expect(stored.issuedAt, date);

    final updated = stored.copyWith(issuedAt: DateTime(2026, 9, 25, 21, 0));
    await database.updateInvoice(updated);
    final reloaded = (await database.getInvoices()).single;
    expect(reloaded.issuedAt, DateTime(2026, 9, 25, 21, 0));
  });
}

Map<String, Object?> _wireRow(Invoice invoice) {
  final row = invoice.toMap()
    ..['id'] = invoice.id ?? const Uuid().v4()
    ..['device_id'] = 'device-aaaa'
    ..['payload_sha256'] = crypto.sha256
        .convert(utf8.encode((invoice.rawPayload).trim()))
        .toString();
  return row;
}
