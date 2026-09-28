/// A user-facing shop category (supermarket, barber, bookstore...).
///
/// Seeded rows ship with fixed UUIDs so every device agrees on their
/// identity and the seed never duplicates after a sync; user-created
/// rows get fresh UUIDs. Deleted rows stay as tombstones so the removal
/// propagates to peers like invoices do.
class ShopCategory {
  const ShopCategory({
    required this.id,
    this.name = '',
    this.nameEn = '',
    this.icon = '',
    this.sortOrder = 0,
    this.deviceId = '',
    this.updatedAt,
    this.isSynced = false,
    this.isDeleted = false,
    this.createdAt,
  });

  /// Fixed ids of the categories seeded on first open, so a seed written
  /// on one device can never duplicate the same seed synced from another.
  static const seedIds = <String>[
    'd9474445-8eea-4e46-a1da-ee1b91a74545',
    '87bdba78-30cc-4f76-b6ac-114751edf802',
    '76320059-b6a0-4aa1-a609-1532bcd85725',
    '9369dce9-b3e3-4cdd-a356-00d5f629a0f9',
    '15ee5c39-c6ba-4285-b121-17de54b40629',
    '16dfa396-9c05-44dd-8de4-6156f358bfb2',
    'cd831f5b-a8af-4d00-94c9-f4083b76162e',
    'eba71aa9-9f0b-4ea6-ba64-dcaea7344483',
    'e17c138c-e90f-4bb6-85e2-9040e5147b49',
    '9bb1c57b-b9f5-44ce-af86-863510ee52b7',
  ];

  final String id;
  final String name;
  final String nameEn;

  /// Key into the app's icon registry (see picker_icons.dart); empty
  /// falls back to a default storefront icon.
  final String icon;
  final int sortOrder;
  final String deviceId;
  final int? updatedAt;
  final bool isSynced;
  final bool isDeleted;
  final DateTime? createdAt;

  /// The name to show in the current UI language.
  String displayName({required bool english}) =>
      english && nameEn.trim().isNotEmpty ? nameEn.trim() : name;

  ShopCategory copyWith({
    String? name,
    String? nameEn,
    String? icon,
    int? sortOrder,
    int? updatedAt,
    bool? isSynced,
    bool? isDeleted,
  }) =>
      ShopCategory(
        id: id,
        name: name ?? this.name,
        nameEn: nameEn ?? this.nameEn,
        icon: icon ?? this.icon,
        sortOrder: sortOrder ?? this.sortOrder,
        deviceId: deviceId,
        updatedAt: updatedAt ?? this.updatedAt,
        isSynced: isSynced ?? this.isSynced,
        isDeleted: isDeleted ?? this.isDeleted,
        createdAt: createdAt,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'name_en': nameEn,
        'icon': icon,
        'sort_order': sortOrder,
        'device_id': deviceId,
        'updated_at': updatedAt ?? DateTime.now().millisecondsSinceEpoch,
        'is_synced': isSynced ? 1 : 0,
        'is_deleted': isDeleted ? 1 : 0,
        'created_at': (createdAt ?? DateTime.now()).toIso8601String(),
      };

  factory ShopCategory.fromMap(Map<String, Object?> map) => ShopCategory(
        id: (map['id'] as String?) ?? '',
        name: (map['name'] as String?) ?? '',
        nameEn: (map['name_en'] as String?) ?? '',
        icon: (map['icon'] as String?) ?? '',
        sortOrder: (map['sort_order'] as num?)?.toInt() ?? 0,
        deviceId: (map['device_id'] as String?) ?? '',
        updatedAt: map['updated_at'] is int ? map['updated_at'] as int : null,
        isSynced: ((map['is_synced'] as num?) ?? 0) != 0,
        isDeleted: ((map['is_deleted'] as num?) ?? 0) != 0,
        createdAt: DateTime.tryParse(map['created_at'] as String? ?? ''),
      );

  /// The categories installed on every fresh database, in display order.
  static const List<ShopCategory> seeds = [
    ShopCategory(
      id: 'd9474445-8eea-4e46-a1da-ee1b91a74545',
      name: 'سوبرماركت',
      nameEn: 'Supermarket',
      icon: 'shopping_cart',
      sortOrder: 10,
    ),
    ShopCategory(
      id: '87bdba78-30cc-4f76-b6ac-114751edf802',
      name: 'مطعم',
      nameEn: 'Restaurant',
      icon: 'restaurant',
      sortOrder: 20,
    ),
    ShopCategory(
      id: '76320059-b6a0-4aa1-a609-1532bcd85725',
      name: 'مقهى',
      nameEn: 'Cafe',
      icon: 'local_cafe',
      sortOrder: 30,
    ),
    ShopCategory(
      id: '9369dce9-b3e3-4cdd-a356-00d5f629a0f9',
      name: 'حلاق',
      nameEn: 'Barber',
      icon: 'content_cut',
      sortOrder: 40,
    ),
    ShopCategory(
      id: '15ee5c39-c6ba-4285-b121-17de54b40629',
      name: 'مكتبة',
      nameEn: 'Bookstore',
      icon: 'menu_book',
      sortOrder: 50,
    ),
    ShopCategory(
      id: '16dfa396-9c05-44dd-8de4-6156f358bfb2',
      name: 'صيدلية',
      nameEn: 'Pharmacy',
      icon: 'local_pharmacy',
      sortOrder: 60,
    ),
    ShopCategory(
      id: 'cd831f5b-a8af-4d00-94c9-f4083b76162e',
      name: 'محطة وقود',
      nameEn: 'Gas station',
      icon: 'local_gas_station',
      sortOrder: 70,
    ),
    ShopCategory(
      id: 'eba71aa9-9f0b-4ea6-ba64-dcaea7344483',
      name: 'ملابس',
      nameEn: 'Clothing',
      icon: 'checkroom',
      sortOrder: 80,
    ),
    ShopCategory(
      id: 'e17c138c-e90f-4bb6-85e2-9040e5147b49',
      name: 'إلكترونيات',
      nameEn: 'Electronics',
      icon: 'devices',
      sortOrder: 90,
    ),
    ShopCategory(
      id: '9bb1c57b-b9f5-44ce-af86-863510ee52b7',
      name: 'أخرى',
      nameEn: 'Other',
      icon: 'category',
      sortOrder: 100,
    ),
  ];
}
