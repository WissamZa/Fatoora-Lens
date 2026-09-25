import 'dart:convert';

import 'package:intl/intl.dart';

import '../models/invoice.dart';
import 'seller_name_splitter.dart';

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

    // Tag 1 often carries both language names in one string ("عربي\nEnglish");
    // separate them so each is stored in its own field.
    final rawName = sellerName.trim();
    final nameParts = SellerNameSplitter.split(rawName);
    final hasArabicName = nameParts.arabic.isNotEmpty;

    return Invoice(
      sellerName: hasArabicName ? nameParts.arabic : rawName,
      sellerNameEn: hasArabicName ? nameParts.english : '',
      vatNumber: values[2]?.trim() ?? '',
      issuedAt: issuedAt,
      totalAmount: totalAmount,
      vatAmount: vatAmount,
      rawPayload: payload.trim(),
    );
  }

  /// Tags 1–5 are UTF-8 text fields required by the ZATCA standard.
  /// Tags 6–9 (Phase 2) carry binary data (hash, signature, public key,
  /// certificate) and must NOT be decoded as UTF-8.
  static const _textTags = {1, 2, 3, 4, 5};

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
        var length = bytes[offset++];

        // BER-TLV multi-byte length: if the high bit is set, the lower
        // 7 bits indicate how many following bytes encode the real length.
        if (length > 127) {
          final lengthBytes = length & 0x7F;
          if (lengthBytes == 0 || offset + lengthBytes > bytes.length) {
            throw const FormatException('طول بيانات TLV غير صحيح.');
          }
          length = 0;
          for (var i = 0; i < lengthBytes; i++) {
            length = (length << 8) | bytes[offset++];
          }
        }

        if (offset + length > bytes.length) {
          throw const FormatException('طول بيانات TLV غير صحيح.');
        }

        // Only decode text tags (1–5); skip binary tags (6+).
        if (_textTags.contains(tag)) {
          fields[tag] = utf8.decode(bytes.sublist(offset, offset + length));
        }
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
