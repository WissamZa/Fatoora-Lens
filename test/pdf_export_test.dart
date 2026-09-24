import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/models/invoice.dart';
import 'package:fatoora_lens/services/export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('builds a PDF with bilingual shop names and SAR symbols', () async {
    final document = await ExportService.buildPdf(
      [
        Invoice(
          sellerName: 'سوبرماركت النخيل',
          sellerNameEn: 'Palm Supermarket',
          vatNumber: '300000000000003',
          issuedAt: DateTime(2026, 9, 21, 14, 30),
          totalAmount: 115,
          vatAmount: 15,
          rawPayload: 'payload',
          invoiceNumber: 'INV-001',
        ),
        Invoice(
          sellerName: 'Panda Retail Company',
          vatNumber: '310000000000003',
          issuedAt: DateTime(2026, 9, 22, 10, 0),
          totalAmount: 230,
          vatAmount: 30,
          rawPayload: 'payload',
        ),
      ],
      english: false,
    );

    final bytes = await document.save();
    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
  });
}
