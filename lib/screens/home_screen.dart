import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../data/database_service.dart';
import '../l10n.dart';
import '../models/invoice.dart';
import '../models/shop.dart';
import '../services/export_service.dart';
import '../services/zatca_qr_parser.dart';
import '../widgets/invoice_editor.dart';
import '../widgets/invoice_tile.dart';
import '../widgets/sar_symbol.dart';
import 'all_invoices_screen.dart';
import 'analysis_screen.dart';
import 'pdf_export_screen.dart';
import 'scanner_screen.dart';
import 'settings_screen.dart';
import 'shops_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.database,
    required this.darkMode,
    required this.onToggleTheme,
    required this.onToggleLanguage,
    super.key,
  });

  final DatabaseService database;
  final bool darkMode;
  final VoidCallback onToggleTheme;
  final VoidCallback onToggleLanguage;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _searchController = TextEditingController();
  List<Invoice> _invoices = const [];
  List<Shop> _shops = const [];
  int _tabIndex = 0;
  bool _loading = true;
  bool _busy = false;
  String? _loadError;
  String? _amountFilterOperator;
  double? _amountFilterValue;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final invoices = await widget.database.getInvoices();
      final shops = await widget.database.getShops();
      if (!mounted) return;
      setState(() {
        _invoices = invoices;
        _shops = shops;
        _loadError = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _scanCamera() async {
    final payload = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScannerScreen()));
    if (payload != null) await _parseAndSave(payload);
  }

  Future<void> _scanImage() async {
    final english = AppL10n.isEnglish(context);
    final image = await _imagePicker.pickImage(source: ImageSource.gallery);
    if (image == null) return;
    setState(() => _busy = true);
    final controller = MobileScannerController(autoStart: false);
    try {
      final capture = await controller.analyzeImage(
        image.path,
        formats: [BarcodeFormat.qrCode],
      );
      final payload = capture?.barcodes
          .map((barcode) => barcode.rawValue)
          .whereType<String>()
          .firstOrNull;
      if (payload == null || payload.isEmpty) {
        _message(
          english
              ? 'No QR code found in the image.'
              : 'لم يتم العثور على QR في الصورة.',
        );
      } else {
        await _parseAndSave(payload);
      }
    } on UnsupportedError {
      _message(
        english
            ? 'Image analysis is not supported here.'
            : 'قراءة الصور غير مدعومة على هذا الجهاز.',
      );
    } catch (error) {
      _message('${english ? 'Error' : 'حدث خطأ'}: $error');
    } finally {
      await controller.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _parseAndSave(String payload) async {
    final english = AppL10n.isEnglish(context);
    try {
      final parsed = ZatcaQrParser.parse(payload);
      final invoice = await showInvoiceEditor(context, parsed, review: true);
      if (invoice == null) return;
      await widget.database.insertInvoice(invoice);
      await _loadData();
      _message('${english ? 'Saved' : 'تم الحفظ'}: ${invoice.sellerName}');
    } on FormatException catch (error) {
      _message(error.message);
    } catch (error) {
      _message('${english ? 'Error' : 'حدث خطأ'}: $error');
    }
  }

  Future<void> _editInvoice(Invoice invoice) async {
    final savedText = tr(context, 'saved');
    final updated = await showInvoiceEditor(context, invoice);
    if (updated == null) return;
    await widget.database.updateInvoice(updated);
    await deleteReplacedInvoiceImage(invoice, updated);
    await _loadData();
    _message(savedText);
  }

  Future<void> _deleteInvoice(Invoice invoice) async {
    final deletedText = tr(context, 'deleted');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'deleteInvoice')),
        content: Text(tr(context, 'deleteConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || invoice.id == null) return;
    await widget.database.deleteInvoice(invoice.id!);
    await _loadData();
    _message(deletedText);
  }

  Future<void> _exportCsv() async {
    if (_invoices.isEmpty) return _message(tr(context, 'noInvoices'));
    final english = AppL10n.isEnglish(context);
    await _runBusy(
      () => ExportService.shareCsv(
        _invoices,
        english: english,
        shops: _shops,
      ),
    );
  }

  Future<void> _createBackup() async {
    final english = AppL10n.isEnglish(context);
    await _runBusy(() async {
      final archive = await widget.database.createBackupArchive();
      await ExportService.shareBackupFile(archive, english: english);
    });
  }

  Future<void> _restoreBackup() async {
    final errorText = tr(context, 'error');
    final savedText = tr(context, 'saved');
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr(context, 'restore')),
          content: Text(
            AppL10n.isEnglish(context)
                ? 'Restoring will replace current local data.'
                : 'الاسترداد سيستبدل البيانات المحلية الحالية.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, 'cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, 'restore')),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['zip', 'json'],
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final name = file.name.toLowerCase();
      if (name.endsWith('.json')) {
        await widget.database.restoreBackupJson(utf8.decode(bytes));
      } else {
        await widget.database.restoreBackupArchive(bytes);
      }
      await _loadData();
      _message(savedText);
    } catch (error) {
      _message('$errorText: $error');
    }
  }

  Future<void> _createPdf() async {
    if (_invoices.isEmpty) return _message(tr(context, 'noInvoices'));
    final english = AppL10n.isEnglish(context);
    final selected = await Navigator.of(context).push<List<Invoice>>(
      MaterialPageRoute(
        builder: (_) => PdfExportScreen(invoices: _invoices, shops: _shops),
      ),
    );
    if (selected == null || selected.isEmpty) return;
    await _runBusy(
      () => ExportService.sharePdf(selected, english: english, shops: _shops),
    );
  }

  Future<void> _openAllInvoices() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AllInvoicesScreen(
          database: widget.database,
          invoices: _invoices,
          onChanged: _loadData,
        ),
      ),
    );
  }

  Future<void> _showAmountFilter() async {
    var operator = _amountFilterOperator ?? '>=';
    final controller = TextEditingController(
      text: _amountFilterValue?.toStringAsFixed(2) ?? '',
    );
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(context, 'amountFilter')),
        content: StatefulBuilder(
          builder: (context, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: operator,
                decoration: InputDecoration(labelText: tr(context, 'amountCondition')),
                items: [
                  ('>', 'greaterThan'),
                  ('>=', 'greaterThanOrEqual'),
                  ('=', 'equalTo'),
                  ('<=', 'lessThanOrEqual'),
                  ('<', 'lessThan'),
                ].map((item) => DropdownMenuItem(
                  value: item.$1,
                  child: Text(tr(context, item.$2)),
                )).toList(),
                onChanged: (value) => setDialogState(() => operator = value ?? '>='),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: tr(context, 'amount'),
                  prefixIcon: const Icon(Icons.payments_outlined),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tr(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () {
              final amount = double.tryParse(controller.text.trim().replaceAll(',', ''));
              if (amount == null) return;
              Navigator.pop(dialogContext, {'operator': operator, 'value': amount});
            },
            child: Text(tr(context, 'applyFilter')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || result == null) return;
    setState(() {
      _amountFilterOperator = result['operator'] as String;
      _amountFilterValue = result['value'] as double;
    });
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    final errorText = tr(context, 'error');
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _message('$errorText: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _buildHomeTab(),
      ShopsTab(database: widget.database, shops: _shops, onChanged: _loadData),
      AnalysisTab(shops: _shops),
      SettingsTab(
        darkMode: widget.darkMode,
        onToggleTheme: widget.onToggleTheme,
        onToggleLanguage: widget.onToggleLanguage,
        onExportCsv: _exportCsv,
        onBackup: _createBackup,
        onRestore: _restoreBackup,
        onPdf: _createPdf,
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _tabIndex == 0
              ? tr(context, 'appTitle')
              : [
                  tr(context, 'shops'),
                  tr(context, 'analysis'),
                  tr(context, 'settings'),
                ][_tabIndex - 1],
        ),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_tabIndex == 0)
            IconButton(
              onPressed: _exportCsv,
              tooltip: tr(context, 'exportCsv'),
              icon: const Icon(Icons.file_download_outlined),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? _LoadError(error: _loadError!, onRetry: _loadData)
          : pages[_tabIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) => setState(() => _tabIndex = index),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(Icons.home_rounded),
            label: tr(context, 'home'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.store_outlined),
            selectedIcon: const Icon(Icons.store_rounded),
            label: tr(context, 'shops'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.insights_outlined),
            selectedIcon: const Icon(Icons.insights_rounded),
            label: tr(context, 'analysis'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings_rounded),
            label: tr(context, 'settings'),
          ),
        ],
      ),
      floatingActionButton: _tabIndex == 0
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : _scanCamera,
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: Text(tr(context, 'scan')),
            )
          : null,
    );
  }

  Widget _buildHomeTab() {
    final query = _searchController.text.trim().toLowerCase();
    final filtered = _invoices.where((invoice) {
      final matchesText = query.isEmpty ||
          invoice.sellerName.toLowerCase().contains(query) ||
          invoice.sellerNameEn.toLowerCase().contains(query) ||
          invoice.vatNumber.toLowerCase().contains(query) ||
          invoice.invoiceNumber.toLowerCase().contains(query);
      final filterValue = _amountFilterValue;
      final matchesAmount = filterValue == null || switch (_amountFilterOperator) {
        '>' => invoice.totalAmount > filterValue,
        '>=' => invoice.totalAmount >= filterValue,
        '=' => (invoice.totalAmount - filterValue).abs() < 0.005,
        '<=' => invoice.totalAmount <= filterValue,
        '<' => invoice.totalAmount < filterValue,
        _ => true,
      };
      return matchesText && matchesAmount;
    }).toList();
    final hasFilter = query.isNotEmpty || _amountFilterValue != null;
    final shown = hasFilter ? filtered : filtered.take(5).toList();
    final total = _invoices.fold<double>(
      0,
      (sum, item) => sum + item.totalAmount,
    );
    final tax = _invoices.fold<double>(0, (sum, item) => sum + item.vatAmount);

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          _buildIntro(),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _scanCamera,
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: Text(tr(context, 'camera')),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _scanImage,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Text(tr(context, 'fromImage')),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _searchController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: tr(context, 'search'),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: tr(context, 'amountFilter'),
                    onPressed: _showAmountFilter,
                    icon: Icon(
                      Icons.tune_rounded,
                      color: _amountFilterValue == null
                          ? null
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  if (_searchController.text.isNotEmpty)
                    IconButton(
                      onPressed: () {
                        _searchController.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.clear_rounded),
                    ),
                ],
              ),
            ),
          ),
          if (_amountFilterValue != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: InputChip(
                avatar: const Icon(Icons.filter_alt_outlined, size: 17),
                label: Text(
                  '${tr(context, 'filterActive')}: ${_amountFilterOperator!} ${_amountFilterValue!.toStringAsFixed(2)}',
                ),
                onDeleted: () => setState(() {
                  _amountFilterOperator = null;
                  _amountFilterValue = null;
                }),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _Summary(
                  label: tr(context, 'totalInvoices'),
                  value: '${_invoices.length}',
                  icon: Icons.receipt_long_outlined,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Summary(
                  label: tr(context, 'totalAmount'),
                  amount: total,
                  icon: Icons.payments_outlined,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Summary(
                  label: tr(context, 'totalTax'),
                  amount: tax,
                  icon: Icons.account_balance_wallet_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: Text(
                  !hasFilter
                      ? tr(context, 'latestInvoices')
                      : tr(context, 'allInvoices'),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              TextButton.icon(
                onPressed: _openAllInvoices,
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: Text(tr(context, 'showAll')),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  !hasFilter
                      ? tr(context, 'noInvoices')
                      : tr(context, 'noSearchResults'),
                ),
              ),
            )
          else
            ...shown.map(
              (invoice) => InvoiceTile(
                invoice: invoice,
                shopName: Shop.displayNameForInvoice(_shops, invoice),
                onEdit: () => _editInvoice(invoice),
                onDelete: () => _deleteInvoice(invoice),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildIntro() => Card(
    clipBehavior: Clip.antiAlias,
    child: Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0A7A67), Color(0xFF159E83)],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(context, 'scanNow'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  tr(context, 'scanHint'),
                  style: const TextStyle(color: Colors.white70, height: 1.35),
                ),
              ],
            ),
          ),
          Icon(
            Icons.receipt_long_rounded,
            size: 62,
            color: Colors.white.withValues(alpha: 0.9),
          ),
        ],
      ),
    ),
  );
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.label,
    this.value,
    this.amount,
    required this.icon,
  });

  final String label;
  final String? value;
  final double? amount;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 7),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 3),
          if (amount != null)
            SarAmount(
              amount: amount!,
              style: const TextStyle(fontWeight: FontWeight.w800),
              symbolSize: 12,
            )
          else
            Text(
              value ?? '',
              style: const TextStyle(fontWeight: FontWeight.w800),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    ),
  );
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            size: 58,
            color: Colors.redAccent,
          ),
          const SizedBox(height: 12),
          Text(
            AppL10n.isEnglish(context)
                ? 'Could not load local data.'
                : 'تعذر تحميل البيانات المحلية.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          SelectableText(error, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(
              AppL10n.isEnglish(context) ? 'Retry' : 'إعادة المحاولة',
            ),
          ),
        ],
      ),
    ),
  );
}

extension on Iterable<String?> {
  String? get firstOrNull {
    for (final item in this) {
      if (item != null) return item;
    }
    return null;
  }
}
