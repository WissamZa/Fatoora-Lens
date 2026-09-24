/// بيانات نافذة «حول التطبيق».
///
/// عدّل القيم هنا مباشرة لتظهر في الإعدادات — لا حاجة لتغيير أي ملف آخر.
///
/// رقم النسخة ليس هنا: يُدار من سطر `version` في pubspec.yaml فقط،
/// وتقرأه نافذة «حول التطبيق» تلقائيًا عند التشغيل.
class AppInfo {
  static const String appNameAr = 'عدسة فاتورة';
  static const String appNameEn = 'Fatoora Lens';

  static const String developerName = 'WissamZa';

  static const String descriptionAr =
      'تطبيق لمسح رمز QR لفواتير ZATCA الإلكترونية، واستخراج بياناتها وتخزينها محليًا على جهازك مع إمكانية تصديرها بصيغة CSV وPDF وإنشاء نسخ احتياطية.';
  static const String descriptionEn =
      'Scan ZATCA e-invoice QR codes, extract and store their data locally on your device, with CSV and PDF export and backup support.';

  /// اتركه فارغًا لإخفاء السطر من نافذة «حول التطبيق».
  static const String contactEmail = '';
  static const String contactPhone = '';
}
