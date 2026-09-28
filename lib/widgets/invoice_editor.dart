import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../data/database_service.dart';
import '../l10n.dart';
import '../models/invoice.dart';
import '../models/payment_method.dart';
import '../models/shop_category.dart';
import '../services/zatca_qr_parser.dart';
import '../screens/scanner_screen.dart';
import 'catalog_pickers.dart';
import 'ocr_text_sheet.dart';
import 'picker_icons.dart';
import 'sar_symbol.dart';

Future<Invoice?> showInvoiceEditor(
  BuildContext context,
  Invoice invoice, {
  bool review = false,
  required DatabaseService database,
}) {
  return showDialog<Invoice>(
    context: context,
    builder: (_) => _InvoiceEditorDialog(
      invoice: invoice,
      review: review,
      database: database,
    ),
  );
}

Future<void> deleteReplacedInvoiceImage(
  Invoice previous,
  Invoice updated,
) async {
  final oldImagePath = previous.imagePath;
  if (oldImagePath == null ||
      oldImagePath.isEmpty ||
      oldImagePath == updated.imagePath) {
    return;
  }
  try {
    await File(oldImagePath).delete();
  } catch (_) {
    // The invoice was saved successfully; a missing image should not change that.
  }
}

class _InvoiceEditorDialog extends StatefulWidget {
  const _InvoiceEditorDialog({
    required this.invoice,
    required this.review,
    required this.database,
  });

  final Invoice invoice;
  final bool review;
  final DatabaseService database;

  @override
  State<_InvoiceEditorDialog> createState() => _InvoiceEditorDialogState();
}

class _InvoiceEditorDialogState extends State<_InvoiceEditorDialog> {
  late final TextEditingController _sellerController;
  late final TextEditingController _sellerEnController;
  late final TextEditingController _vatController;
  late final TextEditingController _amountController;
  late final TextEditingController _taxController;
  late final TextEditingController _invoiceNumberController;
  late final TextEditingController _noteController;
  String? _imagePath;

  List<ShopCategory> _categories = const [];
  List<PaymentMethod> _methods = const [];
  List<PaymentCard> _cards = const [];
  String? _categoryId;
  late String? _initialCategoryId;
  String? _methodId;
  String? _cardId;

  @override
  void initState() {
    super.initState();
    final invoice = widget.invoice;
    _sellerController = TextEditingController(text: invoice.sellerName);
    _sellerEnController = TextEditingController(text: invoice.sellerNameEn);
    _vatController = TextEditingController(text: invoice.vatNumber);
    _amountController = TextEditingController(
      text: invoice.totalAmount.toStringAsFixed(2),
    );
    _taxController = TextEditingController(
      text: invoice.vatAmount.toStringAsFixed(2),
    );
    _invoiceNumberController = TextEditingController(text: invoice.invoiceNumber);
    _noteController = TextEditingController(text: invoice.note);
    _imagePath = invoice.imagePath;
    // Payment belongs to the invoice; the category belongs to the SHOP
    // and is preselected from its profile once catalogs load.
    _categoryId = null;
    _initialCategoryId = null;
    _methodId = invoice.paymentMethodId;
    _cardId = invoice.cardId;
    _loadCatalogs();
  }

  Future<void> _loadCatalogs() async {
    final categories = await widget.database.getShopCategories();
    final methods = await widget.database.getPaymentMethods();
    final cards = await widget.database.getPaymentCards();
    final profile = await widget.database.getShopProfile(
      vatNumber: widget.invoice.vatNumber,
      nameAr: widget.invoice.sellerName,
    );
    if (!mounted) return;
    setState(() {
      _categories = categories;
      _methods = methods;
      _cards = cards;
      _initialCategoryId = profile?.categoryId;
      _categoryId ??= _initialCategoryId;
    });
  }

  ShopCategory? get _selectedCategory {
    for (final category in _categories) {
      if (category.id == _categoryId) return category;
    }
    return null;
  }

  PaymentMethod? get _selectedMethod {
    for (final method in _methods) {
      if (method.id == _methodId) return method;
    }
    return null;
  }

  PaymentCard? get _selectedCard {
    for (final card in _cards) {
      if (card.id == _cardId) return card;
    }
    return null;
  }

  bool get _needsCard => _selectedMethod?.requiresCard ?? false;

  String _cardText() {
    final card = _selectedCard;
    if (card == null) return tr(context, 'none');
    return card.description.isEmpty
        ? '${card.name} •••• ${card.last4}'
        : '${card.name} (${card.description}) •••• ${card.last4}';
  }

  @override
  void dispose() {
    _sellerController.dispose();
    _sellerEnController.dispose();
    _vatController.dispose();
    _amountController.dispose();
    _taxController.dispose();
    _invoiceNumberController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final cropTitle = tr(context, 'cropImage');
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: source, imageQuality: 85);
      if (picked == null) return;

      final cropped = await ImageCropper().cropImage(
        sourcePath: picked.path,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: cropTitle,
            toolbarColor: const Color(0xFF0A7A67),
            toolbarWidgetColor: Colors.white,
            activeControlsWidgetColor: const Color(0xFF159E83),
            lockAspectRatio: false,
          ),
          IOSUiSettings(title: cropTitle),
        ],
      );
      if (cropped == null) return;

      final docDir = await getApplicationDocumentsDirectory();
      final imagesDir = Directory('${docDir.path}/invoice_images');
      if (!await imagesDir.exists()) {
        await imagesDir.create(recursive: true);
      }
      final filename = 'invoice_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final savedFile = await File(
        cropped.path,
      ).copy('${imagesDir.path}/$filename');

      if (!mounted) return;
      setState(() {
        _imagePath = savedFile.path;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${tr(context, 'error')}: $e')));
    }
  }

  Future<void> _showImageSourcePicker() async {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr(context, 'invoiceImage'),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.camera_alt_outlined),
                title: Text(tr(context, 'takePhoto')),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: Text(tr(context, 'chooseFromGallery')),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _viewFullImage(String path) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black87,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            Center(
              child: InteractiveViewer(
                clipBehavior: Clip.none,
                minScale: 0.5,
                maxScale: 4.0,
                child: Image.file(File(path), fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                style: IconButton.styleFrom(backgroundColor: Colors.black54),
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final seller = _sellerController.text.trim();
    final amount = double.tryParse(
      _amountController.text.trim().replaceAll(',', ''),
    );
    final tax = double.tryParse(_taxController.text.trim().replaceAll(',', ''));
    if (seller.isEmpty || amount == null || tax == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppL10n.isEnglish(context)
                ? 'Check the required fields.'
                : 'تحقق من الحقول المطلوبة.',
          ),
        ),
      );
      return;
    }
    final vat = _vatController.text.trim();
    // The category is a shop attribute: persist it on the shop profile
    // whenever it was touched, keyed by the shop's business identity.
    if (_categoryId != _initialCategoryId &&
        (vat.isNotEmpty || seller.isNotEmpty)) {
      await widget.database.setShopCategory(
        vatNumber: vat,
        nameAr: seller,
        categoryId: _categoryId,
      );
    }
    if (!mounted) return;
    final method = _selectedMethod;
    final card = _selectedCard;
    final wantsCard = method != null && method.requiresCard;
    Navigator.pop(
      context,
      widget.invoice.copyWith(
        sellerName: seller,
        sellerNameEn: _sellerEnController.text.trim(),
        vatNumber: vat,
        invoiceNumber: _invoiceNumberController.text.trim(),
        totalAmount: amount,
        vatAmount: tax,
        note: _noteController.text.trim(),
        imagePath: _imagePath,
        clearImage: _imagePath == null,
        paymentMethodId: method?.id,
        clearPaymentMethod: method == null,
        cardId: wantsCard ? card?.id : null,
        cardLast4: wantsCard ? card?.last4 : null,
        // Clearing the card also clears the last-4 snapshot together.
        clearCard: !wantsCard || card == null,
      ),
    );
  }

  Future<void> _pickCategory() async {
    final result = await showCategoryPickerSheet(
      context,
      database: widget.database,
      selectedCategoryId: _categoryId,
    );
    if (result == null || !mounted) return;
    await _loadCatalogs();
    if (!mounted) return;
    setState(() {
      _categoryId = result.cleared ? null : result.categoryId;
    });
  }

  Future<void> _pickPaymentMethod() async {
    final result = await showPaymentMethodPickerSheet(
      context,
      database: widget.database,
      selectedMethodId: _methodId,
    );
    if (result == null || !mounted) return;
    await _loadCatalogs();
    if (!mounted) return;
    setState(() {
      _methodId = result.isEmpty ? null : result;
      // Switching to a method that needs no card drops the card choice.
      if (!_needsCard) _cardId = null;
    });
  }

  Future<void> _pickCard() async {
    final result = await showCardPickerSheet(
      context,
      database: widget.database,
      selectedCardId: _cardId,
    );
    if (result == null || !mounted) return;
    await _loadCatalogs();
    if (!mounted) return;
    setState(() {
      _cardId = result.cleared ? null : result.card?.id;
    });
  }

  Future<void> _scanInvoiceNumber() async {
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const ScannerScreen(scanInvoiceNumber: true),
      ),
    );
    if (!mounted || value == null || value.trim().isEmpty) return;
    setState(() => _invoiceNumberController.text = value.trim());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasImage =
        _imagePath != null &&
        _imagePath!.isNotEmpty &&
        File(_imagePath!).existsSync();

    return AlertDialog(
      title: Text(tr(context, widget.review ? 'invoiceData' : 'editInvoice')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _sellerController,
              decoration: InputDecoration(
                labelText: tr(context, 'shop'),
                prefixIcon: const Icon(Icons.storefront_outlined),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _sellerEnController,
              decoration: InputDecoration(
                labelText: tr(context, 'sellerNameEn'),
                prefixIcon: const Icon(Icons.translate_rounded),
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _vatController,
              decoration: InputDecoration(
                labelText: tr(context, 'vatNumber'),
                prefixIcon: const Icon(Icons.pin_outlined),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _invoiceNumberController,
              decoration: InputDecoration(
                labelText: tr(context, 'invoiceNumber'),
                prefixIcon: const Icon(Icons.confirmation_number_outlined),
                suffixIcon: IconButton(
                  tooltip: tr(context, 'scanInvoiceNumber'),
                  onPressed: _scanInvoiceNumber,
                  icon: const Icon(Icons.barcode_reader),
                ),
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _amountController,
                    decoration: InputDecoration(
                      labelText: tr(context, 'amount'),
                      prefixIcon: const Padding(
                        padding: EdgeInsets.all(12),
                        child: SarSymbol(size: 16),
                      ),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _taxController,
                    decoration: InputDecoration(
                      labelText: tr(context, 'tax'),
                      prefixIcon: const Padding(
                        padding: EdgeInsets.all(12),
                        child: SarSymbol(size: 16),
                      ),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _noteController,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: tr(context, 'note'),
                prefixIcon: const Icon(Icons.edit_note_outlined),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 10),
            _PickerRow(
              label: tr(context, 'shopCategory'),
              value: _selectedCategory?.displayName(
                    english: AppL10n.isEnglish(context),
                  ) ??
                  tr(context, 'uncategorized'),
              icon: catalogIcon(_selectedCategory?.icon),
              onTap: _pickCategory,
            ),
            const SizedBox(height: 10),
            _PickerRow(
              label: tr(context, 'paymentMethod'),
              value: _selectedMethod?.displayName(
                    english: AppL10n.isEnglish(context),
                  ) ??
                  tr(context, 'none'),
              icon: catalogIcon(
                _selectedMethod?.icon,
                fallback: Icons.payments_outlined,
              ),
              onTap: _pickPaymentMethod,
            ),
            if (_needsCard) ...[
              const SizedBox(height: 10),
              _PickerRow(
                label: tr(context, 'paymentCard'),
                value: _cardText(),
                icon: Icons.credit_card_outlined,
                onTap: _pickCard,
              ),
            ],
            const SizedBox(height: 14),
            // Invoice Image section
            Text(
              tr(context, 'invoiceImage'),
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            if (hasImage) ...[
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => _viewFullImage(_imagePath!),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Image.file(
                              File(_imagePath!),
                              width: 64,
                              height: 64,
                              fit: BoxFit.cover,
                            ),
                            Container(
                              width: 64,
                              height: 64,
                              color: Colors.black26,
                              child: const Icon(
                                Icons.zoom_in_rounded,
                                color: Colors.white,
                                size: 22,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr(context, 'hasImage'),
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 8,
                            children: [
                              InkWell(
                                onTap: _showImageSourcePicker,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.edit_outlined,
                                        size: 14,
                                        color: theme.colorScheme.primary,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        tr(context, 'changeImage'),
                                        style: TextStyle(
                                          color: theme.colorScheme.primary,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: () => setState(() => _imagePath = null),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.delete_outline_rounded,
                                        size: 14,
                                        color: theme.colorScheme.error,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        tr(context, 'removeImage'),
                                        style: TextStyle(
                                          color: theme.colorScheme.error,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: () =>
                                    showOcrTextSheet(context, _imagePath!),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.document_scanner_outlined,
                                        size: 14,
                                        color: theme.colorScheme.primary,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        tr(context, 'extractText'),
                                        style: TextStyle(
                                          color: theme.colorScheme.primary,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              OutlinedButton.icon(
                onPressed: _showImageSourcePicker,
                icon: const Icon(Icons.add_a_photo_outlined, size: 20),
                label: Text(tr(context, 'addImage')),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                '${tr(context, 'date')}: ${ZatcaQrParser.formatDate(widget.invoice.issuedAt)}  •  ${ZatcaQrParser.formatTime(widget.invoice.issuedAt)}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, 'cancel')),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(
            widget.review ? tr(context, 'saveInvoice') : tr(context, 'save'),
          ),
        ),
      ],
    );
  }
}

/// A read-only field that opens a picker sheet, styled like the editor's
/// text inputs.
class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          suffixIcon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
        child: Text(value, style: const TextStyle(fontSize: 16)),
      ),
    );
  }
}
