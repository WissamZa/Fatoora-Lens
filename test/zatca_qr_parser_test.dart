import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/services/zatca_qr_parser.dart';

/// Builds a TLV Base64 payload. [textFields] are UTF-8 encoded, and
/// [binaryFields] are written as raw bytes. Supports BER multi-byte lengths.
String _tlvWithBinary({
  required Map<int, String> textFields,
  Map<int, List<int>> binaryFields = const {},
}) {
  final bytes = <int>[];

  void addField(int tag, List<int> value) {
    bytes.add(tag);
    final len = value.length;
    if (len <= 127) {
      bytes.add(len);
    } else if (len <= 0xFF) {
      bytes.addAll([0x81, len]);
    } else {
      bytes.addAll([0x82, (len >> 8) & 0xFF, len & 0xFF]);
    }
    bytes.addAll(value);
  }

  for (final entry in textFields.entries) {
    addField(entry.key, utf8.encode(entry.value));
  }
  for (final entry in binaryFields.entries) {
    addField(entry.key, entry.value);
  }
  return base64.encode(bytes);
}

/// Simple TLV helper (text-only, single-byte length) for basic tests.
String _tlv(Map<int, String> fields) =>
    _tlvWithBinary(textFields: fields);

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

  test('parses Phase 2 QR with binary tags 6-9 without crashing', () {
    // Simulate a Phase 2 ZATCA QR code with binary signature/hash data.
    final fakeHash = List<int>.generate(32, (i) => i * 7 & 0xFF);
    final fakeSignature = List<int>.generate(64, (i) => i * 13 & 0xFF);
    final fakePublicKey = List<int>.generate(33, (i) => i * 3 & 0xFF);
    // Tag 9 over 127 bytes to exercise multi-byte BER length encoding.
    final fakeCert = List<int>.generate(200, (i) => i & 0xFF);

    final payload = _tlvWithBinary(
      textFields: {
        1: 'شركة اختبار المرحلة الثانية',
        2: '300012345600003',
        3: '2026-09-21T10:30:00+03:00',
        4: '230.00',
        5: '30.00',
      },
      binaryFields: {
        6: fakeHash,
        7: fakeSignature,
        8: fakePublicKey,
        9: fakeCert,
      },
    );

    final invoice = ZatcaQrParser.parse(payload);
    expect(invoice.sellerName, 'شركة اختبار المرحلة الثانية');
    expect(invoice.vatNumber, '300012345600003');
    expect(invoice.totalAmount, 230);
    expect(invoice.vatAmount, 30);
  });
}
