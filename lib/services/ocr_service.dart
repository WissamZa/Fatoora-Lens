import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';

/// On-device OCR for invoice photos, recognizing Arabic and English via the
/// Tesseract language data bundled in assets/tessdata.
class OcrService {
  const OcrService._();

  static Future<String> extractText(String imagePath) async {
    final text = await FlutterTesseractOcr.extractText(
      imagePath,
      language: 'ara+eng',
    );
    return text.trim();
  }
}
