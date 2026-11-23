/// App state for the SIM-bridge UI.
///
/// A ChangeNotifier model of Tether's iOS `AppModel`: it owns the
/// synced data (SMS, contacts, recents), live calls, link state and
/// the call screen, and routes user actions to the [LinkClient]
/// (real mode on iOS) or the attached [Hub] (real mode on Android),
/// or simulates them locally (demo mode).
///
/// The UI never talks to the link or the Hub directly — only through
/// this model. Incoming link data arrives here because the model is
/// the [ClientStore] the [LinkClient] applies to.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../bark/bark.dart';
import '../link/link.dart';
import '../log/log.dart';
import '../protocol/protocol.dart';
import '../setup/setup.dart';

// ---------------------------------------------------------------------
// link state
// ---------------------------------------------------------------------

enum LinkState {
  unpaired,
  searching,
  connecting,
  handshaking,
  connected,
  poweredOff,
  unauthorized,
}

extension LinkStateX on LinkState {
  bool get isConnected => this == LinkState.connected;

  String get labelFa {
    switch (this) {
      case LinkState.connected:
        return 'متصل';
      case LinkState.connecting:
      case LinkState.handshaking:
        return 'در حال اتصال…';
      case LinkState.poweredOff:
        return 'بلوتوث خاموش است';
      case LinkState.unauthorized:
        return 'دسترسی بلوتوث داده نشده';
      case LinkState.searching:
        return 'خارج از دسترس';
      case LinkState.unpaired:
        return 'جفت نشده';
    }
  }
}

// ---------------------------------------------------------------------
// call screen
// ---------------------------------------------------------------------

/// What the in-app call screen shows. Mirrors Tether's `CallScreen`.
class CallScreen {
  const CallScreen({
    required this.uuid,
    required this.num,
    this.name,
    required this.state,
    required this.incoming,
    this.connectedAt,
    this.sub,
    this.muted = false,
    this.held = false,
    this.speaker = false,
    this.elsewhere = false,
    this.where,
  });

  final String uuid;
  final String num;
  final String? name;

  /// "dialing" | "ringing" | "connecting" | "active" | "holding" | "ended"
  final String state;
  final bool incoming;
  final DateTime? connectedAt;
  final int? sub;
  final bool muted;
  final bool held;
  final bool speaker;

  /// The call's audio is on another client.
  final bool elsewhere;
  final String? where;

  bool get isLive =>
      state == 'dialing' ||
      state == 'ringing' ||
      state == 'connecting' ||
      state == 'active' ||
      state == 'holding';

  CallScreen copyWith({
    String? state,
    DateTime? connectedAt,
    bool? muted,
    bool? held,
    bool? speaker,
    bool? elsewhere,
    String? where,
  }) =>
      CallScreen(
        uuid: uuid,
        num: num,
        name: name,
        state: state ?? this.state,
        incoming: incoming,
        connectedAt: connectedAt ?? this.connectedAt,
        sub: sub,
        muted: muted ?? this.muted,
        held: held ?? this.held,
        speaker: speaker ?? this.speaker,
        elsewhere: elsewhere ?? this.elsewhere,
        where: where ?? this.where,
      );
}

// ---------------------------------------------------------------------
// conversations
// ---------------------------------------------------------------------

class Conversation {
  const Conversation({
    required this.thread,
    required this.address,
    required this.last,
    required this.unread,
  });

  final int thread;
  final String address;
  final Sms last;
  final int unread;
}

// ---------------------------------------------------------------------
// formatting helpers
// ---------------------------------------------------------------------

/// Short time for a Unix-millisecond timestamp: today → HH:mm,
/// yesterday → "دیروز", else day + short month.
String shortTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  if (day == today) return '$hh:$mm';
  if (day == today.subtract(const Duration(days: 1))) return 'دیروز';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${d.day} ${months[d.month - 1]}';
}

/// mm:ss for a call duration.
String formatDuration(int seconds) {
  final m = (seconds ~/ 60).toString().padLeft(2, '0');
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// mm:ss for a live call, from its connected time.
String liveDuration(DateTime? connectedAt) {
  if (connectedAt == null) return '۰۰:۰۰';
  return formatDuration(
      DateTime.now().difference(connectedAt).inSeconds);
}

// ---------------------------------------------------------------------
// the model
// ---------------------------------------------------------------------

class AppModel extends ChangeNotifier implements ClientStore {
  AppModel._({
    required this.demoMode,
    List<Sms>? sms,
    List<Contact>? contacts,
    List<CallEntry>? recents,
    this._status,
    this.isPaired = false,
    this.peerName = 'Android',
    this.linkState = LinkState.unpaired,
    this.ownPairingCode,
  })  : _sms = sms ?? [],
        _contacts = contacts ?? [],
        _recents = recents ?? [];

  /// Demo mode: sample data, simulated calls, never touches a real
  /// phone or pairing.
  factory AppModel.demo() {
    final now = DateTime.now().millisecondsSinceEpoch;
    const minute = 60000;
    const hour = 3600000;
    final sms = <Sms>[
      Sms(id: 1, thread: 1, addr: '+989121234567', body: 'سلام! امشب میای؟', date: now - 190 * minute, box: 1, read: true, sub: 3),
      Sms(id: 2, thread: 1, addr: '+989121234567', body: 'آره! حدود شش از سر کار میام.', date: now - 188 * minute, box: 2, read: true, sub: 3),
      Sms(id: 3, thread: 1, addr: '+989121234567', body: 'چیزی بیارم؟', date: now - 187 * minute, box: 2, read: true, sub: 3),
      Sms(id: 4, thread: 1, addr: '+989121234567', body: 'فقط خودت 😄', date: now - 60 * minute, box: 1, read: true, sub: 3),
      Sms(id: 5, thread: 1, addr: '+989121234567', body: 'میز رو برای ۷:۳۰ رزرو کردیم', date: now - 59 * minute, box: 1, read: true, sub: 3),
      Sms(id: 6, thread: 1, addr: '+989121234567', body: 'عالیه، می‌بینمت', date: now - 2 * minute, box: 2, read: true, sub: 3),
      Sms(id: 7, thread: 2, addr: '+989122223333', body: 'قرار فردا یادت نره', date: now - 5 * hour, box: 1, read: true, sub: 3),
      Sms(id: 8, thread: 2, addr: '+989122223333', body: 'باشه حتما', date: now - 5 * hour + 2 * minute, box: 2, read: true, sub: 3),
      Sms(id: 9, thread: 3, addr: '+15550102', body: 'Demo message 1', date: now - 3 * hour, box: 1, read: false, sub: 3),
      Sms(id: 10, thread: 4, addr: '7000', body: 'رمز پویا: ۸۲۷۱۶۳\nمبلغ: ۱,۲۵۰,۰۰۰ ریال\nزمان اعتبار: ۱۲۰ ثانیه', date: now - 40 * minute, box: 1, read: false, sub: 3),
      Sms(id: 11, thread: 4, addr: '7000', body: 'G-7741 is your Google verification code.', date: now - 25 * minute, box: 1, read: true, sub: 3),
      Sms(id: 12, thread: 5, addr: '+15550105', body: 'سلام! لینک پرداخت قبض شما: https://shaparak.ir/pay?id=88213 تا ساعت ۲۰ معتبر است.', date: now - 90 * minute, box: 1, read: true, sub: 2),
      Sms(id: 13, thread: 5, addr: '+15550105', body: 'برای پشتیبانی با ۰۲۱-۸۸۷۷۶۶۵۵ تماس بگیرید.', date: now - 80 * minute, box: 1, read: true, sub: 3),
    ];
    final contacts = <Contact>[
      const Contact(id: 1, name: 'سارا احمدی', phones: [Phone('+989121234567', 'mobile')], emails: [], starred: true),
      const Contact(id: 2, name: 'نیما محمدی', phones: [Phone('+989122223333', 'mobile')], emails: [], starred: true),
      const Contact(id: 3, name: 'مامان', phones: [Phone('+989191112233', 'mobile')], emails: [], starred: false),
      const Contact(id: 4, name: 'دانیال بروکس', phones: [Phone('+15550102', 'mobile')], emails: [], starred: false),
      const Contact(id: 5, name: 'بانک ملت', phones: [Phone('7000', 'mobile')], emails: [], starred: false),
    ];
    final recents = <CallEntry>[
      CallEntry(id: 1, num: '+989121234567', name: 'سارا احمدی', date: now - 30 * minute, dur: 95, type: 1, sub: 3),
      CallEntry(id: 2, num: '+989122223333', name: 'نیما محمدی', date: now - 2 * hour, dur: 210, type: 2, sub: 3),
      CallEntry(id: 3, num: '+989191112233', name: 'مامان', date: now - 4 * hour, dur: 0, type: 3, sub: 3),
      CallEntry(id: 4, num: '+15550102', name: 'دانیال بروکس', date: now - 6 * hour, dur: 42, type: 1, sub: 2),
    ];
    // A fixed demo pairing code (deterministic, demo only).
    final key = List<int>.generate(65, (i) => i == 0 ? 0x04 : (i * 37 + 11) % 256);
    final token = List<int>.generate(16, (i) => (i * 53 + 7) % 256);
    final code = PairingCode(key, token, 'Galaxy A52');
    return AppModel._(
      demoMode: true,
      sms: sms,
      contacts: contacts,
      recents: recents,
      isPaired: true,
      peerName: 'Galaxy A52',
      linkState: LinkState.connected,
      ownPairingCode: code.encode(),
      status: {
        'device': 'Galaxy A52',
        'battery': 82,
        'charging': false,
        'sims': [
          {
            'slot': 0, 'sub': 3, 'name': 'شخصی', 'carrier': 'ایرانسل',
            'signal': 4, 'net': 'LTE', 'service': 'in',
          },
          {
            'slot': 1, 'sub': 2, 'name': 'کاری', 'carrier': 'همراه اول',
            'signal': 2, 'net': 'LTE+', 'service': 'in',
          },
        ],
        'defaultSub': 3,
        'dialer': true,
        'helper': {'state': 'running', 'method': 'intercept', 'up': true, 'down': true},
        'wifi': true,
      },
    );
  }

  /// Fresh install: nothing paired yet.
  factory AppModel.unpaired() => AppModel._(demoMode: true);

  /// Real mode: empty data, nothing paired yet. The platform code
  /// (main.dart) attaches the link (iOS) or the Hub (Android) before
  /// the UI shows it.
  factory AppModel.real() => AppModel._(demoMode: false);

  final bool demoMode;

  // --- synced data ---------------------------------------------------

  final List<Sms> _sms;
  final List<Contact> _contacts;
  final List<CallEntry> _recents;

  List<Sms> get sms => List.unmodifiable(_sms);
  List<Contact> get contacts => List.unmodifiable(_contacts);
  List<CallEntry> get recents =>
      List.unmodifiable(_recents..sort((a, b) => b.date.compareTo(a.date)));

  /// thread → newest read message id.
  final Map<int, int> readUpTo = {};

  // --- link ----------------------------------------------------------

  bool isPaired;
  String peerName;
  LinkState linkState;
  String? ownPairingCode;

  /// Sets the pairing QR the Android phone shows (from the link
  /// service's open pairing code, in real mode).
  void setOwnPairingCode(String code) {
    ownPairingCode = code;
    notifyListeners();
  }

  /// 'ble' (near, Bluetooth) or 'webrtc' (far, WebRTC + TURN).
  String transportMode = 'ble';

  /// Network switches on the Android phone (demo state until wired).
  final Map<String, dynamic> netState = {
    'data': true,
    'hotspot': false,
    'bt': false,
    'airplane': false,
    'share': false,
  };

  Map<String, dynamic>? _status;
  Map<String, dynamic>? get status => _status;

  int get battery => (_status?['battery'] as num?)?.toInt() ?? 0;
  bool get charging => _status?['charging'] as bool? ?? false;

  List<Map<String, dynamic>> get sims {
    final list = _status?['sims'];
    if (list is! List) return const [];
    return list
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Slot of the default data SIM (for the `rat` switch), or 0.
  int get defaultSlot {
    final sub = _status?['defaultSub'];
    for (final sim in sims) {
      if (sim['sub'] == sub) return (sim['slot'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  // --- calls ---------------------------------------------------------

  final Map<String, CallInfo> liveCalls = {};

  CallScreen? _callScreen;
  CallScreen? get callScreen => _callScreen;
  bool _showCallScreen = false;
  bool get showCallScreen => _showCallScreen && _callScreen != null;

  List<CallInfo> get remoteCalls => liveCalls.values
      .where((c) => c.elsewhere == true)
      .toList();

  // --- navigation / feedback -----------------------------------------

  int tabIndex = 0;
  String? lastError;
  String? notice;

  int _lastSeenRecentsMs = 0;

  Hub? _hub;
  HubData? get _data => _hub?.data;

  // --- local phone data (Android hub) --------------------------------
  // The phone's own call history, contacts and SMS, shown in the
  // Android UI itself. The Hub only read local data to send it to a
  // paired iPhone — with no iPhone paired, the Android lists stayed
  // empty even with all permissions granted (2026-11-23: Recents
  // showed "هنوز تماسی نیست" and Contacts "مخاطبی پیدا نشد").
  //
  // Bounds: the native providers cap full syncs (calls 1000, SMS
  // 5000); the UI keeps a smaller working set.
  static const int maxLocalRecents = 200;
  static const int maxLocalSms = 500;

  /// Whether a full local load has completed with all three
  /// providers readable. False while a permission is still
  /// missing, so a later grant retries the skipped sections.
  bool _localDataLoaded = false;
  bool get localDataLoaded => _localDataLoaded;

  bool _localLoading = false;
  StreamSubscription<SmsEvent>? _localSmsSub;
  StreamSubscription<CallInfo>? _localCallSub;
  Timer? _localRecentsTimer;

  /// The Android link service, when attached (real mode on
  /// Android): used to refresh the pairing QR.
  AndroidLinkService? _linkService;

  /// Whether this side is the Android hub (real mode on Android):
  /// the setup card shows only here.
  bool get isAndroidHub => _linkService != null;

  /// The first-launch setup flow (real mode on Android only):
  /// runtime permissions, Bluetooth on, dialer role, battery
  /// exemption. Attached by main.dart before the link starts.
  AndroidSetup? _setup;
  AndroidSetup? get setup => _setup;

  void attachSetup(AndroidSetup setup) {
    _setup = setup;
    // The local lists need the runtime permissions: when they flip
    // to granted (e.g. the user grants them later from the setup
    // card), load the lists. The load is a no-op once loaded or
    // while one is running.
    setup.addListener(_onSetupChanged);
    notifyListeners();
  }

  void _onSetupChanged() {
    final setup = _setup;
    if (setup == null || _data == null) return;
    if (setup.permissionsGranted) {
      unawaited(loadLocalData());
    }
  }

  /// Attaches the Android link service (real mode on Android):
  /// the Hub behind it, plus the pairing-code refresh.
  void attachLinkService(AndroidLinkService service) {
    _linkService = service;
    attachHub(service.hub);
    // Live local updates: the Hub forwards call/SMS events to a
    // paired peer, but the Android UI itself never saw them — a
    // new SMS or an ended call never landed in the local lists.
    // Subscribe to the same broadcast streams the service uses
    // (cached in the bridges, so both readers get every event).
    _localSmsSub?.cancel();
    _localSmsSub = service.sms.events.listen((event) {
      if (demoMode) return;
      if (event.kind == 'sms.new' && event.sms != null) {
        applySmsNew(event.sms!);
      } else if (event.kind == 'sms.readChanged' && event.ids != null) {
        applySmsUnread(event.ids!, all: event.ids!.length < 3000);
      }
    }, onError: (_) {});
    _localCallSub?.cancel();
    _localCallSub = service.telecom.callEvents.listen((info) {
      if (demoMode) return;
      if (info.state == 'ended') _scheduleLocalRecentsReload();
    }, onError: (_) {});
    // First load of the phone's own history. Setup already ran by
    // now (main.dart runs it before the service starts), so the
    // providers are readable when the permissions are granted;
    // sections whose permission is still missing are skipped and
    // retried when the grant lands (see [_onSetupChanged]).
    unawaited(loadLocalData());
  }

  /// Loads the Android phone's own call history, contacts and SMS
  /// into the local lists (real hub mode only). No-op when the
  /// data is already loaded (unless [force]), while a load is
  /// running, or in demo mode. A section whose provider permission
  /// is still missing is skipped — and the load does not count as
  /// done, so a later grant retries it.
  Future<void> loadLocalData({bool force = false}) async {
    final data = _data;
    if (data == null || demoMode) return;
    if (_localLoading) return;
    if (_localDataLoaded && !force) return;
    _localLoading = true;
    try {
      // Which providers may be read (no setup in tests / on iOS:
      // everything is readable).
      var canCalls = true;
      var canContacts = true;
      var canSms = true;
      final setup = _setup;
      if (setup != null) {
        final perms = await setup.localDataPermissions();
        canCalls = perms.calls;
        canContacts = perms.contacts;
        canSms = perms.sms;
      }
      if (force) {
        // Drop the locally loaded rows (keep optimistic outbox
        // copies, id < 0) so deleted rows disappear too.
        _recents.clear();
        _contacts.clear();
        _sms.removeWhere((m) => m.id >= 0);
      }
      if (canCalls) {
        try {
          final calls = await data.callsSince(0);
          calls.sort((a, b) => b.date.compareTo(a.date));
          applyCallsBatch(calls.take(maxLocalRecents).toList(),
              more: false);
        } catch (e) {
          AppLogger.w('local', 'recents load failed: $e');
        }
      }
      if (canContacts) {
        try {
          final contacts = await data.contactsAll();
          applyContactsBatch(contacts,
              version: data.contactsVersion(), full: true);
        } catch (e) {
          AppLogger.w('local', 'contacts load failed: $e');
        }
      }
      if (canSms) {
        try {
          final sms = await data.smsSince(0);
          sms.sort((a, b) => b.date.compareTo(a.date));
          // Newest 500, then back to chronological order, like
          // the sync path inserts them.
          final newest = sms.take(maxLocalSms).toList()
            ..sort((a, b) => a.date.compareTo(b.date));
          applySmsBatch(newest, more: false);
        } catch (e) {
          AppLogger.w('local', 'sms load failed: $e');
        }
      }
      _localDataLoaded = canCalls && canContacts && canSms;
      AppLogger.i('local',
          'loaded recents=${_recents.length} contacts=${_contacts.length} '
          'sms=${_sms.length} complete=$_localDataLoaded');
      notifyListeners();
    } finally {
      _localLoading = false;
    }
  }

  /// Re-loads the local lists from the phone (pull-to-refresh).
  Future<void> refreshLocalData() async {
    await loadLocalData(force: true);
  }

  /// Loads the local lists if they are not loaded yet (a tab
  /// first opened); a no-op otherwise.
  void ensureLocalDataLoaded() {
    unawaited(loadLocalData());
  }

  /// After a call ends, the call-log provider has the row — reload
  /// the recents incrementally. Delayed a second so the provider
  /// has settled, and debounced (several ends in a row reload
  /// once).
  void _scheduleLocalRecentsReload() {
    _localRecentsTimer?.cancel();
    _localRecentsTimer = Timer(const Duration(seconds: 1), () {
      unawaited(_reloadLocalRecents());
    });
  }

  Future<void> _reloadLocalRecents() async {
    final data = _data;
    if (data == null || demoMode) return;
    try {
      final calls = await data.callsSince(callsSince);
      if (calls.isEmpty) return;
      applyCallsBatch(calls, more: false);
      AppLogger.i('local',
          'recents reloaded after call end: +${calls.length}');
    } catch (e) {
      AppLogger.w('local', 'recents reload after call end failed: $e');
    }
  }

  /// Opens a fresh pairing code on the Android phone and shows it
  /// (the QR the Link tab displays). Pairing codes live 5 minutes.
  Future<void> refreshPairingCode() async {
    final service = _linkService;
    if (service == null || demoMode) return;
    final code = await service.openPairing();
    setOwnPairingCode(code.encode());
  }

  // --- iPhone-side link (real mode on iOS) -------------------------

  LinkClient? _client;
  LinkClient? get client => _client;
  CallKitBridge? _callKit;

  /// Whether this side is the iPhone client (real mode on iOS):
  /// the Bark key is entered here, not on Android.
  bool get isIphoneClient => _client != null;

  /// Builds the camera QR scanner for the Link tab. Overridable in
  /// tests (the real one uses `mobile_scanner`); `null` uses the
  /// default camera scanner.
  Widget Function(ValueChanged<String> onCode)? qrScannerBuilder;

  /// This iPhone's Bark device key (sent in every `sync`, so the
  /// Android side can wake it when the link is down). Set by the
  /// platform code from secure storage.
  @override
  String? barkKey;

  /// The Bark key store (iOS real mode): attached by main.dart.
  /// `null` in demo mode / on Android (there the key arrives over
  /// the link, never from local storage).
  BarkKeyStore? _barkKeyStore;

  /// Whether a Bark device key is saved (iOS far wake-up).
  bool get hasBarkKey => barkKey != null && barkKey!.isNotEmpty;

  /// Attaches the Bark key store and loads the saved key (iOS).
  /// Call after [attachClient], so the client gets the key too.
  Future<void> attachBarkKeyStore(BarkKeyStore store) async {
    _barkKeyStore = store;
    final saved = await store.read();
    if (saved != null && saved.isNotEmpty) {
      barkKey = saved;
      _client?.barkKey = saved;
      notifyListeners();
    }
  }

  /// Saves the Bark device key the user pasted from the Bark app
  /// (Link tab): persists it and sends it in the next `sync`
  /// (finding N1). A blank key is ignored.
  Future<void> saveBarkKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return;
    barkKey = trimmed;
    _client?.barkKey = trimmed;
    await _barkKeyStore?.write(trimmed);
    notifyListeners();
  }

  /// Forgets the saved Bark key (the next `sync` sends none).
  Future<void> clearBarkKey() async {
    barkKey = null;
    _client?.barkKey = null;
    await _barkKeyStore?.clear();
    notifyListeners();
  }

  /// The WebRTC settings store, attached by main.dart. `null` in
  /// demo mode (the Link tab's settings card is hidden there).
  WebrtcSettingsStore? _webrtcSettings;

  /// Loads the persisted WebRTC settings into [WebrtcSettings]
  /// (call at startup, before wiring the transports).
  ///
  /// Best-effort: a failing read must never kill the link that is
  /// already up. A missing native class (e.g. the manual build once
  /// dropped package:jni's `PortContinuation`, 2026-11-23) made the
  /// first read throw and dropped the whole app into demo mode even
  /// though the link service had started fine. Each read is guarded
  /// separately so one bad read does not block the other, and the
  /// store stays attached so later saves still work.
  Future<void> attachWebrtcSettingsStore(WebrtcSettingsStore store) async {
    _webrtcSettings = store;
    try {
      final url = await store.readSignallingUrl();
      if (url != null && url.isNotEmpty) WebrtcSettings.signallingUrl = url;
    } catch (e) {
      AppLogger.w('app', 'WebRTC signalling URL unreadable, '
          'continuing without it: $e');
    }
    try {
      final turn = await store.readTurnCredentials();
      if (turn != null) {
        WebrtcSettings.turnUsername = turn.$1;
        WebrtcSettings.turnCredential = turn.$2;
      }
    } catch (e) {
      AppLogger.w('app', 'WebRTC TURN credentials unreadable, '
          'continuing without them: $e');
    }
    notifyListeners();
  }

  /// Persists the Cloudflare Worker signalling URL (finding N3).
  /// A blank URL clears the setting.
  Future<void> saveSignallingUrl(String url) async {
    final trimmed = url.trim();
    WebrtcSettings.signallingUrl = trimmed;
    await _webrtcSettings?.writeSignallingUrl(trimmed);
    notifyListeners();
  }

  /// Persists the TURN username + credential (finding N3). Blank
  /// values clear the credentials.
  Future<void> saveTurnCredentials(String username, String credential) async {
    final user = username.trim();
    final cred = credential.trim();
    WebrtcSettings.turnUsername = user.isEmpty ? null : user;
    WebrtcSettings.turnCredential = cred.isEmpty ? null : cred;
    if (user.isEmpty || cred.isEmpty) {
      await _webrtcSettings?.clearTurnCredentials();
    } else {
      await _webrtcSettings?.writeTurnCredentials(user, cred);
    }
    notifyListeners();
  }

  /// Fetches fresh TURN credentials from the Cloudflare API with the
  /// user's API token and key id (finding N3). The token is **never
  /// persisted**: it is only used for this one call, then dropped.
  /// The returned credentials are saved in secure storage.
  Future<void> fetchTurnCredentials({
    required String apiToken,
    required String keyId,
  }) async {
    final creds = await CloudflareTurn.fetch(
      apiToken: apiToken.trim(),
      keyId: keyId.trim(),
    );
    await saveTurnCredentials(creds.$1, creds.$2);
  }

  /// Shares this phone's pairing code through the system share
  /// sheet (finding N2): the iPhone user pastes it into the app
  /// instead of scanning. A failure shows a notice instead of
  /// crashing the Link tab.
  Future<void> sharePairingCode() async {
    final code = ownPairingCode;
    if (code == null) return;
    try {
      await SharePlus.instance.share(ShareParams(text: code));
    } catch (_) {
      fail('اشتراک‌گذاری انجام نشد.');
    }
  }

  /// Call audio flowing to this iPhone right now.
  bool audioActive = false;
  String? audioCodec;
  int? audioRate;

  /// Last self-test result document, if any.
  Map<String, dynamic>? lastSelftest;

  /// Block / mute lists from the Android phone.
  Map<String, dynamic> lists = {
    'blocked': <String>[],
    'muted': <int>[],
    'system': false,
  };

  String _contactsVersion = '';

  /// Optimistic outbox messages: temp (negative) id → (address,
  /// body, sentAt). Replaced by the real message when it arrives
  /// via sync.
  final Map<int, (String, String, int)> _outbox = {};
  int _nextTempId = -1;

  /// `sync.ids` ranges accumulate across pages; the store prunes
  /// deleted ids only when the last page arrives (`more: false`).
  final List<List<int>> _pendingSmsRanges = [];
  final List<List<int>> _pendingCallRanges = [];

  final List<Timer> _timers = [];
  Timer? _noticeTimer;

  // --- derived data --------------------------------------------------

  List<Conversation> get conversations {
    final byThread = <int, List<Sms>>{};
    for (final m in _sms) {
      byThread.putIfAbsent(m.thread, () => []).add(m);
    }
    final out = <Conversation>[];
    for (final entry in byThread.entries) {
      final last = entry.value
          .reduce((a, b) => a.date >= b.date ? a : b);
      final seen = readUpTo[entry.key] ?? 0;
      final unread = entry.value
          .where((m) => m.box == 1 && !m.read && m.id > seen)
          .length;
      out.add(Conversation(
        thread: entry.key,
        address: last.addr,
        last: last,
        unread: unread,
      ));
    }
    out.sort((a, b) => b.last.date.compareTo(a.last.date));
    return out;
  }

  int get unreadTotal =>
      conversations.fold<int>(0, (sum, c) => sum + c.unread);

  int get missedCount => _recents
      .where((c) => c.type == 3 && c.date > _lastSeenRecentsMs)
      .length;

  List<Sms> messagesForThread(int thread) {
    final list =
        _sms.where((m) => m.thread == thread).toList();
    list.sort((a, b) {
      final byDate = a.date.compareTo(b.date);
      return byDate != 0 ? byDate : a.id.compareTo(b.id);
    });
    return list;
  }

  int unreadForThread(int thread) {
    final seen = readUpTo[thread] ?? 0;
    return _sms
        .where((m) =>
            m.thread == thread && m.box == 1 && !m.read && m.id > seen)
        .length;
  }

  String? nameFor(String number) {
    final key = numberKey(number);
    for (final c in _contacts) {
      for (final p in c.phones) {
        if (numberKey(p.n) == key) return c.name;
      }
    }
    return null;
  }

  /// A contact's name, else the number in a left-to-right isolate
  /// (so "+98…" keeps its plus sign in Persian layout).
  String displayName(String number) =>
      nameFor(number) ??
      (number.isEmpty ? 'ناشناس' : '\u2066$number\u2069');

  // --- ClientStore counters (what the client sends in `sync`) -----

  @override
  int get smsSince =>
      _sms.map((m) => m.id).fold(0, (a, b) => a > b ? a : b);

  @override
  int get callsSince =>
      _recents.map((c) => c.id).fold(0, (a, b) => a > b ? a : b);

  @override
  String get contactsVersion => _contactsVersion;

  // --- hub wiring ----------------------------------------------------

  /// Attaches a live [Hub]; call state then follows the hub, and
  /// actions go to the phone through [HubData].
  void attachHub(Hub hub) {
    _hub = hub;
    hub.addListener(_syncFromHub);
    _syncFromHub();
  }

  /// Attaches the iPhone-side link (real mode on iOS). Incoming data
  /// flows into this model ([ClientStore]); actions go out through
  /// the client. Optionally attaches CallKit: its actions become
  /// `call.*` messages, and outgoing dials start through it.
  void attachClient(LinkClient client, {CallKitBridge? callKit}) {
    _client = client;
    client.store = this;
    if (callKit != null) {
      _callKit = callKit;
      client.attachCallKit(callKit);
    }
    linkState = client.isPaired
        ? (client.isConnected
            ? LinkState.connected
            : LinkState.connecting)
        : LinkState.unpaired;
    notifyListeners();
  }

  /// Called (by main.dart) when the link reports a completed
  /// pairing, or when a stored pairing is resumed at startup.
  void setPaired(String peer) {
    isPaired = true;
    peerName = peer;
    linkState = LinkState.connected;
    notifyListeners();
  }

  /// Called (by main.dart) when the user unpairs, or the peer
  /// unpairs us.
  void setUnpaired() {
    isPaired = false;
    peerName = 'Android';
    linkState = LinkState.unpaired;
    liveCalls.clear();
    _callScreen = null;
    _showCallScreen = false;
    notifyListeners();
  }

  void _syncFromHub() {
    final hub = _hub;
    if (hub == null) return;
    liveCalls
      ..clear()
      ..addAll(hub.liveCalls);
    _syncCallScreenFromLive();
    notifyListeners();
  }

  void _syncCallScreenFromLive() {
    final primary = _primaryCall();
    if (primary == null) {
      if (_callScreen != null && _callScreen!.state != 'ended') {
        _endScreen();
      }
      return;
    }
    final existing = _callScreen;
    final screen = CallScreen(
      uuid: primary.cid,
      num: primary.num,
      name: primary.name ?? nameFor(primary.num),
      state: primary.state,
      incoming: primary.dir == 'in',
      connectedAt: primary.since == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(primary.since!),
      sub: primary.sub,
      muted: existing?.uuid == primary.cid ? existing!.muted : false,
      held: primary.state == 'holding',
      speaker: existing?.uuid == primary.cid ? existing!.speaker : false,
      elsewhere: primary.elsewhere ?? false,
      where: primary.where,
    );
    _callScreen = screen;
    _showCallScreen = true;
  }

  CallInfo? _primaryCall() {
    CallInfo? pick;
    for (final c in liveCalls.values) {
      if (c.state == 'ended') continue;
      if (pick == null) {
        pick = c;
        continue;
      }
      // Ringing wins, then active.
      if (c.state == 'ringing' && pick.state != 'ringing') pick = c;
      if (c.state == 'active' && pick.state == 'dialing') pick = c;
    }
    return pick;
  }

  // --- ClientStore: incoming link data (real mode on iOS) ----------

  @override
  void applyStatus(Map<String, dynamic> status) {
    _status = Map<String, dynamic>.of(status);
    notifyListeners();
  }

  @override
  void applySmsBatch(List<Sms> msgs, {required bool more}) {
    for (final msg in msgs) {
      _upsertSms(msg);
    }
    notifyListeners();
  }

  @override
  void applySmsNew(Sms msg) {
    _upsertSms(msg);
    notifyListeners();
  }

  void _upsertSms(Sms msg) {
    final index = _sms.indexWhere((m) => m.id == msg.id);
    if (index >= 0) {
      _sms[index] = msg;
    } else {
      _sms.add(msg);
    }
    // A sent message the phone now reports is the same one this
    // iPhone sent optimistically: drop the temp copy.
    if (msg.box == 2) {
      _outbox.removeWhere((tempId, v) {
        final match = v.$1 == msg.addr &&
            v.$2 == msg.body &&
            (msg.date - v.$3).abs() < 10000;
        if (match) _sms.removeWhere((m) => m.id == tempId);
        return match;
      });
    }
  }

  @override
  void applySmsRead(int thread, int upTo) {
    readUpTo[thread] = upTo;
    for (var i = 0; i < _sms.length; i++) {
      final m = _sms[i];
      if (m.thread == thread && m.id <= upTo && !m.read) {
        _sms[i] = Sms(
          id: m.id,
          thread: m.thread,
          addr: m.addr,
          body: m.body,
          date: m.date,
          box: m.box,
          read: true,
          sub: m.sub,
        );
      }
    }
    notifyListeners();
  }

  @override
  void applySmsUnread(List<int> ids, {required bool all}) {
    for (var i = 0; i < _sms.length; i++) {
      final m = _sms[i];
      if (m.box != 1) continue;
      final unread = ids.contains(m.id);
      final newRead = all ? !unread : (unread ? false : m.read);
      if (newRead != m.read) {
        _sms[i] = Sms(
          id: m.id,
          thread: m.thread,
          addr: m.addr,
          body: m.body,
          date: m.date,
          box: m.box,
          read: newRead,
          sub: m.sub,
        );
      }
    }
    notifyListeners();
  }

  @override
  void applySmsResult({required bool ok, String? state, String? err}) {
    // Delivery state flows through the `sendSms` Future (which the
    // model awaits), not through this broadcast — nothing to do
    // here.
  }

  @override
  void applySmsDeleted(List<int> ids) {
    _sms.removeWhere((m) => ids.contains(m.id));
    notifyListeners();
  }

  @override
  void applyCallsBatch(List<CallEntry> calls, {required bool more}) {
    for (final call in calls) {
      final index = _recents.indexWhere((c) => c.id == call.id);
      if (index >= 0) {
        _recents[index] = call;
      } else {
        _recents.add(call);
      }
    }
    notifyListeners();
  }

  @override
  void applyCallState(CallInfo call) {
    if (call.state == 'ended') {
      liveCalls.remove(call.cid);
    } else {
      liveCalls[call.cid] = call;
    }
    _syncCallScreenFromLive();
    notifyListeners();
  }

  @override
  void applyCallList(List<CallInfo> calls) {
    liveCalls
      ..clear()
      ..addEntries(calls.map((c) => MapEntry(c.cid, c)));
    _syncCallScreenFromLive();
    notifyListeners();
  }

  @override
  void applyCallDialed({required bool ok, String? err}) {
    if (!ok) {
      fail('شماره‌گیری انجام نشد${err == null ? '' : ': $err'}');
    }
  }

  @override
  void applyCallsDeleted(List<int> ids, {required bool all}) {
    if (all) {
      _recents.clear();
    } else {
      _recents.removeWhere((c) => ids.contains(c.id));
    }
    notifyListeners();
  }

  @override
  void applyContactsBatch(List<Contact> contacts,
      {required String version, required bool full}) {
    if (full) {
      _contacts
        ..clear()
        ..addAll(contacts);
    } else {
      for (final contact in contacts) {
        final index = _contacts.indexWhere((c) => c.id == contact.id);
        if (index >= 0) {
          _contacts[index] = contact;
        } else {
          _contacts.add(contact);
        }
      }
    }
    _contactsVersion = version;
    notifyListeners();
  }

  @override
  void applyContactResult({required bool ok, int? id, String? err}) {
    if (!ok) {
      fail('ذخیره مخاطب انجام نشد${err == null ? '' : ': $err'}');
    }
  }

  @override
  void applyLists(Map<String, dynamic> lists) {
    this.lists = Map<String, dynamic>.of(lists);
    notifyListeners();
  }

  @override
  void applySyncIds(
      {required List<List<int>> smsRanges,
      required List<List<int>> callRanges,
      required bool more}) {
    _pendingSmsRanges.addAll(smsRanges);
    _pendingCallRanges.addAll(callRanges);
    if (more) return;
    final smsKept = <int>{};
    for (final r in _pendingSmsRanges) {
      for (var i = r[0]; i <= r[1]; i++) {
        smsKept.add(i);
      }
    }
    // Optimistic outbox copies have negative ids: never pruned.
    _sms.removeWhere((m) => m.id >= 0 && !smsKept.contains(m.id));
    final callsKept = <int>{};
    for (final r in _pendingCallRanges) {
      for (var i = r[0]; i <= r[1]; i++) {
        callsKept.add(i);
      }
    }
    _recents.removeWhere((c) => !callsKept.contains(c.id));
    _pendingSmsRanges.clear();
    _pendingCallRanges.clear();
    notifyListeners();
  }

  @override
  void applyNetState(Map<String, dynamic> net) {
    netState.addAll(net);
    notifyListeners();
  }

  @override
  void applySelftestResult(Map<String, dynamic> result) {
    lastSelftest = result;
    notifyListeners();
  }

  @override
  void applyAudioStarted({required String codec, required int rate}) {
    audioActive = true;
    audioCodec = codec;
    audioRate = rate;
    notifyListeners();
  }

  @override
  void applyAudioStopped() {
    audioActive = false;
    notifyListeners();
  }

  @override
  void applyLinkUp() {
    linkState = LinkState.connected;
    notifyListeners();
  }

  @override
  void applyLinkLost() {
    // The client reconnects on its own; the UI shows "connecting"
    // until it does (unpairing overrides this through setUnpaired).
    linkState = LinkState.connecting;
    notifyListeners();
  }

  // --- navigation ----------------------------------------------------

  void selectTab(int i) {
    tabIndex = i;
    if (i == 0) _lastSeenRecentsMs = DateTime.now().millisecondsSinceEpoch;
    // Opening a tab in real hub mode loads the local lists if
    // they are not in yet (e.g. permissions were granted after
    // wiring); a no-op once loaded.
    ensureLocalDataLoaded();
    notifyListeners();
  }

  void openCallScreen() {
    if (_callScreen != null) {
      _showCallScreen = true;
      notifyListeners();
    }
  }

  /// A thread a deep link wants opened (`simbridge://sms?thread=…`):
  /// consumed by the Messages tab, which pushes the thread view.
  /// Set by [openThread]; cleared when the tab picks it up.
  int? pendingThread;

  /// Opens an SMS thread from a deep link: switches to the Messages
  /// tab and asks it to push the thread view (see [pendingThread]).
  void openThread(int thread) {
    pendingThread = thread;
    markThreadRead(thread);
    selectTab(3);
  }

  void closeCallScreen() {
    _showCallScreen = false;
    notifyListeners();
  }

  // --- feedback ------------------------------------------------------

  void flash(String text) {
    notice = text;
    lastError = null;
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(milliseconds: 1600), () {
      notice = null;
      notifyListeners();
    });
    notifyListeners();
  }

  void fail(String text) {
    lastError = text;
    notice = null;
    notifyListeners();
  }

  void dismissNotice() {
    notice = null;
    notifyListeners();
  }

  void dismissError() {
    lastError = null;
    notifyListeners();
  }

  // --- calls ---------------------------------------------------------

  void _later(Duration d, void Function() fn) {
    final t = Timer(d, () {
      _timers.removeWhere((e) => !e.isActive);
      fn();
    });
    _timers.add(t);
  }

  void dial(String num, {int? sub}) {
    if (num.isEmpty) return;
    final client = _client;
    if (client != null && !demoMode) {
      // iOS real mode: start through CallKit when attached (the
      // native screen appears at once; its dial action flows back
      // through the client, which reports accepted/failed). Without
      // CallKit, dial over the link directly.
      final kit = _callKit;
      if (kit != null) {
        unawaited(kit.startOutgoing(num, sub: sub));
      } else {
        unawaited(client.dial(num, sub: sub).then((result) {
          if (result['ok'] != true) {
            fail('شماره‌گیری انجام نشد');
          }
        }));
      }
      return;
    }
    final data = _data;
    if (data != null && !demoMode) {
      unawaited(data.dial(num, sub));
      return;
    }
    final cid = 'demo-${DateTime.now().millisecondsSinceEpoch}';
    final info = CallInfo(
      cid: cid,
      num: num,
      name: nameFor(num),
      state: 'dialing',
      dir: 'out',
      sub: sub,
      hold: true,
    );
    liveCalls[cid] = info;
    _callScreen = CallScreen(
      uuid: cid,
      num: num,
      name: nameFor(num),
      state: 'dialing',
      incoming: false,
      sub: sub,
    );
    _showCallScreen = true;
    notifyListeners();
    _later(const Duration(seconds: 2), () {
      if (liveCalls[cid]?.state == 'dialing') {
        final active = CallInfo(
          cid: cid,
          num: num,
          name: nameFor(num),
          state: 'active',
          dir: 'out',
          sub: sub,
          since: DateTime.now().millisecondsSinceEpoch,
          hold: true,
        );
        liveCalls[cid] = active;
        _callScreen = _callScreen?.copyWith(
          state: 'active',
          connectedAt: DateTime.now(),
        );
        notifyListeners();
      }
    });
  }

  /// Demo helper (and Link-tab debug button): a ringing incoming call.
  void simulateIncomingCall({required String number, String? name}) {
    final cid = 'demo-in-${DateTime.now().millisecondsSinceEpoch}';
    final info = CallInfo(
      cid: cid,
      num: number,
      name: name ?? nameFor(number),
      state: 'ringing',
      dir: 'in',
      hold: true,
    );
    liveCalls[cid] = info;
    _callScreen = CallScreen(
      uuid: cid,
      num: number,
      name: name ?? nameFor(number),
      state: 'ringing',
      incoming: true,
    );
    _showCallScreen = true;
    notifyListeners();
  }

  void answerCall(String cid) {
    final client = _client;
    if (client != null && !demoMode) {
      client.answer(cid);
      // The in-app screen answered: keep the native CallKit screen
      // in sync (user actions in CallKit flow back through the
      // client instead; Dart-initiated commands never echo).
      unawaited(_callKit?.answer(cid));
      return;
    }
    final data = _data;
    if (data != null && !demoMode) {
      unawaited(data.answerCall(cid));
      return;
    }
    final info = liveCalls[cid];
    if (info == null) return;
    final active = CallInfo(
      cid: info.cid,
      num: info.num,
      name: info.name,
      state: 'active',
      dir: info.dir,
      sub: info.sub,
      since: DateTime.now().millisecondsSinceEpoch,
      hold: true,
    );
    liveCalls[cid] = active;
    _callScreen = _callScreen?.copyWith(
      state: 'active',
      connectedAt: DateTime.now(),
    );
    notifyListeners();
  }

  void rejectCall(String cid) {
    final client = _client;
    if (client != null && !demoMode) {
      client.reject(cid);
      return;
    }
    final data = _data;
    if (data != null && !demoMode) {
      unawaited(data.rejectCall(cid));
      return;
    }
    _finishCall(cid, answered: false);
  }

  void endCall(String cid) {
    final client = _client;
    if (client != null && !demoMode) {
      client.end(cid);
      unawaited(_callKit?.end(cid));
      return;
    }
    final data = _data;
    if (data != null && !demoMode) {
      unawaited(data.endCall(cid));
      return;
    }
    _finishCall(cid, answered: true);
  }

  void _finishCall(String cid, {required bool answered}) {
    final info = liveCalls[cid];
    if (info == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final dur = answered && info.since != null
        ? (now - info.since!) ~/ 1000
        : 0;
    _recents.insert(
      0,
      CallEntry(
        id: (_recents.map((e) => e.id).fold<int>(0, (a, b) => a > b ? a : b)) + 1,
        num: info.num,
        name: info.name ?? nameFor(info.num),
        date: now,
        dur: dur,
        type: info.dir == 'in' ? (answered ? 1 : 3) : 2,
        sub: info.sub,
      ),
    );
    liveCalls.remove(cid);
    _callScreen = _callScreen?.copyWith(state: 'ended');
    notifyListeners();
    _later(const Duration(milliseconds: 900), () {
      if (_callScreen?.state == 'ended') _endScreen();
    });
  }

  void _endScreen() {
    _callScreen = null;
    _showCallScreen = false;
    notifyListeners();
  }

  void holdCall(String cid, bool on) {
    final client = _client;
    if (client != null && !demoMode) {
      client.hold(cid, on);
      unawaited(_callKit?.setHeld(cid, on));
      return;
    }
    final data = _data;
    if (data != null && !demoMode) {
      unawaited(data.holdCall(cid, on));
      return;
    }
    final info = liveCalls[cid];
    if (info == null) return;
    liveCalls[cid] = CallInfo(
      cid: info.cid,
      num: info.num,
      name: info.name,
      state: on ? 'holding' : 'active',
      dir: info.dir,
      sub: info.sub,
      since: info.since,
      hold: true,
    );
    _callScreen = _callScreen?.copyWith(
      state: on ? 'holding' : 'active',
      held: on,
    );
    notifyListeners();
  }

  void toggleHold() {
    final screen = _callScreen;
    if (screen == null) return;
    holdCall(screen.uuid, !screen.held);
  }

  void toggleMute() {
    final screen = _callScreen;
    if (screen == null) return;
    final on = !screen.muted;
    final client = _client;
    if (client != null && !demoMode) {
      // Muting tells the Android phone to mute the injected uplink,
      // and the native CallKit call to mute its microphone.
      client.mute(screen.uuid, on);
      unawaited(_callKit?.setMuted(screen.uuid, on));
    }
    // On Android the InCallService owns the microphone; the screen
    // state below is all the model tracks there.
    _callScreen = screen.copyWith(muted: on);
    notifyListeners();
  }

  void toggleSpeaker() {
    final screen = _callScreen;
    if (screen == null) return;
    final on = !screen.speaker;
    if (_client != null && !demoMode) {
      unawaited(_callKit?.setSpeaker(on));
    }
    _callScreen = screen.copyWith(speaker: on);
    notifyListeners();
  }

  void sendDtmf(String digit) {
    final screen = _callScreen;
    if (screen == null) return;
    final client = _client;
    if (client != null && !demoMode) {
      client.dtmf(screen.uuid, digit);
      unawaited(_callKit?.dtmf(screen.uuid, digit));
      return;
    }
    final data = _data;
    if (data != null && !demoMode) {
      unawaited(data.dtmf(screen.uuid, digit));
    }
  }

  /// Moves a call whose audio is on another client to this client.
  void takeCall(String cid) {
    final client = _client;
    if (client != null && !demoMode) {
      client.take(cid);
      unawaited(_callKit?.take(cid));
      return;
    }
    // On Android the audio is local by default; there is nothing to
    // take. (The Hub-side take is the iPhone's `call.take`.)
    final info = liveCalls[cid];
    if (info == null) return;
    liveCalls[cid] = CallInfo(
      cid: info.cid,
      num: info.num,
      name: info.name,
      state: info.state == 'ringing' ? 'ringing' : 'active',
      dir: info.dir,
      sub: info.sub,
      since: info.since ?? DateTime.now().millisecondsSinceEpoch,
      hold: true,
    );
    _callScreen = CallScreen(
      uuid: info.cid,
      num: info.num,
      name: info.name ?? nameFor(info.num),
      state: info.state == 'ringing' ? 'ringing' : 'active',
      incoming: info.dir == 'in',
      connectedAt: DateTime.now(),
      sub: info.sub,
    );
    _showCallScreen = true;
    notifyListeners();
  }

  // --- messages ------------------------------------------------------

  void sendSms(String address, String body, {int? thread}) {
    if (body.trim().isEmpty) return;
    final client = _client;
    if (client != null && !demoMode) {
      // Optimistic outbox copy (negative temp id): replaced by the
      // real message when it arrives via sync, dropped on failure.
      final now = DateTime.now().millisecondsSinceEpoch;
      final resolvedThread = thread ??
          _sms
              .where((m) => numberKey(m.addr) == numberKey(address))
              .map((m) => m.thread)
              .firstOrNull ??
          ((_sms.map((m) => m.thread).fold<int>(0, (a, b) => a > b ? a : b)) +
              1);
      final tempId = _nextTempId--;
      _sms.add(Sms(
        id: tempId,
        thread: resolvedThread,
        addr: address,
        body: body,
        date: now,
        box: 4,
        read: true,
      ));
      _outbox[tempId] = (address, body, now);
      notifyListeners();
      unawaited(client.sendSms(to: address, body: body).then((result) {
        final ok = result['ok'] == true;
        if (!ok) {
          _sms.removeWhere((m) => m.id == tempId);
          _outbox.remove(tempId);
          fail('پیام ارسال نشد');
        } else {
          final i = _sms.indexWhere((m) => m.id == tempId);
          if (i >= 0) {
            _sms[i] = Sms(
              id: tempId,
              thread: resolvedThread,
              addr: address,
              body: body,
              date: now,
              box: 2,
              read: true,
            );
          }
        }
        notifyListeners();
      }));
      return;
    }
    final data = _data;
    if (data != null && !demoMode) {
      final localId = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
      unawaited(data.sendSms(
        to: address,
        body: body,
        localId: localId,
      ));
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final resolvedThread = thread ??
        _sms
            .where((m) => numberKey(m.addr) == numberKey(address))
            .map((m) => m.thread)
            .firstOrNull ??
        ((_sms.map((m) => m.thread).fold<int>(0, (a, b) => a > b ? a : b)) + 1);
    final id = _sms.map((m) => m.id).fold<int>(0, (a, b) => a > b ? a : b) + 1;
    _sms.add(Sms(
      id: id,
      thread: resolvedThread,
      addr: address,
      body: body,
      date: now,
      box: 2,
      read: true,
    ));
    notifyListeners();
  }

  void markThreadRead(int thread) {
    final client = _client;
    final upTo = _sms
        .where((m) => m.thread == thread)
        .map((m) => m.id)
        .fold<int>(0, (a, b) => a > b ? a : b);
    readUpTo[thread] = upTo;
    if (client != null && !demoMode) {
      // Sent at once when connected; queued and flushed after the
      // next sync when offline (the client owns the queue).
      client.markThreadRead(thread, upTo);
      notifyListeners();
      return;
    }
    final data = _data;
    if (data != null && !demoMode) {
      unawaited(data.markSmsRead(thread, upTo));
    }
    notifyListeners();
  }

  // --- contacts ------------------------------------------------------

  void toggleStar(Contact contact) {
    final client = _client;
    final index = _contacts.indexWhere((c) => c.id == contact.id);
    if (index < 0) return;
    final updated = Contact(
      id: contact.id,
      name: contact.name,
      phones: contact.phones,
      emails: contact.emails,
      photo: contact.photo,
      starred: !contact.starred,
    );
    _contacts[index] = updated;
    if (client != null && !demoMode) {
      // Optimistic: reverted if the phone refuses.
      unawaited(client.starContact(contact.id, updated.starred).then((r) {
        if (r['ok'] != true) {
          _contacts[index] = contact;
          fail('تغییر ستاره انجام نشد');
          notifyListeners();
        }
      }));
      notifyListeners();
      return;
    }
    final data = _data;
    if (data != null && !demoMode) {
      unawaited(data.setContactStarred(contact.id, updated.starred));
    }
    notifyListeners();
  }

  // --- pairing / link -----------------------------------------------

  void pair(PairingCode code) {
    final client = _client;
    if (client != null && !demoMode) {
      // Real pairing: the QR code's token starts a pair-mode
      // handshake. Persistence happens in the client's `onPaired`
      // callback (wired in main.dart); the link state follows the
      // client's `applyLinkUp` / `applyLinkLost`.
      isPaired = true;
      peerName = code.deviceName;
      linkState = LinkState.connecting;
      notifyListeners();
      client.pair(code);
      return;
    }
    isPaired = true;
    peerName = code.deviceName;
    linkState = LinkState.connecting;
    notifyListeners();
    _later(const Duration(milliseconds: 1500), () {
      linkState = LinkState.connected;
      notifyListeners();
    });
  }

  void unpair() {
    AppLogger.i('app', 'unpair requested');
    final client = _client;
    if (client != null && !demoMode) {
      // Tells the Android phone to forget this iPhone, drops the
      // link and clears the peer; the client's `onUnpaired`
      // callback (wired in main.dart) persists the change.
      client.unpair();
      setUnpaired();
      return;
    }
    // On Android the peripheral forgets a central per central
    // (HubData.unpair, driven by the Hub when the iPhone unpairs);
    // there is no local "unpair all" action here.
    isPaired = false;
    linkState = LinkState.unpaired;
    liveCalls.clear();
    _callScreen = null;
    _showCallScreen = false;
    notifyListeners();
  }

  void setTransportMode(String mode) {
    if (transportMode == mode) return;
    AppLogger.i('app', 'transport mode -> $mode');
    transportMode = mode;
    // Real mode: the platform code swaps the client's transport
    // factory (BLE ↔ WebRTC) through this hook.
    onTransportModeChanged?.call(mode);
    notifyListeners();
  }

  /// Called when the user flips the transport switch in real mode:
  /// the platform code (main.dart) swaps the link's transport
  /// factory. Null in demo mode.
  void Function(String mode)? onTransportModeChanged;

  void setNet(String key, bool on,
      {int? sub, int? slot, String? mode}) {
    netState[key] = on;
    // Selection switches store their choice too, so the dropdown
    // shows the current value (`dataSub` → sub id, `rat` → mode).
    if (sub != null) netState['dataSub'] = sub;
    if (mode != null) netState['rat'] = mode;
    final client = _client;
    if (client != null && !demoMode) {
      // The reply (`net.state`) corrects the optimistic value
      // through applyNetState.
      unawaited(client.setNet({
        'what': key,
        'on': on,
        'sub': ?sub,
        'slot': ?slot,
        'mode': ?mode,
      }));
      notifyListeners();
      return;
    }
    final data = _data;
    if (data != null && !demoMode) {
      unawaited(
          data.netControl(what: key, on: on, sub: sub, slot: slot, mode: mode));
    }
    notifyListeners();
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _noticeTimer?.cancel();
    _localRecentsTimer?.cancel();
    _localSmsSub?.cancel();
    _localCallSub?.cancel();
    _setup?.removeListener(_onSetupChanged);
    _hub?.removeListener(_syncFromHub);
    _client?.dispose();
    super.dispose();
  }
}
