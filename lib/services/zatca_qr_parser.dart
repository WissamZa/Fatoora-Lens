import 'dart:convert';

import 'package:intl/intl.dart';

import '../models/invoice.dart';

class ZatcaQrParser {
  static Invoice parse(String payload) {
    final values = _decodeTlv(payload);
    final sellerName = values[1];
    final issuedAtText = values[3];
    final totalText = values[4];
    final vatText = values[5];

    if (sellerName == null || sellerName.trim().isEmpty) {
      throw const FormatException('لم يتم العثور على اسم المحل في رمز QR.');
    }
    if (issuedAtText == null || totalText == null || vatText == null) {
      throw const FormatException(
        'رمز QR لا يحتوي على حقول فاتورة الزكاة المطلوبة.',
      );
    }

    final issuedAt = DateTime.tryParse(issuedAtText);
    final totalAmount = _parseAmount(totalText);
    final vatAmount = _parseAmount(vatText);

    if (issuedAt == null || totalAmount == null || vatAmount == null) {
      throw const FormatException('تعذر قراءة التاريخ أو المبالغ من رمز QR.');
    }

    return Invoice(
      sellerName: sellerName.trim(),
      vatNumber: values[2]?.trim() ?? '',
      issuedAt: issuedAt,
      totalAmount: totalAmount,
      vatAmount: vatAmount,
      rawPayload: payload.trim(),
    );
  }

  static Map<int, String> _decodeTlv(String payload) {
    var encoded = payload.trim();
    final commaIndex = encoded.indexOf(',');
    if (encoded.startsWith('data:') && commaIndex >= 0) {
      encoded = encoded.substring(commaIndex + 1);
    }
    encoded = encoded.replaceAll(RegExp(r'\s+'), '').replaceAll('-', '+').replaceAll('_', '/');

    try {
      final bytes = base64.decode(base64.normalize(encoded));
      final fields = <int, String>{};
      var offset = 0;
      while (offset < bytes.length) {
        if (offset + 2 > bytes.length) {
          throw const FormatException('بنية TLV غير مكتملة.');
        }
        final tag = bytes[offset++];
        final length = bytes[offset++];
        if (offset + length > bytes.length) {
          throw const FormatException('طول بيانات TLV غير صحيح.');
        }
        fields[tag] = utf8.decode(bytes.sublist(offset, offset + length));
        offset += length;
      }
      return fields;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('رمز QR ليس Base64 صالحًا.');
    }
  }

  static double? _parseAmount(String value) {
    final normalized = value.trim().replaceAll(',', '');
    return double.tryParse(normalized);
  }

  static String formatDate(DateTime dateTime) =>
      DateFormat('dd/MM/yyyy', 'en_US').format(dateTime.toLocal());

  static String formatTime(DateTime dateTime) =>
      DateFormat('hh:mm a', 'en_US').format(dateTime.toLocal());
}
