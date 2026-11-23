/// Platform-channel interfaces for the native bridges.
///
/// MethodChannel / EventChannel definitions ONLY — no native code is
/// written here. The Kotlin (Android) and Swift (iOS) sides implement
/// the methods below with exactly these channel names, method names
/// and argument shapes; the Dart wrappers here are the contract they
/// code against.
///
/// Channels:
/// - `com.simbridge/ble` — BLE peripheral (Android) / central (iOS)
/// - `com.simbridge/telecom` — Android default dialer / InCallService
/// - `com.simbridge/sms` — Android SMS provider
/// - `com.simbridge/audio` — call-audio shell helper (Android)
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../protocol/messages.dart';

// ---------------------------------------------------------------------
// BLE link
// ---------------------------------------------------------------------

/// Events arriving from the native BLE layer.
class BleEvent {
  const BleEvent._(this.kind, {this.bytes, this.address, this.mtu});

  /// `bytes` — a chunk of the record byte stream.
  /// `closed` — the pipe ended (remote close / link loss).
  /// `peerRestart` — the peer started a new session on the same pipe;
  ///   `bytes` holds the first record of the new session.
  /// `mtuChanged` — GATT MTU changed; `mtu` holds the new value.
  /// `connected` / `disconnected` — central-side link state; `address`
  ///   holds the peer.
  final String kind;
  final List<int>? bytes;
  final String? address;
  final int? mtu;

  static BleEvent parse(dynamic event) {
    if (event is Uint8List) {
      return BleEvent._('bytes', bytes: event.toList());
    }
    if (event is List<int>) return BleEvent._('bytes', bytes: event);
    if (event is Map) {
      final map = Map<String, dynamic>.from(event);
      final kind = map['t'] as String? ?? 'bytes';
      final raw = map['bytes'];
      return BleEvent._(
        kind,
        bytes: raw is List ? List<int>.from(raw) : null,
        address: map['address'] as String?,
        mtu: (map['mtu'] as num?)?.toInt(),
      );
    }
    return const BleEvent._('bytes');
  }
}

/// BLE transport, owned by the native side.
///
/// Android (peripheral): advertises the Tether service, accepts an
/// L2CAP channel (primary) or GATT RX/TX characteristics (fallback).
/// iOS (central): scans for the service UUID and connects. Either way
/// the byte stream is the same record stream as [Transport].
class BleLink {
  BleLink({MethodChannel? methodChannel, EventChannel? eventChannel})
      : _methods =
            methodChannel ?? const MethodChannel('com.simbridge/ble'),
        _events =
            eventChannel ?? const EventChannel('com.simbridge/ble/events');

  final MethodChannel _methods;
  final EventChannel _events;

  /// Starts advertising the service (peripheral). Returns true when
  /// the service is up.
  Future<bool> startAdvertising({
    required String serviceUuid,
    required String psm,
  }) async {
    final result = await _methods.invokeMethod<bool>(
      'startAdvertising',
      {'serviceUuid': serviceUuid, 'psm': psm},
    );
    return result ?? false;
  }

  Future<void> stopAdvertising() =>
      _methods.invokeMethod<void>('stopAdvertising');

  /// Connects to a peripheral (central). Resolves when the L2CAP
  /// channel (or GATT fallback) is open; bytes arrive on [events].
  Future<void> connect(String address) =>
      _methods.invokeMethod<void>('connect', {'address': address});

  Future<void> disconnect() => _methods.invokeMethod<void>('disconnect');

  /// Writes record bytes to the peer.
  Future<void> write(List<int> bytes) => _methods.invokeMethod<void>(
      'write', {'bytes': Uint8List.fromList(bytes)});

  /// Sends the 1-byte wake notification right before urgent traffic
  /// (ringing, call end, new SMS); wakes a suspended iOS app.
  Future<void> wake(String address) =>
      _methods.invokeMethod<void>('wake', {'address': address});

  /// Asks the link for high connection priority / 2M PHY while a call
  /// runs (peripheral side).
  Future<void> tune(String address, {required bool high}) =>
      _methods.invokeMethod<void>(
          'tune', {'address': address, 'high': high});

  /// Whether a link to the peer is currently open.
  Future<bool> get isConnected async =>
      (await _methods.invokeMethod<bool>('isConnected')) ?? false;

  /// Whether Bluetooth is currently on (Android only — the iOS
  /// side does not implement it; a call there throws
  /// MissingPluginException, which the setup flow catches).
  Future<bool> get isBluetoothOn async =>
      (await _methods.invokeMethod<bool>('isBluetoothOn')) ?? false;

  /// Opens the system "turn on Bluetooth" dialog (Android only).
  /// Returns whether Bluetooth is on after the user answers.
  Future<bool> requestEnableBluetooth() async =>
      (await _methods.invokeMethod<bool>('requestEnableBluetooth')) ??
      false;

  // ---- LE link management (Android peripheral; see NATIVE_CHANNELS.md) ----

  /// A session is up / ended. While linked, advertising runs at the
  /// slower interval (less radio time taken from call audio).
  Future<void> setLinked(bool on) =>
      _methods.invokeMethod<void>('setLinked', {'on': on});

  /// Re-enables advertising if the stack stopped it by itself (seen
  /// on Samsung). Returns whether advertising is up now.
  Future<bool> ensureAdvertising() async =>
      (await _methods.invokeMethod<bool>('ensureAdvertising')) ?? false;

  /// Holds the LE link to the paired iPhone while a session is up.
  Future<void> holdLe(String address) =>
      _methods.invokeMethod<void>('holdLe', {'address': address});

  /// Releases a held LE link the moment the session ends (a held link
  /// blocks a freshly started app's connect on iOS).
  Future<void> releaseLe(String address) =>
      _methods.invokeMethod<void>('releaseLe', {'address': address});

  /// Brings an LE link up for 3 s, then drops it. A link coming up
  /// completes a suspended/relaunched app's pending connect.
  Future<void> pulseLe(String address) =>
      _methods.invokeMethod<void>('pulseLe', {'address': address});

  /// Drops a stale LE connection so the next pulse can bring a fresh
  /// one up.
  Future<void> closeLeConnection(String address) => _methods
      .invokeMethod<void>('closeLeConnection', {'address': address});

  /// Diagnostics: `{'psm', 'running', 'advertising', 'securityCheck',
  /// 'linkParams'}`.
  Future<Map<String, dynamic>> linkState() async {
    final result = await _methods
        .invokeMethod<Map<dynamic, dynamic>>('linkState');
    if (result == null) return const {};
    return Map<String, dynamic>.from(result);
  }

  Stream<BleEvent> get events =>
      _events.receiveBroadcastStream().map(BleEvent.parse);
}

// ---------------------------------------------------------------------
// Telecom (Android default dialer)
// ---------------------------------------------------------------------

/// The Android dialer bridge: the app must be the default phone app
/// for [TelecomBridge] to see live calls (InCallService).
class TelecomBridge {
  TelecomBridge({MethodChannel? methodChannel, EventChannel? eventChannel})
      : _methods = methodChannel ??
            const MethodChannel('com.simbridge/telecom'),
        _events = eventChannel ??
            const EventChannel('com.simbridge/telecom/events');

  final MethodChannel _methods;
  final EventChannel _events;

  Future<bool> isDefaultDialer() async =>
      (await _methods.invokeMethod<bool>('isDefaultDialer')) ?? false;

  /// Opens the system role request ("Set as default phone app").
  /// Returns true when the user accepted.
  Future<bool> requestDefaultDialer() async =>
      (await _methods.invokeMethod<bool>('requestDefaultDialer')) ?? false;

  Future<List<CallInfo>> liveCalls() async {
    final result =
        await _methods.invokeMethod<List<dynamic>>('liveCalls');
    if (result == null) return const [];
    return result
        .map((e) => CallInfo.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> answerCall(String cid) =>
      _methods.invokeMethod<void>('answerCall', {'cid': cid});

  Future<void> rejectCall(String cid) =>
      _methods.invokeMethod<void>('rejectCall', {'cid': cid});

  Future<void> endCall(String cid) =>
      _methods.invokeMethod<void>('endCall', {'cid': cid});

  Future<void> holdCall(String cid, bool on) =>
      _methods.invokeMethod<void>('holdCall', {'cid': cid, 'on': on});

  /// Mutes the Android phone's own microphone (bridged calls only).
  Future<void> muteCall(bool on) =>
      _methods.invokeMethod<void>('muteCall', {'on': on});

  Future<void> dtmf(String cid, String digit) =>
      _methods.invokeMethod<void>('dtmf', {'cid': cid, 'd': digit});

  /// Dials a number. Returns `{'ok': bool, 'err': String?}`.
  Future<Map<String, dynamic>> dial(String num, {int? sub}) async {
    final result = await _methods.invokeMethod<Map<dynamic, dynamic>>(
      'dial',
      {'num': num, 'sub': ?sub},
    );
    if (result == null) return const {'ok': false};
    return Map<String, dynamic>.from(result);
  }

  /// Live call-state events (`call.state` bodies as [CallInfo]).
  /// Cached: every `receiveBroadcastStream()` call replaces the
  /// channel's message handler, so a second reader would starve
  /// the first — the link service and the model's local mirror
  /// share this one broadcast stream instead.
  late final Stream<CallInfo> callEvents = _events
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from(e as Map))
      .map(CallInfo.fromJson);

  /// Writes the block list the screening service enforces. Call it
  /// whenever the user's block list changes; the `listsJson` /
  /// `setLists` methods on the SMS channel are the source of truth
  /// for the list itself.
  Future<void> setBlockedNumbers(List<String> numbers) => _methods
      .invokeMethod<void>('setBlockedNumbers', {'numbers': numbers});
}

// ---------------------------------------------------------------------
// SMS (Android SMS provider)
// ---------------------------------------------------------------------

/// SMS events arriving from the native side.
class SmsEvent {
  const SmsEvent._(this.kind, {this.sms, this.localId, this.state, this.ok, this.err, this.ids});

  /// `sms.new` — a message arrived; `sms` holds it.
  /// `sms.result` — a send/delivery report; `localId`, `state`
  ///   (`sent` / `delivered` / `failed`), `ok`, `err`.
  /// `sms.readChanged` — read state changed on the phone; `ids` holds
  ///   the unread incoming ids.
  final String kind;
  final Sms? sms;
  final int? localId;
  final String? state;
  final bool? ok;
  final String? err;
  final List<int>? ids;

  static SmsEvent parse(dynamic event) {
    final map = Map<String, dynamic>.from(event);
    final kind = map['t'] as String? ?? '';
    final item = map['item'];
    return SmsEvent._(
      kind,
      sms: item is Map
          ? Sms.fromJson(Map<String, dynamic>.from(item))
          : null,
      localId: (map['localId'] as num?)?.toInt(),
      state: map['state'] as String?,
      ok: map['ok'] as bool?,
      err: map['err'] as String?,
      ids: (map['ids'] as List?)
          ?.map((e) => (e as num).toInt())
          .toList(),
    );
  }
}

/// The Android SMS bridge: sending, read state, deletion, and live
/// delivery of incoming messages.
class SmsBridge {
  SmsBridge({MethodChannel? methodChannel, EventChannel? eventChannel})
      : _methods =
            methodChannel ?? const MethodChannel('com.simbridge/sms'),
        _events =
            eventChannel ?? const EventChannel('com.simbridge/sms/events');

  final MethodChannel _methods;
  final EventChannel _events;

  /// Sends an SMS. Returns `{'ok': bool, 'err': String?}` for the
  /// immediate accept; the sent/delivered report arrives on [events]
  /// as `sms.result` with the same [localId].
  Future<Map<String, dynamic>> sendSms({
    required String to,
    required String body,
    int? sub,
    required int localId,
  }) async {
    final result = await _methods.invokeMethod<Map<dynamic, dynamic>>(
      'sendSms',
      {
        'to': to,
        'body': body,
        'sub': ?sub,
        'localId': localId,
      },
    );
    if (result == null) return const {'ok': false};
    return Map<String, dynamic>.from(result);
  }

  /// Marks a thread read up to a message id. Returns rows changed.
  Future<int> markRead(int thread, int upTo) async =>
      (await _methods.invokeMethod<int>(
          'markRead', {'thread': thread, 'upTo': upTo})) ??
      0;

  /// Deletes messages (or a whole thread). Returns deleted ids, or
  /// `null` when Android refused.
  Future<List<int>?> deleteMessages(List<int> ids, {int? thread}) async {
    final result = await _methods.invokeMethod<List<dynamic>>(
      'deleteMessages',
      {
        'ids': ids,
        'thread': ?thread,
      },
    );
    return result?.map((e) => (e as num).toInt()).toList();
  }

  /// Deletes call-log rows (all when [ids] is `null`). Returns rows
  /// deleted, or -1 when Android refused.
  Future<int> deleteCalls({List<int>? ids}) async =>
      (await _methods.invokeMethod<int>(
          'deleteCalls', {'ids': ids})) ??
      -1;

  Future<bool> isDefaultSmsApp() async =>
      (await _methods.invokeMethod<bool>('isDefaultSmsApp')) ?? false;

  /// Opens the system prompt to become the default SMS app.
  Future<bool> requestDefaultSmsApp() async =>
      (await _methods.invokeMethod<bool>('requestDefaultSmsApp')) ??
      false;

  /// Live SMS events (see [SmsEvent]). Cached, like
  /// [TelecomBridge.callEvents]: every `receiveBroadcastStream()`
  /// call replaces the channel's message handler, so the link
  /// service and the model's local mirror share this one stream.
  late final Stream<SmsEvent> events =
      _events.receiveBroadcastStream().map(SmsEvent.parse);

  // ---- HubData data queries (see NATIVE_CHANNELS.md) ----

  /// Messages with id > [since], oldest first. A full sync
  /// (`since` = 0) returns the newest 5000.
  Future<List<Sms>> smsSince(int since) async {
    final result = await _methods
        .invokeMethod<List<dynamic>>('smsSince', {'since': since});
    if (result == null) return const [];
    return result
        .map((e) => Sms.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Call-log rows with id > [since] (same paging rule, capped
  /// at 1000).
  Future<List<CallEntry>> callsSince(int since) async {
    final result = await _methods
        .invokeMethod<List<dynamic>>('callsSince', {'since': since});
    if (result == null) return const [];
    return result
        .map((e) =>
            CallEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// All contacts (photos: base64 JPEG ≤ 96 px).
  Future<List<Contact>> contactsAll() async {
    final result =
        await _methods.invokeMethod<List<dynamic>>('contactsAll');
    if (result == null) return const [];
    return result
        .map((e) => Contact.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// SHA-1 of raw-contact id:version pairs (16 hex chars); `""`
  /// when contacts are unreadable.
  Future<String> contactsVersion() async =>
      (await _methods.invokeMethod<String>('contactsVersion')) ?? '';

  /// Every SMS id on the phone (ascending, for sync.ids).
  Future<List<int>> smsAllIds() async {
    final result =
        await _methods.invokeMethod<List<dynamic>>('smsAllIds');
    if (result == null) return const [];
    return result.map((e) => (e as num).toInt()).toList();
  }

  /// Every call-log id on the phone (ascending).
  Future<List<int>> callAllIds() async {
    final result =
        await _methods.invokeMethod<List<dynamic>>('callAllIds');
    if (result == null) return const [];
    return result.map((e) => (e as num).toInt()).toList();
  }

  /// Ids of unread incoming texts (newest first, capped at 3000).
  /// Null when the provider cannot be read: the Hub must send no
  /// `sms.unread` at all then (an empty list would mark every text
  /// read on the iPhone).
  Future<List<int>?> unreadSmsIds() async {
    final result =
        await _methods.invokeMethod<List<dynamic>>('unreadSmsIds');
    if (result == null) return null;
    return result.map((e) => (e as num).toInt()).toList();
  }

  /// Phone status document (`device`, `battery`, `charging`,
  /// `sims`, `defaultSub`, `dialer`, `helper`, `wifi`, `adbWifi`).
  Future<Map<String, dynamic>> statusJson() async {
    final result = await _methods
        .invokeMethod<Map<dynamic, dynamic>>('statusJson');
    if (result == null) return const {};
    return Map<String, dynamic>.from(result);
  }

  /// Stars / unstars a contact. Returns rows changed, or -1.
  Future<int> setContactStarred(int id, bool on) async =>
      (await _methods.invokeMethod<int>(
          'setContactStarred', {'id': id, 'on': on})) ??
      -1;

  /// Adds a contact. Returns the new row id, or -1 on failure.
  Future<int> addContact(
      String name, List<Phone> phones, List<String> emails) async =>
      (await _methods.invokeMethod<int>('addContact', {
        'name': name,
        'phones': phones.map((p) => p.toJson()).toList(),
        'emails': emails,
      })) ??
      -1;

  /// Updates a contact. Returns `{'ok', 'err'}`.
  Future<Map<String, dynamic>> updateContact(
      int id, String name, List<Phone> phones, List<String> emails) async {
    final result = await _methods.invokeMethod<Map<dynamic, dynamic>>(
      'updateContact',
      {
        'id': id,
        'name': name,
        'phones': phones.map((p) => p.toJson()).toList(),
        'emails': emails,
      },
    );
    if (result == null) return const {'ok': false};
    return Map<String, dynamic>.from(result);
  }

  /// Block / mute lists: `{'blocked', 'muted', 'system'}`.
  Future<Map<String, dynamic>> listsJson() async {
    final result = await _methods
        .invokeMethod<Map<dynamic, dynamic>>('listsJson');
    if (result == null) return const {};
    return Map<String, dynamic>.from(result);
  }

  /// Block / mute lists. Returns the new lists document plus
  /// `'where'` (`'tether'` on success, `'error: …'` otherwise).
  Future<Map<String, dynamic>> setLists(
    String what, {
    String? num,
    int? thread,
    required bool on,
  }) async {
    final result = await _methods.invokeMethod<Map<dynamic, dynamic>>(
      'setLists',
      {
        'what': what,
        'num': ?num,
        'thread': ?thread,
        'on': on,
      },
    );
    if (result == null) return const {};
    return Map<String, dynamic>.from(result);
  }
}

// ---------------------------------------------------------------------
// Call audio (Android shell helper)
// ---------------------------------------------------------------------

/// The call-audio bridge: the shell helper (uid 2000, started through
/// the phone's own wireless debugging) captures the call downlink and
/// injects the uplink through Android's call-audio interception API.
/// Dart only steers it and moves PCM frames; the helper owns the
/// audio path.
class CallAudioBridge {
  CallAudioBridge({MethodChannel? methodChannel, EventChannel? eventChannel})
      : _methods =
            methodChannel ?? const MethodChannel('com.simbridge/audio'),
        _events =
            eventChannel ?? const EventChannel('com.simbridge/audio/events');

  final MethodChannel _methods;
  final EventChannel _events;

  /// Starts the helper if needed. Returns its state document
  /// (`{state, method?, up, down}`) or `null` when it did not answer.
  Future<Map<String, dynamic>?> ensureHelperRunning() async {
    final result = await _methods
        .invokeMethod<Map<dynamic, dynamic>>('ensureHelperRunning');
    if (result == null) return null;
    return Map<String, dynamic>.from(result);
  }

  /// Probes whether the current call is interceptable, without
  /// starting audio.
  Future<Map<String, dynamic>?> probe() async {
    final result =
        await _methods.invokeMethod<Map<dynamic, dynamic>>('probe');
    if (result == null) return null;
    return Map<String, dynamic>.from(result);
  }

  /// Starts capturing the downlink and injecting the uplink.
  /// `rate` is the sample rate (16000); `method` is the capture
  /// method (`auto` / `intercept` / ...); `inject` the injection
  /// method (`auto` / `intercept` / ...).
  Future<void> startCapture({
    required int rate,
    required String method,
    required String inject,
  }) =>
      _methods.invokeMethod<void>('startCapture',
          {'rate': rate, 'method': method, 'inject': inject});

  Future<void> stopCapture() =>
      _methods.invokeMethod<void>('stopCapture');

  /// Injects one 20 ms uplink PCM frame (16-bit little-endian mono).
  Future<void> injectUplink(List<int> pcm) =>
      _methods.invokeMethod<void>(
          'injectUplink', {'pcm': Uint8List.fromList(pcm)});

  /// Runs the helper self-test (needs an active call for the live
  /// path; up to [timeoutSeconds]). Returns its result document.
  Future<Map<String, dynamic>> selftest({int timeoutSeconds = 40}) async {
    final result = await _methods.invokeMethod<Map<dynamic, dynamic>>(
        'selftest', {'timeout': timeoutSeconds});
    if (result == null) return const {'ok': false};
    return Map<String, dynamic>.from(result);
  }

  /// Downlink PCM frames (16-bit little-endian mono, 20 ms each) from
  /// the helper, to encode and send to the peer.
  Stream<List<int>> get downlink => _events.receiveBroadcastStream().map(
        (e) => e is Uint8List
            ? e.toList()
            : List<int>.from(e as List),
      );

  // ---- extra methods (see NATIVE_CHANNELS.md) ----

  /// Encodes one (or more) 20 ms PCM frame(s) to Opus, via Concentus
  /// on Android. Returns the encoded frames (usually one).
  Future<List<List<int>>> opusEncode(List<int> pcm) async {
    final result = await _methods.invokeMethod<List<dynamic>>(
        'opusEncode', {'pcm': Uint8List.fromList(pcm)});
    if (result == null) return const [];
    return result
        .map((e) => e is Uint8List ? e.toList() : List<int>.from(e as List))
        .toList();
  }

  /// Decodes one Opus frame to PCM bytes (16-bit little-endian mono).
  Future<List<int>> opusDecode(List<int> frame) async {
    final result = await _methods.invokeMethod<Uint8List>(
        'opusDecode', {'frame': Uint8List.fromList(frame)});
    return result?.toList() ?? const [];
  }

  /// Network switches via the helper (`data` / `hotspot` / `bt` /
  /// `dataSub` / `rat`; `null` reads only). Returns the new state
  /// document, or `null` when the helper did not answer.
  Future<Map<String, dynamic>?> netControl({
    String? what,
    bool on = false,
    int? sub,
    int? slot,
    String? mode,
  }) async {
    final result = await _methods.invokeMethod<Map<dynamic, dynamic>>(
      'netControl',
      {
        'what': ?what,
        'on': on,
        'sub': ?sub,
        'slot': ?slot,
        'mode': ?mode,
      },
    );
    if (result == null) return null;
    return Map<String, dynamic>.from(result);
  }

  /// The last known helper state document (used by `statusJson`).
  Future<Map<String, dynamic>?> helperState() async {
    final result = await _methods
        .invokeMethod<Map<dynamic, dynamic>>('helperState');
    if (result == null) return null;
    return Map<String, dynamic>.from(result);
  }

  // ---- one-time Wireless-debugging setup (see NATIVE_CHANNELS.md) ----

  /// Whether adb pairing already succeeded.
  Future<bool> adbPaired() async =>
      (await _methods.invokeMethod<bool>('adbPaired')) ?? false;

  /// Enables Wireless debugging (needs `WRITE_SECURE_SETTINGS`,
  /// granted by `bootstrapAdb` on a later run; the first run needs
  /// the user to toggle it in Settings).
  Future<bool> enableWirelessDebugging() async =>
      (await _methods.invokeMethod<bool>('enableWirelessDebugging')) ??
      false;

  /// Shows the pairing notification; the user opens Settings ›
  /// Wireless debugging › Pair device with pairing code and types
  /// the 6-digit code into the notification.
  Future<void> pairAdb() => _methods.invokeMethod<void>('pairAdb');

  /// Grants the runtime permissions and the `WRITE_SMS` app-op
  /// through adb, and whitelists the app from battery optimisation.
  /// Returns the adb output.
  Future<String> bootstrapAdb() async =>
      (await _methods.invokeMethod<String>('bootstrapAdb')) ?? '';
}
