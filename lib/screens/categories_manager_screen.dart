import 'package:flutter/material.dart';

import '../data/database_service.dart';
import '../l10n.dart';
import '../models/shop_category.dart';
import '../widgets/catalog_pickers.dart';
import '../widgets/picker_icons.dart';

/// Manage the shop-category catalog: the seeded categories plus any the
/// user adds. Deletes are tombstoned so they propagate to sync peers.
class CategoriesManagerScreen extends StatefulWidget {
  const CategoriesManagerScreen({required this.database, super.key});

  final DatabaseService database;

  @override
  State<CategoriesManagerScreen> createState() =>
      _CategoriesManagerScreenState();
}

class _CategoriesManagerScreenState extends State<CategoriesManagerScreen> {
  late Future<List<ShopCategory>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.database.getShopCategories();
  }

  void _reload() {
    setState(() => _future = widget.database.getShopCategories());
  }

  Future<void> _add() async {
    final created = await showCategoryEditDialog(context);
    if (created == null) return;
    await widget.database.upsertShopCategory(created);
    _reload();
  }

  Future<void> _edit(ShopCategory category) async {
    final updated = await showCategoryEditDialog(context, category: category);
    if (updated == null) return;
    await widget.database.upsertShopCategory(updated);
    _reload();
  }

  Future<void> _delete(ShopCategory category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'deleteCategoryQ')),
        content: Text(tr(context, 'deleteCategoryConfirm')),
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
    if (confirmed != true) return;
    await widget.database.deleteShopCategory(category.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr(context, 'deleted'))),
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final english = AppL10n.isEnglish(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'manageCategories'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add_rounded),
        label: Text(tr(context, 'addCategory')),
      ),
      body: FutureBuilder<List<ShopCategory>>(
        future: _future,
        builder: (context, snapshot) {
          final categories = snapshot.data;
          if (categories == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (categories.isEmpty) {
            return Center(child: Text(tr(context, 'noData')));
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
            itemCount: categories.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final category = categories[index];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                        Theme.of(context).colorScheme.primaryContainer,
                    child: Icon(
                      catalogIcon(category.icon),
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  title: Text(
                    category.displayName(english: english),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: category.nameEn.isNotEmpty
                      ? Text(category.name)
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _edit(category),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.delete_outline_rounded,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        onPressed: () => _delete(category),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
