import 'dart:convert';

import 'package:csv/csv.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../models/invoice.dart';
import '../models/shop.dart';
import 'zatca_qr_parser.dart';

class ExportService {
  /// Unified base font size for all body text; every cell wraps its content
  /// in a FittedBox so longer text scales down to fit instead of clipping.
  static const double _pdfFontSize = 8;

  static Future<void> shareCsv(
    List<Invoice> invoices, {
    required bool english,
    List<Shop> shops = const [],
  }) async {
    final headers = english
        ? ['Shop', 'Invoice no.', 'VAT number', 'Date', 'Time', 'Amount', 'Tax', 'Note']
        : ['اسم المحل', 'رقم الفاتورة', 'الرقم الضريبي', 'التاريخ', 'الوقت', 'المبلغ', 'الضريبة', 'ملاحظة'];
    final rows = <List<Object?>>[
      headers,
      ...invoices.map((invoice) => [
            Shop.displayNameForInvoice(shops, invoice) ?? invoice.sellerName,
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

  /// Builds the PDF report; separated from sharing so it can be tested.
  static Future<pw.Document> buildPdf(
    List<Invoice> invoices, {
    required bool english,
    List<Shop> shops = const [],
  }) async {
    final fontData = await rootBundle.load('assets/fonts/NotoSansArabic-Regular.ttf');
    final font = pw.Font.ttf(fontData.buffer.asByteData());
    // The official SAR symbol is a path-only SVG, drawn directly by the pdf package.
    final sarSvg = await rootBundle.loadString('assets/icons/sar_symbol.svg');
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
              _shopCell(invoice, shops),
              _pdfCell(invoice.invoiceNumber.isEmpty ? '-' : invoice.invoiceNumber),
              _pdfCell(invoice.vatNumber.isEmpty ? '-' : invoice.vatNumber),
              _pdfCell(ZatcaQrParser.formatDate(invoice.issuedAt)),
              _pdfCell(ZatcaQrParser.formatTime(invoice.issuedAt)),
              _amountCell(invoice.totalAmount, sarSvg),
              _amountCell(invoice.vatAmount, sarSvg),
            ])
        .toList();
    final total = invoices.fold<double>(0, (sum, item) => sum + item.totalAmount);
    final tax = invoices.fold<double>(0, (sum, item) => sum + item.vatAmount);
    const boldStyle = pw.TextStyle(
      fontWeight: pw.FontWeight.bold,
      fontSize: _pdfFontSize,
    );

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
            cellStyle: const pw.TextStyle(fontSize: _pdfFontSize),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.teal700),
            columnWidths: {
              0: const pw.FixedColumnWidth(140),
              1: const pw.FixedColumnWidth(72),
              2: const pw.FixedColumnWidth(96),
              3: const pw.FixedColumnWidth(56),
              4: const pw.FixedColumnWidth(60),
              5: const pw.FixedColumnWidth(60),
              6: const pw.FixedColumnWidth(55),
            },
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            border: pw.TableBorder.all(color: PdfColors.grey400),
            cellAlignment: pw.Alignment.center,
          ),
          pw.SizedBox(height: 18),
          pw.Row(
            mainAxisSize: pw.MainAxisSize.min,
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Text('${english ? 'Total' : 'الإجمالي'}: ', style: boldStyle),
              pw.Text(total.toStringAsFixed(2), style: boldStyle),
              _sarSymbol(sarSvg, 9),
              pw.SizedBox(width: 18),
              pw.Text('${english ? 'Tax' : 'الضريبة'}: ', style: boldStyle),
              pw.Text(tax.toStringAsFixed(2), style: boldStyle),
              _sarSymbol(sarSvg, 9),
            ],
          ),
        ],
      ),
    );

    return document;
  }

  static Future<void> sharePdf(
    List<Invoice> invoices, {
    required bool english,
    List<Shop> shops = const [],
  }) async {
    final document = await buildPdf(invoices, english: english, shops: shops);
    final title = english ? 'Zakat invoices report' : 'تقرير فواتير الزكاة';

    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    await _shareBytes(
      await document.save(),
      'fatoora_lens_$stamp.pdf',
      'application/pdf',
      title,
    );
  }

  static pw.Widget _pdfCell(String value, {pw.Alignment align = pw.Alignment.center}) {
    return pw.FittedBox(
      fit: pw.BoxFit.scaleDown,
      alignment: align,
      child: _bidiText(value),
    );
  }

  /// Shop display name (custom name when set) on the first line with the
  /// English name under it when available.
  static pw.Widget _shopCell(Invoice invoice, List<Shop> shops) {
    final shownName =
        Shop.displayNameForInvoice(shops, invoice) ?? invoice.sellerName;
    final englishName = invoice.sellerNameEn.trim();
    if (englishName.isEmpty) return _pdfCell(shownName);
    return pw.FittedBox(
      fit: pw.BoxFit.scaleDown,
      alignment: pw.Alignment.center,
      child: pw.Column(
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          _bidiText(shownName, fontWeight: pw.FontWeight.bold),
          pw.SizedBox(height: 2),
          _bidiText(englishName, color: PdfColors.grey700),
        ],
      ),
    );
  }

  static pw.Widget _amountCell(double value, String sarSvg) {
    return pw.FittedBox(
      fit: pw.BoxFit.scaleDown,
      alignment: pw.Alignment.centerRight,
      child: pw.Row(
        mainAxisSize: pw.MainAxisSize.min,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(
            value.toStringAsFixed(2),
            style: const pw.TextStyle(fontSize: _pdfFontSize),
          ),
          pw.SizedBox(width: 3),
          _sarSymbol(sarSvg, 9),
        ],
      ),
    );
  }

  /// The SAR symbol SVG is taller than wide (1124x1256 viewBox), so the width
  /// keeps its aspect ratio.
  static pw.Widget _sarSymbol(String svg, double height) {
    return pw.SvgImage(svg: svg, width: height * 0.895, height: height);
  }

  static pw.Text _bidiText(
    String value, {
    double fontSize = _pdfFontSize,
    PdfColor? color,
    pw.FontWeight? fontWeight,
  }) {
    final hasArabic = RegExp(r'[\u0600-\u06ff]').hasMatch(value);
    return pw.Text(
      value,
      textAlign: pw.TextAlign.center,
      textDirection: hasArabic ? pw.TextDirection.rtl : pw.TextDirection.ltr,
      style: pw.TextStyle(fontSize: fontSize, color: color, fontWeight: fontWeight),
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
