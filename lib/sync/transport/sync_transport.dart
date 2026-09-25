import 'dart:async';
import 'dart:typed_data';

import '../protocol/sync_frame.dart';

/// Lifecycle of a transport connection.
enum TransportState { idle, listening, connecting, connected, closed, error }

/// Carries sync frames between two devices. The sync protocol is defined
/// entirely on top of this interface, so the carrier (loopback, local
/// WebSocket, WebRTC data channel) can be swapped without touching it.
abstract class SyncTransport {
  /// Inbound frames, in arrival order.
  Stream<SyncFrame> get frames;

  /// Connection lifecycle events.
  Stream<TransportState> get state;

  TransportState get currentState;

  Future<void> sendControl(
    String type, {
    required int seq,
    String? sessionId,
    Map<String, Object?>? data,
  });

  Future<void> sendBlob({required int seq, required Uint8List bytes});

  Future<void> close();
}

/// Shared plumbing for transports: state broadcasting, frame decoding and
/// safe shutdown. Concrete transports deliver raw socket messages to
/// [ingest] and implement [onClose] for socket teardown.
abstract class BaseTransport implements SyncTransport {
  final _stateController = StreamController<TransportState>.broadcast();
  final _frameController = StreamController<SyncFrame>.broadcast();
  TransportState _state = TransportState.idle;
  bool _closed = false;

  @override
  TransportState get currentState => _state;

  @override
  Stream<SyncFrame> get frames => _frameController.stream;

  @override
  Stream<TransportState> get state => _stateController.stream;

  bool get isClosed => _closed;

  /// Called by the concrete transport when a raw socket message arrives.
  void ingest(dynamic message) {
    if (_closed) return;
    try {
      _frameController.add(SyncFrame.decode(message));
    } on FormatException catch (error) {
      _frameController.addError(error);
    }
  }

  void setState(TransportState state) {
    _state = state;
    if (!_stateController.isClosed) _stateController.add(state);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    setState(TransportState.closed);
    await onClose();
    await _frameController.close();
    await _stateController.close();
  }

  /// Socket teardown, invoked once by [close] before streams close.
  Future<void> onClose();
}

/// Two in-memory transports wired to each other, used by tests and by the
/// self-diagnostic so the whole protocol can run without a network.
class LoopbackTransport extends BaseTransport {
  LoopbackTransport._();

  LoopbackTransport? _other;
  bool _peerClosed = false;

  /// Creates a connected pair of transports.
  static (LoopbackTransport, LoopbackTransport) pair() {
    final a = LoopbackTransport._();
    final b = LoopbackTransport._();
    a._other = b;
    b._other = a;
    a.setState(TransportState.connected);
    b.setState(TransportState.connected);
    return (a, b);
  }

  LoopbackTransport get _peer {
    final peer = _other;
    if (peer == null) {
      throw StateError('Loopback transport has no peer attached.');
    }
    return peer;
  }

  @override
  Future<void> sendControl(
    String type, {
    required int seq,
    String? sessionId,
    Map<String, Object?>? data,
  }) async {
    _ensureOpen();
    _peer.ingest(
      SyncFrame.control(
        type: type,
        sessionId: sessionId ?? '',
        seq: seq,
        data: data,
      ).encodeControl(),
    );
  }

  @override
  Future<void> sendBlob({required int seq, required Uint8List bytes}) async {
    _ensureOpen();
    _peer.ingest(SyncFrame.blob(seq: seq, bytes: bytes).encodeBlob());
  }

  void _ensureOpen() {
    if (isClosed || _peerClosed) {
      throw StateError('Loopback transport is closed.');
    }
  }

  @override
  Future<void> close() async {
    final peer = _other;
    _peerClosed = true;
    await super.close();
    if (peer != null && !peer.isClosed) {
      peer._peerClosed = true;
      await peer.close();
    }
  }

  @override
  Future<void> onClose() async {}
}
