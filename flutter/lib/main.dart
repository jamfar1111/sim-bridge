import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:material_ui/material_ui.dart';

import 'src/bark/bark.dart';
import 'src/link/link.dart';
import 'src/log/log.dart';
import 'src/setup/setup.dart';
import 'src/ui/ui.dart';

/// App version, for the first log line (kept in sync with
/// pubspec.yaml).
const String kAppVersion = '1.0.0+1';

/// Real wiring, per platform. Demo mode is only the fallback when
/// setup fails (with a visible error), so the app still opens.
///
/// iOS: the [LinkClient] over BLE (the Swift side scans for the
/// Android peripheral, or reconnects to the known one, when the
/// address is empty), CallKit, the iOS audio engine, and the
/// persisted pairing (KeyStore) + Bark key (secure storage).
///
/// Android: the [AndroidLinkService] (Hub over the platform
/// channels + BLE peripheral) and the pairing QR it opens.
///
/// Anything else (macOS / Windows / web): a real, empty model with
/// no link — the UI shows the unpaired state.
///
/// Crash diagnostics: the file logger starts FIRST, before any
/// wiring, so a crash during startup is still recorded in
/// `sim_bridge.log` (the same file the Kotlin uncaught-exception
/// handler writes to). Flutter errors, uncaught async errors and
/// zone errors are all logged there.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.init();
  AppLogger.i('app', 'start sim_bridge $kAppVersion '
      'platform=$defaultTargetPlatform');
  FlutterError.onError = (details) {
    AppLogger.e('flutter',
        '${details.exception}\n${details.stack ?? ''}');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.e('uncaught', '$error\n$stack');
    return true;
  };
  await runZonedGuarded(_run, (error, stack) {
    AppLogger.e('zone', '$error\n$stack');
  });
}

Future<void> _run() async {
  AppModel model;
  try {
    model = AppModel.real();
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        AppLogger.i('app', 'wiring iOS client');
        await _wireIOS(model);
        AppLogger.i('app', 'iOS client wired');
      case TargetPlatform.android:
        AppLogger.i('app', 'wiring Android link service');
        await _wireAndroid(model);
        AppLogger.i('app', 'Android link service wired');
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        AppLogger.i('app', 'no link on $defaultTargetPlatform');
        break;
    }
  } catch (e, s) {
    // Real wiring failed: fall back to demo so the app still opens,
    // with a visible error explaining why.
    AppLogger.e('app', 'wiring failed, demo fallback: $e\n$s');
    model = AppModel.demo();
    model.fail('راه‌اندازی پیوند ناموفق بود؛ حالت نمایشی فعال شد.');
  }
  runApp(SimBridgeApp(model: model));
  // Deep links (`simbridge://call?cid=…` / `simbridge://sms?thread=…`
  // from a tapped Bark alert): route them to the call screen / thread.
  unawaited(DeepLinkHandler(model).start());
}

Future<void> _wireIOS(AppModel model) async {
  final keyStore = KeyStore();
  await keyStore.init();
  final ble = BleLink();
  final audioSink = IosClientAudioSink(IosAudioBridge());
  final callKit = CallKitBridge();
  final client = LinkClient(
    transportFactory: () => _iosTransportFactory(model, ble, keyStore),
    ownKey: keyStore.ownKey,
    audioSink: audioSink,
    clientName: 'iPhone',
  );
  // The transport switch (BLE ↔ WebRTC) swaps the client's factory
  // and restarts the reconnect loop (finding 7).
  model.onTransportModeChanged = (_) {
    client.useTransportFactory(
        () => _iosTransportFactory(model, ble, keyStore));
  };
  // This iPhone's Bark device key, for the `sync` client object
  // (the Android side pushes a wake-up alert to it when the link
  // is down). The key is created by the Bark setup flow, not here:
  // without one the client just sends no key. The key store is
  // attached to the model so the Link tab can save it (finding N1).
  client.onPaired = () {
    final key = client.peerStaticKey;
    if (key != null) {
      unawaited(
          keyStore.savePeer(key, client.peerName ?? 'Android'));
    }
    // The pairing token seeds the signalling HMAC key (finding N6);
    // it is read here, before the client clears it.
    final token = client.pairToken;
    if (token != null) {
      unawaited(keyStore.saveSignallingKey(token));
    }
    model.setPaired(client.peerName ?? 'Android');
  };
  client.onUnpaired = () {
    unawaited(keyStore.clearPeer());
    model.setUnpaired();
  };
  model.attachClient(client, callKit: callKit);
  // The Bark device key, for the `sync` client object (finding N1):
  // loaded from secure storage if the user set it up in the Link
  // tab; without one the client just sends no key.
  await model.attachBarkKeyStore(SecureBarkKeyStore());
  // WebRTC settings (finding N3): the persisted Worker URL and
  // TURN credentials, so far mode works without editing source.
  await model.attachWebrtcSettingsStore(
      SharedPrefsWebrtcSettingsStore());
  final peer = keyStore.peer;
  if (peer != null) {
    client.loadPaired(peer.key);
    model.setPaired(peer.name);
  }
  client.start();
}

/// Creates the iPhone-side transport for the current mode
/// (finding 7): BLE nearby, WebRTC + Cloudflare TURN far away. The
/// WebRTC room is the paired peripheral's key hash, so both phones
/// derive it. Throws when far mode is selected but the signalling
/// server is not configured yet — the reconnect loop retries with
/// backoff, and the Link tab says the server is missing.
Future<Transport> _iosTransportFactory(
    AppModel model, BleLink ble, KeyStore keyStore) async {
  if (model.transportMode == 'webrtc') {
    if (!WebrtcSettings.isConfigured) {
      throw StateError('WebRTC signalling is not configured yet');
    }
    final peer = keyStore.peer;
    if (peer == null) throw StateError('not paired');
    final room = webrtcRoomId(peer.key);
    return WebrtcTransport.connect(
      room: room,
      signalling: HttpSignalling(
        Uri.parse(WebrtcSettings.signallingUrl),
        room: room,
        // Signalling is HMAC-authenticated once a pairing exists
        // (finding N6); before the first pairing this is null and
        // messages go unsigned.
        authKey: keyStore.signallingKey,
      ),
      config: WebrtcSettings.config,
    );
  }
  // Empty address: the Swift side scans for the Android peripheral
  // (service UUID) or reconnects to the known one.
  await ble.connect('');
  return BleTransport(ble, disconnectOnClose: true);
}

Future<void> _wireAndroid(AppModel model) async {
  final keyStore = KeyStore();
  // Far wake-up: Bark pushes to the iPhone when a call or SMS
  // arrives while the link is down. The device key arrives over
  // the link (the iPhone sends its `barkKey` in `sync`); the
  // server is the default Bark server until the user configures
  // their own.
  final farWake = FarWakeNotifier(
    keyStore: SecureBarkKeyStore(),
  );
  await farWake.loadStoredKey();
  final service = AndroidLinkService(
    ble: BleLink(),
    sms: SmsBridge(),
    telecom: TelecomBridge(),
    audio: CallAudioBridge(),
    keyStore: keyStore,
    farWake: farWake,
  );
  // First-launch setup (2026-11-23: the app never asked for any
  // permission and never turned Bluetooth on, because that code
  // did not exist): permissions, Bluetooth on, dialer role,
  // battery exemption — BEFORE the link starts advertising, which
  // needs the Bluetooth permissions. Runs once, ever: the flag is
  // persisted, and the Link tab's setup card stays available for
  // manual re-runs. A failing step is logged, never fatal: wiring
  // continues and the card shows what is still missing.
  final setup = AndroidSetup(
    ble: service.ble,
    telecom: service.telecom,
    permissions: PermissionHandlerPermissions(),
    flagStore: SharedPrefsSetupFlagStore(),
  );
  model.attachSetup(setup);
  if (await setup.shouldAutoRun()) {
    try {
      AppLogger.i('app', 'first launch: running setup flow');
      await setup.runFullFlow();
    } catch (e, s) {
      AppLogger.w('app', 'setup flow failed, continuing: $e\n$s');
    } finally {
      await setup.markAutoRunComplete();
    }
  }
  await service.start();
  model.attachLinkService(service);
  // WebRTC settings (finding N3): the persisted Worker URL and
  // TURN credentials, so far mode works without editing source.
  // Non-critical: the link above is already up, so a failure here
  // (e.g. the settings store throwing) must not drop the app into
  // demo mode — far mode just reports "not configured" until the
  // user saves the settings. (2026-11-23: a missing package:jni
  // class made this step throw and killed the whole wiring even
  // though the link service had started fine.)
  try {
    await model.attachWebrtcSettingsStore(
        SharedPrefsWebrtcSettingsStore());
  } catch (e, s) {
    AppLogger.w('app', 'WebRTC settings unavailable, continuing '
        'with the link only: $e\n$s');
  }
  // The transport switch (BLE ↔ WebRTC): far mode listens for
  // WebRTC offers on the signalling channel (finding 7).
  model.onTransportModeChanged = (mode) {
    if (mode == 'webrtc') {
      unawaited(service.startWebrtcListening());
    } else {
      unawaited(service.stopWebrtcListening());
    }
  };
  if (model.transportMode == 'webrtc') {
    unawaited(service.startWebrtcListening());
  }
  // The pairing QR the Link tab shows.
  await model.refreshPairingCode();
}
