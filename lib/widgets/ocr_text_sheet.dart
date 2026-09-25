import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n.dart';
import '../services/ocr_service.dart';

/// Runs OCR on the invoice photo and shows the recognized text in a bottom
/// sheet, selectable and copyable.
Future<void> showOcrTextSheet(BuildContext context, String imagePath) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _OcrTextSheet(imagePath: imagePath),
  );
}

class _OcrTextSheet extends StatefulWidget {
  const _OcrTextSheet({required this.imagePath});

  final String imagePath;

  @override
  State<_OcrTextSheet> createState() => _OcrTextSheetState();
}

class _OcrTextSheetState extends State<_OcrTextSheet> {
  String? _text;
  String? _error;

  @override
  void initState() {
    super.initState();
    _extract();
  }

  Future<void> _extract() async {
    try {
      final text = await OcrService.extractText(widget.imagePath);
      if (!mounted) return;
      setState(() => _text = text);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  void _copyAll() {
    final text = _text;
    if (text == null || text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr(context, 'copied')), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 12, bottom: 14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr(context, 'extractText'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (_text != null && _text!.isNotEmpty)
                    FilledButton.tonalIcon(
                      onPressed: _copyAll,
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: Text(tr(context, 'copyAll')),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.error_outline_rounded, size: 44, color: Colors.redAccent),
                          const SizedBox(height: 10),
                          Text(
                            tr(context, 'ocrFailed'),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 8),
                          SelectableText(
                            _error ?? '',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    )
                  : _text == null
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 14),
                        Text(tr(context, 'ocrProcessing')),
                      ],
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                      child: SelectableText(
                        _text!.isEmpty ? tr(context, 'ocrEmpty') : _text!,
                        style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
