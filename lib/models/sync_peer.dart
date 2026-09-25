/// A device this one has successfully synced with. Saved automatically
/// after the first pairing so later sessions need no QR scan.
class SyncPeer {
  const SyncPeer({
    required this.deviceId,
    this.name = '',
    this.hostPublicKeyB64,
    this.pairToken,
    this.lastIp,
    this.lastPort,
    this.lastRole,
    this.lastSyncedAt,
  });

  final String deviceId;

  /// User-editable display name; empty falls back to a device-id snippet.
  final String name;

  /// The X25519 public key (base64) the peer uses when IT hosts a session.
  final String? hostPublicKeyB64;

  /// Shared pairing token exchanged inside the encrypted first session;
  /// proves a reconnecting peer is the one we paired with.
  final String? pairToken;

  /// Last known endpoint of the peer (meaningful when the peer hosted).
  final String? lastIp;
  final int? lastPort;

  /// The role the peer played in the last session: 'host' or 'guest'.
  final String? lastRole;

  final int? lastSyncedAt;

  String get displayName =>
      name.isNotEmpty ? name : 'جهاز ${deviceId.substring(0, 4)}';

  SyncPeer copyWith({
    String? name,
    String? hostPublicKeyB64,
    String? pairToken,
    String? lastIp,
    int? lastPort,
    String? lastRole,
    int? lastSyncedAt,
  }) => SyncPeer(
        deviceId: deviceId,
        name: name ?? this.name,
        hostPublicKeyB64: hostPublicKeyB64 ?? this.hostPublicKeyB64,
        pairToken: pairToken ?? this.pairToken,
        lastIp: lastIp ?? this.lastIp,
        lastPort: lastPort ?? this.lastPort,
        lastRole: lastRole ?? this.lastRole,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      );

  Map<String, Object?> toMap() => {
        'device_id': deviceId,
        'name': name,
        'host_public_key': hostPublicKeyB64,
        'pair_token': pairToken,
        'last_ip': lastIp,
        'last_port': lastPort,
        'last_role': lastRole,
        'last_synced_at': lastSyncedAt ?? DateTime.now().millisecondsSinceEpoch,
      };

  factory SyncPeer.fromMap(Map<String, Object?> map) => SyncPeer(
        deviceId: (map['device_id'] as String?) ?? '',
        name: (map['name'] as String?) ?? '',
        hostPublicKeyB64: map['host_public_key'] as String?,
        pairToken: map['pair_token'] as String?,
        lastIp: map['last_ip'] as String?,
        lastPort: map['last_port'] is int ? map['last_port'] as int : null,
        lastRole: map['last_role'] as String?,
        lastSyncedAt:
            map['last_synced_at'] is int ? map['last_synced_at'] as int : null,
      );
}
