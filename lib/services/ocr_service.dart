import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';

/// On-device OCR for invoice photos, recognizing Arabic and English via the
/// Tesseract language data bundled in assets/tessdata.
class OcrService {
  const OcrService._();

  static Future<String> extractText(String imagePath) async {
    final text = await FlutterTesseractOcr.extractText(
      imagePath,
      language: 'ara+eng',
      // PSM_AUTO (3): the plugin's default PSM_AUTO_OSD requires the
      // osd.traineddata file we do not bundle, and would fail every run.
      args: const {'psm': '3', 'preserve_interword_spaces': '1'},
    );
    return text.trim();
  }
}
