import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n.dart';

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({this.scanInvoiceNumber = false, super.key});

  final bool scanInvoiceNumber;

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  late final MobileScannerController _controller;
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: widget.scanInvoiceNumber
          ? [
              BarcodeFormat.code128,
              BarcodeFormat.code39,
              BarcodeFormat.ean13,
              BarcodeFormat.ean8,
              BarcodeFormat.upcA,
              BarcodeFormat.upcE,
              BarcodeFormat.itf14,
              BarcodeFormat.codabar,
            ]
          : [BarcodeFormat.qrCode],
    );
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;
    final value = capture.barcodes
        .map((barcode) => barcode.rawValue)
        .whereType<String>()
        .firstOrNull;
    if (value == null || value.isEmpty) return;

    _handled = true;
    await _controller.stop();
    if (mounted) Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          tr(context, widget.scanInvoiceNumber ? 'scanInvoiceNumber' : 'scanTitle'),
        ),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: tr(context, 'flash'),
            onPressed: _controller.toggleTorch,
            icon: const Icon(Icons.flash_on_rounded),
          ),
          IconButton(
            tooltip: tr(context, 'switchCamera'),
            onPressed: _controller.switchCamera,
            icon: const Icon(Icons.flip_camera_android_rounded),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Center(
            child: Container(
              width: 270,
              height: 270,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 32,
            child: Text(
              tr(
                context,
                widget.scanInvoiceNumber ? 'invoiceNumberScanHint' : 'cameraScanHint',
              ),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

extension on Iterable<String?> {
  String? get firstOrNull {
    for (final item in this) {
      if (item != null) return item;
    }
    return null;
  }
}
