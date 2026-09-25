import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/models/invoice.dart';
import 'package:fatoora_lens/data/database_service.dart';
import 'package:fatoora_lens/widgets/invoice_tile.dart';
import 'package:fatoora_lens/widgets/sar_symbol.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('deleting an invoice removes its stored image file', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp(
      'fatoora_lens_test_',
    );
    final image = File('${directory.path}/invoice.jpg');
    await image.writeAsString('test image');
    final database = DatabaseService(
      databasePath: '${directory.path}/database.db',
      databaseFactory: databaseFactoryFfi,
    );

    try {
      await database.initialize();
      final id = await database.insertInvoice(
        Invoice(
          sellerName: 'Test shop',
          vatNumber: '300000000000003',
          issuedAt: DateTime(2026, 9, 21),
          totalAmount: 115,
          vatAmount: 15,
          rawPayload: 'payload',
          imagePath: image.path,
        ),
      );

      await database.deleteInvoice(id);

      expect(await image.exists(), isFalse);
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });

  group('Invoice Model with imagePath', () {
    test('supports imagePath serialization and deserialization', () {
      final invoice = Invoice(
        id: 'inv-1',
        sellerName: 'سوبرماركت النخيل',
        vatNumber: '300000000000003',
        issuedAt: DateTime(2026, 3, 15, 14, 30),
        totalAmount: 115.00,
        vatAmount: 15.00,
        rawPayload: 'test-payload',
        note: 'ملاحظة تجريبية',
        imagePath: '/data/user/0/com.fatooralens.app/invoices/inv_1.jpg',
      );

      final map = invoice.toMap();
      expect(
        map['image_path'],
        '/data/user/0/com.fatooralens.app/invoices/inv_1.jpg',
      );

      final fromMap = Invoice.fromMap(map);
      expect(
        fromMap.imagePath,
        '/data/user/0/com.fatooralens.app/invoices/inv_1.jpg',
      );
      expect(fromMap.sellerName, 'سوبرماركت النخيل');
      expect(fromMap.totalAmount, 115.00);
      expect(fromMap.vatAmount, 15.00);

      // copyWith new image
      final updated = invoice.copyWith(imagePath: '/new/path/image.jpg');
      expect(updated.imagePath, '/new/path/image.jpg');

      // copyWith clear image
      final cleared = invoice.copyWith(clearImage: true);
      expect(cleared.imagePath, isNull);
    });

    test('supports sellerNameEn serialization and defaults to empty', () async {
      sqfliteFfiInit();
      final directory = await Directory.systemTemp.createTemp(
        'fatoora_lens_test_',
      );
      final database = DatabaseService(
        databasePath: '${directory.path}/database.db',
        databaseFactory: databaseFactoryFfi,
      );

      try {
        await database.initialize();

        final bilingual = Invoice(
          sellerName: 'سوبرماركت النخيل',
          sellerNameEn: 'Palm Supermarket',
          vatNumber: '300000000000003',
          issuedAt: DateTime(2026, 3, 15),
          totalAmount: 115,
          vatAmount: 15,
          rawPayload: 'payload',
        );
        expect(bilingual.toMap()['seller_name_en'], 'Palm Supermarket');
        expect(Invoice.fromMap(bilingual.toMap()).sellerNameEn, 'Palm Supermarket');
        expect(
          bilingual.copyWith(sellerNameEn: 'Palm Market').sellerNameEn,
          'Palm Market',
        );

        final id = await database.insertInvoice(bilingual);
        final stored = await database.getInvoices();
        expect(stored.single.sellerNameEn, 'Palm Supermarket');

        await database.updateInvoice(
          Invoice(
            id: id,
            sellerName: bilingual.sellerName,
            sellerNameEn: 'Palm Market',
            vatNumber: bilingual.vatNumber,
            issuedAt: bilingual.issuedAt,
            totalAmount: bilingual.totalAmount,
            vatAmount: bilingual.vatAmount,
            rawPayload: bilingual.rawPayload,
          ),
        );
        final updated = await database.getInvoices();
        expect(updated.single.sellerNameEn, 'Palm Market');

        // Invoices without an English name keep loading fine.
        final plain = Invoice(
          sellerName: 'محل آخر',
          vatNumber: '300000000000003',
          issuedAt: DateTime(2026, 3, 16),
          totalAmount: 50,
          vatAmount: 5,
          rawPayload: 'payload',
        );
        expect(plain.sellerNameEn, '');
        await database.insertInvoice(plain);
        final all = await database.getInvoices();
        expect(all.where((invoice) => invoice.sellerNameEn.isEmpty).length, 1);
      } finally {
        await database.close();
        await directory.delete(recursive: true);
      }
    });
  });

  group('SAR Symbol and Amount Widgets', () {
    testWidgets('renders SarSymbol and SarAmount without crashing', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Column(
                children: [
                  SarSymbol(size: 20),
                  SarAmount(amount: 250.75),
                  SarTaxBadge(amount: 37.61),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.byType(SarSymbol), findsWidgets);
      expect(find.text('250.75'), findsOneWidget);
      expect(find.text('37.61'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('InvoiceTile Widget', () {
    testWidgets('renders invoice tile with SAR amount and tax badge', (
      tester,
    ) async {
      final invoice = Invoice(
        id: 'inv-42',
        sellerName: 'شركة تجريبية',
        vatNumber: '310123456700003',
        issuedAt: DateTime(2026, 5, 10, 10, 0),
        totalAmount: 575.0,
        vatAmount: 75.0,
        rawPayload: 'payload',
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: InvoiceTile(invoice: invoice, onEdit: () {}, onDelete: () {}),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('شركة تجريبية'), findsOneWidget);
      expect(find.text('575.00'), findsOneWidget);
      expect(find.byType(SarTaxBadge), findsOneWidget);
      expect(find.byType(SarSymbol), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
