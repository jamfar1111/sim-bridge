/// iOS CallKit bridge: mirrors the Dart call model into CallKit so the
/// iPhone rings / shows the native call screen, and reports the user's
/// CallKit actions back to Dart.
///
/// MethodChannel / EventChannel definitions ONLY — the Swift side
/// (`ios/Runner/CallKitManager.swift` + `SimBridgePlugins.swift`
/// `CallKitPlugin`) implements the methods below with exactly these
/// channel names, method names and argument shapes; the Dart wrapper
/// here is the contract it codes against.
///
/// iOS only. There is no Android equivalent: on Android the same verbs
/// go through `TelecomBridge` (default dialer / InCallService) and the
/// `HubData` call actions. The events here map onto the same verbs the
/// Hub translates into `call.*` messages ([CallKitAction.toMessage]);
/// the Hub also drives this bridge ([Hub.attachCallKit]): call state
/// is mirrored into CallKit, and `linkLost` ends the mirrored calls
/// when the link drops.
///
/// Audio itself is separate: the iOS audio engine lives on
/// `com.simbridge/audio` with different methods from Android's helper
/// (`audioStart` / `audioStop` / `playFrame` / `setMuted` /
/// `setRingback` / `supportedCodecs`); the engine starts/stops with
/// the CallKit audio session and Dart does not drive it directly.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../protocol/messages.dart';

/// One user action taken in CallKit (native call screen / lock screen /
/// Bluetooth headset), for Dart to send over the link as a `call.*`
/// message.
class CallKitAction {
  const CallKitAction._(this.kind,
      {this.cid, this.num, this.sub, this.on, this.digit, this.err});

  /// `answer` / `end` / `reject` — answer, hang up, reject a ringing
  /// call; `cid` holds the call.
  /// `hold` / `mute` — hold / mic-mute toggle; `on` holds the new
  /// state, `cid` the call (`mute` may arrive without a `cid`).
  /// `dtmf` — one digit; `digit` holds it, `cid` the call.
  /// `dial` — the user dialed from CallKit / the iPhone UI; `num`
  /// (+ `sub` when a SIM was chosen).
  /// `take` — "Move here": move the call's audio to this iPhone.
  /// `dialFailed` — starting the dial failed; `num` + `err`.
  final String kind;
  final String? cid;
  final String? num;
  final int? sub;
  final bool? on;
  final String? digit;
  final String? err;

  /// Translates this action into the `call.*` message the Hub routes
  /// to the phone, or `null` when there is nothing to send:
  /// `dialFailed` means the dial never reached the phone, and
  /// unknown kinds have no message.
  Message? toMessage() {
    switch (kind) {
      case 'answer':
        return Message(MessageType.callAnswer, b: {'cid': ?cid});
      case 'end':
        return Message(MessageType.callEnd, b: {'cid': ?cid});
      case 'reject':
        return Message(MessageType.callReject, b: {'cid': ?cid});
      case 'hold':
        return Message(
            MessageType.callHold, b: {'cid': ?cid, 'on': on ?? false});
      case 'mute':
        // PROTOCOL §5: `call.mute` carries only `on` — the Hub
        // mutes the audio target, not the named call.
        return Message(MessageType.callMute, b: {'on': on ?? false});
      case 'dtmf':
        return Message(
            MessageType.callDtmf, b: {'cid': ?cid, 'd': digit ?? ''});
      case 'dial':
        return Message(
            MessageType.callDial, b: {'num': ?num, 'sub': ?sub});
      case 'take':
        return Message(MessageType.callTake, b: {'cid': ?cid});
      default:
        return null;
    }
  }

  static CallKitAction parse(dynamic event) {
    if (event is! Map) return const CallKitAction._('');
    final map = Map<String, dynamic>.from(event);
    return CallKitAction._(
      map['t'] as String? ?? '',
      cid: map['cid'] as String?,
      num: map['num'] as String?,
      // (The `num` field above shadows the `num` type, so the sub is
      // narrowed with a switch instead of an `as num?` cast.)
      sub: switch (map['sub']) {
        int v => v,
        double v => v.toInt(),
        _ => null,
      },
      on: map['on'] as bool?,
      digit: map['d'] as String?,
      err: map['err'] as String?,
    );
  }
}

/// The iOS CallKit bridge (iOS only).
///
/// Dart reports the call model to CallKit ([reportCall] / [reconcile])
/// and steers it from the Dart UI ([answer] / [end] / [setMuted] /
/// [setHeld] / [dtmf] / [take] / [setSpeaker]); user actions taken in
/// CallKit itself arrive on [actions].
///
/// Actions the manager created itself to mirror something done on the
/// Android phone are not echoed back as events.
class CallKitBridge {
  CallKitBridge({MethodChannel? methodChannel, EventChannel? eventChannel})
      : _methods = methodChannel ??
            const MethodChannel('com.simbridge/callkit'),
        _events = eventChannel ??
            const EventChannel('com.simbridge/callkit/events');

  final MethodChannel _methods;
  final EventChannel _events;

  /// Reports one call to CallKit. Incoming ringing calls are reported
  /// as new incoming calls (this is what makes the iPhone ring);
  /// active/held calls as started calls; ended calls as ended.
  Future<void> reportCall(CallInfo call) =>
      _methods.invokeMethod<void>('reportCall', {'call': call.toJson()});

  /// Reconciles CallKit with the live call list (after a reconnect).
  /// CallKit calls the Android phone no longer has are ended.
  Future<void> reconcile(List<CallInfo> calls) =>
      _methods.invokeMethod<void>(
          'reconcile', {'calls': calls.map((c) => c.toJson()).toList()});

  /// The link is gone: CallKit calls are ended locally (they continue
  /// on the Android phone).
  Future<void> linkLost() => _methods.invokeMethod<void>('linkLost');

  /// The Android phone accepted an outgoing dial started on the
  /// iPhone. Arms a 30 s watchdog that fails the dial if no call is
  /// ever reported.
  Future<void> dialAccepted() =>
      _methods.invokeMethod<void>('dialAccepted');

  /// The Android phone failed an outgoing dial started on the iPhone.
  Future<void> dialFailed(String err) =>
      _methods.invokeMethod<void>('dialFailed', {'err': err});

  /// The user dialed from the iPhone UI.
  Future<void> startOutgoing(String num, {int? sub}) =>
      _methods.invokeMethod<void>(
          'startOutgoing', {'num': num, 'sub': ?sub});

  /// From the Dart UI: answer a call.
  Future<void> answer(String cid) =>
      _methods.invokeMethod<void>('answer', {'cid': cid});

  /// From the Dart UI: hang up a call.
  Future<void> end(String cid) =>
      _methods.invokeMethod<void>('end', {'cid': cid});

  /// From the Dart UI: mute / unmute a call's microphone.
  Future<void> setMuted(String cid, bool on) =>
      _methods.invokeMethod<void>('setMuted', {'cid': cid, 'on': on});

  /// From the Dart UI: hold / resume a call.
  Future<void> setHeld(String cid, bool on) =>
      _methods.invokeMethod<void>('setHeld', {'cid': cid, 'on': on});

  /// From the Dart UI: send one DTMF digit.
  Future<void> dtmf(String cid, String digit) =>
      _methods.invokeMethod<void>('dtmf', {'cid': cid, 'd': digit});

  /// "Move here": the call's audio is on another client (`elsewhere`);
  /// asks the Android phone to move it to this iPhone.
  Future<void> take(String cid) =>
      _methods.invokeMethod<void>('take', {'cid': cid});

  /// Speaker override.
  Future<void> setSpeaker(bool on) =>
      _methods.invokeMethod<void>('setSpeaker', {'on': on});

  /// User actions taken in CallKit, for Dart to send over the link as
  /// `call.*` messages. Actions the manager created itself to mirror
  /// something done on the Android phone are not echoed back.
  Stream<CallKitAction> get actions =>
      _events.receiveBroadcastStream().map(CallKitAction.parse);
}
