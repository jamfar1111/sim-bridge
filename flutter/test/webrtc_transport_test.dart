// WebRTC transport tests: the handshake, byte flow, close and the
// Android-side listener, all against a fake peer connection and an
// in-memory signalling pair — no native WebRTC, no network. The
// real `flutter_webrtc` path cannot be compiled on this VM, so these
// tests cover the transport logic only. The `HttpSignalling` tests
// use a local HTTP server (loopback) instead of the Worker.
import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:io'
    show ContentType, HttpRequest, HttpServer, InternetAddress;

import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/link/link.dart';

// ------------------------------------------------------------------
// fakes
// ------------------------------------------------------------------

/// In-memory signalling pair: what one side sends, the other
/// receives (a microtask later, like real I/O).
class FakeSignalling implements WebrtcSignalling {
  FakeSignalling();

  static (FakeSignalling, FakeSignalling) pair() {
    final a = FakeSignalling();
    final b = FakeSignalling();
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  FakeSignalling? _peer;
  final _messages = StreamController<Map<String, dynamic>>.broadcast();

  /// Messages this side sent (test observation).
  final List<Map<String, dynamic>> sent = [];
  bool _closed = false;

  bool get isClosed => _closed;

  @override
  Future<void> send(Map<String, dynamic> message) async {
    if (_closed) return;
    sent.add(Map<String, dynamic>.of(message));
    final peer = _peer;
    if (peer == null || peer._closed) return;
    scheduleMicrotask(() {
      if (!peer._closed) peer._messages.add(Map<String, dynamic>.of(message));
    });
  }

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _messages.close();
  }
}

class FakeRtcDataChannel implements RtcDataChannel {
  FakeRtcDataChannel({this.label = 'tether'});

  final String label;
  FakeRtcDataChannel? _peer;
  final _messages = StreamController<List<int>>.broadcast();
  final _openCompleter = Completer<void>();
  bool _open = false;
  bool _closed = false;

  void _markOpen() {
    if (_open || _closed) return;
    _open = true;
    _openCompleter.complete();
  }

  @override
  Stream<List<int>> get messages => _messages.stream;

  @override
  Future<void> get whenOpen => _openCompleter.future;

  @override
  Future<void> send(List<int> bytes) async {
    if (_closed) throw StateError('channel closed');
    final peer = _peer;
    if (peer == null || peer._closed) throw StateError('channel closed');
    scheduleMicrotask(() {
      if (!peer._closed) peer._messages.add(List<int>.of(bytes));
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _messages.close();
  }
}

class FakeRtcPeerConnection implements RtcPeerConnection {
  FakeRtcPeerConnection();

  static (FakeRtcPeerConnection, FakeRtcPeerConnection) pair() {
    final a = FakeRtcPeerConnection();
    final b = FakeRtcPeerConnection();
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  FakeRtcPeerConnection? _peer;
  void Function(RtcCandidate)? _onIceCandidate;
  void Function(RtcDataChannel)? _onDataChannel;
  void Function(String)? _onConnectionState;

  RtcSessionDescription? localDescription;
  RtcSessionDescription? remoteDescription;
  final List<RtcCandidate> candidates = [];

  /// A data channel the peer created, waiting for [onDataChannel]
  /// to be set (the peer may create it before this side listens).
  RtcDataChannel? _pendingChannel;

  /// The channel pair this side created (initiator), if any.
  (FakeRtcDataChannel, FakeRtcDataChannel)? _createdPair;

  /// Like the real stack, the data channel only opens once both
  /// sides have a local and a remote description (the DTLS
  /// handshake needs the offer/answer exchange first): an
  /// unanswered offer never opens a channel, so a connect with no
  /// answer times out instead of succeeding silently.
  void _maybeOpen() {
    final peer = _peer;
    if (peer == null) return;
    final pair = _createdPair ?? peer._createdPair;
    if (pair == null) return;
    if (localDescription != null &&
        remoteDescription != null &&
        peer.localDescription != null &&
        peer.remoteDescription != null) {
      pair.$1._markOpen();
      pair.$2._markOpen();
      // Like the real stack, the connection state flips to
      // connected once the handshake completes.
      _onConnectionState?.call('connected');
      peer._onConnectionState?.call('connected');
    }
  }

  @override
  set onIceCandidate(void Function(RtcCandidate)? handler) {
    _onIceCandidate = handler;
  }

  @override
  set onDataChannel(void Function(RtcDataChannel)? handler) {
    _onDataChannel = handler;
    final pending = _pendingChannel;
    if (pending != null) {
      _pendingChannel = null;
      handler?.call(pending);
    }
  }

  @override
  set onConnectionState(void Function(String)? handler) {
    _onConnectionState = handler;
  }

  @override
  Future<RtcSessionDescription> createOffer() async =>
      const RtcSessionDescription('fake-offer-sdp', 'offer');

  @override
  Future<RtcSessionDescription> createAnswer() async =>
      const RtcSessionDescription('fake-answer-sdp', 'answer');

  @override
  Future<void> setLocalDescription(RtcSessionDescription description) async {
    localDescription = description;
    _maybeOpen();
    // ICE gathering: one candidate, like the real stack.
    scheduleMicrotask(() => _onIceCandidate?.call(
        const RtcCandidate('candidate:fake 1 udp 1 10.0.0.1 5000 typ host',
            '0', 0)));
  }

  @override
  Future<void> setRemoteDescription(RtcSessionDescription description) async {
    remoteDescription = description;
    _maybeOpen();
  }

  @override
  Future<void> addCandidate(RtcCandidate candidate) async {
    candidates.add(candidate);
  }

  @override
  Future<RtcDataChannel> createDataChannel(String label) async {
    final mine = FakeRtcDataChannel(label: label);
    final theirs = FakeRtcDataChannel(label: label);
    mine._peer = theirs;
    theirs._peer = mine;
    _createdPair = (mine, theirs);
    final peer = _peer;
    scheduleMicrotask(() {
      if (peer != null) {
        if (peer._onDataChannel != null) {
          peer._onDataChannel!(theirs);
        } else {
          peer._pendingChannel = theirs;
        }
      }
    });
    _maybeOpen();
    return mine;
  }

  @override
  Future<void> close() async {}
}

class FakeRtcFactory implements RtcPeerConnectionFactory {
  FakeRtcFactory(this._pc);

  final FakeRtcPeerConnection _pc;

  @override
  Future<RtcPeerConnection> create(Map<String, dynamic> configuration) async =>
      _pc;
}

/// A factory whose `create` throws (finding N5): the peer
/// connection never exists.
class ThrowingRtcFactory implements RtcPeerConnectionFactory {
  @override
  Future<RtcPeerConnection> create(Map<String, dynamic> configuration) async {
    throw StateError('no peer connection');
  }
}

/// The shared HMAC key for the signalling-auth tests (finding N6).
final _authKey = List<int>.generate(32, (i) => i + 1);

/// Answers every GET with the same messages (test observation for
/// the auth/dedupe tests): the handler decides the payload.
Future<HttpServer> _stubServer(
    Future<void> Function(HttpRequest request) onRequest) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    try {
      await onRequest(request);
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  });
  return server;
}

void _jsonResponse(HttpRequest request, Map<String, dynamic> body) {
  request.response
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
}

Future<void> _okResponse(HttpRequest request) async {
  _jsonResponse(request, {'ok': true});
  await request.response.close();
}

// ------------------------------------------------------------------
// tests
// ------------------------------------------------------------------

void main() {
  group('WebrtcConfig', () {
    test('defaults to Cloudflare STUN only', () {
      const config = WebrtcConfig();
      final servers =
          config.configuration['iceServers'] as List<Map<String, dynamic>>;
      expect(servers, hasLength(1));
      expect(servers.single['urls'], 'stun:stun.cloudflare.com:3478');
    });

    test('adds Cloudflare TURN when credentials are set', () {
      const config = WebrtcConfig(
        turnUsername: 'u',
        turnCredential: 'c',
      );
      final servers =
          config.configuration['iceServers'] as List<Map<String, dynamic>>;
      expect(servers, hasLength(2));
      final turn = servers[1];
      expect(turn['username'], 'u');
      expect(turn['credential'], 'c');
      expect(
          (turn['urls'] as List).join(' '), contains('turn.cloudflare.com'));
    });

    test('room id is the hex SHA-256 of the peripheral key', () {
      final room = webrtcRoomId(List<int>.generate(65, (i) => i));
      expect(room.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(room), isTrue);
      expect(webrtcRoomId(List<int>.generate(65, (i) => i)), room);
      expect(webrtcRoomId(List<int>.generate(65, (i) => i + 1)),
          isNot(room));
    });
  });

  group('WebrtcTransport', () {
    test('initiator and responder exchange bytes', () async {
      final (sigA, sigB) = FakeSignalling.pair();
      final (pcA, pcB) = FakeRtcPeerConnection.pair();
      final initiator = WebrtcTransport.connect(
        room: 'room-1',
        signalling: sigA,
        factory: FakeRtcFactory(pcA),
      );
      final responder = WebrtcTransport.answer(
        room: 'room-1',
        signalling: sigB,
        factory: FakeRtcFactory(pcB),
      );
      final (a, b) = await (initiator, responder).wait;

      // Let the trailing ICE-candidate microtasks flush.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The handshake crossed the signalling channel: offer, answer,
      // and at least one ICE candidate each way.
      expect(
          sigA.sent.map((m) => m['type']), containsAll(['offer', 'candidate']));
      expect(sigB.sent.map((m) => m['type']),
          containsAll(['answer', 'candidate']));
      expect(pcA.remoteDescription?.type, 'answer');
      expect(pcB.remoteDescription?.type, 'offer');

      final receivedA = <List<int>>[];
      final receivedB = <List<int>>[];
      var closedA = false;
      var closedB = false;
      a.start((bytes, _) => receivedA.add(bytes), () => closedA = true);
      b.start((bytes, _) => receivedB.add(bytes), () => closedB = true);
      a.write([1, 2, 3]);
      b.write([4, 5]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(receivedB, [
        [1, 2, 3]
      ]);
      expect(receivedA, [
        [4, 5]
      ]);

      a.close();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(closedA, isTrue);
      expect(() => a.write([9]), throwsStateError);
      expect(closedB, isFalse);
      b.close();
      await b.closed;
    });

    test('bytes written before start are buffered', () async {
      final (sigA, sigB) = FakeSignalling.pair();
      final (pcA, pcB) = FakeRtcPeerConnection.pair();
      final (a, b) = await (
        WebrtcTransport.connect(
            room: 'room-2', signalling: sigA, factory: FakeRtcFactory(pcA)),
        WebrtcTransport.answer(
            room: 'room-2', signalling: sigB, factory: FakeRtcFactory(pcB)),
      ).wait;
      a.write([7, 8]);
      final received = <List<int>>[];
      b.start((bytes, _) => received.add(bytes), () {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(received, [
        [7, 8]
      ]);
      a.close();
      b.close();
    });

    test('connect times out when nobody answers', () async {
      final (sigA, sigB) = FakeSignalling.pair();
      final (pcA, _) = FakeRtcPeerConnection.pair();
      // The responder side never runs: its signalling is closed at
      // once, so no answer ever arrives.
      await sigB.close();
      await expectLater(
        WebrtcTransport.connect(
          room: 'room-3',
          signalling: sigA,
          factory: FakeRtcFactory(pcA),
          handshakeTimeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('a failed peer-connection creation closes the signalling '
        'channel (N5)', () async {
      final (sigA, sigB) = FakeSignalling.pair();
      await expectLater(
        WebrtcTransport.connect(
          room: 'room-5',
          signalling: sigA,
          factory: ThrowingRtcFactory(),
        ),
        throwsStateError,
      );
      // The signalling channel (2 s poll timer + HttpClient) must
      // not leak when the peer connection never existed.
      expect(sigA.isClosed, isTrue);
      await sigB.close();
    });
  });

  group('SignallingAuth', () {
    test('signs and verifies; key order does not matter', () {
      final a = SignallingAuth.sign({'type': 'offer', 'sdp': 's'}, _authKey);
      final b = SignallingAuth.sign({'sdp': 's', 'type': 'offer'}, _authKey);
      expect(a['hmac'], b['hmac']);
      expect(SignallingAuth.verify(a, _authKey), isTrue);
      expect(SignallingAuth.verify(b, _authKey), isTrue);
    });

    test('a tampered message, a wrong key, or no hmac all fail', () {
      final signed =
          SignallingAuth.sign({'type': 'offer', 'sdp': 's'}, _authKey);
      final tampered = Map<String, dynamic>.of(signed)..['sdp'] = 'evil';
      expect(SignallingAuth.verify(tampered, _authKey), isFalse);
      expect(SignallingAuth.verify(signed, List<int>.filled(32, 9)),
          isFalse);
      expect(SignallingAuth.verify({'type': 'offer', 'sdp': 's'}, _authKey),
          isFalse);
      // The signature covers the message, not the hmac itself:
      // re-signing the signed map gives the same hmac.
      expect(
          SignallingAuth.sign(signed, _authKey)['hmac'], signed['hmac']);
    });

    test('HttpSignalling signs outgoing messages (N6)', () async {
      final posted = <Map<String, dynamic>>[];
      final server = await _stubServer((request) async {
        if (request.method == 'POST') {
          final body = await utf8.decoder.bind(request).join();
          posted.add(jsonDecode(body) as Map<String, dynamic>);
          await _okResponse(request);
          return;
        }
        _jsonResponse(request, {'messages': [], 'cursor': 0});
        await request.response.close();
      });
      final signalling = HttpSignalling(
        Uri.parse('http://127.0.0.1:${server.port}'),
        room: 'r',
        authKey: _authKey,
        pollInterval: const Duration(seconds: 30),
      );
      await signalling.send({'type': 'offer', 'sdp': 's'});
      expect(posted, hasLength(1));
      final message = posted.single['message'] as Map<String, dynamic>;
      expect(message['hmac'], isNotNull);
      expect(SignallingAuth.verify(message, _authKey), isTrue);
      await signalling.close();
      await server.close();
    });

    test('HttpSignalling drops tampered and unsigned messages (N6)',
        () async {
      final good = SignallingAuth.sign({'type': 'offer', 'sdp': 's'}, _authKey);
      final tampered = Map<String, dynamic>.of(good)..['sdp'] = 'evil';
      final server = await _stubServer((request) async {
        if (request.method == 'POST') {
          await _okResponse(request);
          return;
        }
        // The worker returns the same three messages on every poll
        // (it ignores `since` here): the good one must arrive once,
        // the tampered and unsigned ones never.
        _jsonResponse(request, {
          'messages': [
            good,
            tampered,
            {'type': 'offer', 'sdp': 'unsigned'},
          ],
          'cursor': 3,
        });
        await request.response.close();
      });
      final signalling = HttpSignalling(
        Uri.parse('http://127.0.0.1:${server.port}'),
        room: 'r',
        authKey: _authKey,
        pollInterval: const Duration(milliseconds: 20),
      );
      final received = <Map<String, dynamic>>[];
      final sub = signalling.messages.listen(received.add);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(received, [good]);
      await sub.cancel();
      await signalling.close();
      await server.close();
    });

    test('HttpSignalling without a key accepts unsigned messages '
        '(first pairing, N6)', () async {
      final server = await _stubServer((request) async {
        if (request.method == 'POST') {
          await _okResponse(request);
          return;
        }
        _jsonResponse(request, {
          'messages': [
            {'type': 'offer', 'sdp': 's'},
          ],
          'cursor': 1,
        });
        await request.response.close();
      });
      final signalling = HttpSignalling(
        Uri.parse('http://127.0.0.1:${server.port}'),
        room: 'r',
        pollInterval: const Duration(milliseconds: 20),
      );
      final received = <Map<String, dynamic>>[];
      final sub = signalling.messages.listen(received.add);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, [
        {'type': 'offer', 'sdp': 's'}
      ]);
      await sub.cancel();
      await signalling.close();
      await server.close();
    });
  });

  group('HttpSignalling dedupe', () {
    test('re-delivered messages after a cursor regression arrive '
        'once (N9)', () async {
      var polls = 0;
      final server = await _stubServer((request) async {
        if (request.method == 'POST') {
          await _okResponse(request);
          return;
        }
        polls++;
        // First poll: cursor 2. Later polls regress the cursor to 0
        // (the newest message expired), so the worker re-sends both.
        final cursor = polls == 1 ? 2 : 0;
        _jsonResponse(request, {
          'messages': [
            {'type': 'offer', 'sdp': 's1'},
            {'type': 'answer', 'sdp': 's2'},
          ],
          'cursor': cursor,
        });
        await request.response.close();
      });
      final signalling = HttpSignalling(
        Uri.parse('http://127.0.0.1:${server.port}'),
        room: 'r',
        pollInterval: const Duration(milliseconds: 20),
      );
      final received = <Map<String, dynamic>>[];
      final sub = signalling.messages.listen(received.add);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(received, hasLength(2));
      expect(received.map((m) => m['type']), ['offer', 'answer']);
      await sub.cancel();
      await signalling.close();
      await server.close();
    });

    test('SignallingDedupe forgets the oldest entries', () {
      final dedupe = SignallingDedupe(capacity: 2);
      expect(dedupe.isDuplicate('a'), isFalse);
      expect(dedupe.isDuplicate('b'), isFalse);
      expect(dedupe.isDuplicate('a'), isTrue);
      expect(dedupe.isDuplicate('c'), isFalse);
      // 'a' was pushed out by 'c'.
      expect(dedupe.isDuplicate('a'), isFalse);
      // 'c' is still remembered; re-adding 'a' pushed out 'b'.
      expect(dedupe.isDuplicate('c'), isTrue);
      expect(dedupe.isDuplicate('b'), isFalse);
    });
  });

  group('WebrtcListener', () {
    test('delivers a transport per offer, then listens again', () async {
      final (sigPhone, sigAndroid) = FakeSignalling.pair();
      final (pcPhone, pcAndroid) = FakeRtcPeerConnection.pair();
      final delivered = <Transport>[];
      final listener = WebrtcListener(
        signallingFactory: () => sigAndroid,
        room: 'room-4',
        factory: FakeRtcFactory(pcAndroid),
        onTransport: delivered.add,
        // Short timeout: after the first transport ends, the next
        // listen iteration (on the already-closed signalling) fails
        // fast instead of waiting 60 s, so `stop()` returns promptly.
        handshakeTimeout: const Duration(milliseconds: 200),
        retryDelay: const Duration(milliseconds: 10),
      );
      final listening = listener.start();
      final initiator = WebrtcTransport.connect(
        room: 'room-4',
        signalling: sigPhone,
        factory: FakeRtcFactory(pcPhone),
      );
      final phone = await initiator;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(delivered, hasLength(1));
      // Bytes flow over the delivered transport.
      final received = <List<int>>[];
      delivered.single
          .start((bytes, _) => received.add(bytes), () {});
      phone.start((_, _) {}, () {});
      phone.write([42]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(received, [
        [42]
      ]);
      // The transport ends: the listener goes back to listening.
      delivered.single.close();
      phone.close();
      await listener.stop();
      await listening.timeout(const Duration(seconds: 2));
    });

    test('stop cancels an in-flight answer (N7)', () async {
      final (sigPhone, sigAndroid) = FakeSignalling.pair();
      final listener = WebrtcListener(
        signallingFactory: () => sigAndroid,
        room: 'room-7',
        factory: FakeRtcFactory(FakeRtcPeerConnection()),
        // A 60 s handshake: without cancellation `stop()` would
        // wait it out (no offer ever arrives).
        handshakeTimeout: const Duration(seconds: 60),
        retryDelay: const Duration(seconds: 5),
      );
      final listening = listener.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final stopwatch = Stopwatch()..start();
      await listener.stop();
      await listening.timeout(const Duration(seconds: 2));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      await sigPhone.close();
    });
  });
}
