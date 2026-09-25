import 'dart:convert';

/// What the user chose to sync. Stored as JSON in the settings table and
/// sent during the session handshake so both ends agree on the scope.
class SyncPreferences {
  const SyncPreferences({
    this.syncInvoices = true,
    this.syncShopProfiles = true,
    this.syncImages = true,
    this.allowCloudFallback = true,
    this.issuedAtFrom,
  });

  static const String _settingsKey = 'sync_preferences';

  final bool syncInvoices;
  final bool syncShopProfiles;

  /// Whether image files are transferred. Invoice rows always sync; this
  /// only controls the binary media pipeline.
  final bool syncImages;

  /// WebRTC-over-Firebase fallback when the local network is unreachable.
  final bool allowCloudFallback;

  /// Optional lower bound on the invoice date for LIVE rows only;
  /// tombstones always sync so deletions are never lost.
  final DateTime? issuedAtFrom;

  SyncPreferences copyWith({
    bool? syncInvoices,
    bool? syncShopProfiles,
    bool? syncImages,
    bool? allowCloudFallback,
    DateTime? issuedAtFrom,
    bool clearIssuedAtFrom = false,
  }) => SyncPreferences(
        syncInvoices: syncInvoices ?? this.syncInvoices,
        syncShopProfiles: syncShopProfiles ?? this.syncShopProfiles,
        syncImages: syncImages ?? this.syncImages,
        allowCloudFallback: allowCloudFallback ?? this.allowCloudFallback,
        issuedAtFrom: clearIssuedAtFrom
            ? null
            : (issuedAtFrom ?? this.issuedAtFrom),
      );

  Map<String, Object?> toJson() => {
        'syncInvoices': syncInvoices,
        'syncShopProfiles': syncShopProfiles,
        'syncImages': syncImages,
        'allowCloudFallback': allowCloudFallback,
        'issuedAtFrom': issuedAtFrom?.toIso8601String(),
      };

  factory SyncPreferences.fromJson(Map<String, Object?> json) =>
      SyncPreferences(
        syncInvoices: (json['syncInvoices'] as bool?) ?? true,
        syncShopProfiles: (json['syncShopProfiles'] as bool?) ?? true,
        syncImages: (json['syncImages'] as bool?) ?? true,
        allowCloudFallback: (json['allowCloudFallback'] as bool?) ?? true,
        issuedAtFrom: json['issuedAtFrom'] is String
            ? DateTime.tryParse(json['issuedAtFrom'] as String)
            : null,
      );

  /// Loads the stored preferences, falling back to defaults.
  static Future<SyncPreferences> load(
    Future<String?> Function(String key) readSetting,
  ) async {
    final raw = await readSetting(_settingsKey);
    if (raw == null || raw.isEmpty) return const SyncPreferences();
    try {
      return SyncPreferences.fromJson(
        Map<String, Object?>.from(jsonDecode(raw) as Map),
      );
    } on FormatException {
      return const SyncPreferences();
    }
  }

  Future<void> save(Future<void> Function(String key, String value) writeSetting) =>
      writeSetting(_settingsKey, jsonEncode(toJson()));
}
