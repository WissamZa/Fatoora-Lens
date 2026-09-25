import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../protocol/sync_frame.dart';
import '../transport/sync_transport.dart';

/// Handshake protocol version.
const int kSyncProtoVersion = 1;

/// Side of the session. The host's static public key travels inside the
/// pairing QR, which is what makes the handshake MITM-resistant: the peer
/// is authenticated by physically scanning the code.
enum SyncSide { host, guest }

/// Errors raised when the encrypted channel cannot be established or an
/// incoming frame fails authentication.
class SyncChannelException implements Exception {
  const SyncChannelException(this.message);

  final String message;

  @override
  String toString() => 'SyncChannelException: $message';
}

/// E2EE channel on top of any [SyncTransport].
///
/// Handshake: the guest generates an ephemeral X25519 key pair and sends
/// the public half in a plaintext `hs` frame; both sides then run ECDH —
/// guest(ephemeral private × host QR public) and host(static private ×
/// guest ephemeral public) — and derive two direction keys with HKDF so
/// the AES-GCM nonces (plain frame counters) never collide. Every frame
/// after the handshake is encrypted; a failed authentication tag aborts
/// the channel, which doubles as key confirmation.
class SyncSecureChannel implements SyncTransport {
  SyncSecureChannel._(
    this._transport,
    this._sendKey,
    this._receiveKey,
    this.sessionId,
  );

  static const String _hsFrameType = 'hs';
  static const String _hsOkFrameType = 'hs-ok';
  static const String _kdfInfoHostToGuest = 'fatoora-sync/v1 host->guest';
  static const String _kdfInfoGuestToHost = 'fatoora-sync/v1 guest->host';

  static final AesGcm _aes = AesGcm.with256bits();

  final SyncTransport _transport;
  final SecretKey _sendKey;
  final SecretKey _receiveKey;

  final String sessionId;

  int _sendCounter = 0;
  int _receiveCounter = 0;
  bool _closed = false;
  StreamSubscription<SyncFrame>? _subscription;
  Future<void> _processing = Future.value();
  final _frameController = StreamController<SyncFrame>.broadcast();

  @override
  TransportState get currentState => _transport.currentState;

  @override
  Stream<TransportState> get state => _transport.state;

  @override
  Stream<SyncFrame> get frames => _frameController.stream;

  /// Runs the handshake and returns the established channel.
  ///
  /// The host passes the static key pair whose public half is printed in
  /// the pairing QR; the guest passes those public bytes as scanned.
  static Future<SyncSecureChannel> establish({
    required SyncTransport transport,
    required SyncSide side,
    required String sessionId,
    KeyPair? hostStaticKeyPair,
    Uint8List? hostPublicKey,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final x25519 = X25519();
    final ephemeralPair = await x25519.newKeyPair();
    final ephemeralPublic = (await ephemeralPair.extractPublicKey()).bytes;

    SecretKey shared;
    if (side == SyncSide.guest) {
      if (hostPublicKey == null) {
        throw ArgumentError('Guest side requires hostPublicKey.');
      }
      shared = await x25519.sharedSecretKey(
        keyPair: ephemeralPair,
        remotePublicKey: SimplePublicKey(hostPublicKey, type: KeyPairType.x25519),
      );
      await transport.sendControl(
        _hsFrameType,
        seq: 0,
        sessionId: sessionId,
        data: {
          'proto': kSyncProtoVersion,
          'pub': base64Encode(ephemeralPublic),
        },
      );
      // Key confirmation arrives as the first successfully decrypted
      // frame; nothing plaintext is awaited here.
      final hsOk = await transport.frames
          .firstWhere((frame) => frame.type == _hsOkFrameType)
          .timeout(timeout);
      if (((hsOk.data['proto'] as num?)?.toInt() ?? 0) != kSyncProtoVersion) {
        throw const SyncChannelException('Protocol version mismatch.');
      }
    } else {
      final hs = await transport.frames
          .firstWhere((frame) => frame.type == _hsFrameType)
          .timeout(timeout);
      if (((hs.data['proto'] as num?)?.toInt() ?? 0) != kSyncProtoVersion) {
        throw const SyncChannelException('Protocol version mismatch.');
      }
      final remoteBytes = base64Decode('${hs.data['pub'] ?? ''}');
      if (hostStaticKeyPair == null) {
        throw ArgumentError('Host side requires hostStaticKeyPair.');
      }
      shared = await x25519.sharedSecretKey(
        keyPair: hostStaticKeyPair,
        remotePublicKey:
            SimplePublicKey(remoteBytes, type: KeyPairType.x25519),
      );
      await transport.sendControl(
        _hsOkFrameType,
        seq: 0,
        sessionId: sessionId,
        data: {'proto': kSyncProtoVersion},
      );
    }

    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final sendKey = await hkdf.deriveKey(
      secretKey: shared,
      info: utf8.encode(
        side == SyncSide.host ? _kdfInfoHostToGuest : _kdfInfoGuestToHost,
      ),
    );
    final receiveKey = await hkdf.deriveKey(
      secretKey: shared,
      info: utf8.encode(
        side == SyncSide.host ? _kdfInfoGuestToHost : _kdfInfoHostToGuest,
      ),
    );

    final channel = SyncSecureChannel._(transport, sendKey, receiveKey, sessionId);
    channel._listen();
    return channel;
  }

  void _listen() {
    _subscription = _transport.frames.listen(
      (frame) {
        // Serial queue: decryption is async, frames must stay in order so
        // the receive counter can reject replays.
        _processing = _processing
            .then((_) => _handleFrame(frame))
            .catchError((Object error, StackTrace stackTrace) {
          if (!_frameController.isClosed) {
            _frameController.addError(error, stackTrace);
          }
        });
      },
      onError: (Object error) {
        if (!_frameController.isClosed) _frameController.addError(error);
      },
      onDone: () {
        if (!_frameController.isClosed) _frameController.close();
      },
    );
  }

  Future<void> _handleFrame(SyncFrame frame) async {
    if (_closed) return;
    if (frame.type == _hsOkFrameType || frame.type == _hsFrameType) {
      return; // Handshake frames never appear after establishment.
    }
    if (!frame.isBlob || frame.bytes == null) {
      _fail(const SyncChannelException('Expected an encrypted blob frame.'));
      return;
    }
    final bytes = frame.bytes!;
    if (bytes.length < 16) {
      _fail(const SyncChannelException('Encrypted frame is too short.'));
      return;
    }
    final expectedCounter = _receiveCounter + 1;
    // A frame with an unexpected counter is a replay or desync: reject it
    // before spending any decryption work.
    final cipherText = bytes.sublist(0, bytes.length - 16);
    final mac = bytes.sublist(bytes.length - 16);
    try {
      final clear = await _aes.decrypt(
        SecretBox(
          cipherText,
          nonce: _nonce(expectedCounter),
          mac: Mac(mac),
        ),
        secretKey: _receiveKey,
      );
      _receiveCounter = expectedCounter;
      final inner = SyncFrame.decodeBytes(Uint8List.fromList(clear));
      if (!_frameController.isClosed) _frameController.add(inner);
    } on SecretBoxAuthenticationError {
      _fail(const SyncChannelException('Frame authentication failed.'));
    }
  }

  void _fail(SyncChannelException error) {
    if (!_frameController.isClosed) _frameController.addError(error);
  }

  Uint8List _nonce(int counter) {
    final nonce = Uint8List(12);
    ByteData.view(nonce.buffer).setUint64(4, counter, Endian.big);
    return nonce;
  }

  @override
  Future<void> sendControl(
    String type, {
    required int seq,
    String? sessionId,
    Map<String, Object?>? data,
  }) {
    return _sendEncrypted(
      Uint8List.fromList(
        utf8.encode(
          SyncFrame.control(
            type: type,
            sessionId: sessionId ?? this.sessionId,
            seq: seq,
            data: data,
          ).encodeControl(),
        ),
      ),
    );
  }

  @override
  Future<void> sendBlob({required int seq, required Uint8List bytes}) {
    return _sendEncrypted(SyncFrame.blob(seq: seq, bytes: bytes).encodeBlob());
  }

  Future<void> _sendEncrypted(List<int> clearBytes) async {
    if (_closed) throw StateError('Secure channel is closed.');
    final counter = _sendCounter + 1;
    // No AAD on purpose: the direction keys are derived from a fresh
    // ECDH per session, so a session id that the two peers might encode
    // differently (e.g. timestamp-based) must not silently break the
    // authentication tag. Counter nonces already isolate sessions.
    final box = await _aes.encrypt(
      clearBytes,
      secretKey: _sendKey,
      nonce: _nonce(counter),
    );
    final out = Uint8List(box.cipherText.length + box.mac.bytes.length);
    out.setAll(0, box.cipherText);
    out.setAll(box.cipherText.length, box.mac.bytes);
    _sendCounter = counter;
    await _transport.sendBlob(seq: counter, bytes: out);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    await _frameController.close();
  }
}
