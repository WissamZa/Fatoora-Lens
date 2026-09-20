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
        ? ['Shop', 'VAT number', 'Date', 'Time', 'Amount', 'Tax', 'Note']
        : ['اسم المحل', 'الرقم الضريبي', 'التاريخ', 'الوقت', 'المبلغ', 'الضريبة', 'ملاحظة'];
    final rows = <List<Object?>>[
      headers,
      ...invoices.map((invoice) => [
            invoice.sellerName,
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
      'zakat_invoices_$stamp.csv',
      'text/csv',
      english ? 'Zakat invoices CSV' : 'فواتير الزكاة CSV',
    );
  }

  static Future<void> shareBackup(String json, {required bool english}) async {
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    await _shareBytes(
      utf8.encode(json),
      'zakat_backup_$stamp.json',
      'application/json',
      english ? 'Zakat invoices backup' : 'نسخة احتياطية لفواتير الزكاة',
    );
  }

  static Future<void> sharePdf(
    List<Invoice> invoices, {
    required bool english,
  }) async {
    final fontData = await rootBundle.load('assets/fonts/NotoSansArabic-Regular.ttf');
    final font = pw.Font.ttf(fontData.buffer.asByteData());
    final document = pw.Document(
      theme: pw.ThemeData.withFont(base: font),
    );
    final title = english ? 'Zakat invoices report' : 'تقرير فواتير الزكاة';
    final headers = english
        ? ['Shop', 'VAT number', 'Date', 'Time', 'Amount', 'Tax']
        : ['المحل', 'الرقم الضريبي', 'التاريخ', 'الوقت', 'المبلغ', 'الضريبة'];
    final data = invoices
        .map((invoice) => [
              invoice.sellerName,
              invoice.vatNumber,
              ZatcaQrParser.formatDate(invoice.issuedAt),
              ZatcaQrParser.formatTime(invoice.issuedAt),
              invoice.totalAmount.toStringAsFixed(2),
              invoice.vatAmount.toStringAsFixed(2),
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
            headers: headers,
            data: data,
            headerStyle: const pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.teal700),
            cellPadding: const pw.EdgeInsets.all(7),
            border: pw.TableBorder.all(color: PdfColors.grey400),
            cellAlignment: pw.Alignment.center,
          ),
          pw.SizedBox(height: 18),
          pw.Text(
            '${english ? 'Total' : 'الإجمالي'}: ${total.toStringAsFixed(2)} $currency   •   ${english ? 'Tax' : 'الضريبة'}: ${tax.toStringAsFixed(2)} $currency',
            style: const pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
        ],
      ),
    );

    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    await _shareBytes(
      await document.save(),
      'zakat_invoices_$stamp.pdf',
      'application/pdf',
      title,
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
