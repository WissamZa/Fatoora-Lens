import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../data/database_service.dart';
import '../l10n.dart';
import '../models/payment_method.dart';
import '../models/shop_category.dart';
import 'picker_icons.dart';

const Uuid _uuid = Uuid();

/// Result of picking a shop category: either a picked id or an explicit
/// clear, so "I did not touch it" stays distinguishable from "remove it".
class CategorySelection {
  const CategorySelection.picked(this.categoryId) : cleared = false;
  const CategorySelection.cleared()
      : categoryId = null,
        cleared = true;

  final String? categoryId;
  final bool cleared;
}

/// Result of picking a saved card for a card-paid invoice.
class CardSelection {
  const CardSelection.picked(this.card) : cleared = false;
  const CardSelection.cleared()
      : card = null,
        cleared = true;

  final PaymentCard? card;
  final bool cleared;
}

// ---- sheets ----------------------------------------------------------------

/// Category picker for the invoice editor: lists the catalog with a
/// "none" row and an inline add row that opens the edit dialog.
Future<CategorySelection?> showCategoryPickerSheet(
  BuildContext context, {
  required DatabaseService database,
  required String? selectedCategoryId,
}) {
  return showModalBottomSheet<CategorySelection>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _CategoryPickerSheet(
      database: database,
      selectedCategoryId: selectedCategoryId,
    ),
  );
}

class _CategoryPickerSheet extends StatefulWidget {
  const _CategoryPickerSheet({
    required this.database,
    required this.selectedCategoryId,
  });

  final DatabaseService database;
  final String? selectedCategoryId;

  @override
  State<_CategoryPickerSheet> createState() => _CategoryPickerSheetState();
}

class _CategoryPickerSheetState extends State<_CategoryPickerSheet> {
  late Future<List<ShopCategory>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.database.getShopCategories();
  }

  Future<void> _addCategory() async {
    final created = await showCategoryEditDialog(context);
    if (created == null) return;
    await widget.database.upsertShopCategory(created);
    if (!mounted) return;
    setState(() => _future = widget.database.getShopCategories());
  }

  @override
  Widget build(BuildContext context) {
    final english = AppL10n.isEnglish(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetHandle(),
            Text(
              tr(context, 'selectCategory'),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: FutureBuilder<List<ShopCategory>>(
                future: _future,
                builder: (context, snapshot) {
                  final categories = snapshot.data ?? const <ShopCategory>[];
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.block_outlined),
                        title: Text(tr(context, 'uncategorized')),
                        onTap: () =>
                            Navigator.pop(context, const CategorySelection.cleared()),
                      ),
                      for (final category in categories)
                        ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .primaryContainer,
                            child: Icon(
                              catalogIcon(category.icon),
                              size: 20,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          title: Text(category.displayName(english: english)),
                          trailing: category.id == widget.selectedCategoryId
                              ? Icon(
                                  Icons.check_rounded,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : null,
                          onTap: () => Navigator.pop(
                            context,
                            CategorySelection.picked(category.id),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            const Divider(height: 16),
            ListTile(
              leading: const Icon(Icons.add_circle_outline_rounded),
              title: Text(
                tr(context, 'addCategory'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              onTap: _addCategory,
            ),
          ],
        ),
      ),
    );
  }
}

/// Payment method picker; methods flagged as requiring a card make the
/// editor show the card row.
Future<String?> showPaymentMethodPickerSheet(
  BuildContext context, {
  required DatabaseService database,
  required String? selectedMethodId,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _PaymentMethodPickerSheet(
      database: database,
      selectedMethodId: selectedMethodId,
    ),
  );
}

class _PaymentMethodPickerSheet extends StatefulWidget {
  const _PaymentMethodPickerSheet({
    required this.database,
    required this.selectedMethodId,
  });

  final DatabaseService database;
  final String? selectedMethodId;

  @override
  State<_PaymentMethodPickerSheet> createState() =>
      _PaymentMethodPickerSheetState();
}

class _PaymentMethodPickerSheetState extends State<_PaymentMethodPickerSheet> {
  late Future<List<PaymentMethod>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.database.getPaymentMethods();
  }

  Future<void> _addMethod() async {
    final created = await showPaymentMethodEditDialog(context);
    if (created == null) return;
    await widget.database.upsertPaymentMethod(created);
    if (!mounted) return;
    setState(() => _future = widget.database.getPaymentMethods());
  }

  @override
  Widget build(BuildContext context) {
    final english = AppL10n.isEnglish(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetHandle(),
            Text(
              tr(context, 'selectPaymentMethod'),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: FutureBuilder<List<PaymentMethod>>(
                future: _future,
                builder: (context, snapshot) {
                  final methods = snapshot.data ?? const <PaymentMethod>[];
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.block_outlined),
                        title: Text(tr(context, 'none')),
                        // Empty string = explicit "no method"; a null pop
                        // means the sheet was dismissed without choosing.
                        onTap: () => Navigator.pop(context, ''),
                      ),
                      for (final method in methods)
                        ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .primaryContainer,
                            child: Icon(
                              catalogIcon(
                                method.icon,
                                fallback: Icons.payments_outlined,
                              ),
                              size: 20,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          title: Text(method.displayName(english: english)),
                          trailing: method.id == widget.selectedMethodId
                              ? Icon(
                                  Icons.check_rounded,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : null,
                          onTap: () => Navigator.pop(context, method.id),
                        ),
                    ],
                  );
                },
              ),
            ),
            const Divider(height: 16),
            ListTile(
              leading: const Icon(Icons.add_circle_outline_rounded),
              title: Text(
                tr(context, 'addPaymentMethod'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              onTap: _addMethod,
            ),
          ],
        ),
      ),
    );
  }
}

/// Saved-card picker with an inline add-card dialog.
Future<CardSelection?> showCardPickerSheet(
  BuildContext context, {
  required DatabaseService database,
  required String? selectedCardId,
}) {
  return showModalBottomSheet<CardSelection>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _CardPickerSheet(
      database: database,
      selectedCardId: selectedCardId,
    ),
  );
}

class _CardPickerSheet extends StatefulWidget {
  const _CardPickerSheet({
    required this.database,
    required this.selectedCardId,
  });

  final DatabaseService database;
  final String? selectedCardId;

  @override
  State<_CardPickerSheet> createState() => _CardPickerSheetState();
}

class _CardPickerSheetState extends State<_CardPickerSheet> {
  late Future<List<PaymentCard>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.database.getPaymentCards();
  }

  Future<void> _addCard() async {
    final created = await showCardEditDialog(context);
    if (created == null) return;
    await widget.database.upsertPaymentCard(created);
    if (!mounted) return;
    Navigator.pop(context, CardSelection.picked(created));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetHandle(),
            Text(
              tr(context, 'selectCard'),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: FutureBuilder<List<PaymentCard>>(
                future: _future,
                builder: (context, snapshot) {
                  final cards = snapshot.data ?? const <PaymentCard>[];
                  if (cards.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 8,
                      ),
                      child: Text(
                        tr(context, 'noCardsYet'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    );
                  }
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.block_outlined),
                        title: Text(tr(context, 'none')),
                        onTap: () =>
                            Navigator.pop(context, const CardSelection.cleared()),
                      ),
                      for (final card in cards)
                        ListTile(
                          leading: const Icon(Icons.credit_card_outlined),
                          title: Text(card.name),
                          subtitle: card.description.isEmpty
                              ? null
                              : Text(card.description),
                          trailing: Text(
                            '•••• ${card.last4}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                            ),
                          ),
                          selected: card.id == widget.selectedCardId,
                          onTap: () =>
                              Navigator.pop(context, CardSelection.picked(card)),
                        ),
                    ],
                  );
                },
              ),
            ),
            const Divider(height: 16),
            ListTile(
              leading: const Icon(Icons.add_circle_outline_rounded),
              title: Text(
                tr(context, 'addCard'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              onTap: _addCard,
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

// ---- edit dialogs ----------------------------------------------------------

/// Add/edit dialog for a shop category. Returns the (unsaved) category,
/// or null when cancelled.
Future<ShopCategory?> showCategoryEditDialog(
  BuildContext context, {
  ShopCategory? category,
}) {
  return showDialog<ShopCategory>(
    context: context,
    builder: (_) => _CategoryEditDialog(category: category),
  );
}

class _CategoryEditDialog extends StatefulWidget {
  const _CategoryEditDialog({this.category});

  final ShopCategory? category;

  @override
  State<_CategoryEditDialog> createState() => _CategoryEditDialogState();
}

class _CategoryEditDialogState extends State<_CategoryEditDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _nameEnController;
  late String _icon;

  /// Icon choices offered when creating/editing a category.
  static const _iconChoices = [
    'storefront',
    'shopping_cart',
    'restaurant',
    'local_cafe',
    'content_cut',
    'menu_book',
    'local_pharmacy',
    'local_gas_station',
    'checkroom',
    'devices',
    'flight',
    'school',
    'fitness_center',
    'pets',
    'diamond',
    'category',
  ];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.category?.name ?? '');
    _nameEnController =
        TextEditingController(text: widget.category?.nameEn ?? '');
    _icon = widget.category?.icon ?? 'storefront';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameEnController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(
      context,
      (widget.category ?? ShopCategory(id: _uuid.v4())).copyWith(
        name: name,
        nameEn: _nameEnController.text.trim(),
        icon: _icon,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr(
        context,
        widget.category == null ? 'addCategory' : 'editCategory',
      )),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: tr(context, 'categoryName'),
                prefixIcon: const Icon(Icons.storefront_outlined),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _nameEnController,
              decoration: InputDecoration(
                labelText: tr(context, 'categoryNameEn'),
                prefixIcon: const Icon(Icons.translate_rounded),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              tr(context, 'chooseIcon'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final key in _iconChoices)
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => setState(() => _icon = key),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: key == _icon
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Colors.transparent,
                        border: Border.all(
                          color: key == _icon
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      child: Icon(
                        catalogIcon(key),
                        size: 22,
                        color: key == _icon
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
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
          onPressed: _nameController.text.trim().isEmpty ? null : _save,
          child: Text(tr(context, 'save')),
        ),
      ],
    );
  }
}

/// Add/edit dialog for a payment method.
Future<PaymentMethod?> showPaymentMethodEditDialog(
  BuildContext context, {
  PaymentMethod? method,
}) {
  return showDialog<PaymentMethod>(
    context: context,
    builder: (_) => _PaymentMethodEditDialog(method: method),
  );
}

class _PaymentMethodEditDialog extends StatefulWidget {
  const _PaymentMethodEditDialog({this.method});

  final PaymentMethod? method;

  @override
  State<_PaymentMethodEditDialog> createState() =>
      _PaymentMethodEditDialogState();
}

class _PaymentMethodEditDialogState extends State<_PaymentMethodEditDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _nameEnController;
  late bool _requiresCard;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.method?.name ?? '');
    _nameEnController =
        TextEditingController(text: widget.method?.nameEn ?? '');
    _requiresCard = widget.method?.requiresCard ?? false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameEnController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(
      context,
      (widget.method ?? PaymentMethod(id: _uuid.v4())).copyWith(
        name: name,
        nameEn: _nameEnController.text.trim(),
        requiresCard: _requiresCard,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr(
        context,
        widget.method == null ? 'addPaymentMethod' : 'editPaymentMethod',
      )),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _nameController,
            autofocus: true,
            decoration: InputDecoration(
              labelText: tr(context, 'methodName'),
              prefixIcon: const Icon(Icons.payments_outlined),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _nameEnController,
            decoration: InputDecoration(
              labelText: tr(context, 'methodNameEn'),
              prefixIcon: const Icon(Icons.translate_rounded),
            ),
          ),
          const SizedBox(height: 6),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              tr(context, 'requiresCard'),
              style: const TextStyle(fontSize: 14),
            ),
            value: _requiresCard,
            onChanged: (value) => setState(() => _requiresCard = value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, 'cancel')),
        ),
        FilledButton(
          onPressed: _nameController.text.trim().isEmpty ? null : _save,
          child: Text(tr(context, 'save')),
        ),
      ],
    );
  }
}

/// Add/edit dialog for a saved card: name, description and exactly the
/// last four digits. There is no field for a full card number anywhere.
Future<PaymentCard?> showCardEditDialog(
  BuildContext context, {
  PaymentCard? card,
}) {
  return showDialog<PaymentCard>(
    context: context,
    builder: (_) => _CardEditDialog(card: card),
  );
}

class _CardEditDialog extends StatefulWidget {
  const _CardEditDialog({this.card});

  final PaymentCard? card;

  @override
  State<_CardEditDialog> createState() => _CardEditDialogState();
}

class _CardEditDialogState extends State<_CardEditDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _last4Controller;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.card?.name ?? '');
    _descriptionController =
        TextEditingController(text: widget.card?.description ?? '');
    _last4Controller = TextEditingController(text: widget.card?.last4 ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _last4Controller.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    final last4 = _last4Controller.text.trim();
    if (name.isEmpty || last4.length != 4) return;
    Navigator.pop(
      context,
      (widget.card ?? PaymentCard(id: _uuid.v4())).copyWith(
        name: name,
        description: _descriptionController.text.trim(),
        last4: last4,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final last4 = _last4Controller.text.trim();
    return AlertDialog(
      title: Text(tr(context, widget.card == null ? 'addCard' : 'editCard')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: tr(context, 'cardName'),
                prefixIcon: const Icon(Icons.credit_card_outlined),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _descriptionController,
              decoration: InputDecoration(
                labelText: tr(context, 'cardDescription'),
                prefixIcon: const Icon(Icons.notes_outlined),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _last4Controller,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: tr(context, 'cardLast4'),
                prefixIcon: const Icon(Icons.pin_outlined),
                errorText: last4.isNotEmpty && last4.length != 4
                    ? tr(context, 'cardLast4Error')
                    : null,
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 4,
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
          onPressed: _nameController.text.trim().isNotEmpty &&
                  last4.length == 4
              ? _save
              : null,
          child: Text(tr(context, 'save')),
        ),
      ],
    );
  }
}
