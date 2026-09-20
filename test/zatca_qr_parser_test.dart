import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zakat_invoice_scanner/services/zatca_qr_parser.dart';

String _tlv(Map<int, String> fields) {
  final bytes = <int>[];
  for (final entry in fields.entries) {
    final value = utf8.encode(entry.value);
    bytes
      ..add(entry.key)
      ..add(value.length)
      ..addAll(value);
  }
  return base64.encode(bytes);
}

void main() {
  test('parses the five required ZATCA TLV fields', () {
    final invoice = ZatcaQrParser.parse(
      _tlv({
        1: 'متجر الاختبار',
        2: '310123456700003',
        3: '2026-09-21T13:05:00+03:00',
        4: '115.00',
        5: '15.00',
      }),
    );

    expect(invoice.sellerName, 'متجر الاختبار');
    expect(invoice.vatNumber, '310123456700003');
    expect(invoice.totalAmount, 115);
    expect(invoice.vatAmount, 15);
    expect(ZatcaQrParser.formatTime(invoice.issuedAt), '01:05 PM');
  });

  test('rejects a payload without required fields', () {
    expect(
      () => ZatcaQrParser.parse(_tlv({1: 'متجر فقط'})),
      throwsA(isA<FormatException>()),
    );
  });
}
