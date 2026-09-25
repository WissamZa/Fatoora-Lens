import 'dart:convert';
import 'dart:typed_data';

/// A single message on the sync channel.
///
/// Two wire forms exist:
/// - [control]: a small JSON object sent as a text message (handshake,
///   pings, transfer metadata, acks).
/// - [blob]: raw binary payload sent as a binary message with a short
///   header, used for media chunks and bulk transfers.
class SyncFrame {
  SyncFrame.control({
    required this.type,
    required this.sessionId,
    required this.seq,
    Map<String, Object?>? data,
  })  : bytes = null,
        data = data ?? const {};

  SyncFrame.blob({required this.seq, required this.bytes, this.sessionId = ''})
      : type = SyncFrame.kTypeBlob,
        data = const {};

  /// Control frame type strings.
  static const kTypeHello = 'hello';
  static const kTypePing = 'ping';
  static const kTypePong = 'pong';
  static const kTypeBye = 'bye';
  static const kTypeError = 'error';
  static const kTypeBusy = 'busy';
  static const kTypeTransferStart = 'xfer-start';
  static const kTypeBlob = 'blob';

  /// Header magic for binary frames ("FL").
  static const int _magic0 = 0x46;
  static const int _magic1 = 0x4C;

  /// Maximum accepted blob payload (1 MiB) — anything larger is treated as
  /// a corrupt/garbage frame rather than a memory hazard.
  static const int maxBlobBytes = 1 << 20;

  final String type;
  final String sessionId;
  final int seq;
  final Map<String, Object?> data;
  final Uint8List? bytes;

  bool get isBlob => bytes != null;

  /// Encodes a control frame into the text message sent over the wire.
  String encodeControl() => jsonEncode({
        't': type,
        'sid': sessionId,
        'seq': seq,
        'd': data,
      });

  /// Encodes a blob frame into the binary message sent over the wire:
  /// `[magic 2][seq 4 BE][length 4 BE][payload]`.
  Uint8List encodeBlob() {
    final payload = bytes!;
    final out = Uint8List(10 + payload.length);
    out[0] = _magic0;
    out[1] = _magic1;
    final header = ByteData.view(out.buffer);
    header.setUint32(2, seq, Endian.big);
    header.setUint32(6, payload.length, Endian.big);
    out.setAll(10, payload);
    return out;
  }

  /// Parses an inbound WebSocket message into a frame, throwing
  /// [FormatException] for anything malformed.
  static SyncFrame decode(Object message) {
    if (message is String) {
      return _decodeControl(message);
    }
    if (message is List<int>) {
      return _decodeBlob(message);
    }
    throw const FormatException('Unsupported frame payload type.');
  }

  /// Decodes a decrypted channel payload, which may be either a control
  /// frame (JSON text) or a blob frame (binary with header).
  static SyncFrame decodeBytes(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == _magic0 && bytes[1] == _magic1) {
      return _decodeBlob(bytes);
    }
    return _decodeControl(utf8.decode(bytes));
  }

  static SyncFrame _decodeControl(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException('Control frame is not valid JSON.');
    }
    if (decoded is! Map) {
      throw const FormatException('Control frame must be a JSON object.');
    }
    final type = decoded['t'];
    final seq = decoded['seq'];
    if (type is! String || type.isEmpty) {
      throw const FormatException('Control frame is missing a type.');
    }
    if (seq is! int) {
      throw const FormatException('Control frame is missing a sequence.');
    }
    final data = decoded['d'];
    return SyncFrame.control(
      type: type,
      sessionId: decoded['sid'] is String ? decoded['sid'] as String : '',
      seq: seq,
      data: data is Map ? Map<String, Object?>.from(data) : const {},
    );
  }

  static SyncFrame _decodeBlob(List<int> raw) {
    if (raw.length < 10) {
      throw const FormatException('Blob frame header is truncated.');
    }
    final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
    if (bytes[0] != _magic0 || bytes[1] != _magic1) {
      throw const FormatException('Blob frame magic mismatch.');
    }
    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    final seq = view.getUint32(2, Endian.big);
    final length = view.getUint32(6, Endian.big);
    if (length > maxBlobBytes || 10 + length > bytes.length) {
      throw const FormatException('Blob frame length is invalid.');
    }
    return SyncFrame.blob(
      seq: seq,
      bytes: Uint8List.sublistView(bytes, 10, 10 + length),
    );
  }
}
