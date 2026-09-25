import 'dart:convert';
import 'dart:typed_data';

/// Everything a guest needs to join a sync session, encoded in the host's
/// pairing QR code. The public key inside the QR is the trust anchor for
/// the encrypted channel.
class PairingInfo {
  const PairingInfo({
    required this.deviceId,
    required this.publicKeyB64,
    required this.ip,
    required this.port,
  });

  static const int protoVersion = 1;

  final String deviceId;
  final String publicKeyB64;
  final String ip;
  final int port;

  Uint8List get publicKeyBytes => base64Decode(publicKeyB64);

  String qrPayload() => jsonEncode({
        'fatoora-sync': protoVersion,
        'deviceId': deviceId,
        'pub': publicKeyB64,
        'ip': ip,
        'port': port,
      });

  factory PairingInfo.decode(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! Map ||
        decoded['fatoora-sync'] != protoVersion ||
        decoded['pub'] is! String ||
        decoded['ip'] is! String) {
      throw const FormatException('Not a Fatoora Lens pairing QR.');
    }
    final port = decoded['port'];
    return PairingInfo(
      deviceId: (decoded['deviceId'] as String?) ?? '',
      publicKeyB64: decoded['pub'] as String,
      ip: decoded['ip'] as String,
      port: port is int ? port : int.parse('$port'),
    );
  }
}
