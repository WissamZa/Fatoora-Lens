import 'package:flutter/material.dart';

/// Maps the icon keys stored in the catalog tables (shop categories,
/// payment methods) to Material icons. Keys are plain strings so the
/// synced rows stay JSON-safe and forward-compatible.
const Map<String, IconData> kCatalogIcons = {
  // Shop category keys
  'shopping_cart': Icons.shopping_cart_outlined,
  'restaurant': Icons.restaurant_outlined,
  'local_cafe': Icons.local_cafe_outlined,
  'content_cut': Icons.content_cut_outlined,
  'menu_book': Icons.menu_book_outlined,
  'local_pharmacy': Icons.local_pharmacy_outlined,
  'local_gas_station': Icons.local_gas_station_outlined,
  'checkroom': Icons.checkroom_outlined,
  'devices': Icons.devices_outlined,
  'category': Icons.category_outlined,
  'storefront': Icons.storefront_outlined,
  'fastfood': Icons.fastfood_outlined,
  'flight': Icons.flight_outlined,
  'school': Icons.school_outlined,
  'fitness_center': Icons.fitness_center_outlined,
  'pets': Icons.pets_outlined,
  'toys': Icons.toys_outlined,
  'car_repair': Icons.car_repair_outlined,
  'diamond': Icons.diamond_outlined,
  // Payment method keys
  'payments': Icons.payments_outlined,
  'point_of_sale': Icons.point_of_sale_outlined,
  'credit_card': Icons.credit_card_outlined,
  'account_balance': Icons.account_balance_outlined,
  'account_balance_wallet': Icons.account_balance_wallet_outlined,
  'wallet': Icons.wallet_outlined,
};

/// Resolves an icon key, falling back when empty or unknown.
IconData catalogIcon(
  String? key, {
  IconData fallback = Icons.storefront_outlined,
}) =>
    kCatalogIcons[key ?? ''] ?? fallback;
