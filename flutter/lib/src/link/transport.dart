/// Transports: reliable, ordered byte pipes to the peer.
///
/// Mirrors Tether's Android `link/Transport.kt`. A transport only moves
/// bytes; framing, handshake and records live in [LinkConnection] above
/// it, so the same code runs over BLE L2CAP/GATT (via platform channels),
/// plain TCP (far mode, e.g. over Tailscale) and WebRTC data channels
/// (far mode, via Cloudflare TURN) alike.
library;

import 'dart:async';
import 'dart:io' show Socket;
import 'dart:typed_data' show Uint8List;

/// A reliable, ordered byte pipe to the peer.
abstract class Transport {
  /// Short name used in logs and in the clients list: `l2cap`, `gatt`,
  /// `tcp`, `fake`.
  String get label;

  /// The peer's address: a Bluetooth MAC, a `host:port`, or a test id.
  String get address;

  /// A test transport: whatever its client asks is never done for real
  /// (no call, SMS or edit), however late it runs.
  bool get dry => false;

  /// Starts reading. [onBytes] is called with each chunk received;
  /// [onClosed] once when the pipe ends (remote close or error).
  void start(
      void Function(List<int> bytes, int length) onBytes, void Function() onClosed);

  /// Writes bytes. Throws [StateError] after [close].
  void write(List<int> bytes);

  /// Closes the pipe. Idempotent; [onClosed] fires at most once.
  void close();
}

/// An in-memory transport pair, for tests and on-device self-tests.
///
/// `FakeTransport.pair()` returns two transports wired to each other:
/// bytes written on one arrive at the other's `onBytes`. Delivery is
/// asynchronous (a microtask), like real I/O, so tests must let the
/// event loop run — see [settle] in the tests.
class FakeTransport implements Transport {
  FakeTransport({
    this.label = 'fake',
    this.address = 'fake',
    this.dry = false,
  });

  /// Creates two transports wired to each other.
  static (FakeTransport, FakeTransport) pair({
    String label = 'fake',
    String addressA = 'fake-a',
    String addressB = 'fake-b',
    bool dry = false,
  }) {
    final a = FakeTransport(label: label, address: addressA, dry: dry);
    final b = FakeTransport(label: label, address: addressB, dry: dry);
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  @override
  final String label;

  @override
  final String address;

  @override
  final bool dry;

  FakeTransport? _peer;
  void Function(List<int>, int)? _onBytes;
  void Function()? _onClosed;
  bool _closed = false;
  bool _closedNotified = false;

  /// Bytes written through this transport (test observation).
  int bytesWritten = 0;

  bool get isClosed => _closed;

  @override
  void start(void Function(List<int> bytes, int length) onBytes,
      void Function() onClosed) {
    _onBytes = onBytes;
    _onClosed = onClosed;
  }

  @override
  void write(List<int> bytes) {
    if (_closed) throw StateError('transport closed');
    bytesWritten += bytes.length;
    final peer = _peer;
    if (peer == null) return;
    final copy = List<int>.of(bytes);
    scheduleMicrotask(() {
      if (!peer._closed) peer._onBytes?.call(copy, copy.length);
    });
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _notifyClosed();
    // The other side sees EOF, like a socket.
    final peer = _peer;
    if (peer != null && !peer._closed) {
      scheduleMicrotask(peer._notifyClosed);
    }
  }

  void _notifyClosed() {
    if (_closedNotified) return;
    _closedNotified = true;
    scheduleMicrotask(() => _onClosed?.call());
  }
}

/// A TCP transport: one [Socket] carrying the record byte stream.
///
/// Used for the far mode: the two phones talk to each other over a plain
/// TCP socket — directly over the Tailscale tailnet, or through a relay.
/// The byte stream is identical to the BLE one, so the handshake and
/// records above it do not change.
class TcpTransport implements Transport {
  TcpTransport._(this._socket, {required this.label});

  /// Connects to a listening peer.
  static Future<TcpTransport> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    return TcpTransport._(socket, label: 'tcp');
  }

  /// Wraps an already-connected socket (e.g. from a server accept).
  factory TcpTransport.fromSocket(Socket socket, {String label = 'tcp'}) =>
      TcpTransport._(socket, label: label);

  final Socket _socket;

  @override
  final String label;

  @override
  bool get dry => false;

  @override
  String get address =>
      '${_socket.remoteAddress.address}:${_socket.remotePort}';

  StreamSubscription<Uint8List>? _subscription;
  void Function()? _onClosed;
  bool _closed = false;
  bool _closedNotified = false;

  @override
  void start(void Function(List<int> bytes, int length) onBytes,
      void Function() onClosed) {
    _onClosed = onClosed;
    _subscription = _socket.listen(
      (data) => onBytes(data, data.length),
      onError: (_) => _notifyClosed(),
      onDone: _notifyClosed,
      cancelOnError: true,
    );
  }

  @override
  void write(List<int> bytes) {
    if (_closed) throw StateError('transport closed');
    _socket.add(bytes);
  }

  /// Flushes pending bytes. The writer loop does not await this: like
  /// the BLE transports, ordering is what matters, not acknowledgement.
  Future<void> flush() => _socket.flush();

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_subscription?.cancel());
    _socket.destroy();
    _notifyClosed();
  }

  void _notifyClosed() {
    if (_closedNotified) return;
    _closedNotified = true;
    scheduleMicrotask(() => _onClosed?.call());
  }
}
