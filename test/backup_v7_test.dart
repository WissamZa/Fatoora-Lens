import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/data/database_service.dart';
import 'package:fatoora_lens/models/invoice.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Invoice _invoice({
  String? id,
  String name = 'متجر الأصيل',
  String nameEn = 'Al Aseel Store',
  String? imagePath,
}) => Invoice(
      id: id,
      sellerName: name,
      sellerNameEn: nameEn,
      vatNumber: '300000000000003',
      issuedAt: DateTime(2026, 9, 1),
      totalAmount: 115,
      vatAmount: 15,
      rawPayload: 'raw-payload',
      imagePath: imagePath,
    );

Future<DatabaseService> _openDb(Directory directory) async {
  final database = DatabaseService(
    databasePath: '${directory.path}/database.db',
    databaseFactory: databaseFactoryFfi,
  );
  await database.initialize();
  return database;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('ZIP backup (schema v7)', () {
    test('round-trips invoices, media, and shop profiles', () async {
      final sourceDir =
          await Directory.systemTemp.createTemp('fatoora_bk_src_');
      final targetDir =
          await Directory.systemTemp.createTemp('fatoora_bk_dst_');
      final source = await _openDb(sourceDir);
      try {
        final imageFile =
            File('${sourceDir.path}/invoice_images/receipt.jpg');
        await imageFile.parent.create(recursive: true);
        final imageBytes =
            Uint8List.fromList(List.generate(2048, (i) => i % 251));
        await imageFile.writeAsBytes(imageBytes);

        final id = await source.insertInvoice(
          _invoice(imagePath: imageFile.path),
        );
        final shops = await source.getShops();
        await source.updateShopProfile(
          shopId: shops.single.id!,
          displayName: 'الأصيل',
          note: 'بقالة الحي',
        );

        final zipFile = await source.createBackupArchive();
        expect(zipFile.existsSync(), isTrue);

        final target = await _openDb(targetDir);
        await target.restoreBackupArchive(await zipFile.readAsBytes());

        final restored = await target.getInvoices();
        expect(restored, hasLength(1));
        expect(restored.single.id, id);
        expect(restored.single.sellerNameEn, 'Al Aseel Store');
        expect(restored.single.imageSha256, isNotNull);

        // The image was restored into the target's media directory and its
        // content still matches the recorded hash.
        final restoredPath = restored.single.imagePath!;
        expect(File(restoredPath).existsSync(), isTrue);
        final restoredHash =
            crypto.sha256.convert(await File(restoredPath).readAsBytes());
        expect(restoredHash.toString(), restored.single.imageSha256);

        final restoredShops = await target.getShops();
        expect(restoredShops.single.name, 'الأصيل');
        expect(restoredShops.single.note, 'بقالة الحي');
        expect(restoredShops.single.nameAr, 'متجر الأصيل');
        await target.close();
      } finally {
        await source.close();
        await sourceDir.delete(recursive: true);
        if (targetDir.existsSync()) {
          await targetDir.delete(recursive: true);
        }
      }
    });

    test('rejects unsafe archive entry paths (zip-slip)', () async {
      final directory = await Directory.systemTemp.createTemp('fatoora_slip_');
      final database = await _openDb(directory);
      try {
        final archive = Archive()
          ..addFile(ArchiveFile.string(
            'backup.json',
            jsonEncode({'schemaVersion': 7, 'invoices': []}),
          ))
          ..addFile(ArchiveFile('..${Platform.pathSeparator}evil.bin', 4,
              [1, 2, 3, 4]));
        final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

        await expectLater(
          database.restoreBackupArchive(bytes),
          throwsA(isA<FormatException>()),
        );
      } finally {
        await database.close();
        await directory.delete(recursive: true);
      }
    });

    test('rejects media entries whose content does not match their hash',
        () async {
      final directory = await Directory.systemTemp.createTemp('fatoora_bad_');
      final database = await _openDb(directory);
      try {
        final goodSha =
            crypto.sha256.convert([1, 2, 3, 4]).toString();
        final archive = Archive()
          ..addFile(ArchiveFile.string(
            'backup.json',
            jsonEncode({'schemaVersion': 7, 'invoices': []}),
          ))
          ..addFile(
            ArchiveFile('media/$goodSha', 4, [9, 9, 9, 9]),
          );
        final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

        await expectLater(
          database.restoreBackupArchive(bytes),
          throwsA(isA<FormatException>()),
        );
      } finally {
        await database.close();
        await directory.delete(recursive: true);
      }
    });

    test('restores legacy JSON backups and assigns UUID identities',
        () async {
      final directory = await Directory.systemTemp.createTemp('fatoora_lg_');
      final database = await _openDb(directory);
      try {
        final legacy = jsonEncode({
          'schemaVersion': 6,
          'invoices': [
            {
              'id': 1,
              'seller_name': 'شركة بندة للتجزئة\nPanda Retail Company',
              'seller_name_en': '',
              'vat_number': '300056521610003',
              'issued_at': '2026-09-01T10:00:00.000',
              'total_amount': 32.99,
              'vat_amount': 4.3,
              'raw_payload': 'payload',
              'created_at': '2026-09-01T10:00:00.000',
            },
          ],
          'shops': [
            {
              'seller_name': 'شركة بندة للتجزئة\nPanda Retail Company',
              'vat_number': '300056521610003',
              'note': 'ملاحظة قديمة',
              'created_at': '2026-09-01T10:00:00.000',
            },
          ],
        });

        await database.restoreBackupJson(legacy);

        final invoices = await database.getInvoices();
        expect(invoices, hasLength(1));
        // The integer id from the legacy backup is replaced by a UUID and
        // the combined name is separated.
        expect(invoices.single.id, isNot('1'));
        expect(invoices.single.sellerName, 'شركة بندة للتجزئة');
        expect(invoices.single.sellerNameEn, 'Panda Retail Company');

        final shops = await database.getShops();
        expect(shops.single.note, 'ملاحظة قديمة');
      } finally {
        await database.close();
        await directory.delete(recursive: true);
      }
    });

    test('deleting an invoice keeps a tombstone that hides it from lists',
        () async {
      final directory = await Directory.systemTemp.createTemp('fatoora_td_');
      final database = await _openDb(directory);
      try {
        final id = await database.insertInvoice(_invoice());
        expect((await database.getInvoices()), hasLength(1));

        await database.deleteInvoice(id);
        expect(await database.getInvoices(), isEmpty);

        final shops = await database.getShops();
        expect(shops, isEmpty, reason: 'Tombstones must not keep shops alive');
      } finally {
        await database.close();
        await directory.delete(recursive: true);
      }
    });
  });
}
