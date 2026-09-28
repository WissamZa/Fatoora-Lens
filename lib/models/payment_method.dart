/// A payment method that can be attached to an invoice (cash, mada
/// network, credit card...). Seeded rows ship with fixed UUIDs so every
/// device agrees on their identity; user-created rows get fresh UUIDs.
class PaymentMethod {
  const PaymentMethod({
    required this.id,
    this.name = '',
    this.nameEn = '',
    this.icon = '',
    this.requiresCard = false,
    this.sortOrder = 0,
    this.deviceId = '',
    this.updatedAt,
    this.isSynced = false,
    this.isDeleted = false,
    this.createdAt,
  });

  /// Fixed ids of the methods seeded on first open.
  static const seedIds = <String>[
    '4c3bac01-f8d4-48b4-bd42-81abff84684c',
    'b3e41a51-299a-43eb-a91c-6c00ac4d41f8',
    'b5b90544-8dd9-4bbf-9b57-52aa966bd759',
    '22fd2fe3-7eec-4312-b1e2-3998aa086dea',
    'd87a887b-daa6-45f0-870d-5665ba04a711',
  ];

  final String id;
  final String name;
  final String nameEn;

  /// Key into the app's icon registry (see picker_icons.dart).
  final String icon;

  /// When true, picking this method also asks for a saved card so the
  /// invoice records which card paid (name + last 4 digits).
  final bool requiresCard;
  final int sortOrder;
  final String deviceId;
  final int? updatedAt;
  final bool isSynced;
  final bool isDeleted;
  final DateTime? createdAt;

  /// The name to show in the current UI language.
  String displayName({required bool english}) =>
      english && nameEn.trim().isNotEmpty ? nameEn.trim() : name;

  PaymentMethod copyWith({
    String? name,
    String? nameEn,
    String? icon,
    bool? requiresCard,
    int? sortOrder,
    int? updatedAt,
    bool? isSynced,
    bool? isDeleted,
  }) =>
      PaymentMethod(
        id: id,
        name: name ?? this.name,
        nameEn: nameEn ?? this.nameEn,
        icon: icon ?? this.icon,
        requiresCard: requiresCard ?? this.requiresCard,
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
        'requires_card': requiresCard ? 1 : 0,
        'sort_order': sortOrder,
        'device_id': deviceId,
        'updated_at': updatedAt ?? DateTime.now().millisecondsSinceEpoch,
        'is_synced': isSynced ? 1 : 0,
        'is_deleted': isDeleted ? 1 : 0,
        'created_at': (createdAt ?? DateTime.now()).toIso8601String(),
      };

  factory PaymentMethod.fromMap(Map<String, Object?> map) => PaymentMethod(
        id: (map['id'] as String?) ?? '',
        name: (map['name'] as String?) ?? '',
        nameEn: (map['name_en'] as String?) ?? '',
        icon: (map['icon'] as String?) ?? '',
        requiresCard: ((map['requires_card'] as num?) ?? 0) != 0,
        sortOrder: (map['sort_order'] as num?)?.toInt() ?? 0,
        deviceId: (map['device_id'] as String?) ?? '',
        updatedAt: map['updated_at'] is int ? map['updated_at'] as int : null,
        isSynced: ((map['is_synced'] as num?) ?? 0) != 0,
        isDeleted: ((map['is_deleted'] as num?) ?? 0) != 0,
        createdAt: DateTime.tryParse(map['created_at'] as String? ?? ''),
      );

  /// The payment methods installed on every fresh database, in display
  /// order. "شبكة" and credit cards ask for a saved card on the invoice.
  static const List<PaymentMethod> seeds = [
    PaymentMethod(
      id: '4c3bac01-f8d4-48b4-bd42-81abff84684c',
      name: 'نقدي',
      nameEn: 'Cash',
      icon: 'payments',
      sortOrder: 10,
    ),
    PaymentMethod(
      id: 'b3e41a51-299a-43eb-a91c-6c00ac4d41f8',
      name: 'شبكة',
      nameEn: 'Mada',
      icon: 'point_of_sale',
      requiresCard: true,
      sortOrder: 20,
    ),
    PaymentMethod(
      id: 'b5b90544-8dd9-4bbf-9b57-52aa966bd759',
      name: 'بطاقة ائتمانية',
      nameEn: 'Credit card',
      icon: 'credit_card',
      requiresCard: true,
      sortOrder: 30,
    ),
    PaymentMethod(
      id: '22fd2fe3-7eec-4312-b1e2-3998aa086dea',
      name: 'تحويل بنكي',
      nameEn: 'Bank transfer',
      icon: 'account_balance',
      sortOrder: 40,
    ),
    PaymentMethod(
      id: 'd87a887b-daa6-45f0-870d-5665ba04a711',
      name: 'محفظة إلكترونية',
      nameEn: 'Digital wallet',
      icon: 'account_balance_wallet',
      sortOrder: 50,
    ),
  ];
}

/// A saved bank card for classification only: name, description and the
/// last 4 digits. Full card numbers are never stored anywhere.
class PaymentCard {
  const PaymentCard({
    required this.id,
    this.name = '',
    this.description = '',
    this.last4 = '',
    this.deviceId = '',
    this.updatedAt,
    this.isSynced = false,
    this.isDeleted = false,
    this.createdAt,
  });

  final String id;
  final String name;

  /// Free-form note, e.g. the issuing bank or "salary card".
  final String description;

  /// Exactly the last four digits shown on the card.
  final String last4;
  final String deviceId;
  final int? updatedAt;
  final bool isSynced;
  final bool isDeleted;
  final DateTime? createdAt;

  PaymentCard copyWith({
    String? name,
    String? description,
    String? last4,
    int? updatedAt,
    bool? isSynced,
    bool? isDeleted,
  }) =>
      PaymentCard(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        last4: last4 ?? this.last4,
        deviceId: deviceId,
        updatedAt: updatedAt ?? this.updatedAt,
        isSynced: isSynced ?? this.isSynced,
        isDeleted: isDeleted ?? this.isDeleted,
        createdAt: createdAt,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'description': description,
        'last4': last4,
        'device_id': deviceId,
        'updated_at': updatedAt ?? DateTime.now().millisecondsSinceEpoch,
        'is_synced': isSynced ? 1 : 0,
        'is_deleted': isDeleted ? 1 : 0,
        'created_at': (createdAt ?? DateTime.now()).toIso8601String(),
      };

  factory PaymentCard.fromMap(Map<String, Object?> map) => PaymentCard(
        id: (map['id'] as String?) ?? '',
        name: (map['name'] as String?) ?? '',
        description: (map['description'] as String?) ?? '',
        last4: (map['last4'] as String?) ?? '',
        deviceId: (map['device_id'] as String?) ?? '',
        updatedAt: map['updated_at'] is int ? map['updated_at'] as int : null,
        isSynced: ((map['is_synced'] as num?) ?? 0) != 0,
        isDeleted: ((map['is_deleted'] as num?) ?? 0) != 0,
        createdAt: DateTime.tryParse(map['created_at'] as String? ?? ''),
      );
}
