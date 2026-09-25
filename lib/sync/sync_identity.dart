import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../data/database_service.dart';

/// This device's stable hosting identity for sync sessions.
///
/// The X25519 key pair is generated once, its seed is stored in the local
/// settings table, and the public half is what appears in the pairing QR
/// and inside saved peer records — so later sessions can re-establish the
/// encrypted channel without re-scanning the QR.
class SyncIdentity {
  SyncIdentity._();

  static const String _seedSettingKey = 'sync_host_key_seed';
  static final X25519 _x25519 = X25519();

  /// Loads (or creates) this device's persistent hosting key pair.
  static Future<SimpleKeyPair> loadHostKeyPair(DatabaseService database) async {
    final stored = await database.getSetting(_seedSettingKey);
    Uint8List seed;
    if (stored != null && stored.isNotEmpty) {
      seed = Uint8List.fromList(base64Decode(stored));
    } else {
      final random = Random.secure();
      seed = Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
      await database.setSetting(_seedSettingKey, base64Encode(seed));
    }
    return _x25519.newKeyPairFromSeed(seed);
  }

  /// A fresh pairing token (base64) shared with the peer inside the
  /// encrypted first session and stored by both sides for re-syncs.
  static String newPairToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Encode(bytes);
  }
}
