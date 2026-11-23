/// One link to the peer: handshake, then sealed records in both
/// directions, above any [Transport].
///
/// Mirrors Tether's Android `link/Connection.kt` (peripheral side) and
/// the iOS `TetherCore/TetherLink.swift` handshake (central side).
/// The Flutter app runs both roles: the Android phone (holds the SIM)
/// is the peripheral and waits for HELLO; the iPhone is the central
/// and initiates it.
library;

import 'dart:async';

import '../protocol/crypto.dart';
import '../protocol/messages.dart';
import '../protocol/records.dart';
import 'transport.dart';

/// The link layer's view of its owner (the [Hub]).
abstract class ConnectionListener {
  /// False while another (test) session holds the link exclusively: the
  /// peer is told to retry.
  bool admits(LinkConnection c) => true;

  void onEstablished(LinkConnection c, bool newlyPaired);

  void onMessage(LinkConnection c, Message m);

  void onAudio(LinkConnection c, List<int> payload);

  void onClosed(LinkConnection c);
}

/// Keys the peripheral side needs for the handshake.
class PeripheralKeys {
  const PeripheralKeys({
    required this.staticKey,
    this.pairedCentrals = const [],
    this.openToken,
    this.tokenFor,
  });

  /// This phone's long-term static P-256 key pair.
  final P256KeyPair staticKey;

  /// Centrals already paired with this phone.
  final List<PairedCentral> pairedCentrals;

  /// An open pairing token (pair mode accepts any central key).
  final List<int>? openToken;

  /// Per-central token lookup (see `PeripheralHandshake.receiveHello`).
  final List<int>? Function(List<int> centralKey)? tokenFor;
}

/// Keys the central side needs for the handshake.
class CentralKeys {
  const CentralKeys({
    required this.staticKey,
    required this.peerStatic,
    this.token,
  });

  /// This phone's long-term static P-256 key pair.
  final P256KeyPair staticKey;

  /// The peripheral's long-term static public key (65 bytes).
  final List<int> peerStatic;

  /// Pairing token, or `null` for resume mode.
  final List<int>? token;
}

enum _LinkState { hello, finish, up, closed }

class _OutItem {
  const _OutItem(this.channel, this.payload, this.audio, this.raw)
      : at = null;

  const _OutItem.stamped(this.channel, this.payload, this.audio, this.raw,
      this.at);

  final int channel;
  final List<int> payload;
  final bool audio;

  /// A raw (unencrypted) record, e.g. HELLO_ACK / FIN.
  final Record? raw;

  final DateTime? at;
}

/// Shared writer/reader machinery for both handshake roles.
abstract class LinkConnection {
  LinkConnection(
    this.transport,
    this.listener, {
    this.handshakeTimeout = const Duration(seconds: 15),
  });

  final Transport transport;
  final ConnectionListener listener;

  /// A peer that never finishes the handshake is dropped after this.
  final Duration handshakeTimeout;

  final RecordReader _reader = RecordReader();

  /// Normal lane (sync pages, status…) and priority lane (handshake,
  /// call events, audio).
  final List<_OutItem> _queue = [];
  final List<_OutItem> _prio = [];
  Completer<void>? _signal;

  _LinkState _state = _LinkState.hello;

  SecureSession? _session;

  /// Called when the peer starts a new session on the same pipe while
  /// this one is up (HELLO on a GATT transport). The bytes are the
  /// first record of the new session, to hand to a fresh connection.
  /// When `null`, a peer restart just closes this connection.
  void Function(List<int> firstRecord)? onPeerRestart;

  DateTime _lastRx = DateTime.now();

  /// Since when a record has been half received ([DateTime] epoch: none).
  DateTime _partialSince = DateTime.fromMillisecondsSinceEpoch(0);

  DateTime _upAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The peer's static key once the handshake is done: identifies the
  /// iPhone vs Mac across reconnects.
  List<int>? peerKey;

  /// From the peer's sync: "iphone" / "mac", its name, and the codecs
  /// it can decode.
  String kind = 'iphone';
  String name = 'iPhone';
  List<String> codecs = const ['pcmu'];

  /// The peer's Bark device key (from its `sync` client object), so
  /// the Android side can push a wake-up alert when the link is down.
  /// Null when the peer never sent one.
  String? barkKey;

  /// Last user action (answer, dial, take) from this peer, for choosing
  /// where call audio goes.
  DateTime lastAction = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _handshakeTimer;
  bool _closed = false;
  bool _closeNotified = false;
  final Completer<void> _closedCompleter = Completer<void>();

  bool get isUp => _state == _LinkState.up;

  bool get isClosed => _closed;

  /// Completes when this connection closes, for any reason.
  Future<void> get whenClosed => _closedCompleter.future;

  /// How long a record has been half received: a lost or corrupted
  /// chunk leaves the stream stuck mid-record.
  Duration stalled([DateTime? now]) {
    if (_partialSince.millisecondsSinceEpoch == 0) return Duration.zero;
    return (now ?? DateTime.now()).difference(_partialSince);
  }

  Duration get lastRxAgo => DateTime.now().difference(_lastRx);

  /// How long the link has been up (zero when never up).
  Duration get upDuration => _upAt.millisecondsSinceEpoch == 0
      ? Duration.zero
      : DateTime.now().difference(_upAt);

  void start() {
    _handshakeTimer = Timer(handshakeTimeout, () {
      if (!isUp && !_closed) close('handshake timeout');
    });
    unawaited(_writerLoop());
    transport.start(_onBytes, () => close('transport closed'));
  }

  /// Sends a control message on the normal lane.
  void send(Message m) {
    if (!isUp) return;
    final bytes = _fits(m);
    if (bytes == null) return;
    _enqueue(_OutItem(Proto.channelControl, bytes, false, null));
  }

  /// Call events jump ahead of normal messages (a big sync may be
  /// queued) but keep their own order: "ringing" then "ended" must
  /// never arrive as "ended" then "ringing".
  void sendUrgent(Message m) {
    if (!isUp) return;
    final bytes = _fits(m);
    if (bytes == null) return;
    _enqueue(_OutItem(Proto.channelControl, bytes, false, null),
        priority: true);
  }

  /// Audio is dropped when the link is backed up (> 60 ms old at send
  /// time).
  void sendAudio(List<int> frame) {
    if (!isUp) return;
    // Never let audio pile up: drop the oldest audio frame (it is the
    // stalest), never a call event or record.
    if (_prio.length > 25) {
      final oldest = _prio.indexWhere((it) => it.audio);
      if (oldest >= 0) _prio.removeAt(oldest);
    }
    _enqueue(
        _OutItem.stamped(Proto.channelAudio, frame, true, null,
            DateTime.now()),
        priority: true);
  }

  void _sendRaw(Record record) {
    _enqueue(_OutItem(0, const [], false, record), priority: true);
  }

  /// A record body holds at most 65534 bytes: an oversized message is
  /// dropped, never sent (the writer would fail and close the link,
  /// and every re-sync would do it again).
  List<int>? _fits(Message m) {
    final bytes = m.toJsonBytes();
    if (bytes.length > 65000) return null;
    return bytes;
  }

  void _enqueue(_OutItem item, {bool priority = false}) {
    if (_closed) return;
    (priority ? _prio : _queue).add(item);
    if (_signal != null && !_signal!.isCompleted) _signal!.complete();
  }

  Future<_OutItem?> _take() async {
    while (true) {
      if (_closed) return null;
      if (_prio.isNotEmpty) return _prio.removeAt(0);
      if (_queue.isNotEmpty) return _queue.removeAt(0);
      _signal ??= Completer<void>();
      await _signal!.future;
      _signal = null;
    }
  }

  Future<void> _writerLoop() async {
    try {
      while (!_closed) {
        final item = await _take();
        if (item == null) break;
        if (item.raw != null) {
          transport.write(item.raw!.encoded());
          continue;
        }
        if (item.audio &&
            item.at != null &&
            DateTime.now().difference(item.at!).inMilliseconds > 60) {
          continue;
        }
        final session = _session;
        if (session == null) continue;
        transport.write(session.seal(item.channel, item.payload).encoded());
      }
    } catch (_) {
      close('write failed');
    }
  }

  void _onBytes(List<int> bytes, int length) {
    if (_closed) return;
    _lastRx = DateTime.now();
    try {
      _reader.append(bytes, 0, length);
      while (true) {
        final record = _reader.next();
        if (record == null) break;
        _handle(record);
        if (_closed) return;
      }
      _partialSince = _reader.pendingBytes == 0
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : _partialSince.millisecondsSinceEpoch == 0
              ? _lastRx
              : _partialSince;
    } on FramingException catch (e) {
      close('framing: ${e.message}');
    } on HandshakeException catch (e) {
      close('handshake: ${e.message}');
    } on SessionException catch (e) {
      close('session: ${e.message}');
    } on FormatException catch (e) {
      close('message: ${e.message}');
    } catch (e) {
      close('error: $e');
    }
  }

  /// Handles one record in the current state. Implemented per role.
  void _handle(Record record);

  /// Opens a sealed record in the UP state and dispatches it.
  void _handleUp(Record record) {
    // A peer that dropped its side starts again with a HELLO on the
    // same pipe: end this session and hand the HELLO to a new one,
    // instead of failing "not sealed" and leaving the peer waiting.
    if (record.kind == RecordKind.hello) {
      final restart = onPeerRestart;
      final encoded = record.encoded();
      close('peer started a new session');
      restart?.call(encoded);
      return;
    }
    final session = _session;
    if (session == null) throw const SessionException('no session');
    final (channel, payload) = session.open(record);
    switch (channel) {
      case Proto.channelControl:
        listener.onMessage(this, Message.parse(payload));
      case Proto.channelAudio:
        listener.onAudio(this, payload);
      default:
        // Unknown channel: ignored, like the reference.
        break;
    }
  }

  /// Closes the link. Idempotent; the listener is told exactly once.
  void close([String reason = 'closed']) {
    if (_closed) return;
    _closed = true;
    _state = _LinkState.closed;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    if (_signal != null && !_signal!.isCompleted) _signal!.complete();
    _signal = null;
    transport.close();
    if (!_closeNotified) {
      _closeNotified = true;
      listener.onClosed(this);
    }
    if (!_closedCompleter.isCompleted) _closedCompleter.complete();
  }
}

/// Peripheral side (Android phone, holds the SIM): waits for HELLO.
class PeripheralConnection extends LinkConnection {
  PeripheralConnection(
    super.transport,
    super.listener,
    this.keys, {
    super.handshakeTimeout,
  });

  final PeripheralKeys keys;

  PeripheralHandshake? _handshake;
  bool _pairing = false;
  List<int>? _pendingStatic;

  @override
  void _handle(Record record) {
    switch (_state) {
      case _LinkState.hello:
        if (record.kind != RecordKind.hello) {
          throw const HandshakeException('expected HELLO');
        }
        final hs = PeripheralHandshake(keys.staticKey);
        _handshake = hs;
        final reply = listener.admits(this)
            ? hs.receiveHello(
                record,
                pairedCentrals: keys.pairedCentrals,
                tokenFor: keys.tokenFor,
                openToken: keys.openToken,
              )
            : Record(RecordKind.reject, [RejectReason.busy]);
        _sendRaw(reply);
        if (reply.kind == RecordKind.reject) {
          // Let the REJECT go out before closing.
          _state = _LinkState.finish;
          _handshake = null;
          Future.delayed(const Duration(milliseconds: 300), () {
            if (!_closed) close('rejected');
          });
          return;
        }
        _pairing = hs.hello!.mode == Proto.modePair;
        _pendingStatic = hs.hello!.staticKey;
        _state = _LinkState.finish;
      case _LinkState.finish:
        final hs = _handshake;
        if (hs == null) {
          throw const HandshakeException('rejected peer kept talking');
        }
        final (session, fin) = hs.receiveFinish(record);
        _session = session;
        peerKey = _pendingStatic;
        _sendRaw(fin);
        _state = _LinkState.up;
        _upAt = DateTime.now();
        listener.onEstablished(this, _pairing);
      case _LinkState.up:
        _handleUp(record);
      case _LinkState.closed:
        break;
    }
  }
}

/// Central side (iPhone): initiates the handshake with HELLO.
class CentralConnection extends LinkConnection {
  CentralConnection(
    super.transport,
    super.listener,
    this.keys, {
    super.handshakeTimeout,
  });

  final CentralKeys keys;

  CentralHandshake? _handshake;
  SecureSession? _pendingSession;

  @override
  void start() {
    final hs = CentralHandshake(
      keys.staticKey,
      keys.peerStatic,
      token: keys.token,
    );
    _handshake = hs;
    super.start();
    // The writer loop is async, so the HELLO goes out after the
    // transport has started; the peer's reader is ready by then.
    _sendRaw(hs.hello());
  }

  @override
  void _handle(Record record) {
    switch (_state) {
      case _LinkState.hello:
        final hs = _handshake;
        if (hs == null) throw const HandshakeException('no handshake');
        final (session, fin) = hs.receive(record);
        _pendingSession = session;
        _sendRaw(fin);
        _state = _LinkState.finish;
      case _LinkState.finish:
        final hs = _handshake;
        final session = _pendingSession;
        if (hs == null || session == null) {
          throw const HandshakeException('no handshake');
        }
        hs.verifyFinish(session, record);
        _session = session;
        peerKey = keys.peerStatic;
        _state = _LinkState.up;
        _upAt = DateTime.now();
        listener.onEstablished(this, keys.token != null);
      case _LinkState.up:
        _handleUp(record);
      case _LinkState.closed:
        break;
    }
  }
}

/// Exponential backoff for reconnect attempts: 1 s, 2 s, 4 s, … capped
/// at [max]. Resets on a successful connection.
class Backoff {
  Backoff({
    this.base = const Duration(seconds: 1),
    this.max = const Duration(seconds: 30),
    this.factor = 2.0,
  });

  final Duration base;
  final Duration max;
  final double factor;

  int _attempts = 0;

  int get attempts => _attempts;

  Duration next() {
    var delay = base * _pow(factor, _attempts);
    if (delay > max) delay = max;
    _attempts++;
    return delay;
  }

  void reset() => _attempts = 0;

  static double _pow(double base, int exp) {
    var result = 1.0;
    for (var i = 0; i < exp; i++) {
      result *= base;
    }
    return result;
  }
}

/// Keeps a link up: builds a transport, runs the handshake, and on any
/// close waits [Backoff.next] and tries again — until [stop].
///
/// The [transportFactory] creates the transport for each attempt (a
/// fresh TCP socket, or a fresh BLE link via the platform channel);
/// [connectionFactory] builds the right role for it.
class ReconnectingLink {
  ReconnectingLink({
    required this.transportFactory,
    required this.connectionFactory,
    required this.listener,
    Backoff? backoff,
  }) : _backoff = backoff ?? Backoff();

  final Future<Transport> Function() transportFactory;
  final LinkConnection Function(Transport transport) connectionFactory;
  final ConnectionListener listener;
  final Backoff _backoff;

  LinkConnection? _current;
  bool _stopped = false;
  bool _running = false;

  LinkConnection? get current => _current;

  bool get isUp => _current?.isUp ?? false;

  /// Starts the (re)connect loop. Returns immediately; the loop runs
  /// until [stop].
  void start() {
    if (_running) return;
    _running = true;
    _stopped = false;
    unawaited(_loop());
  }

  /// Stops reconnecting and closes the current connection, if any.
  void stop() {
    _stopped = true;
    _current?.close('stopped');
    _current = null;
  }

  Future<void> _loop() async {
    while (!_stopped) {
      LinkConnection? connection;
      try {
        final transport = await transportFactory();
        if (_stopped) {
          transport.close();
          break;
        }
        connection = connectionFactory(transport);
        _current = connection;
        connection.start();
        await connection.whenClosed;
        _current = null;
        if (_stopped) break;
        if (connection.isUp) _backoff.reset();
      } catch (_) {
        // Transport creation failed (e.g. refused): treat like a drop.
        connection?.close('factory failed');
        _current = null;
      }
      if (_stopped) break;
      await Future<void>.delayed(_backoff.next());
    }
    _running = false;
  }
}
