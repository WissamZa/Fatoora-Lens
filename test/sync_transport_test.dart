import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fatoora_lens/sync/protocol/sync_frame.dart';
import 'package:fatoora_lens/sync/transport/sync_transport.dart';

void main() {
  group('LoopbackTransport', () {
    test('delivers control frames both directions in order', () async {
      final (a, b) = LoopbackTransport.pair();

      final receivedOnB = <SyncFrame>[];
      final subB = b.frames.listen(receivedOnB.add);
      final receivedOnA = <SyncFrame>[];
      final subA = a.frames.listen(receivedOnA.add);

      for (var i = 1; i <= 5; i++) {
        await a.sendControl(SyncFrame.kTypePing, seq: i, sessionId: 's');
      }
      for (var i = 1; i <= 3; i++) {
        await b.sendControl(SyncFrame.kTypePong, seq: i, sessionId: 's');
      }
      // Streams deliver asynchronously; yield one microtask round.
      await Future<void>.delayed(Duration.zero);

      expect(
        [for (final frame in receivedOnB) frame.seq],
        [1, 2, 3, 4, 5],
      );
      expect(
        [for (final frame in receivedOnA) frame.seq],
        [1, 2, 3],
      );
      await subB.cancel();
      await subA.cancel();
      await a.close();
    });

    test('delivers blob frames with intact payloads', () async {
      final (a, b) = LoopbackTransport.pair();
      final received = <SyncFrame>[];
      final sub = b.frames.listen(received.add);

      final payload = Uint8List.fromList(List.generate(1000, (i) => i % 251));
      await a.sendBlob(seq: 9, bytes: payload);
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.single.seq, 9);
      expect(received.single.bytes, orderedEquals(payload));
      await sub.cancel();
      await a.close();
    });

    test('closing one end closes the peer and rejects further sends', () async {
      final (a, b) = LoopbackTransport.pair();
      await a.close();

      expect(a.currentState, TransportState.closed);
      await Future<void>.delayed(Duration.zero);
      expect(b.currentState, TransportState.closed);
      expect(
        () => b.sendControl(SyncFrame.kTypePing, seq: 1, sessionId: 's'),
        throwsA(isA<StateError>()),
      );
    });

    test('starts in the connected state', () {
      final (a, b) = LoopbackTransport.pair();
      expect(a.currentState, TransportState.connected);
      expect(b.currentState, TransportState.connected);
      a.close();
    });
  });
}
