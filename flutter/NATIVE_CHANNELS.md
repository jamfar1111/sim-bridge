# Native channels — contract for the Dart side

The Dart wrappers in `lib/src/link/channels.dart` (`BleLink`, `TelecomBridge`,
`SmsBridge`, `CallAudioBridge`) are the contract for the four Android channels.
This file documents everything **beyond** that contract: the extra methods the
native side implements for `HubData` (`lib/src/link/hub.dart`), the iOS-only
CallKit channel, the iOS audio channel (which differs from Android's), and the
setup flows the UI must drive.

The Dart side that implements against this file (no "UI agent" owns it —
the classes below do):
- `ChannelHubData` (`lib/src/link/hub_data.dart`) implements `HubData`
  over the channels.
- `AndroidLinkService` (`lib/src/link/link_service.dart`) owns the Hub,
  the BLE peripheral and the LE lifecycle on Android.
- `LinkClient` (`lib/src/link/client.dart`) is the iPhone side of the
  link; `AppModel` (`lib/src/ui/app_model.dart`) is its `ClientStore`.
- `AudioSession` (`lib/src/link/audio_session.dart`) drives call audio
  on the Hub side; `KeyStore` (`lib/src/link/key_store.dart`) holds the
  pairing keys; `BleTransport` (`lib/src/link/ble_transport.dart`) is a
  transport over `BleLink`.
- The iOS wrappers live with the link layer, not in `channels.dart`:
  `CallKitBridge` (`lib/src/link/callkit.dart`) and `IosAudioBridge`
  (`lib/src/link/ios_audio.dart`).

Do not change the native method names without updating the Dart side.

All method arguments and results use the standard message codec. `Long` ids
from Kotlin arrive in Dart as `int`; Dart `int` arrives in Kotlin as
`Long`/`Integer` — native code reads them as `Number` and converts.

## `com.simbridge/ble` — BLE link (Android peripheral / iOS central)

Contract methods (see `channels.dart` `BleLink`): `startAdvertising`
`{serviceUuid, psm}` → bool, `stopAdvertising`, `connect` `{address}`,
`disconnect`, `write` `{bytes}`, `wake` `{address}`, `tune`
`{address, high}`, `isConnected` `{address?}` → bool, `isBluetoothOn`
→ bool, `requestEnableBluetooth` → bool (opens the system "turn on
Bluetooth" dialog; completes with whether Bluetooth is on after the
user answers).

Events (`com.simbridge/ble/events`, `BleEvent.parse`):
- raw bytes (`Uint8List`) — a chunk of the record byte stream.
- `{'t': 'closed', 'address': …}` — the pipe ended.
- `{'t': 'peerRestart', 'address': …, 'bytes': …}` — the peer started a new
  session on a *new* channel while one is up; `bytes` is its first record.
  (A HELLO on the *same* pipe is caught by the link layer instead —
  `LinkConnection.onPeerRestart` — and replayed the same way.)
- `{'t': 'mtuChanged', 'address': …, 'mtu': …}` — Android only (GATT MTU).
- `{'t': 'connected' | 'disconnected', 'address': …}` — link state.

Platform notes:
- Android is the **peripheral**: `startAdvertising` starts the GATT server +
  L2CAP listener + advertising set. The `psm` argument is informational —
  Android assigns the PSM when the listener opens and publishes it in the
  PSM characteristic. `connect` is unsupported on Android (the central
  connects to us) and returns an error.
- iOS is the **central**: `startAdvertising` is a no-op returning `true`;
  `connect` takes the peripheral's identifier (UUID string) or `""` to scan
  for the service. The result completes when the L2CAP channel (or GATT
  fallback) opens, or errors after 20 s. The Dart client uses `""` (scan)
  today; the identifier is not persisted by Dart yet. `wake` and `tune`
  are no-ops on iOS (wake notifications flow peripheral → central; iOS
  manages connection parameters itself).

Extra methods (Android only; the Dart side drives them from the link state):
- `setLinked` `{on}` — a session is up / ended. While linked, advertising
  runs at the slower interval (less radio time taken from call audio).
- `ensureAdvertising` → bool — re-enables advertising if the stack stopped
  it by itself (seen on Samsung). Call it on a timer (every ~10 s).
- `holdLe` `{address}` / `releaseLe` `{address}` — hold the LE link to the
  paired iPhone while a session is up; release it the moment the session
  ends (a held link blocks a freshly started app's connect on iOS).
- `pulseLe` `{address}` — paired, no session: bring an LE link up for 3 s,
  then drop it. A link coming up completes a suspended/relaunched app's
  pending connect.
- `closeLeConnection` `{address}` — drop a stale LE connection so the next
  pulse can bring a fresh one up.
- `linkState` → `{'psm', 'running', 'advertising', 'securityCheck',
  'linkParams'}` — diagnostics. `securityCheck` must be `"ok"` (nothing in
  the GATT service asks for link encryption).

## `com.simbridge/telecom` — Android default dialer

Contract methods (see `channels.dart` `TelecomBridge`): `isDefaultDialer`,
`requestDefaultDialer` (opens the system role prompt; completes with whether
the user accepted), `liveCalls` → list of `CallInfo` maps, `answerCall`
`{cid}`, `rejectCall` `{cid}`, `endCall` `{cid}`, `holdCall` `{cid, on}`,
`muteCall` `{on}`, `dtmf` `{cid, d}`, `dial` `{num, sub?}` →
`{'ok', 'err'}`.

Events (`com.simbridge/telecom/events`): one `CallInfo` map per call-state
change (same shape as `CallInfo.fromJson`).

Extra method:
- `setBlockedNumbers` `{numbers}` — writes the block list the screening
  service enforces (SharedPreferences `sim_bridge` / `blocked_numbers`).
  Call it whenever the user's block list changes; the `listsJson`/`setLists`
  methods on the SMS channel (below) are the source of truth for the list
  itself.

Call ids (`cid`) are short random ids minted by `CallRegistry` per live
call. A `cid` from a client that the app never knew (e.g. the app restarted
mid-call) falls back to the only live call, if there is exactly one.

## `com.simbridge/sms` — Android SMS provider (+ HubData data queries)

Contract methods (see `channels.dart` `SmsBridge`): `sendSms`
`{to, body, sub?, localId}` → `{'ok', 'err'}` (the sent/delivered report
arrives later as an event with the same `localId`), `markRead`
`{thread, upTo}` → rows changed, `deleteMessages` `{ids, thread?}` →
deleted ids or `null` when Android refused, `deleteCalls` `{ids?}` → rows
deleted or `-1`, `isDefaultSmsApp`, `requestDefaultSmsApp` (system role
prompt; completes with whether the user accepted).

Events (`com.simbridge/sms/events`, `SmsEvent.parse`):
- `{'t': 'sms.new', 'item': Sms}` — a message arrived (broadcast + provider
  observer; the observer also fires for read-flag changes, which are
  filtered by id).
- `{'t': 'sms.result', 'localId': …, 'state': 'sent'|'delivered'|'failed',
  'ok': …, 'err': …}` — send/delivery report for a sent SMS.
- `{'t': 'sms.readChanged', 'ids': […]}` — read flags changed; `ids` are the
  unread incoming ids. `null` from the provider means "unknown": the event
  is not sent at all (an empty list would mark every text read).

Writes (mark read / delete) need the `WRITE_SMS` app-op when the app is
**not** the default SMS app; without it they return `-1` / `null`. Grant it
once through adb after pairing Wireless debugging (see "Helper setup" below,
`bootstrapAdb` grants it along with the other permissions).

Extra methods — the `HubData` data queries (`ChannelHubData` in
`lib/src/link/hub_data.dart` calls these; the call actions of `HubData` —
answer/reject/end/hold/dial/dtmf — go through the telecom channel above):
- `smsSince` `{since}` → list of `Sms` maps (id > since, oldest first; a
  full sync `since = 0` returns the newest 5000).
- `callsSince` `{since}` → list of `CallEntry` maps (same paging rule,
  capped at 1000).
- `contactsAll` → list of `Contact` maps (photos: base64 JPEG ≤ 96 px).
- `contactsVersion` → String (SHA-1 of raw-contact id:version pairs, 16 hex
  chars; `""` when contacts are unreadable).
- `smsAllIds` → list of ids (ascending). `callAllIds` → same for the call log.
- `unreadSmsIds` → list of unread incoming ids (newest first, capped 3000).
- `statusJson` → `{'device', 'battery', 'charging', 'sims': [{sub, slot,
  name, carrier, num}], 'defaultSub'?, 'dialer', 'helper': {state, method?,
  up, down}, 'wifi', 'adbWifi'}`.
- `setContactStarred` `{id, on}` → rows changed or `-1`.
- `addContact` `{name, phones: [{n, type, label?}], emails}` → new contact
  id or `-1`.
- `updateContact` `{id, name, phones, emails}` → `{'ok', 'err'}`.
- `listsJson` → `{'blocked': [numbers], 'muted': [thread ids], 'system':
  false}`.
- `setLists` `{what: 'block'|'mute', num?, thread?, on}` → the new lists
  document plus `'where'` (`'tether'` on success, `'error: …'` otherwise).
  Blocking a number also writes it to the screening service's list (see the
  telecom channel's `setBlockedNumbers`).

`HubData.unpair` has **no** native method: pairing keys live in Dart
(`KeyStore` in `lib/src/link/key_store.dart`); the Dart side forgets the
peer key itself. `HubData.netControl` and `HubData.selftest` live on the
audio channel (below).

## `com.simbridge/audio` — call audio

### Android (shell helper)

The helper (uid 2000, `com.simbridge.helper.HelperMain`) is started through
the phone's own Wireless debugging; the app talks to it over a
`127.0.0.1` socket with a mutual HMAC challenge-response (protocol §6, same
as Tether). Contract methods (see `channels.dart` `CallAudioBridge`):
`ensureHelperRunning` → state document or `null`, `probe` → document or
`null`, `startCapture` `{rate, method, inject}` (also starts the
`AudioForegroundService` while audio is bridged), `stopCapture`,
`injectUplink` `{pcm}` (20 ms 16-bit LE mono), `selftest` `{timeout}` →
result document.

Events (`com.simbridge/audio/events`): downlink PCM frames (16-bit LE mono,
20 ms each) as byte arrays.

Extra methods:
- `opusEncode` `{pcm}` → list of encoded frames (bytes) — the Dart side has
  no Opus implementation; the native side uses Concentus (pure-Java libopus).
  `opusDecode` `{frame}` → PCM bytes. Encode and decode run on a background
  thread; results arrive on the platform thread.
- `netControl` `{what, on?, sub?, slot?, mode?}` → state document or `null`
  (`HubData.netControl`). `what`: `data` | `hotspot` | `bt` | `dataSub` |
  `rat` | `null` (read only). Needs the helper running.
- `helperState` → the last known helper state document (used by
  `statusJson`).
- Setup (one-time Wireless-debugging flow; the UI must drive it):
  - `adbPaired` → bool (whether pairing already succeeded).
  - `enableWirelessDebugging` → bool (needs `WRITE_SECURE_SETTINGS`,
    granted by `bootstrapAdb` on a later run; the first run needs the user
    to toggle it in Settings › Developer options › Wireless debugging).
  - `pairAdb` — shows the pairing notification; the user opens Settings ›
    Wireless debugging › Pair device with pairing code and types the 6-digit
    code into the notification. Pairing succeeds → the receiver runs
    `bootstrapAdb` and kicks the helper.
  - `bootstrapAdb` → output string — grants the runtime permissions and the
    `WRITE_SMS` app-op through adb, and whitelists the app from battery
    optimisation. Run it after pairing, and again if a write starts being
    refused.

### iOS (AVAudioEngine)

The Dart wrapper is `IosAudioBridge` (`lib/src/link/ios_audio.dart`);
`IosClientAudioSink` (`lib/src/link/client.dart`) adapts it to the
client's audio sink. The iOS audio channel has **different methods**
from Android's (no helper):
- `audioStart` `{codec: 'opus'|'pcmu', rate, bitrate?}` — selects the codec
  for the call. Call it when the audio-start handshake arrives (Dart knows
  the codec from the peer).
- `audioStop` — stops the engine.
- `playFrame` `{codec, seq, payload}` — decodes a received audio frame and
  queues it in the playout buffer.
- `setMuted` `{on}` / `setRingback` `{on}` — mic mute / local ringback
  (the engine plays a 425 Hz ringback while dialing until the far end is
  heard).
- `supportedCodecs` → `['opus', 'pcmu']` (or `['pcmu']` if AudioToolbox
  Opus is unavailable on the device).
- `opusEncode` `{pcm}` → one encoded frame (bytes); `opusDecode` `{frame}`
  → PCM bytes. Same purpose as on Android (Dart has no Opus).

Events (`com.simbridge/audio/events`): `{'t': 'captured', 'codec', 'seq',
'payload'}` — an encoded 20 ms mic frame, for Dart to send as an audio
record. The engine itself starts/stops with the CallKit audio session
(`CallKitManager` drives `sessionActivated`/`sessionDeactivated`); Dart
does not start the engine directly.

## `com.simbridge/callkit` — iOS only

CallKit mirroring of the Dart call model. The Dart wrapper is
`CallKitBridge` (`lib/src/link/callkit.dart`); the Hub drives it on
the Android side (`Hub.attachCallKit`) and the `LinkClient` on the
iPhone side (`LinkClient.attachCallKit`).

Methods (Dart → native):
- `reportCall` `{call}` — a `CallInfo` map (same shape as the Android
  `CallInfo`). Drives CallKit: incoming ringing calls are reported as new
  incoming calls (this is what makes the iPhone ring); active/held calls
  are reported as started calls; ended calls are reported ended.
- `reconcile` `{calls}` — list of live `CallInfo` maps (after a reconnect);
  CallKit calls the Android phone no longer has are ended.
- `linkLost` — the link is gone: CallKit calls are ended locally (they
  continue on the Android phone).
- `dialAccepted` / `dialFailed` `{err}` — the Android phone accepted (or
  failed) an outgoing dial started on the iPhone; `dialAccepted` arms a
  30 s watchdog that fails the dial if no call is ever reported.
- `startOutgoing` `{num, sub?}` — the user dialed from the iPhone UI.
- `answer` `{cid}` / `end` `{cid}` — from the Dart UI.
- `setMuted` `{cid, on}` / `setHeld` `{cid, on}` / `dtmf` `{cid, d}` — from
  the Dart UI.
- `take` `{cid}` — "Move here": the call's audio is on another client
  (`elsewhere`); asks the Android phone to move it to this iPhone.
- `setSpeaker` `{on}` — speaker override.

Events (`com.simbridge/callkit/events`) — user actions in CallKit, for Dart
to send over the link as `call.*` messages (the Dart `Hub` translates
them; `HubData` call actions cover the same verbs for the Android side):
- `{'t': 'answer'|'end'|'reject', 'cid': …}` — answer / hang up / reject
  (a ringing call that is ended reports `'reject'`, otherwise `'end'`).
- `{'t': 'hold'|'mute', 'cid': …, 'on': …}`
- `{'t': 'dtmf', 'cid': …, 'd': …}` — one event per digit.
- `{'t': 'dial', 'num': …, 'sub'?}` — the user dialed from CallKit/the
  iPhone UI; Dart sends `call.dial`.
- `{'t': 'take', 'cid': …}` — "Move here"; Dart sends `call.take`.
- `{'t': 'dialFailed', 'num': …, 'err': …}` — the start action failed.

Actions the manager created itself to mirror something done on the Android
phone are **not** echoed back as events.

## `com.simbridge/log` — Android only

Downloads mirror for the crash log, so the user can reach
`sim_bridge.log` without the Files app's Android/data folder
(Android 13+ refuses to show Android/data on-device) and without
opening the app (which may crash on launch). The Kotlin side is
`LogMirror` / `LogMirrorPlugin`
(`android/app/src/main/kotlin/com/simbridge/sim_bridge/LogMirror.kt`);
the Dart side is `AppLogger.mirrorToDownloads`
(`lib/src/log/app_log.dart`).

Method (Dart → native):
- `mirrorLog` (no arguments) → `bool`: copies
  `<external files dir>/sim_bridge.log` to Files → Downloads as
  `sim_bridge.log` (MediaStore, `text/plain`, `Download/`), replacing
  any previous copy with the same name. Returns `false` when there
  is no log yet or the MediaStore write failed. Never throws.

Mirror triggers:
- `AppLogger.init` (previous run's log, at startup).
- Every Dart error-level log line (throttled: at most once per 5 s;
  the manual button ignores the throttle).
- `SimBridgeApplication.onCreate` (Kotlin, previous run's log).
- `SimBridgeCrashHandler.uncaughtException` (Kotlin, right after the
  FATAL line is written — the app is dying, so the copy happens
  immediately).

## Entitlements (iOS)

`ios/Runner/Runner.entitlements` exists but is **not** wired into the build
(no `CODE_SIGN_ENTITLEMENTS` setting) — enabling it needs a **paid** Apple
Developer account:
- `com.apple.developer.pushkit.unrestricted-voip` — VoIP push (PushKit)
  that wakes the app for an incoming call while it is closed.
- `com.apple.developer.usernotifications.communication` — communication
  notifications.

Without a paid account, far-apart calls only ring while the app is open;
the free path uses Bark push as a fallback (the user taps the alert, the
app opens, and the still-ringing call is answered over the link).

## What was NOT verified

Nothing native was compiled here: Kotlin cannot be compiled on this VM
(Gradle/Java loopback is blocked by the sandbox) and Swift cannot be
compiled here (no Xcode/macOS). Everything below must be verified by
CI/local build once the sandbox allows:
- All Kotlin files compile (including the copied helper/adb/codec files and
  the new Gradle dependencies: concentus 1.0.2, libadb-android 3.1.1,
  conscrypt-android 2.5.3, bcpkix-jdk15to18 1.81).
- The `BluetoothGattServer.setPreferredPhy` call and the hidden
  `onConnectionUpdated` callback behave as in Tether (both are taken from
  Tether's code, which builds against the same SDK).
- All Swift files compile (including the `project.pbxproj` edits adding the
  five new Swift files to the Runner target) and the app signs with a free
  Apple ID (entitlements **not** enabled).
- The `CBCentralManager` state-restoration identifier works on a real
  device (it needs the `bluetooth-central` background mode, set in
  Info.plist).
- The helper launch command (`app_process` with the APK classpath) works
  from this Flutter app's APK (Tether launches it the same way from its own
  APK).
- End-to-end: BLE L2CAP/GATT byte stream, CallKit incoming call, Opus
  audio both ways, SMS send/receive, and the Wireless-debugging pairing
  flow on real phones.

## File map

Android (`android/app/src/main/kotlin/com/simbridge/`):
- `sim_bridge/BlePeripheral.kt`, `BlePlugin.kt` — BLE peripheral + channel.
- `sim_bridge/CallRegistry.kt`, `TelecomPlugin.kt`,
  `SimBridgeScreeningService.kt` — dialer + channel.
- `sim_bridge/SmsRepo.kt`, `SmsPlugin.kt`, `ContactsRepo.kt`, `SimRepo.kt`
  — SMS/contacts/call-log/SIMs/lists + channel.
- `sim_bridge/CallAudioPlugin.kt`, `HelperBridge.kt`, `Codecs.kt`,
  `G711.kt`, `Adb.kt` — audio/helper/Opus/adb + channel.
- `helper/HelperMain.kt`, `CallAudio.kt`, `Net.kt`, `ShellEnv.kt` — the
  shell helper (runs as uid 2000; copied from Tether, package renamed).
- `sim_bridge/MainActivity.kt` — registers the four plugins.
- `AndroidManifest.xml`, `app/build.gradle.kts` — permissions, services,
  receivers, dependencies.

iOS (`ios/Runner/`):
- `BleCentral.swift`, `SimBridgePlugins.swift` (`BlePlugin`) — BLE central
  + channel.
- `CallKitManager.swift`, `SimBridgePlugins.swift` (`CallKitPlugin`) —
  CallKit + channel.
- `CallAudioEngine.swift`, `Playout.swift`,
  `SimBridgePlugins.swift` (`AudioPlugin`) — audio engine + channel.
- `AppDelegate.swift` — registers the three plugins.
- `Info.plist` — background modes + usage descriptions.
- `Runner.entitlements` — paid-only entitlements (not wired in).
- `Runner.xcodeproj/project.pbxproj` — the five new Swift files added to
  the Runner target.
