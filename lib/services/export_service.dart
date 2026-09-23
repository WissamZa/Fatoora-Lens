import 'dart:convert';

import 'package:csv/csv.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../models/invoice.dart';
import 'zatca_qr_parser.dart';

class ExportService {
  static Future<void> shareCsv(List<Invoice> invoices, {required bool english}) async {
    final headers = english
        ? ['Shop', 'Invoice no.', 'VAT number', 'Date', 'Time', 'Amount', 'Tax', 'Note']
        : ['اسم المحل', 'رقم الفاتورة', 'الرقم الضريبي', 'التاريخ', 'الوقت', 'المبلغ', 'الضريبة', 'ملاحظة'];
    final rows = <List<Object?>>[
      headers,
      ...invoices.map((invoice) => [
            invoice.sellerName,
            invoice.invoiceNumber,
            invoice.vatNumber,
            ZatcaQrParser.formatDate(invoice.issuedAt),
            ZatcaQrParser.formatTime(invoice.issuedAt),
            invoice.totalAmount.toStringAsFixed(2),
            invoice.vatAmount.toStringAsFixed(2),
            invoice.note,
          ]),
    ];
    final content = '\uFEFF${csv.encode(rows)}';
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    await _shareBytes(
      utf8.encode(content),
      'fatoora_lens_$stamp.csv',
      'text/csv',
      english ? 'Fatoora Lens CSV' : 'فواتير عدسة فاتورة CSV',
    );
  }

  static Future<void> shareBackup(String json, {required bool english}) async {
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    await _shareBytes(
      utf8.encode(json),
      'fatoora_lens_backup_$stamp.json',
      'application/json',
      english ? 'Fatoora Lens backup' : 'نسخة احتياطية عدسة فاتورة',
    );
  }

  static Future<void> sharePdf(
    List<Invoice> invoices, {
    required bool english,
  }) async {
    final fontData = await rootBundle.load('assets/fonts/NotoSansArabic-Regular.ttf');
    final font = pw.Font.ttf(fontData.buffer.asByteData());
    final document = pw.Document(
      // Noto Sans Arabic in the app intentionally contains Arabic glyphs;
      // Helvetica is kept as a fallback for Latin shop names and headers.
      theme: pw.ThemeData.withFont(
        base: font,
        bold: font,
        fontFallback: [pw.Font.helvetica()],
      ),
    );
    final title = english ? 'Zakat invoices report' : 'تقرير فواتير الزكاة';
    final headers = english
        ? ['Shop', 'VAT number', 'Date', 'Time', 'Amount', 'Tax']
        : ['المحل', 'رقم الفاتورة', 'الرقم الضريبي', 'التاريخ', 'الوقت', 'المبلغ', 'الضريبة'];
    final englishHeaders = ['Shop', 'Invoice no.', 'VAT number', 'Date', 'Time', 'Amount', 'Tax'];
    final resolvedHeaders = english ? englishHeaders : headers;
    final data = invoices
        .map((invoice) => [
              _pdfCell(invoice.sellerName),
              _pdfCell(invoice.invoiceNumber.isEmpty ? '-' : invoice.invoiceNumber),
              _pdfCell(invoice.vatNumber.isEmpty ? '-' : invoice.vatNumber),
              _pdfCell(ZatcaQrParser.formatDate(invoice.issuedAt)),
              _pdfCell(ZatcaQrParser.formatTime(invoice.issuedAt)),
              _pdfCell(invoice.totalAmount.toStringAsFixed(2), align: pw.Alignment.centerRight),
              _pdfCell(invoice.vatAmount.toStringAsFixed(2), align: pw.Alignment.centerRight),
            ])
        .toList();
    final total = invoices.fold<double>(0, (sum, item) => sum + item.totalAmount);
    final tax = invoices.fold<double>(0, (sum, item) => sum + item.vatAmount);
    final currency = english ? 'SAR' : 'ر.س';

    document.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          margin: const pw.EdgeInsets.all(28),
          textDirection: english ? pw.TextDirection.ltr : pw.TextDirection.rtl,
        ),
        header: (context) => pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 18),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(title, style: const pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
              pw.Text(DateFormat('yyyy-MM-dd').format(DateTime.now())),
            ],
          ),
        ),
        build: (context) => [
          pw.TableHelper.fromTextArray(
            headers: resolvedHeaders,
            data: data,
            headerStyle: const pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
              fontSize: 8,
            ),
            cellStyle: const pw.TextStyle(fontSize: 8),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.teal700),
            columnWidths: {
              0: const pw.FixedColumnWidth(140),
              1: const pw.FixedColumnWidth(74),
              2: const pw.FixedColumnWidth(100),
              3: const pw.FixedColumnWidth(58),
              4: const pw.FixedColumnWidth(62),
              5: const pw.FixedColumnWidth(53),
              6: const pw.FixedColumnWidth(52),
            },
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            border: pw.TableBorder.all(color: PdfColors.grey400),
            cellAlignment: pw.Alignment.center,
          ),
          pw.SizedBox(height: 18),
          pw.Text(
            '${english ? 'Total' : 'الإجمالي'}: ${total.toStringAsFixed(2)} $currency   |   ${english ? 'Tax' : 'الضريبة'}: ${tax.toStringAsFixed(2)} $currency',
            style: const pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
        ],
      ),
    );

    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    await _shareBytes(
      await document.save(),
      'fatoora_lens_$stamp.pdf',
      'application/pdf',
      title,
    );
  }

  static pw.Widget _pdfCell(String value, {pw.Alignment align = pw.Alignment.center}) {
    final hasArabic = RegExp(r'[\u0600-\u06ff]').hasMatch(value);
    return pw.FittedBox(
      fit: pw.BoxFit.scaleDown,
      alignment: align,
      child: pw.Text(
        value,
        textAlign: pw.TextAlign.center,
        textDirection: hasArabic ? pw.TextDirection.rtl : pw.TextDirection.ltr,
      ),
    );
  }

  static Future<void> _shareBytes(
    List<int> bytes,
    String fileName,
    String mimeType,
    String title,
  ) async {
    final file = XFile.fromData(
      Uint8List.fromList(bytes),
      name: fileName,
      mimeType: mimeType,
    );
    await SharePlus.instance.share(
      ShareParams(
        title: title,
        files: [file],
        fileNameOverrides: [fileName],
      ),
    );
  }
}
