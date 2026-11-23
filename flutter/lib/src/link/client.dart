/// The iPhone side of the link (finding 2): a [CentralConnection]
/// over a transport (BLE via [BleLink] or TCP), sending `sync` /
/// `sms.send` / `call.*` / `net.*` / `selftest` / `unpair`, and
/// applying incoming batches and call events to a [ClientStore]
/// (the app model).
///
/// Design note: message handling is split by direction, in the class
/// that owns that role. The [Hub] handles the iPhone→Android types
/// (it is the peripheral, and its `onMessage` is the Android side);
/// this class handles the Android→iPhone types. Neither class sees
/// the other's direction, so there is exactly one place where each
/// message type is applied.
library;

import 'dart:async';

import '../log/log.dart';
import '../protocol/audio.dart';
import '../protocol/crypto.dart';
import '../protocol/messages.dart';
import 'callkit.dart';
import 'connection.dart';
import 'ios_audio.dart';
import 'transport.dart';

/// The app data the client applies incoming link data to.
///
/// Implemented by the app model (see `AppModel`); a fake stands in
/// for it in tests. All methods are fire-and-forget: the link never
/// waits for the UI.
abstract class ClientStore {
  /// Highest SMS id the store holds (sent in `sync` as `sms`).
  int get smsSince;

  /// Highest call id the store holds (sent in `sync` as `calls`).
  int get callsSince;

  /// Contacts version the store holds (sent in `sync` as `contacts`).
  String get contactsVersion;

  /// This iPhone's Bark device key, for the `sync` client object
  /// (so the Android side can wake it when the link is down).
  String? get barkKey;

  void applyStatus(Map<String, dynamic> status);
  void applySmsBatch(List<Sms> msgs, {required bool more});
  void applySmsNew(Sms msg);

  /// Another client marked a thread read up to an SMS id.
  void applySmsRead(int thread, int upTo);
  void applySmsUnread(List<int> ids, {required bool all});
  void applySmsResult({required bool ok, String? state, String? err});
  void applySmsDeleted(List<int> ids);

  /// Call history (recents): `calls.batch` carries [CallEntry] rows,
  /// not live [CallInfo] — the two are different shapes.
  void applyCallsBatch(List<CallEntry> calls, {required bool more});
  void applyCallState(CallInfo call);
  void applyCallList(List<CallInfo> calls);
  void applyCallDialed({required bool ok, String? err});
  void applyCallsDeleted(List<int> ids, {required bool all});
  void applyContactsBatch(List<Contact> contacts,
      {required String version, required bool full});
  void applyContactResult({required bool ok, int? id, String? err});
  void applyLists(Map<String, dynamic> lists);
  void applySyncIds(
      {required List<List<int>> smsRanges,
      required List<List<int>> callRanges,
      required bool more});
  void applyNetState(Map<String, dynamic> net);
  void applySelftestResult(Map<String, dynamic> result);
  void applyAudioStarted({required String codec, required int rate});
  void applyAudioStopped();
  void applyLinkUp();
  void applyLinkLost();
}

/// The iPhone's audio path: the native audio engine behind CallKit.
///
/// The client's captured microphone frames are forwarded to the
/// Android phone as audio records; downlink frames from the Android
/// phone are played through the engine.
abstract class ClientAudioSink {
  Future<void> startAudio(
      {required String codec, required int rate, int? bitrate});
  Future<void> stopAudio();

  /// Encoded microphone frames, captured while a call is active.
  Stream<AudioFrame> get captured;

  Future<void> playFrame(
      {required int codec, required int seq, required List<int> payload});
}

/// [ClientAudioSink] over the iOS `com.simbridge/audio` channel.
class IosClientAudioSink implements ClientAudioSink {
  IosClientAudioSink(this._bridge);

  final IosAudioBridge _bridge;

  @override
  Future<void> startAudio(
          {required String codec, required int rate, int? bitrate}) =>
      _bridge.audioStart(codec: codec, rate: rate, bitrate: bitrate);

  @override
  Future<void> stopAudio() => _bridge.audioStop();

  @override
  Stream<AudioFrame> get captured => _bridge.captured
      .map((f) => AudioFrame(f.codec, f.seq, f.payload));

  @override
  Future<void> playFrame(
          {required int codec,
          required int seq,
          required List<int> payload}) =>
      _bridge.playFrame(codec: codec, seq: seq, payload: payload);
}

/// The iPhone side of one link to the Android phone.
///
/// Owns the [CentralConnection] (via a [ReconnectingLink], so a
/// dropped transport is retried with backoff), the sync flow, the
/// CallKit wiring, the audio sink, and the ping timer. Pairing is
/// [pair] (QR code → pair-mode handshake); a later launch resumes
/// with [loadPaired] and no token.
class LinkClient implements ConnectionListener {
  LinkClient({
    required this.transportFactory,
    required this.ownKey,
    required this.audioSink,
    this.store,
    this.clientName = 'iPhone',
    this.pingInterval = const Duration(seconds: 25),
  }) {
    _capturedSub = audioSink.captured.listen(
      (frame) {
        _connection?.sendAudio(frame.encoded());
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  /// Creates a transport for each (re)connect attempt. Mutable: the
  /// transport switch (BLE ↔ WebRTC) swaps it at runtime through
  /// [useTransportFactory].
  Future<Transport> Function() transportFactory;

  /// This iPhone's long-term static P-256 key pair.
  final P256KeyPair ownKey;

  /// The native audio engine.
  final ClientAudioSink audioSink;

  /// Where incoming data is applied. Set before [start].
  ClientStore? store;

  /// Display name sent in the `sync` client object.
  final String clientName;

  /// How often to ping while connected (the Hub answers `pong`).
  final Duration pingInterval;

  /// This iPhone's Bark device key (sent in every `sync`).
  String? barkKey;

  /// Called after a successful pair-mode handshake, so the caller can
  /// persist the peer (KeyStore).
  void Function()? onPaired;

  /// Called when the user unpairs (or the peer unpairs us).
  void Function()? onUnpaired;

  List<int>? _peerStatic;
  List<int>? _pairToken;
  String? _peerName;
  ReconnectingLink? _link;

  /// The pairing token from the QR code, while pairing is in
  /// progress. The caller reads it in [onPaired] to persist the
  /// signalling key ([KeyStore.saveSignallingKey]); it is cleared
  /// right after, so a later read returns `null`.
  List<int>? get pairToken => _pairToken;

  /// Set when the link is closed deliberately (unpair / stop): the
  /// close is not a loss, so the store is not told the link was
  /// lost. Cleared when a new link starts.
  bool _closedByUs = false;
  StreamSubscription<AudioFrame>? _capturedSub;
  Timer? _pingTimer;
  int _nextId = 1;

  /// Monotonic counter for dial call ids (`c1`, `c2`, …) — never
  /// reused while the client lives (finding N12).
  int _nextCid = 1;

  /// Requests waiting for their `re` reply: id → completer with the
  /// reply body.
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  /// Request id → call id, for `call.dialed` → CallKit.
  final Map<int, String> _dialCids = {};

  /// SMS ids whose read state changed while offline: sent after the
  /// next sync. Entries are (thread, upTo) pairs.
  final List<(int, int)> _pendingReadSms = [];

  bool get isPaired => _peerStatic != null;
  bool get isConnected => _link?.isUp ?? false;

  /// The paired peripheral's static key, for persistence (KeyStore).
  List<int>? get peerStaticKey => _peerStatic;

  /// The paired peripheral's name, from the pairing code.
  String? get peerName => _peerName;
  CentralConnection? get _connection =>
      _link?.current as CentralConnection?;

  /// Starts the (re)connect loop. Does nothing until paired.
  void start() {
    final peer = _peerStatic;
    if (peer == null || _link != null) return;
    AppLogger.i('client', 'connect loop start');
    _closedByUs = false;
    final token = _pairToken;
    _link = ReconnectingLink(
      transportFactory: transportFactory,
      connectionFactory: (t) => CentralConnection(
        t,
        this,
        CentralKeys(staticKey: ownKey, peerStatic: peer, token: token),
      ),
      listener: this,
    );
    _link!.start();
  }

  /// Stops reconnecting and closes the current connection, if any.
  void stop() {
    AppLogger.i('client', 'stop');
    _closedByUs = true;
    _pingTimer?.cancel();
    _pingTimer = null;
    _link?.stop();
    _link = null;
    unawaited(audioSink.stopAudio().catchError((_) {}));
  }

  /// Swaps the transport factory (BLE ↔ WebRTC when the user flips
  /// the transport switch) and restarts the reconnect loop, so the
  /// next attempt uses the new transport. No-op when the link is
  /// not running yet (the new factory is used at the next [start]).
  void useTransportFactory(Future<Transport> Function() factory) {
    transportFactory = factory;
    if (_link != null) {
      stop();
      start();
    }
  }

  void dispose() {
    stop();
    unawaited(_capturedSub?.cancel());
    _capturedSub = null;
  }

  /// Pairs with the Android phone from a scanned QR code: connects
  /// in pair mode with the code's token. On success [onPaired] fires
  /// and the caller persists the peer.
  void pair(PairingCode code) {
    AppLogger.i('client', 'pairing with ${code.deviceName}');
    _peerStatic = code.peripheralKey;
    _pairToken = code.token;
    _peerName = code.deviceName;
    _link?.stop();
    _link = null;
    start();
  }

  /// Resumes a previously paired peer (no token): the handshake runs
  /// in resume mode.
  void loadPaired(List<int> peerStaticKey) {
    _peerStatic = peerStaticKey;
    _pairToken = null;
  }

  /// Unpairs: tells the Android phone to forget this iPhone, then
  /// drops the link and clears the peer. The link is closed after a
  /// short delay so the `unpair` message goes out first (the same
  /// reason the Hub waits 300 ms after a REJECT).
  void unpair() {
    // Deliberate: any close from here on (including the Hub
    // closing the link when it receives this) is not a link loss.
    _closedByUs = true;
    _connection?.send(const Message(MessageType.unpair));
    // The peer is forgotten at once (the message is already
    // queued); only the link close waits, so it goes out first.
    _peerStatic = null;
    _pairToken = null;
    _peerName = null;
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      stop();
      onUnpaired?.call();
    });
  }

  /// Attaches CallKit: its actions become `call.*` messages, and
  /// incoming call state is mirrored into the native call screen.
  /// Dialing from CallKit goes through [dial] so the `call.dialed`
  /// reply can be reported back as accepted/failed; the other
  /// actions use [CallKitAction.toMessage] directly.
  void attachCallKit(CallKitBridge kit) {
    kit.actions.listen((event) {
      if (event.kind == 'dial') {
        final num = event.num;
        if (num != null) unawaited(dial(num, sub: event.sub));
        return;
      }
      final msg = event.toMessage();
      if (msg != null) _connection?.sendUrgent(msg);
    });
    _callKit = kit;
  }

  CallKitBridge? _callKit;

  // ------------------------------------------------------------------
  // outgoing

  /// Sends `sync`: what this iPhone already has, so the Android
  /// phone replies with only the missing batches, then the ids that
  /// still exist, the lists, and the unread ids.
  void sendSync() {
    final s = store;
    final client = <String, dynamic>{
      'kind': 'iphone',
      'name': clientName,
    };
    final key = barkKey ?? s?.barkKey;
    if (key != null && key.isNotEmpty) client['barkKey'] = key;
    _connection?.send(Message(MessageType.sync, b: {
      'sms': s?.smsSince ?? 0,
      'calls': s?.callsSince ?? 0,
      'contacts': s?.contactsVersion ?? '',
      'codecs': const ['opus', 'pcmu'],
      'client': client,
    }));
  }

  /// Sends an SMS. Completes with the `sms.result` body when the
  /// Android phone reports it sent (or failed).
  Future<Map<String, dynamic>> sendSms({
    required String to,
    required String body,
    int? sub,
    bool draft = false,
  }) =>
      _request(Message(MessageType.smsSend, b: {
        'to': to,
        'body': body,
        'sub': ?sub,
        'draft': draft,
      }));

  /// Marks a thread read up to an SMS id. While offline the pair is
  /// queued and flushed after the next sync.
  void markThreadRead(int thread, int upTo) {
    final c = _connection;
    if (c == null || !c.isUp) {
      _pendingReadSms.add((thread, upTo));
      return;
    }
    c.send(Message(MessageType.smsRead, b: {
      'thread': thread,
      'upTo': upTo,
    }));
  }

  void deleteSms(List<int> ids, {int? thread}) {
    _connection?.send(Message(MessageType.smsDelete, b: {
      'ids': ids,
      'thread': ?thread,
    }));
  }

  void deleteCalls(List<int> ids) {
    _connection?.send(Message(MessageType.callsDelete, b: {'ids': ids}));
  }

  void setLists(Map<String, dynamic> lists) {
    _connection?.send(Message(MessageType.listsSet, b: lists));
  }

  Future<Map<String, dynamic>> addContact(Contact contact) =>
      _request(Message(MessageType.contactAdd, b: contact.toJson()));

  Future<Map<String, dynamic>> updateContact(Contact contact) =>
      _request(Message(MessageType.contactUpdate, b: contact.toJson()));

  Future<Map<String, dynamic>> starContact(int id, bool starred) =>
      _request(Message(MessageType.contactStar, b: {
        'id': id,
        'on': starred,
      }));

  /// Dials from this iPhone. Completes with the `call.dialed` body;
  /// CallKit is told whether the dial was accepted. The call id is a
  /// monotonic counter, not wall-clock milliseconds: two dials in
  /// the same millisecond must not collide (finding N12).
  Future<Map<String, dynamic>> dial(String num, {int? sub}) {
    final cid = 'c${_nextCid++}';
    final id = _nextId++;
    _dialCids[id] = cid;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _connection?.sendUrgent(Message(MessageType.callDial,
        b: {
          'num': num,
          'cid': cid,
          'sub': ?sub,
        },
        id: id));
    return _timeout(id, completer);
  }

  void answer(String cid) {
    _connection?.sendUrgent(
        Message(MessageType.callAnswer, b: {'cid': cid}));
  }

  void reject(String cid) {
    _connection?.sendUrgent(
        Message(MessageType.callReject, b: {'cid': cid}));
  }

  void end(String cid) {
    _connection?.sendUrgent(Message(MessageType.callEnd, b: {'cid': cid}));
  }

  void hold(String cid, bool on) {
    _connection?.sendUrgent(
        Message(MessageType.callHold, b: {'cid': cid, 'on': on}));
  }

  void mute(String cid, bool on) {
    // PROTOCOL §5: `call.mute` body is `{on}` only — no `cid`
    // (finding N4; the Hub's `callMute` handler reads only `on`).
    // `cid` is kept as a parameter so callers do not change; it is
    // deliberately not sent.
    _connection?.sendUrgent(
        Message(MessageType.callMute, b: {'on': on}));
  }

  void dtmf(String cid, String digit) {
    _connection?.sendUrgent(
        Message(MessageType.callDtmf, b: {'cid': cid, 'd': digit}));
  }

  void take(String cid) {
    _connection?.sendUrgent(Message(MessageType.callTake, b: {'cid': cid}));
  }

  Future<Map<String, dynamic>> getNet() =>
      _request(const Message(MessageType.netGet));

  Future<Map<String, dynamic>> setNet(Map<String, dynamic> net) =>
      _request(Message(MessageType.netSet, b: net));

  Future<Map<String, dynamic>> selftest() =>
      _request(const Message(MessageType.selftest));

  Future<Map<String, dynamic>> _request(Message m) {
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _connection?.send(Message(m.t, b: m.b, id: id));
    return _timeout(id, completer);
  }

  Future<Map<String, dynamic>> _timeout(
      int id, Completer<Map<String, dynamic>> completer) {
    Future<void>.delayed(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        _pending.remove(id);
        _dialCids.remove(id);
        completer.complete({'ok': false, 'err': 'timeout'});
      }
    });
    return completer.future;
  }

  void _completePending(int? re, Map<String, dynamic> body) {
    if (re == null) return;
    final completer = _pending.remove(re);
    if (completer != null && !completer.isCompleted) {
      completer.complete(body);
    }
  }

  // ------------------------------------------------------------------
  // ConnectionListener

  @override
  bool admits(LinkConnection c) => true;

  @override
  void onEstablished(LinkConnection c, bool newlyPaired) {
    AppLogger.i('client', 'link up newlyPaired=$newlyPaired');
    if (newlyPaired) {
      // `onPaired` first: the caller persists the signalling key
      // from [pairToken] (finding N6) before it is cleared. The
      // pairing token has done its job: later reconnects must
      // resume (token null). The peripheral closes pairing after
      // the first pair — with only a 10-minute HELLO-repeat grace
      // (PROTOCOL §1) — so a token left over here would make every
      // reconnect after that window fail with `pairingClosed`.
      onPaired?.call();
      _pairToken = null;
    }
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(pingInterval, (_) {
      _connection?.send(const Message(MessageType.ping));
    });
    sendSync();
    // Reads queued while offline go out after the sync, so the
    // Android phone applies them on the fresh state.
    if (_pendingReadSms.isNotEmpty) {
      final reads = List<(int, int)>.of(_pendingReadSms);
      _pendingReadSms.clear();
      for (final (thread, upTo) in reads) {
        markThreadRead(thread, upTo);
      }
    }
    store?.applyLinkUp();
  }

  @override
  void onMessage(LinkConnection c, Message m) {
    final s = store;
    switch (m.t) {
      case MessageType.ping:
        c.send(const Message(MessageType.pong));
      case MessageType.pong:
        break;
      case MessageType.status:
        s?.applyStatus(m.b);
      case MessageType.smsBatch:
        s?.applySmsBatch(
          _parseList(m.b['items'], Sms.fromJson),
          more: m.b['more'] as bool? ?? false,
        );
      case MessageType.smsNew:
        final msg = m.b['item'];
        if (msg is Map<String, dynamic>) s?.applySmsNew(Sms.fromJson(msg));
      case MessageType.smsRead:
        final thread = (m.b['thread'] as num?)?.toInt();
        final upTo = (m.b['upTo'] as num?)?.toInt();
        if (thread != null && upTo != null) s?.applySmsRead(thread, upTo);
      case MessageType.smsUnread:
        final ids = _parseInts(m.b['ids']);
        s?.applySmsUnread(ids, all: m.b['all'] as bool? ?? false);
      case MessageType.smsResult:
        _completePending(m.re, m.b);
        s?.applySmsResult(
          ok: m.b['ok'] as bool? ?? false,
          state: m.b['state'] as String?,
          err: m.b['err'] as String?,
        );
      case MessageType.smsDeleted:
        s?.applySmsDeleted(_parseInts(m.b['ids']));
      case MessageType.callsBatch:
        s?.applyCallsBatch(
          _parseList(m.b['items'], CallEntry.fromJson),
          more: m.b['more'] as bool? ?? false,
        );
      case MessageType.callState:
        final call = CallInfo.fromJson(m.b);
        s?.applyCallState(call);
        unawaited(_callKit?.reportCall(call));
      case MessageType.callList:
        s?.applyCallList(_parseList(m.b['calls'], CallInfo.fromJson));
      case MessageType.callDialed:
        _completePending(m.re, m.b);
        final ok = m.b['ok'] as bool? ?? false;
        final err = m.b['err'] as String?;
        s?.applyCallDialed(ok: ok, err: err);
        final cid = _dialCids.remove(m.re);
        if (cid != null) {
          if (ok) {
            unawaited(_callKit?.dialAccepted());
          } else {
            unawaited(_callKit?.dialFailed(err ?? 'dial failed'));
          }
        }
      case MessageType.callsDeleted:
        s?.applyCallsDeleted(_parseInts(m.b['ids']),
            all: m.b['all'] as bool? ?? false);
      case MessageType.contactsBatch:
        s?.applyContactsBatch(
          _parseList(m.b['items'], Contact.fromJson),
          version: m.b['version'] as String? ?? '',
          full: m.b['full'] as bool? ?? false,
        );
      case MessageType.contactResult:
        _completePending(m.re, m.b);
        s?.applyContactResult(
          ok: m.b['ok'] as bool? ?? false,
          id: (m.b['id'] as num?)?.toInt(),
          err: m.b['err'] as String?,
        );
      case MessageType.lists:
        s?.applyLists(m.b);
      case MessageType.syncIds:
        s?.applySyncIds(
          smsRanges: _parseRanges(m.b['sms']),
          callRanges: _parseRanges(m.b['calls']),
          more: m.b['more'] as bool? ?? false,
        );
      case MessageType.audioStart:
        final codec = m.b['codec'] as String? ?? 'opus';
        final rate = (m.b['rate'] as num?)?.toInt() ?? 16000;
        final bitrate = (m.b['bitrate'] as num?)?.toInt();
        unawaited(audioSink
            .startAudio(codec: codec, rate: rate, bitrate: bitrate)
            .catchError((_) {}));
        s?.applyAudioStarted(codec: codec, rate: rate);
      case MessageType.audioStop:
        unawaited(audioSink.stopAudio().catchError((_) {}));
        s?.applyAudioStopped();
      case MessageType.netState:
        _completePending(m.re, m.b);
        s?.applyNetState(m.b);
      case MessageType.selftestResult:
        _completePending(m.re, m.b);
        s?.applySelftestResult(m.b);
      default:
        // Unknown types are ignored.
        break;
    }
  }

  @override
  void onAudio(LinkConnection c, List<int> payload) {
    final frame = AudioFrame.parse(payload);
    if (frame == null) return;
    unawaited(audioSink
        .playFrame(codec: frame.codec, seq: frame.seq, payload: frame.payload)
        .catchError((_) {}));
  }

  @override
  void onClosed(LinkConnection c) {
    AppLogger.i('client', 'link closed byUs=$_closedByUs');
    _pingTimer?.cancel();
    _pingTimer = null;
    unawaited(audioSink.stopAudio().catchError((_) {}));
    // A deliberate close (unpair / stop) is not a link loss: the
    // model already shows the right state, and the reconnect loop
    // is stopped anyway.
    if (!_closedByUs) {
      store?.applyLinkLost();
    }
    unawaited(_callKit?.linkLost());
  }

  static List<T> _parseList<T>(
      dynamic raw, T Function(Map<String, dynamic>) fromJson) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(fromJson)
        .toList(growable: false);
  }

  static List<int> _parseInts(dynamic raw) {
    if (raw is! List) return const [];
    return raw.whereType<num>().map((e) => e.toInt()).toList();
  }

  static List<List<int>> _parseRanges(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<List>()
        .map((r) => r.whereType<num>().map((e) => e.toInt()).toList())
        .where((r) => r.length == 2)
        .toList();
  }
}
