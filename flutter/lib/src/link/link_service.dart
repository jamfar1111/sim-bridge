/// The Android-side link service (finding 3): the Dart equivalent
/// of Tether's `LinkService` (minus the Android `Service` shell,
/// which is native — the foreground-service notification and the
/// lifecycle live in Kotlin; this class owns the Dart wiring).
///
/// Owns the [Hub] ([ChannelHubData] over the platform channels),
/// the BLE peripheral (advertising + LE lifecycle), the key store,
/// and the native event subscriptions (live calls, incoming SMS and
/// send reports). The far wake-up ([FarWakeNotifier]) is passed to
/// the Hub, which uses it when the iPhone cannot be reached.
///
/// LE lifecycle, mirroring Tether's `Hub.kt` / `LinkPolicy`:
/// - a session up → `setLinked(true)` + `holdLe(address)` (held
///   only while a session is up — a held link blocks a freshly
///   started iPhone app's connect);
/// - a session down → `releaseLe(address)` + `setLinked(false)`
///   when no session is left, then a pulse burst (every 5 s for
///   60 s) so a reconnecting iPhone completes its pending connect;
/// - steady state, paired with no session → one pulse every 30 s
///   (only when no LE link is open — a pulse into an existing link
///   just keeps it alive);
/// - advertising is re-ensured every 10 s (the stack stops it by
///   itself on some phones).
library;

import 'dart:async';

import '../bark/bark.dart';
import '../log/log.dart';
import '../protocol/crypto.dart';
import '../protocol/messages.dart';
import 'audio_session.dart';
import 'ble_transport.dart';
import 'channels.dart';
import 'connection.dart';
import 'hub.dart';
import 'hub_data.dart';
import 'key_store.dart';
import 'transport.dart';
import 'webrtc_transport.dart';

class AndroidLinkService {
  AndroidLinkService({
    required this.ble,
    required this.sms,
    required this.telecom,
    required this.audio,
    required this.keyStore,
    this.farWake,
    this.deviceName = 'Android',
    Stream<BleEvent>? bleEvents,
  }) : _bleEvents = bleEvents ?? ble.events;

  final BleLink ble;
  final SmsBridge sms;
  final TelecomBridge telecom;
  final CallAudioBridge audio;
  final KeyStore keyStore;
  final FarWakeNotifier? farWake;

  /// Name shown to the iPhone in the `sync` client object.
  final String deviceName;

  final Stream<BleEvent> _bleEvents;

  ChannelHubData? _data;
  Hub? _hub;

  /// The Hub, once [start] has run.
  Hub get hub {
    final h = _hub;
    if (h == null) throw StateError('AndroidLinkService.start() not called');
    return h;
  }

  /// The channel-backed Hub data, once [start] has run.
  ChannelHubData get data {
    final d = _data;
    if (d == null) throw StateError('AndroidLinkService.start() not called');
    return d;
  }

  bool get isRunning => _hub != null;

  BleTransport? _currentTransport;
  StreamSubscription<BleEvent>? _bleSub;
  StreamSubscription<CallInfo>? _callSub;
  StreamSubscription<SmsEvent>? _smsSub;
  Timer? _pulseTimer;
  Timer? _burstTimer;
  Timer? _advertisingTimer;
  int _burstLeft = 0;

  /// The paired iPhone's BLE address, learned at the first session
  /// (for the LE pulses while it is away).
  String? _pairedAddress;

  /// Whether an LE link to the iPhone is currently open (from the
  /// BLE `connected` / `disconnected` events).
  bool _linkOpen = false;

  /// Starts the Hub, the BLE peripheral, and the native event
  /// subscriptions. Idempotent.
  Future<void> start() async {
    if (isRunning) return;
    AppLogger.i('link', 'service start');
    await keyStore.init();
    final data = ChannelHubData(
      sms: sms,
      telecom: telecom,
      audio: audio,
      onUnpair: (key) => unawaited(keyStore.removePairedCentral(key)),
    );
    await data.refreshContactsVersion();
    late final Hub hub;
    hub = Hub(
      data,
      connectionFactory: (t) => _peripheralConnection(t, hub),
      audioBridge: AndroidAudioBridge(audio),
      telecom: telecom,
      ble: ble,
      farWake: farWake,
      airplaneStore: SecureAirplaneFailSafeStore(),
    );
    hub.onPaired = (c) {
      AppLogger.i('link', 'paired with ${c.name}');
      final key = c.peerKey;
      if (key != null) {
        unawaited(keyStore.addPairedCentral(
          PairedCentral(key, name: c.name, kind: c.kind),
        ));
        unawaited(keyStore.completePairing(key));
      }
    };
    hub.onSessionUp = (c) {
      AppLogger.i('link', 'session up (${c.transport.address})');
      final address = c.transport.address;
      if (address.isNotEmpty) {
        _pairedAddress = address;
        unawaited(ble.setLinked(true));
        unawaited(ble.holdLe(address));
      }
    };
    hub.onSessionDown = (c) {
      AppLogger.i('link', 'session down (${c.transport.address})');
      final address = c.transport.address;
      if (address.isNotEmpty) {
        unawaited(ble.releaseLe(address));
      }
      if (hub.targets().isEmpty) {
        unawaited(ble.setLinked(false));
        _startPulseBurst();
      }
    };
    hub.onWake = (c) {
      final address = c.transport.address;
      if (address.isNotEmpty) {
        unawaited(ble.wake(address));
      }
    };
    _data = data;
    _hub = hub;
    hub.startTimers();
    // Re-arm the airplane fail-safe if the app was killed while
    // airplane mode was on (finding N10).
    unawaited(hub.restoreAirplaneFailSafe());
    _callSub = telecom.callEvents.listen(
      (info) {
        AppLogger.i('call', 'event ${info.state} ${info.num}');
        hub.onCall(info);
      },
      onError: (_) {},
      cancelOnError: false,
    );
    _smsSub = sms.events.listen(
      (event) {
        switch (event.kind) {
          case 'sms.new':
            if (event.sms != null) {
              AppLogger.i('sms', 'received from ${event.sms!.addr}');
              hub.onSms(event.sms!, blocked: false);
            }
          case 'sms.result':
            if (event.localId != null) {
              AppLogger.i('sms',
                  'send result localId=${event.localId} ok=${event.ok}');
              hub.smsResult(
                event.localId!,
                event.ok ?? false,
                event.state ?? 'failed',
                event.err,
              );
            }
          case 'sms.readChanged':
            if (event.ids != null) hub.onUnreadChanged(event.ids!);
        }
      },
      onError: (_) {},
      cancelOnError: false,
    );
    _bleSub = _bleEvents.listen(
      _onBleEvent,
      onError: (_) {},
      cancelOnError: false,
    );
    await ble.startAdvertising(serviceUuid: bleServiceUuid, psm: '');
    _advertisingTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(ble.ensureAdvertising().catchError((_) => false));
    });
    _pulseTimer = Timer.periodic(const Duration(seconds: 30), (_) => _pulse());
    _startPulseBurst();
    AppLogger.i('link', 'service started');
  }

  /// Stops everything: timers, subscriptions, advertising, the Hub.
  Future<void> stop() async {
    AppLogger.i('link', 'service stop');
    await stopWebrtcListening();
    _pulseTimer?.cancel();
    _burstTimer?.cancel();
    _advertisingTimer?.cancel();
    _pulseTimer = null;
    _burstTimer = null;
    _advertisingTimer = null;
    _burstLeft = 0;
    await _bleSub?.cancel();
    await _callSub?.cancel();
    await _smsSub?.cancel();
    _bleSub = null;
    _callSub = null;
    _smsSub = null;
    _currentTransport?.close();
    _currentTransport = null;
    await ble.stopAdvertising().catchError((_) {});
    final hub = _hub;
    _hub = null;
    _data = null;
    hub?.dispose();
  }

  /// Opens pairing: returns the QR code to show on the Android
  /// phone. The Hub's connection factory reads the open token from
  /// the key store on every new connection, so the code is live
  /// immediately.
  Future<PairingCode> openPairing() => keyStore.openPairing(deviceName);

  /// Listens for WebRTC offers (far mode, finding 7): each accepted
  /// offer hands a transport to the Hub, like a BLE connection does.
  /// Idempotent; a no-op until the signalling server is configured.
  Future<void> startWebrtcListening() async {
    if (_webrtcListener != null) return;
    if (!WebrtcSettings.isConfigured) return;
    final room = webrtcRoomId(keyStore.ownKey.publicEncoded);
    final listener = WebrtcListener(
      signallingFactory: () => HttpSignalling(
        Uri.parse(WebrtcSettings.signallingUrl),
        room: room,
        // Signalling is HMAC-authenticated once a pairing exists
        // (finding N6); before the first pairing this is null and
        // messages go unsigned.
        authKey: keyStore.signallingKey,
      ),
      room: room,
      config: WebrtcSettings.config,
      onTransport: (t) => _hub?.onTransport(t),
    );
    _webrtcListener = listener;
    AppLogger.i('webrtc', 'listening for offers');
    unawaited(listener.start());
  }

  /// Stops listening for WebRTC offers (back to BLE only). The
  /// current WebRTC transport, if any, keeps running until it ends.
  Future<void> stopWebrtcListening() async {
    final listener = _webrtcListener;
    _webrtcListener = null;
    AppLogger.i('webrtc', 'listening stopped');
    await listener?.stop();
  }

  WebrtcListener? _webrtcListener;

  /// Closes pairing (the code is used up or expired).
  Future<void> closePairing() => keyStore.closePairing();

  PeripheralConnection _peripheralConnection(Transport t, Hub hub) {
    final c = PeripheralConnection(
      t,
      hub,
      PeripheralKeys(
        staticKey: keyStore.ownKey,
        pairedCentrals: keyStore.pairedCentrals,
        openToken: keyStore.currentToken,
        tokenFor: keyStore.tokenFor,
      ),
    );
    // The peer restarted on the same pipe: replay its HELLO on a
    // fresh transport so the handshake runs again.
    c.onPeerRestart = (first) {
      hub.onTransport(BleTransport(
        ble,
        events: _bleEvents,
        address: c.transport.address,
        replayFirst: first,
      ));
    };
    return c;
  }

  void _onBleEvent(BleEvent e) {
    switch (e.kind) {
      case 'connected':
        AppLogger.i('link', 'BLE connected (${e.address ?? ''})');
        final address = e.address ?? '';
        if (address.isNotEmpty) {
          _pairedAddress = address;
          _linkOpen = true;
        }
        // A new channel replaces any stale transport (the Hub
        // admits one session; a second central is rejected there).
        _currentTransport?.close();
        final transport = BleTransport(
          ble,
          events: _bleEvents,
          address: address,
        );
        transport.onPeerRestart = (addr, first) {
          _hub?.onTransport(BleTransport(
            ble,
            events: _bleEvents,
            address: addr,
            replayFirst: first,
          ));
        };
        _currentTransport = transport;
        _hub?.onTransport(transport);
      case 'disconnected':
      case 'closed':
        AppLogger.i('link', 'BLE ${e.kind}');
        _linkOpen = false;
        _currentTransport?.close();
        _currentTransport = null;
    }
  }

  /// One steady LE pulse, when paired with no session and no LE
  /// link open (LinkPolicy.pulseLeLink).
  void _pulse() {
    final address = _pairedAddress;
    if (!keyStore.isPaired || address == null || address.isEmpty) return;
    if (_hub?.targets().isNotEmpty ?? false) return;
    if (_linkOpen) return;
    unawaited(ble.pulseLe(address).catchError((_) {}));
  }

  /// Pulses every 5 s for 60 s, after the service starts or a
  /// session ends — while the iPhone is most likely reconnecting.
  void _startPulseBurst() {
    _burstLeft = 12;
    _burstTimer?.cancel();
    _burstTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_burstLeft <= 0) {
        timer.cancel();
        _burstTimer = null;
        return;
      }
      _burstLeft--;
      _pulse();
    });
  }
}
