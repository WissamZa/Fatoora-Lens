import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/sync/protocol/sync_frame.dart';

void main() {
  group('SyncFrame control codec', () {
    test('round-trips a control frame with data', () {
      final frame = SyncFrame.control(
        type: SyncFrame.kTypePing,
        sessionId: 'sess-1',
        seq: 7,
        data: {'ts': 1729860000000, 'role': 'initiator'},
      );

      final decoded = SyncFrame.decode(frame.encodeControl());

      expect(decoded.isBlob, isFalse);
      expect(decoded.type, SyncFrame.kTypePing);
      expect(decoded.sessionId, 'sess-1');
      expect(decoded.seq, 7);
      expect(decoded.data['ts'], 1729860000000);
      expect(decoded.data['role'], 'initiator');
    });

    test('rejects non-JSON text and JSON that is not an object', () {
      expect(
        () => SyncFrame.decode('not json at all'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => SyncFrame.decode(jsonEncode(['array'])),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects control frames without a type or sequence', () {
      expect(
        () => SyncFrame.decode(jsonEncode({'sid': 'x', 'seq': 1})),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => SyncFrame.decode(jsonEncode({'t': 'ping', 'sid': 'x'})),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('SyncFrame blob codec', () {
    test('round-trips a blob frame with its header fields', () {
      final payload = Uint8List.fromList(List.generate(128, (i) => i & 0xFF));
      final frame = SyncFrame.blob(seq: 42, bytes: payload);

      final decoded = SyncFrame.decode(frame.encodeBlob());

      expect(decoded.isBlob, isTrue);
      expect(decoded.seq, 42);
      expect(decoded.bytes, hasLength(128));
      expect(decoded.bytes, orderedEquals(payload));
    });

    test('round-trips a zero-length blob', () {
      final decoded = SyncFrame.decode(
        SyncFrame.blob(seq: 1, bytes: Uint8List(0)).encodeBlob(),
      );
      expect(decoded.bytes, isEmpty);
    });

    test('rejects truncated headers and bad magic', () {
      expect(
        () => SyncFrame.decode(Uint8List.fromList([0x46])),
        throwsA(isA<FormatException>()),
      );
      final badMagic = SyncFrame.blob(seq: 1, bytes: Uint8List(4)).encodeBlob();
      badMagic[0] = 0x00;
      expect(
        () => SyncFrame.decode(badMagic),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a declared length larger than the message', () {
      final raw = SyncFrame.blob(seq: 1, bytes: Uint8List(4)).encodeBlob();
      ByteData.view(raw.buffer).setUint32(6, 9999, Endian.big);
      expect(
        () => SyncFrame.decode(raw),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects payloads exceeding the safety cap', () {
      final raw = SyncFrame.blob(seq: 1, bytes: Uint8List(4)).encodeBlob();
      ByteData.view(raw.buffer).setUint32(6, SyncFrame.maxBlobBytes + 1, Endian.big);
      expect(
        () => SyncFrame.decode(raw),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects unsupported payload types', () {
      expect(
        () => SyncFrame.decode(12345),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
