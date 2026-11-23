/// Far-mode transport over WebRTC data channels (finding 7).
///
/// The "far · internet" switch in the Link tab uses this instead of
/// BLE when the phones are apart: a reliable, ordered
/// `RTCDataChannel` (`tether`) carries the same record byte stream
/// as the BLE and TCP transports, so the handshake and records above
/// it do not change. ICE goes through Cloudflare: public STUN
/// (`stun.cloudflare.com:3478`) always, and Cloudflare TURN relay
/// when TURN credentials are configured (see [WebrtcSettings] —
/// without them the transport still works direct / via STUN, but
/// cannot relay through a symmetric NAT).
///
/// Signalling choice: there is no existing link to signal over when
/// the phones are far apart (BLE is out of range, and that is the
/// whole point of this transport), so signalling runs over a small
/// HTTP service — a Cloudflare Worker backed by a Durable Object
/// (source + deploy steps in `docs/webrtc-signalling-worker.js`).
/// The protocol is tiny: POST `/signal` `{room, message}` to send,
/// GET `/signal?room=…&since=…` to poll for `{messages, cursor}`.
/// [WebrtcSignalling] is the seam: [HttpSignalling] is the real one,
/// tests use an in-memory fake. The room id is the SHA-256 of the
/// peripheral's static public key ([webrtcRoomId]) — both phones
/// derive the same room from the pairing, with no extra exchange.
///
/// The native plugin cannot be compiled on this VM (Gradle/Java
/// loopback is sandbox-blocked; no Xcode here), so the real
/// `flutter_webrtc` path is unverified: only the transport logic
/// (handshake, byte flow, close, listener loop) is tested, against
/// the fake peer connection in `test/webrtc_transport_test.dart`.
/// The iOS client picks this transport when the mode is `webrtc`
/// (see `main.dart`); the Android service listens for offers with
/// [WebrtcListener].
library;

import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:io' show ContentType, HttpClient, HttpException;
import 'dart:typed_data' show Uint8List;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:pointycastle/export.dart';

import '../log/log.dart';
import '../protocol/crypto.dart';
import 'transport.dart';

/// ICE configuration for the far transport.
///
/// Defaults: Cloudflare STUN only. TURN (relay) needs credentials
/// from the Cloudflare dashboard (Realtime → TURN key, then the
/// `generate-ice-servers` endpoint with an API token — see
/// `docs/webrtc-signalling-worker.js`); pass them here and the relay
/// URLs are added.
class WebrtcConfig {
  const WebrtcConfig({
    this.iceServers = const [
      {'urls': 'stun:stun.cloudflare.com:3478'},
    ],
    this.turnUsername,
    this.turnCredential,
  });

  final List<Map<String, dynamic>> iceServers;
  final String? turnUsername;
  final String? turnCredential;

  /// The `createPeerConnection` configuration map.
  Map<String, dynamic> get configuration {
    final servers = List<Map<String, dynamic>>.of(iceServers);
    if (turnUsername != null && turnCredential != null) {
      servers.add({
        'urls': [
          'turn:turn.cloudflare.com:3478?transport=udp',
          'turn:turn.cloudflare.com:3478?transport=tcp',
          'turns:turn.cloudflare.com:5349?transport=tcp',
        ],
        'username': turnUsername,
        'credential': turnCredential,
      });
    }
    return {'iceServers': servers};
  }
}

/// Runtime settings for the far transport.
///
/// The signalling URL is the deployed Cloudflare Worker from
/// `docs/webrtc-signalling-worker.js`. Empty until then: the far
/// switch cannot connect without it, and the Link tab says so.
/// The values are persisted by [WebrtcSettingsStore] (finding N3)
/// and loaded at startup; they can also be set in code (tests).
abstract final class WebrtcSettings {
  /// The Worker URL, e.g. `https://sim-bridge-signal.<sub>.workers.dev`.
  static String signallingUrl = '';

  /// Cloudflare TURN credentials (see [WebrtcConfig]); `null` until
  /// the user adds them — direct / STUN connections still work.
  static String? turnUsername;
  static String? turnCredential;

  static bool get isConfigured => signallingUrl.isNotEmpty;

  static WebrtcConfig get config => WebrtcConfig(
        turnUsername: turnUsername,
        turnCredential: turnCredential,
      );
}

/// The signalling room for one pairing: the SHA-256 of the
/// peripheral's (Android phone's) static public key, hex-encoded.
/// Both phones derive the same room from the pairing.
String webrtcRoomId(List<int> peripheralKey) {
  final hash = P256.sha256([peripheralKey]);
  return hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Canonical JSON for signing and dedupe: maps are encoded with
/// their keys sorted (recursively), so the same message always
/// hashes the same way on both phones, whatever order the keys
/// were built in.
String canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    final parts = <String>[];
    for (final k in keys) {
      parts.add('${jsonEncode(k)}:${canonicalJson(value[k])}');
    }
    return '{${parts.join(',')}}';
  }
  if (value is List) {
    return '[${value.map(canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}

/// HMAC-SHA256 authentication for signalling messages (finding N6).
///
/// The room id is public (SHA-256 of the peripheral's public key,
/// printed in the QR code), so anyone who sees the QR could POST
/// fake offers into the room. The pairing token is the only secret
/// both phones share, so each message carries an `hmac` over its
/// canonical JSON, keyed by SHA-256(token) — the signalling key
/// (see [KeyStore.signallingKey]). The receiver drops messages
/// whose HMAC does not verify, and drops unsigned messages when a
/// key is configured. Without a key (first pairing over WebRTC,
/// before either side persisted one) messages are accepted
/// unsigned — the pairing itself then establishes the key.
///
/// The Worker cannot verify the HMAC: it never learns the token,
/// and giving it the token would defeat the purpose. It only
/// rate-limits the room (see the Worker source). The HMAC still
/// protects the handshake itself: a forged offer cannot pass
/// verification, so it cannot break the real one.
abstract final class SignallingAuth {
  /// Adds the `hmac` field to a copy of [message].
  static Map<String, dynamic> sign(
      Map<String, dynamic> message, List<int> key) {
    final signed = Map<String, dynamic>.of(message);
    signed['hmac'] = _hmac(message, key);
    return signed;
  }

  /// Whether [message]'s `hmac` verifies against [key]. Unsigned
  /// messages fail; a tampered field fails.
  static bool verify(Map<String, dynamic> message, List<int> key) {
    final received = message['hmac'];
    if (received is! String) return false;
    return _constantTimeEquals(received, _hmac(message, key));
  }

  static String _hmac(Map<String, dynamic> message, List<int> key) {
    final unsigned = Map<String, dynamic>.of(message)..remove('hmac');
    final mac = HMac(SHA256Digest(), 64)
      ..init(KeyParameter(Uint8List.fromList(key)));
    final bytes = utf8.encode(canonicalJson(unsigned));
    final out = Uint8List(32);
    mac.update(bytes, 0, bytes.length);
    mac.doFinal(out, 0);
    return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// Remembers the canonical hashes of recently delivered signalling
/// messages, so a cursor regression (the Worker's cursor can move
/// backwards when the newest message expires) does not re-deliver
/// the same offer/answer/candidate (finding N9). Bounded: the
/// oldest hashes are dropped, so memory stays flat. Re-delivery is
/// harmless to drop — every signalling message is idempotent.
class SignallingDedupe {
  SignallingDedupe({this.capacity = 200});

  final int capacity;
  final _seen = <String>{};
  final _order = <String>[];

  /// Whether this canonical message was already delivered.
  /// First sight records it and returns false.
  bool isDuplicate(String canonical) {
    if (_seen.contains(canonical)) return true;
    _seen.add(canonical);
    _order.add(canonical);
    while (_order.length > capacity) {
      _seen.remove(_order.removeAt(0));
    }
    return false;
  }
}

// ------------------------------------------------------------------
// peer-connection seam (testable on the Dart VM)
// ------------------------------------------------------------------

/// One session description: an offer or an answer.
class RtcSessionDescription {
  const RtcSessionDescription(this.sdp, this.type);

  final String sdp;
  final String type;
}

/// One ICE candidate.
class RtcCandidate {
  const RtcCandidate(this.candidate, this.sdpMid, this.sdpMLineIndex);

  final String? candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
}

/// One data channel: binary messages in, binary messages out.
abstract class RtcDataChannel {
  /// Binary messages arriving on the channel.
  Stream<List<int>> get messages;

  /// Completes when the channel opens (immediately when already open).
  Future<void> get whenOpen;

  Future<void> send(List<int> bytes);

  Future<void> close();
}

/// The minimal peer-connection surface the transport needs.
///
/// The real one wraps `flutter_webrtc`; tests use a fake pair. Only
/// the callbacks the transport relies on are exposed.
abstract class RtcPeerConnection {
  set onIceCandidate(void Function(RtcCandidate candidate)? handler);

  set onDataChannel(void Function(RtcDataChannel channel)? handler);

  /// Connection state, normalised: `connected` / `disconnected` /
  /// `failed` / `closed` / anything else.
  set onConnectionState(void Function(String state)? handler);

  Future<RtcSessionDescription> createOffer();

  Future<RtcSessionDescription> createAnswer();

  Future<void> setLocalDescription(RtcSessionDescription description);

  Future<void> setRemoteDescription(RtcSessionDescription description);

  Future<void> addCandidate(RtcCandidate candidate);

  Future<RtcDataChannel> createDataChannel(String label);

  Future<void> close();
}

/// Creates peer connections.
abstract class RtcPeerConnectionFactory {
  Future<RtcPeerConnection> create(Map<String, dynamic> configuration);
}

/// [RtcPeerConnectionFactory] over `flutter_webrtc`.
class FlutterWebrtcFactory implements RtcPeerConnectionFactory {
  const FlutterWebrtcFactory();

  @override
  Future<RtcPeerConnection> create(Map<String, dynamic> configuration) async {
    final pc = await rtc.createPeerConnection(configuration);
    return FlutterRtcPeerConnection(pc);
  }
}

class FlutterRtcDataChannel implements RtcDataChannel {
  FlutterRtcDataChannel(this._channel) {
    _channel.messageStream.listen(
      (msg) {
        if (msg.isBinary) _messages.add(msg.binary);
      },
      onError: (_) {},
      onDone: () => unawaited(_messages.close()),
      cancelOnError: false,
    );
  }

  final rtc.RTCDataChannel _channel;
  final _messages = StreamController<List<int>>.broadcast();

  @override
  Stream<List<int>> get messages => _messages.stream;

  @override
  Future<void> get whenOpen async {
    if (_channel.state == rtc.RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    await _channel.stateChangeStream.firstWhere(
      (s) => s == rtc.RTCDataChannelState.RTCDataChannelOpen,
    );
  }

  @override
  Future<void> send(List<int> bytes) => _channel
      .send(rtc.RTCDataChannelMessage.fromBinary(Uint8List.fromList(bytes)));

  @override
  Future<void> close() async {
    await _messages.close();
    await _channel.close();
  }
}

class FlutterRtcPeerConnection implements RtcPeerConnection {
  FlutterRtcPeerConnection(this._pc);

  final rtc.RTCPeerConnection _pc;

  @override
  set onIceCandidate(void Function(RtcCandidate candidate)? handler) {
    _pc.onIceCandidate = handler == null
        ? null
        : (c) => handler(
            RtcCandidate(c.candidate, c.sdpMid, c.sdpMLineIndex));
  }

  @override
  set onDataChannel(void Function(RtcDataChannel channel)? handler) {
    _pc.onDataChannel =
        handler == null ? null : (ch) => handler(FlutterRtcDataChannel(ch));
  }

  @override
  set onConnectionState(void Function(String state)? handler) {
    _pc.onConnectionState = handler == null
        ? null
        : (s) => handler(switch (s) {
              rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
                'connected',
              rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
                'disconnected',
              rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
                'failed',
              rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed =>
                'closed',
              _ => 'other',
            });
  }

  @override
  Future<RtcSessionDescription> createOffer() async {
    final d = await _pc.createOffer();
    return RtcSessionDescription(d.sdp ?? '', d.type ?? 'offer');
  }

  @override
  Future<RtcSessionDescription> createAnswer() async {
    final d = await _pc.createAnswer();
    return RtcSessionDescription(d.sdp ?? '', d.type ?? 'answer');
  }

  @override
  Future<void> setLocalDescription(RtcSessionDescription description) =>
      _pc.setLocalDescription(
          rtc.RTCSessionDescription(description.sdp, description.type));

  @override
  Future<void> setRemoteDescription(RtcSessionDescription description) =>
      _pc.setRemoteDescription(
          rtc.RTCSessionDescription(description.sdp, description.type));

  @override
  Future<void> addCandidate(RtcCandidate candidate) => _pc.addCandidate(
      rtc.RTCIceCandidate(
          candidate.candidate, candidate.sdpMid, candidate.sdpMLineIndex));

  @override
  Future<RtcDataChannel> createDataChannel(String label) async {
    final init = rtc.RTCDataChannelInit()
      ..ordered = true
      ..id = 0;
    return FlutterRtcDataChannel(
        await _pc.createDataChannel(label, init));
  }

  @override
  Future<void> close() => _pc.close();
}

// ------------------------------------------------------------------
// signalling seam
// ------------------------------------------------------------------

/// One signalling channel for a room: JSON messages
/// (`offer` / `answer` / `candidate`) between the two phones.
///
/// The transport owns the channel it is given: it closes it when the
/// handshake ends (the data channel carries everything after that)
/// and again when the transport closes. Implementations are
/// idempotent on [close].
abstract class WebrtcSignalling {
  Future<void> send(Map<String, dynamic> message);

  Stream<Map<String, dynamic>> get messages;

  Future<void> close();
}

/// [WebrtcSignalling] over the Cloudflare Worker (see
/// `docs/webrtc-signalling-worker.js`): POST `/signal`
/// `{room, message}` to send, GET `/signal?room=…&since=…` polling
/// for `{messages, cursor}` to receive.
///
/// When [authKey] is set, outgoing messages are HMAC-signed and
/// incoming ones are verified ([SignallingAuth]); unsigned or
/// tampered messages are dropped. Re-delivered messages (cursor
/// regression) are dropped by content hash ([SignallingDedupe]).
class HttpSignalling implements WebrtcSignalling {
  HttpSignalling(
    this.base, {
    required this.room,
    this.pollInterval = const Duration(seconds: 2),
    this.authKey,
    HttpClient? client,
  }) : _client = client ?? HttpClient() {
    _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(_poll()));
    unawaited(_poll());
  }

  final Uri base;
  final String room;
  final Duration pollInterval;

  /// HMAC key for signalling messages (SHA-256 of the pairing
  /// token); `null` accepts unsigned messages (first pairing).
  final List<int>? authKey;

  final HttpClient _client;

  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _dedupe = SignallingDedupe();
  Timer? _pollTimer;
  int _cursor = 0;
  bool _polling = false;
  bool _closed = false;

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  @override
  Future<void> send(Map<String, dynamic> message) async {
    final key = authKey;
    final signed =
        key == null ? message : SignallingAuth.sign(message, key);
    final request = await _client.postUrl(base.resolve('/signal'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'room': room, 'message': signed}));
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode >= 400) {
      throw HttpException('signalling POST ${response.statusCode}');
    }
  }

  Future<void> _poll() async {
    if (_closed || _polling) return;
    _polling = true;
    try {
      final uri = base.resolve('/signal').replace(queryParameters: {
        'room': room,
        'since': '$_cursor',
      });
      final request = await _client.getUrl(uri);
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        final msgs = decoded['messages'];
        if (msgs is List) {
          for (final m in msgs) {
            if (m is! Map<String, dynamic>) continue;
            // Unauthenticated or tampered messages are dropped
            // (finding N6); re-deliveries after a cursor regression
            // are dropped by content hash (finding N9).
            final key = authKey;
            if (key != null && !SignallingAuth.verify(m, key)) continue;
            if (_dedupe.isDuplicate(canonicalJson(m))) continue;
            _messages.add(m);
          }
        }
        final cursor = decoded['cursor'];
        if (cursor is int) _cursor = cursor;
      }
    } catch (_) {
      // Transient (offline, worker cold start): the next poll retries.
    } finally {
      _polling = false;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    await _messages.close();
    _client.close();
  }
}

// ------------------------------------------------------------------
// transport
// ------------------------------------------------------------------

/// A [Transport] over a WebRTC data channel.
///
/// Created through [connect] (initiator: the iPhone) or [answer]
/// (responder: the Android phone). The handshake runs over the
/// signalling channel; afterwards the `tether` data channel carries
/// the record bytes, and the signalling channel is closed.
class WebrtcTransport implements Transport {
  WebrtcTransport._(
    this._channel,
    this._pc,
    this._signalling, {
    required this.address,
    required this.room,
  }) {
    _channel.messages.listen(
      _onChannelMessage,
      onError: (_) => close(),
      onDone: close,
      cancelOnError: true,
    );
  }

  /// Initiator (iPhone): creates the offer, sends it, waits for the
  /// answer, then for the data channel to open.
  ///
  /// [cancelWhen] aborts the handshake early (the listener's stop):
  /// it completes the pending handshake with a [StateError] instead
  /// of waiting out [handshakeTimeout] (finding N7).
  static Future<WebrtcTransport> connect({
    required String room,
    required WebrtcSignalling signalling,
    RtcPeerConnectionFactory factory = const FlutterWebrtcFactory(),
    WebrtcConfig config = const WebrtcConfig(),
    Duration handshakeTimeout = const Duration(seconds: 30),
    Future<void>? cancelWhen,
  }) async {
    RtcPeerConnection? pc;
    try {
      pc = await factory.create(config.configuration);
      final transport = await _establish(
        pc: pc,
        signalling: signalling,
        initiator: true,
        room: room,
        timeout: handshakeTimeout,
        cancelWhen: cancelWhen,
      );
      AppLogger.i('webrtc', 'connected as initiator room=$room');
      return transport;
    } catch (e) {
      AppLogger.e('webrtc', 'connect failed: $e');
      await pc?.close().catchError((_) {});
      // The signalling channel starts polling in its constructor:
      // close it here too, or its timer + HttpClient leak when the
      // peer connection never existed (finding N5). `_establish`
      // closes it on every other path, and close is idempotent.
      await signalling.close().catchError((_) {});
      rethrow;
    }
  }

  /// Responder (Android phone): waits for the offer, answers it,
  /// then for the data channel the initiator created to open.
  static Future<WebrtcTransport> answer({
    required String room,
    required WebrtcSignalling signalling,
    RtcPeerConnectionFactory factory = const FlutterWebrtcFactory(),
    WebrtcConfig config = const WebrtcConfig(),
    Duration handshakeTimeout = const Duration(seconds: 60),
    Future<void>? cancelWhen,
  }) async {
    RtcPeerConnection? pc;
    try {
      pc = await factory.create(config.configuration);
      final transport = await _establish(
        pc: pc,
        signalling: signalling,
        initiator: false,
        room: room,
        timeout: handshakeTimeout,
        cancelWhen: cancelWhen,
      );
      AppLogger.i('webrtc', 'connected as responder room=$room');
      return transport;
    } catch (e) {
      AppLogger.e('webrtc', 'answer failed: $e');
      await pc?.close().catchError((_) {});
      await signalling.close().catchError((_) {});
      rethrow;
    }
  }

  static Future<WebrtcTransport> _establish({
    required RtcPeerConnection pc,
    required WebrtcSignalling signalling,
    required bool initiator,
    required String room,
    required Duration timeout,
    Future<void>? cancelWhen,
  }) async {
    final channelCompleter = Completer<RtcDataChannel>();
    final failed = Completer<void>();
    var remoteSet = false;
    final pendingCandidates = <RtcCandidate>[];

    Future<void> flushCandidates() async {
      if (!remoteSet) return;
      for (final c in pendingCandidates) {
        await pc.addCandidate(c).catchError((_) {});
      }
      pendingCandidates.clear();
    }

    pc.onIceCandidate = (candidate) {
      unawaited(signalling.send({
        'type': 'candidate',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      }).catchError((_) {}));
    };
    pc.onConnectionState = (state) {
      if ((state == 'failed' || state == 'closed') &&
          !failed.isCompleted) {
        failed.complete();
      }
    };
    if (initiator) {
      final channel = await pc.createDataChannel('tether');
      if (!channelCompleter.isCompleted) channelCompleter.complete(channel);
    } else {
      pc.onDataChannel = (channel) {
        if (!channelCompleter.isCompleted) {
          channelCompleter.complete(channel);
        }
      };
    }

    final sub = signalling.messages.listen((msg) async {
      try {
        switch (msg['type']) {
          case 'offer':
            if (initiator) return;
            await pc.setRemoteDescription(
                RtcSessionDescription(msg['sdp'] as String, 'offer'));
            remoteSet = true;
            await flushCandidates();
            final answer = await pc.createAnswer();
            await pc.setLocalDescription(answer);
            await signalling.send({'type': 'answer', 'sdp': answer.sdp});
          case 'answer':
            if (!initiator) return;
            await pc.setRemoteDescription(
                RtcSessionDescription(msg['sdp'] as String, 'answer'));
            remoteSet = true;
            await flushCandidates();
          case 'candidate':
            final candidate = msg['candidate'];
            if (candidate is! String) return;
            final c = RtcCandidate(
              candidate,
              msg['sdpMid'] as String?,
              (msg['sdpMLineIndex'] as num?)?.toInt(),
            );
            if (remoteSet) {
              await pc.addCandidate(c).catchError((_) {});
            } else {
              // Candidates can arrive before the remote description:
              // hold them until it is set (the native side rejects
              // early candidates otherwise).
              pendingCandidates.add(c);
            }
        }
      } catch (_) {
        if (!failed.isCompleted) failed.complete();
      }
    }, onError: (_) {
      if (!failed.isCompleted) failed.complete();
    });

    try {
      if (initiator) {
        final offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        await signalling.send({'type': 'offer', 'sdp': offer.sdp});
      }
      // The channel the initiator opens (or the responder receives).
      // The race is over plain values, not throwing futures: a
      // cancellation that lands after the handshake succeeded must
      // stay harmless (a throwing future in Future.any would surface
      // as an unhandled error).
      final result = await Future.any<Object>([
        channelCompleter.future.then<Object>((c) => c),
        failed.future.then<Object>((_) => _HandshakeFailed()),
        if (cancelWhen != null)
          cancelWhen.then<Object>((_) => _HandshakeCancelled()),
      ]).timeout(timeout);
      if (result is _HandshakeFailed) {
        throw StateError('peer connection failed');
      }
      if (result is _HandshakeCancelled) {
        throw StateError('handshake cancelled');
      }
      final channel = result as RtcDataChannel;
      final opened = await Future.any<Object>([
        channel.whenOpen.then<Object>((_) => true),
        if (cancelWhen != null)
          cancelWhen.then<Object>((_) => _HandshakeCancelled()),
      ]).timeout(timeout);
      if (opened is _HandshakeCancelled) {
        throw StateError('handshake cancelled');
      }
      return WebrtcTransport._(
        channel,
        pc,
        signalling,
        address: room,
        room: room,
      );
    } finally {
      // The data channel carries everything from here; the
      // signalling channel is no longer needed.
      await sub.cancel();
      await signalling.close();
    }
  }

  final RtcDataChannel _channel;
  final RtcPeerConnection _pc;
  final WebrtcSignalling _signalling;

  @override
  final String label = 'webrtc';

  @override
  final String address;

  /// A WebRTC transport is never a test transport.
  @override
  bool get dry => false;

  /// The signalling room this transport belongs to.
  final String room;

  void Function(List<int> bytes, int length)? _onBytes;
  void Function()? _onClosed;
  final List<List<int>> _buffer = [];
  bool _closed = false;
  final _closedCompleter = Completer<void>();

  /// Completes when the transport closes (used by [WebrtcListener]
  /// to know when to listen for the next offer).
  Future<void> get closed => _closedCompleter.future;

  void _onChannelMessage(List<int> bytes) {
    if (_closed) return;
    final onBytes = _onBytes;
    if (onBytes == null) {
      _buffer.add(bytes);
      return;
    }
    onBytes(bytes, bytes.length);
  }

  @override
  void start(void Function(List<int> bytes, int length) onBytes,
      void Function() onClosed) {
    _onBytes = onBytes;
    _onClosed = onClosed;
    for (final bytes in _buffer) {
      onBytes(bytes, bytes.length);
    }
    _buffer.clear();
  }

  @override
  void write(List<int> bytes) {
    if (_closed) throw StateError('transport closed');
    unawaited(_channel.send(bytes).catchError((_) => close()));
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_channel.close().catchError((_) {}));
    unawaited(_pc.close().catchError((_) {}));
    unawaited(_signalling.close().catchError((_) {}));
    if (!_closedCompleter.isCompleted) _closedCompleter.complete();
    scheduleMicrotask(() => _onClosed?.call());
  }
}

/// The Android side's WebRTC listener: waits for offers on the
/// signalling channel, answers them, and hands each resulting
/// transport to [onTransport] (the link service feeds it to the
/// Hub). After a transport ends it listens for the next offer.
/// A fresh signalling channel is created per iteration — the
/// transport closes its own when its handshake ends.
class WebrtcListener {
  WebrtcListener({
    required this.signallingFactory,
    required this.room,
    this.factory = const FlutterWebrtcFactory(),
    this.config = const WebrtcConfig(),
    this.onTransport,
    this.handshakeTimeout = const Duration(seconds: 60),
    this.retryDelay = const Duration(seconds: 5),
  });

  /// Creates a signalling channel for one listen iteration.
  final WebrtcSignalling Function() signallingFactory;

  final String room;
  final RtcPeerConnectionFactory factory;
  final WebrtcConfig config;
  final void Function(Transport transport)? onTransport;
  final Duration handshakeTimeout;
  final Duration retryDelay;

  bool _running = false;

  /// Cancels the in-flight `answer()` (finding N7). A fresh one is
  /// created per listen iteration.
  Completer<void>? _cancelCompleter;

  /// Starts listening. Returns when [stop] is called; each offer
  /// produces one transport through [onTransport].
  Future<void> start() async {
    if (_running) return;
    _running = true;
    while (_running) {
      _cancelCompleter = Completer<void>();
      try {
        final transport = await WebrtcTransport.answer(
          room: room,
          signalling: signallingFactory(),
          factory: factory,
          config: config,
          handshakeTimeout: handshakeTimeout,
          cancelWhen: _cancelCompleter!.future,
        );
        if (!_running) {
          transport.close();
          break;
        }
        onTransport?.call(transport);
        await transport.closed;
      } catch (_) {
        if (!_running) break;
        await Future<void>.delayed(retryDelay);
      }
    }
  }

  /// Stops listening. Returns promptly even while `answer()` awaits
  /// an offer: the cancellation token aborts the handshake, and the
  /// `start()` loop sees `_running == false` and exits (finding N7).
  Future<void> stop() async {
    _running = false;
    final c = _cancelCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }
}

/// Marker for the handshake race: the peer connection failed.
class _HandshakeFailed {}

/// Marker for the handshake race: the listener stopped mid-handshake.
class _HandshakeCancelled {}
