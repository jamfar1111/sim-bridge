/// Routes everything between the peer link, the phone's data, calls
/// and call audio.
///
/// A Dart model of Tether's Android `link/Hub.kt`. The Android-only
/// parts (Telecom, SMS provider, helper process, BLE peripheral) are
/// behind [HubData] and the platform channels in `channels.dart`, so
/// this class is testable on the Dart VM with a fake provider.
library;

import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../bark/bark.dart';
import '../log/log.dart';
import '../protocol/messages.dart';
import 'audio_session.dart';
import 'callkit.dart';
import 'channels.dart';
import 'connection.dart';
import 'transport.dart';

/// The phone-side data and actions the Hub routes to.
///
/// Implemented natively later (via the platform channels); faked in
/// tests. Every method is the Android phone's job: the peer only ever
/// asks for things through messages.
abstract class HubData {
  Future<List<Sms>> smsSince(int sinceId);

  Future<List<CallEntry>> callsSince(int sinceId);

  Future<List<Contact>> contactsAll();

  String contactsVersion();

  Future<List<int>> smsAllIds();

  Future<List<int>> callAllIds();

  Future<List<int>?> unreadSmsIds();

  Future<Map<String, dynamic>> statusJson();

  /// Sends an SMS. Returns an error string, or `null` on success.
  /// The result (sent / delivered / failed) arrives later through
  /// [Hub.smsResult].
  Future<String?> sendSms({
    required String to,
    required String body,
    int? sub,
    required int localId,
    bool dry = false,
  });

  /// Marks a thread read up to a message id. Returns rows changed.
  Future<int> markSmsRead(int thread, int upTo);

  /// Deletes messages (or a whole thread). Returns deleted ids, or
  /// `null` when Android refused.
  Future<List<int>?> deleteSms(List<int> ids, int? thread);

  /// Deletes call-log rows (all when [ids] is `null`). Returns rows
  /// deleted, or -1 when Android refused.
  Future<int> deleteCalls(List<int>? ids);

  Future<int> setContactStarred(int id, bool on);

  /// Adds a contact. Returns the new row id, or -1 on failure.
  Future<int> addContact(String name, List<Phone> phones, List<String> emails);

  /// Updates a contact. Returns an error string, or `null` on success.
  Future<String?> updateContact(
      int id, String name, List<Phone> phones, List<String> emails);

  Future<Map<String, dynamic>> listsJson();

  /// Block / mute lists. Returns the new lists document.
  Future<Map<String, dynamic>> setLists(
    String what, {
    String? num,
    int? thread,
    required bool on,
  });

  Future<void> answerCall(String cid);

  Future<void> rejectCall(String cid);

  Future<void> endCall(String cid);

  Future<void> holdCall(String cid, bool on);

  /// Dials a number. Returns an error string, or `null` on success.
  Future<String?> dial(String num, int? sub);

  Future<void> dtmf(String cid, String digit);

  /// Network switches (data / hotspot / bt / dataSub / share /
  /// airplane / rat) via the shell helper. Returns the new state, or
  /// `null` when the helper did not answer.
  Future<Map<String, dynamic>?> netControl({
    String? what,
    bool on = false,
    int? sub,
    int? slot,
    String? mode,
  });

  Future<Map<String, dynamic>> selftest();

  /// Forgets a paired central.
  void unpair(List<int> peerKey);
}

class _PendingSms {
  const _PendingSms(this.connection, this.requestId, this.at);

  final LinkConnection connection;
  final int requestId;
  final DateTime at;
}

/// Persists the airplane fail-safe's armed state, so a restart
/// re-arms it (finding N10; Tether re-arms from a preference).
/// The Hub treats persistence as best-effort: a failing store never
/// breaks the in-memory check.
abstract class AirplaneFailSafeStore {
  Future<bool> readArmed();
  Future<void> writeArmed(bool armed);
}

/// In-memory store (tests, and the default when no store is
/// configured — the old in-memory-only behaviour).
class MemoryAirplaneFailSafeStore implements AirplaneFailSafeStore {
  bool _armed = false;

  @override
  Future<bool> readArmed() async => _armed;

  @override
  Future<void> writeArmed(bool armed) async {
    _armed = armed;
  }
}

/// Secure-storage-backed store (Keychain / EncryptedSharedPreferences).
class SecureAirplaneFailSafeStore implements AirplaneFailSafeStore {
  SecureAirplaneFailSafeStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String storageKey = 'sim_bridge_airplane_failsafe_armed';

  final FlutterSecureStorage _storage;

  @override
  Future<bool> readArmed() async =>
      await _storage.read(key: storageKey) == '1';

  @override
  Future<void> writeArmed(bool armed) async {
    if (armed) {
      await _storage.write(key: storageKey, value: '1');
    } else {
      await _storage.delete(key: storageKey);
    }
  }
}

/// Routes messages between the peer link and [HubData].
class Hub implements ConnectionListener {
  Hub(
    this.data, {
    required this.connectionFactory,
    this.pageWeight = 12000,
    this.smallPageWeight = 1500,
    this.callKit,
    this.farWake,
    AudioBridge? audioBridge,
    TelecomBridge? telecom,
    BleLink? ble,
    this.airplaneFailSafeInterval = const Duration(seconds: 15),
    this.airplaneFailSafeGrace = const Duration(seconds: 90),
    this.airplaneStore,
  })  : audio = AudioSession(
          bridge: audioBridge,
          telecom: telecom,
          ble: ble,
        ) {
    if (callKit != null) attachCallKit(callKit!);
  }

  final HubData data;

  /// Builds the link role for a new transport (peripheral on Android,
  /// central on iOS).
  final LinkConnection Function(Transport transport) connectionFactory;

  /// Page weight for sync batches; smaller while a call is running, so
  /// a big record never holds the next audio frames up.
  final int pageWeight;
  final int smallPageWeight;

  /// Airplane fail-safe timing: how often the check runs, and how
  /// long without any client before airplane mode is switched back
  /// off. Overridable for tests; the defaults match Tether.
  final Duration airplaneFailSafeInterval;
  final Duration airplaneFailSafeGrace;

  /// Persists the airplane fail-safe's armed state, so a restart
  /// re-arms it (finding N10). `null` keeps the old in-memory-only
  /// behaviour.
  final AirplaneFailSafeStore? airplaneStore;

  /// Every connected client (the protocol allows several; today the
  /// iPhone).
  final List<LinkConnection> conns = [];

  /// The client call audio goes to, else any connected client.
  LinkConnection? get conn =>
      audio.target ?? targets().firstOrNull;

  final AudioSession audio;

  /// Set by on-device tests: only this transport may hold the link.
  Transport? exclusive;

  /// Debug: only clients of this kind see calls and messages.
  String? onlyKind;

  /// A test transport may ask for things, but never performs a real
  /// call, SMS or edit.
  bool dryRun = false;

  /// Wakes the peer app before urgent traffic (BLE wake notification).
  /// Supplied by the platform code; no-op when unset.
  void Function(LinkConnection c)? onWake;

  /// Called when a pair-mode handshake completes, so the service can
  /// persist the central (KeyStore) and close pairing.
  void Function(LinkConnection c)? onPaired;

  /// Called when a session comes up / goes down, so the service can
  /// drive the LE lifecycle (setLinked / holdLe / releaseLe). Fired
  /// for every session, paired or not.
  void Function(LinkConnection c)? onSessionUp;
  void Function(LinkConnection c)? onSessionDown;

  /// iOS CallKit bridge, when this Hub runs on the iPhone side (the
  /// app's call router there). Null on Android — no CallKit exists
  /// there. Attached by [attachCallKit]; call state is mirrored into
  /// CallKit and user actions in CallKit come back as `call.*`
  /// messages. The bridge itself is a no-op without its native
  /// plugin, so attaching it on Android is harmless but pointless.
  CallKitBridge? callKit;

  /// Far wake-up notifier (Bark push), Android side only. Null when
  /// no Bark key is known yet. When a call or SMS arrives and no
  /// client is connected, the notifier pushes a Bark alert to the
  /// iPhone so the user can open the app and answer over the link.
  FarWakeNotifier? farWake;

  StreamSubscription<CallKitAction>? _callKitSub;

  /// Attaches an iOS CallKit bridge: its actions are routed into the
  /// Hub as `call.*` messages (see [_onCallKitAction]), and the Hub
  /// mirrors call state into it ([onCall], [onEstablished]).
  void attachCallKit(CallKitBridge bridge) {
    _callKitSub?.cancel();
    callKit = bridge;
    _callKitSub = bridge.actions.listen(_onCallKitAction);
  }

  /// Detaches the CallKit bridge; mirrored calls stay as they are
  /// (the native side ends them when its own link drops).
  void detachCallKit() {
    _callKitSub?.cancel();
    _callKitSub = null;
    callKit = null;
  }

  /// A user action in CallKit becomes the `call.*` message the Hub
  /// routes to the phone, as if it had arrived from the iPhone's own
  /// connection — so audio claiming, dry-transport guards and replies
  /// behave exactly like a message from the client UI. `dialFailed`
  /// and unknown kinds have no message and are ignored here (the
  /// dial never reached the phone).
  void _onCallKitAction(CallKitAction action) {
    final message = action.toMessage();
    if (message == null) return;
    final c = conn;
    if (c == null) return; // no link: the action has nowhere to go
    onMessage(c, message);
  }

  /// Detaches CallKit and stops the timers.
  void dispose() {
    detachCallKit();
    stopTimers();
    audio.dispose();
  }

  /// UI refresh callbacks.
  final List<void Function()> _listeners = [];

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) =>
      _listeners.remove(listener);

  void refresh() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  /// Live calls, by id, as last reported by the phone.
  final Map<String, CallInfo> liveCalls = {};

  final Map<int, _PendingSms> _smsRequests = {};

  /// Next SMS local id (monotonic, never reused while the Hub lives).
  int _nextSmsLocalId = 1;
  final Map<String, DateTime> _endedSent = {};
  final Map<LinkConnection, String> _lastStatusSent = {};
  String _lastUnreadKey = '';

  Timer? _statusTimer;
  Timer? _stallTimer;
  Timer? _audioTimer;

  // ------------------------------------------------------------------
  // connection lifecycle

  bool _dry(LinkConnection c) => c.transport.dry || (dryRun && admits(c));

  @override
  bool admits(LinkConnection c) =>
      exclusive == null || exclusive == c.transport;

  /// Clients that get broadcasts.
  List<LinkConnection> targets() => conns
      .where((c) =>
          c.isUp && admits(c) && (onlyKind == null || c.kind == onlyKind))
      .toList();

  void broadcast(Message m) {
    for (final c in targets()) {
      c.send(m);
    }
  }

  void onTransport(Transport transport) {
    AppLogger.i('hub', 'transport ${transport.runtimeType}');
    final connection = connectionFactory(transport);
    connection.start();
  }

  @override
  void onEstablished(LinkConnection c, bool newlyPaired) {
    AppLogger.i(
        'hub', 'session established newlyPaired=$newlyPaired kind=${c.kind}');
    if (!admits(c)) {
      c.close('link reserved by a test');
      return;
    }
    // A client is here: the airplane fail-safe counts from now.
    _lastClientSeen = DateTime.now();
    // The same peer reconnecting replaces its old link; other clients
    // stay. A reconnecting peer keeps its place: its last action, and
    // the call audio if it had it.
    final olds =
        conns.where((o) => o != c && _samePeer(o, c)).toList();
    conns.add(c);
    for (final old in olds) {
      if (old.lastAction.isAfter(c.lastAction)) {
        c.lastAction = old.lastAction;
      }
      audio.handOver(old, c);
      old.close('replaced');
    }
    refresh();
    audio.reconcile(targets(), callWantsAudio: _callWantsAudio());
    onSessionUp?.call(c);
    if (newlyPaired) onPaired?.call(c);
    unawaited(_sendCallList(c));
    unawaited(pushStatus());
    // A reconnected client gets the live call list again, and
    // CallKit is reconciled with it (calls the phone no longer has
    // are ended on the iPhone).
    unawaited(callKit?.reconcile(liveCalls.values.toList()));
  }

  bool _samePeer(LinkConnection a, LinkConnection b) {
    final ka = a.peerKey;
    final kb = b.peerKey;
    if (ka == null || kb == null) return false;
    if (ka.length != kb.length) return false;
    for (var i = 0; i < ka.length; i++) {
      if (ka[i] != kb[i]) return false;
    }
    return true;
  }

  Future<void> _sendCallList(LinkConnection c) async {
    final calls = liveCalls.values.toList();
    c.send(Message(MessageType.callList, b: {
      'calls': calls.map((info) => _callJson(info, c)).toList(),
    }));
  }

  @override
  void onClosed(LinkConnection c) {
    AppLogger.i('hub', 'session closed');
    if (conns.remove(c)) {
      audio.reconcile(targets(), callWantsAudio: _callWantsAudio());
      refresh();
      onSessionDown?.call(c);
      // No clients left: the iPhone cannot be reached over the link
      // any more, so its mirrored CallKit calls end locally (they
      // continue on the Android phone).
      if (targets().isEmpty) {
        unawaited(callKit?.linkLost());
      }
    }
  }

  @override
  void onAudio(LinkConnection c, List<int> payload) {
    unawaited(audio.onUplink(c, payload));
  }

  // ------------------------------------------------------------------
  // timers

  /// Starts the background timers: status + ping every 60 s, stall
  /// check every 5 s. Call once; [stopTimers] undoes it.
  void startTimers() {
    stopTimers();
    _statusTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      unawaited(_watchdog());
    });
    _stallTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _stallCheck();
    });
    // The audio session re-checks every second: the helper may only
    // be ready after a claim, and a retarget must not wait for the
    // next call event.
    _audioTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      audio.reconcile(targets(), callWantsAudio: _callWantsAudio());
    });
  }

  void stopTimers() {
    _statusTimer?.cancel();
    _stallTimer?.cancel();
    _audioTimer?.cancel();
    _disarmAirplaneFailSafe();
    _statusTimer = null;
    _stallTimer = null;
    _audioTimer = null;
  }

  void _stallCheck() {
    for (final c in List.of(conns)) {
      if (c.stalled() > const Duration(seconds: 10)) {
        c.close('stream stalled mid-record');
      }
    }
  }

  Future<void> _watchdog() async {
    await pushStatus();
    for (final c in List.of(conns)) {
      if (c.lastRxAgo > const Duration(minutes: 15)) {
        c.close('no traffic for 15 min');
        continue;
      }
      c.send(Message(MessageType.ping, b: {
        'ts': DateTime.now().millisecondsSinceEpoch,
      }));
    }
  }

  // ------------------------------------------------------------------
  // message routing

  static const _callControls = {
    MessageType.callAnswer,
    MessageType.callTake,
    MessageType.callReject,
    MessageType.callEnd,
    MessageType.callHold,
    MessageType.callDtmf,
    MessageType.selftest,
  };

  @override
  void onMessage(LinkConnection c, Message m) {
    // Any traffic from a client counts as "seen" for the airplane
    // fail-safe.
    _lastClientSeen = DateTime.now();
    // A test client may only touch calls on the test line, never a
    // real call: dry transports get their call controls ignored.
    if (c.transport.dry && _callControls.contains(m.t)) return;
    switch (m.t) {
      case MessageType.ping:
        c.send(Message(MessageType.pong,
            b: {'ts': m.b['ts']}, re: m.id));
      case MessageType.pong:
        break;
      case MessageType.sync:
        final codecs = m.b['codecs'];
        if (codecs is List) {
          c.codecs = codecs.map((e) => e.toString()).toList();
        }
        final client = m.b['client'];
        if (client is Map<String, dynamic>) {
          c.kind = client['kind'] as String? ?? c.kind;
          final name = client['name'] as String?;
          if (name != null) c.name = name.substring(0, name.length > 60 ? 60 : name.length);
          // The iPhone's Bark device key (optional): the Android side
          // uses it to push a wake-up alert when the link is down.
          // Sent again on every sync, so a changed key is picked up.
          final barkKey = client['barkKey'] as String?;
          if (barkKey != null && barkKey.isNotEmpty) {
            c.barkKey = barkKey;
            farWake?.setDeviceKey(barkKey);
          }
          refresh();
        }
        unawaited(sync(
          c,
          smsSince: (m.b['sms'] as num?)?.toInt() ?? 0,
          callsSince: (m.b['calls'] as num?)?.toInt() ?? 0,
          contactsVersion: m.b['contacts'] as String? ?? '',
        ));
      case MessageType.smsSend:
        unawaited(_sendSms(c, m));
      case MessageType.smsRead:
        unawaited(_readSms(c, m));
      case MessageType.smsDelete:
        unawaited(_deleteSms(c, m));
      case MessageType.callsDelete:
        unawaited(_deleteCalls(c, m));
      case MessageType.listsSet:
        unawaited(_setLists(c, m));
      case MessageType.contactAdd:
        unawaited(_addContact(c, m));
      case MessageType.contactUpdate:
        unawaited(_updateContact(c, m));
      case MessageType.contactStar:
        unawaited(_starContact(c, m));
      case MessageType.callAnswer:
        audio.claim(c);
        audio.reconcile(targets(), callWantsAudio: _callWantsAudio());
        unawaited(data.answerCall(m.b['cid'] as String? ?? ''));
      case MessageType.callTake:
        audio.claim(c);
        audio.reconcile(targets(), callWantsAudio: _callWantsAudio());
        _broadcastCalls();
      case MessageType.callReject:
        unawaited(data.rejectCall(m.b['cid'] as String? ?? ''));
      case MessageType.callEnd:
        unawaited(data.endCall(m.b['cid'] as String? ?? ''));
      case MessageType.callHold:
        unawaited(data.holdCall(
            m.b['cid'] as String? ?? '', m.b['on'] as bool? ?? false));
      case MessageType.callMute:
        if (c == audio.target) {
          audio.uplinkMuted = m.b['on'] as bool? ?? false;
        }
      case MessageType.callDtmf:
        final d = m.b['d'] as String?;
        if (d != null && d.isNotEmpty) {
          unawaited(data.dtmf(m.b['cid'] as String? ?? '', d[0]));
        }
      case MessageType.callDial:
        unawaited(_dial(c, m));
      case MessageType.netGet:
      case MessageType.netSet:
        unawaited(_net(c, m));
      case MessageType.selftest:
        unawaited(_selftest(c, m));
      case MessageType.unpair:
        if (!c.transport.dry) {
          final key = c.peerKey;
          if (key != null) data.unpair(key);
          c.close('unpaired by ${c.name}');
          refresh();
        }
      default:
        // Unknown types are ignored.
        break;
    }
  }

  Future<void> _sendSms(LinkConnection c, Message m) async {
    final req = m.id ?? 0;
    // Monotonic, never reused while the Hub lives: the old formula
    // hashed the clock + request id, so two clients sending at the
    // same instant with the same request id collided and the first
    // SMS's result went to the wrong connection.
    final localId = _nextSmsLocalId++;
    _smsRequests[localId] = _PendingSms(c, req, DateTime.now());
    final sub = m.b['sub'] as num?;
    final err = await data.sendSms(
      to: m.b['to'] as String? ?? '',
      body: m.b['body'] as String? ?? '',
      sub: sub?.toInt(),
      localId: localId,
      dry: _dry(c),
    );
    if (err != null || _dry(c)) {
      _smsRequests.remove(localId);
      c.send(Message(MessageType.smsResult,
          b: {
            'ok': err == null,
            'state': err == null ? 'sent' : 'failed',
            'err': ?err,
          },
          re: req));
    }
  }

  /// A send/delivery report for a tracked SMS request.
  void smsResult(int localId, bool ok, String state, String? err) {
    _pruneSmsRequests();
    final pending = _smsRequests[localId];
    if (pending == null) return;
    if (state != 'sent') _smsRequests.remove(localId);
    pending.connection.send(Message(MessageType.smsResult,
        b: {
          'ok': ok,
          'state': state,
          'err': ?err,
        },
        re: pending.requestId));
  }

  void _pruneSmsRequests() {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 10));
    _smsRequests.removeWhere((_, p) => p.at.isBefore(cutoff));
  }

  Future<void> _readSms(LinkConnection c, Message m) async {
    final thread = (m.b['thread'] as num?)?.toInt() ?? -1;
    final upTo = (m.b['upTo'] as num?)?.toInt() ?? -1;
    if (thread < 0 || upTo <= 0) return;
    if (!_dry(c)) await data.markSmsRead(thread, upTo);
    for (final other in targets()) {
      if (other != c) {
        other.send(Message(MessageType.smsRead, b: {
          'thread': thread,
          'upTo': upTo,
        }));
      }
    }
  }

  Future<void> _deleteSms(LinkConnection c, Message m) async {
    final ids = (m.b['ids'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        const <int>[];
    final thread = (m.b['thread'] as num?)?.toInt();
    final gone = _dry(c)
        ? ids
        : await data.deleteSms(ids, thread);
    final ok = gone != null;
    final body = <String, dynamic>{
      'ok': ok,
      'ids': gone ?? const <int>[],
      if (!ok) 'err': 'Android refused the deletion',
      'thread': ?thread,
    };
    c.send(Message(MessageType.smsDeleted, b: body, re: m.id));
    if (ok) {
      for (final other in targets()) {
        if (other != c) other.send(Message(MessageType.smsDeleted, b: body));
      }
    }
  }

  Future<void> _deleteCalls(LinkConnection c, Message m) async {
    final all = m.b['all'] as bool? ?? false;
    final ids = all
        ? null
        : (m.b['ids'] as List?)
                ?.map((e) => (e as num).toInt())
                .toList();
    final n = _dry(c) ? (ids?.length ?? 0) : await data.deleteCalls(ids);
    final ok = n >= 0;
    final body = <String, dynamic>{
      'ok': ok,
      'all': ids == null,
      'ids': ids ?? const <int>[],
      if (!ok) 'err': 'Android refused the deletion',
    };
    c.send(Message(MessageType.callsDeleted, b: body, re: m.id));
    if (ok) {
      for (final other in targets()) {
        if (other != c) {
          other.send(Message(MessageType.callsDeleted, b: body));
        }
      }
    }
  }

  Future<void> _setLists(LinkConnection c, Message m) async {
    final what = m.b['what'] as String? ?? '';
    final body = await data.setLists(
      what,
      num: m.b['num'] as String?,
      thread: (m.b['thread'] as num?)?.toInt(),
      on: m.b['on'] as bool? ?? false,
    );
    c.send(Message(MessageType.lists, b: body, re: m.id));
    for (final other in targets()) {
      if (other != c) other.send(Message(MessageType.lists, b: body));
    }
  }

  Future<void> _addContact(LinkConnection c, Message m) async {
    final phones = (m.b['phones'] as List?)
            ?.map((p) => Phone.fromJson(p as Map<String, dynamic>))
            .toList() ??
        const <Phone>[];
    final emails = (m.b['emails'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];
    final id = _dry(c)
        ? -1
        : await data.addContact(
            m.b['name'] as String? ?? '', phones, emails);
    c.send(Message(MessageType.contactResult,
        b: {'ok': id != -1, 'id': id}, re: m.id));
  }

  Future<void> _updateContact(LinkConnection c, Message m) async {
    final phones = (m.b['phones'] as List?)
            ?.map((p) => Phone.fromJson(p as Map<String, dynamic>))
            .toList() ??
        const <Phone>[];
    final emails = (m.b['emails'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];
    final id = (m.b['id'] as num?)?.toInt() ?? -1;
    final err = _dry(c)
        ? null
        : await data.updateContact(
            id, m.b['name'] as String? ?? '', phones, emails);
    c.send(Message(MessageType.contactResult,
        b: {
          'ok': err == null,
          'id': id,
          'err': ?err,
        },
        re: m.id));
  }

  Future<void> _starContact(LinkConnection c, Message m) async {
    final id = (m.b['id'] as num?)?.toInt() ?? -1;
    final on = m.b['on'] as bool? ?? false;
    // A dry transport simulates the star (rows 0 = no failure);
    // a real one reports the rows changed, -1 when Android refused.
    final rows =
        id >= 0 && !_dry(c) ? await data.setContactStarred(id, on) : 0;
    final ok = id >= 0 && rows >= 0;
    c.send(Message(MessageType.contactResult,
        b: {
          'ok': ok,
          'id': id,
          'err': ?(ok ? null : 'Android refused the change'),
        },
        re: m.id));
  }

  Future<void> _dial(LinkConnection c, Message m) async {
    if (!_dry(c)) {
      audio.claim(c);
      audio.reconcile(targets(), callWantsAudio: _callWantsAudio());
    }
    final sub = m.b['sub'] as num?;
    final err = _dry(c)
        ? null
        : await data.dial(m.b['num'] as String? ?? '', sub?.toInt());
    c.send(Message(MessageType.callDialed,
        b: {
          'ok': err == null,
          'err': ?err,
        },
        re: m.id));
  }

  Future<void> _net(LinkConnection c, Message m) async {
    final isSet = m.t == MessageType.netSet;
    final what = isSet && !c.transport.dry
        ? m.b['what'] as String?
        : null;
    final on = m.b['on'] as bool? ?? false;
    final sub = (m.b['sub'] as num?)?.toInt();
    final slot = (m.b['slot'] as num?)?.toInt();
    final mode = m.b['mode'] as String?;

    // Validation mirrors Tether Hub.kt: only these switches reach
    // the helper, and the two parametrised ones are checked first.
    Map<String, dynamic>? state;
    if (isSet && what != null && !_netSwitches.contains(what)) {
      state = {'err': 'unknown switch'};
    } else if (what == 'dataSub') {
      // Only a currently active SIM may carry mobile data.
      final status = await data.statusJson();
      final sims = status['sims'];
      final known = sims is List &&
          sims.any((e) => e is Map && e['sub'] == sub);
      state = known
          ? await data.netControl(what: what, on: on, sub: sub)
          : {'err': 'unknown SIM'};
    } else if (what == 'rat') {
      final valid = slot != null &&
          slot >= 0 &&
          slot <= 1 &&
          mode != null &&
          _ratModes.contains(mode);
      state = valid
          ? await data.netControl(
              what: what, on: on, slot: slot, mode: mode)
          : {'err': 'unknown network mode'};
    } else if (what == 'share') {
      // The Share-VPN proxy does not exist in this app yet (Tether
      // runs its own proxy on the Android phone): the switch is
      // shown disabled in the UI, and a stray request is refused
      // here instead of reaching the helper.
      state = {'err': 'Share-VPN proxy is not available yet'};
    } else {
      state = await data.netControl(
        what: what,
        on: on,
        sub: sub,
        slot: slot,
        mode: mode,
      );
    }
    if (isSet && what == 'airplane') _armAirplaneFailSafe(on);
    final body = state ?? {'err': 'helper did not answer'};
    c.send(Message(MessageType.netState, b: body, re: m.id));
    if (what == 'share' || what == 'airplane') {
      for (final other in targets()) {
        if (other != c) other.send(Message(MessageType.netState, b: body));
      }
    }
  }

  /// Switches the iPhone may flip (PROTOCOL §7, Tether Hub.kt).
  static const _netSwitches = {
    'data',
    'hotspot',
    'bt',
    'dataSub',
    'share',
    'airplane',
    'rat',
  };

  /// Radio modes the `rat` switch accepts.
  static const _ratModes = {'2G', '3G', '4G', '5G'};

  /// When the iPhone turns airplane mode on, the link dies with it —
  /// so if no client has been seen for [airplaneFailSafeGrace],
  /// turn it back off (Tether Hub.kt `airplaneFailSafe`). The check
  /// stays armed while a client is connected (airplane mode kills
  /// the radios, so that is always transient) and retries until the
  /// helper answers. The armed state is persisted through
  /// [airplaneStore] and re-armed on restart (finding N10, like
  /// Tether's preference); without a store the old in-memory-only
  /// behaviour applies.
  Timer? _airplaneTimer;

  /// Last time any client was seen (establish or any message).
  DateTime _lastClientSeen = DateTime.now();

  void _armAirplaneFailSafe(bool on) {
    _airplaneTimer?.cancel();
    _airplaneTimer = null;
    if (!on) {
      unawaited(_writeAirplaneArmed(false));
      return;
    }
    _airplaneTimer = Timer.periodic(airplaneFailSafeInterval, (_) {
      unawaited(_checkAirplaneFailSafe());
    });
    unawaited(_writeAirplaneArmed(true));
  }

  void _disarmAirplaneFailSafe() {
    _airplaneTimer?.cancel();
    _airplaneTimer = null;
    unawaited(_writeAirplaneArmed(false));
  }

  Future<void> _writeAirplaneArmed(bool armed) async {
    try {
      await airplaneStore?.writeArmed(armed);
    } catch (_) {
      // Persistence is best-effort: the in-memory timer still works.
    }
  }

  /// Re-arms the airplane fail-safe from its persisted state, like
  /// Tether does on restart (finding N10). Call once at startup,
  /// after [startTimers]: if the app was killed while airplane mode
  /// was on, the check runs again instead of being lost with the
  /// old process. The grace still applies from the restart, so the
  /// check waits [airplaneFailSafeGrace] before switching airplane
  /// mode off.
  Future<void> restoreAirplaneFailSafe() async {
    var armed = false;
    try {
      armed = await airplaneStore?.readArmed() ?? false;
    } catch (_) {
      armed = false;
    }
    if (armed) _armAirplaneFailSafe(true);
  }

  Future<void> _checkAirplaneFailSafe() async {
    // A client is still here: the link is alive, nothing to do —
    // but stay armed, the client may drop at any moment (airplane
    // mode kills the radios, so a connected client is always
    // transient here).
    if (targets().isNotEmpty) return;
    if (DateTime.now().difference(_lastClientSeen) <=
        airplaneFailSafeGrace) {
      return;
    }
    final state = await data.netControl(what: 'airplane', on: false);
    if (state != null && state['err'] == null) _disarmAirplaneFailSafe();
  }

  Future<void> _selftest(LinkConnection c, Message m) async {
    final result = await data.selftest();
    c.send(Message(MessageType.selftestResult, b: result, re: m.id));
  }

  // ------------------------------------------------------------------
  // sync

  /// Sends everything the peer is missing since its last sync, then
  /// the ids that still exist and the block / mute lists.
  Future<void> sync(
    LinkConnection c, {
    required int smsSince,
    required int callsSince,
    required String contactsVersion,
  }) async {
    final weight =
        audio.running ? smallPageWeight : pageWeight;
    final sms = await data.smsSince(smsSince);
    final smsPages = paginate(sms, weight, (s) => 120 + s.body.length * 3);
    for (var i = 0; i < smsPages.length; i++) {
      c.send(Message(MessageType.smsBatch, b: {
        'items': smsPages[i].map((s) => s.toJson()).toList(),
        'more': i < smsPages.length - 1,
      }));
    }
    final calls = await data.callsSince(callsSince);
    final callPages = paginate(calls, weight, (_) => 110);
    for (var i = 0; i < callPages.length; i++) {
      c.send(Message(MessageType.callsBatch, b: {
        'items': callPages[i].map((e) => e.toJson()).toList(),
        'more': i < callPages.length - 1,
      }));
    }
    final version = data.contactsVersion();
    if (version != contactsVersion) {
      final contacts = await data.contactsAll();
      final pages = paginate(contacts, weight, (ct) => ct.weight());
      for (var i = 0; i < pages.length; i++) {
        c.send(Message(MessageType.contactsBatch, b: {
          'items': pages[i].map((ct) => ct.toJson()).toList(),
          'more': i < pages.length - 1,
          'version': version,
          'full': true,
        }));
      }
    }
    final smsRanges = idRanges(await data.smsAllIds());
    final callRanges = idRanges(await data.callAllIds());
    const perPage = 1400; // ≤ ~2 × 1400 × 18 bytes even with 8-digit
    // ids: well under the 65,000-byte record cap.
    final total = [
      (smsRanges.length / perPage).ceil(),
      (callRanges.length / perPage).ceil(),
    ].reduce((a, b) => a > b ? a : b).clamp(1, 1 << 30);
    for (var i = 0; i < total; i++) {
      c.send(Message(MessageType.syncIds, b: {
        'sms': smsRanges
            .skip(i * perPage)
            .take(perPage)
            .map((r) => [r[0], r[1]])
            .toList(),
        'calls': callRanges
            .skip(i * perPage)
            .take(perPage)
            .map((r) => [r[0], r[1]])
            .toList(),
        if (total > 1) 'more': i < total - 1,
      }));
    }
    c.send(Message(MessageType.lists, b: await data.listsJson()));
    final unread = await data.unreadSmsIds();
    // Null = the SMS provider could not be read: send nothing.
    // An empty list would tell the iPhone every text is read.
    if (unread != null) {
      c.send(Message(MessageType.smsUnread, b: {
        'ids': unread,
        'all': unread.length < 3000,
      }));
    }
  }

  /// Sends the current status to every connected client, skipping
  /// clients whose document did not change.
  Future<void> pushStatus() async {
    final live = targets();
    if (live.isEmpty) return;
    final base = await data.statusJson();
    for (final c in live) {
      final clients = live
          .map((o) => {
                'name': o.name,
                'kind': o.kind,
                'self': o == c,
                'audio': o == audio.target,
              })
          .toList();
      final body = Map<String, dynamic>.of(base)..['clients'] = clients;
      final key = body.toString();
      if (_lastStatusSent[c] == key) continue;
      _lastStatusSent[c] = key;
      c.send(Message(MessageType.status, b: body));
    }
    _lastStatusSent.removeWhere((c, _) => !live.contains(c));
  }

  // ------------------------------------------------------------------
  // phone-side events

  /// A live call changed state. Call events go out ahead of anything
  /// queued, and every change wakes a suspended peer app.
  void onCall(CallInfo info) {
    AppLogger.i('hub', 'call ${info.state} ${info.num} cid=${info.cid}');
    if (info.state == 'ended') {
      final sent = _endedSent[info.cid];
      if (sent != null &&
          DateTime.now().difference(sent) < const Duration(seconds: 60)) {
        return;
      }
      _endedSent[info.cid] = DateTime.now();
      liveCalls.remove(info.cid);
    } else {
      liveCalls[info.cid] = info;
    }
    // Reconcile AFTER the registry update: for an ended call
    // _callWantsAudio() must see the call gone, or the audio session
    // would keep running on a call that no longer exists.
    audio.reconcile(targets(), callWantsAudio: _callWantsAudio());
    _endedSent.removeWhere((_, t) =>
        DateTime.now().difference(t) > const Duration(seconds: 60));
    for (final c in targets()) {
      c.sendUrgent(Message(MessageType.callState, b: _callJson(info, c)));
      onWake?.call(c);
    }
    // Mirror the call into iOS CallKit (ringing makes the iPhone
    // ring; ended ends the mirrored call).
    unawaited(callKit?.reportCall(info));
    // Far wake-up: a ringing call and no link to the iPhone means the
    // app is asleep and cannot be rung over the link — Bark is the
    // only way to reach it.
    if (info.state == 'ringing' && targets().isEmpty) {
      unawaited(farWake?.notifyIncomingCall(
          cid: info.cid, num: info.num, name: info.name));
    }
    refresh();
  }

  /// A new SMS arrived on the phone: forward it live, unless the
  /// sender is blocked.
  void onSms(Sms sms, {required bool blocked}) {
    if (blocked) return;
    AppLogger.i('hub', 'sms from ${sms.addr} thread=${sms.thread}');
    broadcast(Message(MessageType.smsNew, b: {'item': sms.toJson()}));
    for (final c in targets()) {
      onWake?.call(c);
    }
    // Far wake-up: no link to the iPhone, so forward the SMS as a
    // Bark alert (the text itself shows in the notification).
    if (targets().isEmpty) {
      unawaited(farWake?.notifySms(sms));
    }
  }

  /// The unread-ids set changed: push it when it actually changed.
  void onUnreadChanged(List<int> ids) {
    final key = ids.join(',');
    if (key == _lastUnreadKey) return;
    _lastUnreadKey = key;
    broadcast(Message(MessageType.smsUnread, b: {
      'ids': ids,
      'all': ids.length < 3000,
    }));
  }

  /// Re-sends every call's state (after call audio moved clients).
  void _broadcastCalls() {
    for (final info in liveCalls.values) {
      for (final c in targets()) {
        c.sendUrgent(Message(MessageType.callState, b: _callJson(info, c)));
      }
    }
    // CallKit mirrors the live list again (the `elsewhere` flags may
    // have changed with the audio move).
    unawaited(callKit?.reconcile(liveCalls.values.toList()));
  }

  bool _callWantsAudio() => liveCalls.values.any((info) =>
      info.state == 'ringing' ||
      info.state == 'dialing' ||
      info.state == 'connecting' ||
      info.state == 'active' ||
      info.state == 'holding');

  /// Call info as one client sees it. `elsewhere` = the call's audio
  /// is on another client: this client stops ringing / shows
  /// `on <name>` with a button to move it here.
  Map<String, dynamic> _callJson(CallInfo info, LinkConnection c) {
    final json = info.toJson();
    final owner = audio.owner;
    if (owner != null &&
        owner != c &&
        info.state != 'ringing' &&
        info.state != 'ended') {
      json['elsewhere'] = true;
      json['where'] = owner.name;
    }
    return json;
  }
}
