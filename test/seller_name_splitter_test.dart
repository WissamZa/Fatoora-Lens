import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/services/seller_name_splitter.dart';

void main() {
  group('SellerNameSplitter', () {
    test('keeps a single-script name whole', () {
      final arabicOnly = SellerNameSplitter.split('سوبرماركت النخيل');
      expect(arabicOnly.arabic, 'سوبرماركت النخيل');
      expect(arabicOnly.english, '');

      final latinOnly = SellerNameSplitter.split('Al-Rajhi Trading Co.');
      expect(latinOnly.arabic, '');
      expect(latinOnly.english, 'Al-Rajhi Trading Co.');
    });

    test('returns empty parts for empty input', () {
      final empty = SellerNameSplitter.split('   ');
      expect(empty.arabic, '');
      expect(empty.english, '');
    });

    test('splits names joined by a newline', () {
      final parts = SellerNameSplitter.split('شركة بندة للتجزئة\nPanda Retail Company');
      expect(parts.arabic, 'شركة بندة للتجزئة');
      expect(parts.english, 'Panda Retail Company');
    });

    test('splits names joined by a pipe', () {
      final parts = SellerNameSplitter.split('متجر الأمل | Al Amal Store');
      expect(parts.arabic, 'متجر الأمل');
      expect(parts.english, 'Al Amal Store');
    });

    test('splits names inside brackets and trims the edges', () {
      final parts = SellerNameSplitter.split('(Panda | بندة)');
      expect(parts.arabic, 'بندة');
      expect(parts.english, 'Panda');
    });

    test('splits when the English name comes first', () {
      final parts = SellerNameSplitter.split('stc | الاتصالات السعودية');
      expect(parts.arabic, 'الاتصالات السعودية');
      expect(parts.english, 'stc');
    });

    test('splits names with no separator at all', () {
      final parts = SellerNameSplitter.split('شركة بندة للتجزئة Panda Retail Company');
      expect(parts.arabic, 'شركة بندة للتجزئة');
      expect(parts.english, 'Panda Retail Company');
    });

    test('keeps Latin hyphenated names intact', () {
      final parts = SellerNameSplitter.split('مؤسسة النهدي Al-Nahdi Trading');
      expect(parts.arabic, 'مؤسسة النهدي');
      expect(parts.english, 'Al-Nahdi Trading');
    });

    test('keeps a number at the script boundary with the preceding name', () {
      final parts = SellerNameSplitter.split('متجر 5 Store');
      expect(parts.arabic, 'متجر 5');
      expect(parts.english, 'Store');
    });

    test('keeps punctuation between runs of the same script', () {
      final parts = SellerNameSplitter.split('شركة الاتصالات stc Co. Ltd.');
      expect(parts.arabic, 'شركة الاتصالات');
      expect(parts.english, 'stc Co. Ltd.');
    });

    test('handles extended Arabic presentation forms', () {
      final parts = SellerNameSplitter.split('ﺷﺮﻛﺔ ﺍﻟﺒﻄﺮﺍء Al Batra Co.');
      expect(parts.arabic, 'ﺷﺮﻛﺔ ﺍﻟﺒﻄﺮﺍء');
      expect(parts.english, 'Al Batra Co.');
    });

    test('exposes script detection helpers', () {
      expect(SellerNameSplitter.isMixedScript('عربي English'), isTrue);
      expect(SellerNameSplitter.isMixedScript('عربي فقط'), isFalse);
      expect(SellerNameSplitter.containsArabic('عربي'), isTrue);
      expect(SellerNameSplitter.containsArabic('English'), isFalse);
      expect(SellerNameSplitter.containsLatin('English'), isTrue);
      expect(SellerNameSplitter.containsLatin('عربي'), isFalse);
    });
  });
}
