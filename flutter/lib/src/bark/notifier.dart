/// Far wake-up: pushes a Bark alert to the iPhone when a call or SMS
/// arrives while the link to it is down (far mode, iPhone app asleep).
///
/// Without a paid Apple Developer account there is no VoIP push, so
/// Bark is the free path's only way to reach a closed iPhone: the
/// user taps the alert, the bridge app opens through its URL scheme,
/// and the still-ringing call is answered over the link. A Bark push
/// cannot open the app or show the native call screen by itself —
/// that is the free path's known top risk, not something this class
/// can fix.
///
/// The device key arrives over the link (the iPhone sends its
/// `barkKey` in the `sync` client object; the Hub stores it here),
/// or is loaded from secure storage at startup ([loadStoredKey]).
library;

import 'dart:async';

import '../log/log.dart';
import '../protocol/messages.dart';
import 'client.dart';
import 'key_store.dart';

/// One push, as the notifier would send it (recorded in dry-run mode).
class BarkPush {
  const BarkPush({
    required this.title,
    required this.body,
    this.url,
    this.level = 'timeSensitive',
  });

  final String title;
  final String body;
  final String? url;
  final String level;
}

class FarWakeNotifier {
  FarWakeNotifier({
    BarkClient? client,
    BarkClient Function(String deviceKey)? clientFactory,
    BarkKeyStore? keyStore,
    this.callDedupe = const Duration(minutes: 10),
    this.smsDedupe = const Duration(seconds: 30),
    this.dryRun = false,
    this.appScheme = 'simbridge',
  }) : _clientFactory =
            clientFactory ?? ((key) => BarkClient(deviceKey: key)) {
    _client = client;
    _keyStore = keyStore;
  }

  /// The client a push goes through, or `null` when no device key is
  /// known yet (pushes are dropped until one arrives).
  BarkClient? get client => _client;
  BarkClient? _client;

  final BarkClient Function(String deviceKey) _clientFactory;
  BarkKeyStore? _keyStore;

  /// A call id is pushed at most once within this window (a call
  /// never rings this long, so effectively once per call).
  final Duration callDedupe;

  /// The same SMS delivered twice is pushed once within this window.
  final Duration smsDedupe;

  /// When true, pushes are recorded in [dryRunSent] instead of
  /// being sent. Used in tests (and by on-device self-tests).
  bool dryRun;

  /// The URL scheme the Bark notification opens (`simbridge://…`).
  /// The scheme must be registered in the iOS app's Info.plist —
  /// a native step, not done here.
  final String appScheme;

  /// Pushes recorded in dry-run mode, in order.
  final List<BarkPush> dryRunSent = [];

  final Map<String, DateTime> _recent = {};

  /// Restores the device key saved by an earlier run, if any.
  Future<void> loadStoredKey() async {
    final stored = await _keyStore?.read();
    if (stored != null && stored.isNotEmpty) setDeviceKey(stored);
  }

  /// Learns the iPhone's Bark device key (from the link, or from the
  /// user). A no-op when the key is unchanged; the key is persisted
  /// to secure storage when one is configured.
  void setDeviceKey(String deviceKey) {
    if (_client?.deviceKey == deviceKey) return;
    _client = _clientFactory(deviceKey);
    unawaited(_keyStore?.write(deviceKey).catchError((_) {}));
  }

  /// A call is ringing and the iPhone link is down: wake it. Returns
  /// true when a push was sent (or recorded in dry-run mode). A
  /// ringing call is worth one retry: a missed push means a missed
  /// call, and the dedupe window keeps it from storming.
  Future<bool> notifyIncomingCall({
    required String cid,
    required String num,
    String? name,
  }) =>
      _notify(
        key: 'call:$cid',
        window: callDedupe,
        retries: 1,
        title: 'تماس ورودی',
        body: name ?? num,
        url: '$appScheme://call?cid=${Uri.encodeComponent(cid)}',
      );

  /// An SMS arrived and the iPhone link is down: forward it as a
  /// Bark alert (the message itself shows in the notification).
  /// Note: the SMS text travels through the Bark server — inherent
  /// to Bark, like any push fallback.
  Future<bool> notifySms(Sms sms) => _notify(
        key: 'sms:${sms.id}',
        window: smsDedupe,
        title: sms.addr,
        body: sms.body,
        url: '$appScheme://sms?thread=${sms.thread}',
      );

  Future<bool> _notify({
    required String key,
    required Duration window,
    required String title,
    required String body,
    String? url,
    int retries = 0,
  }) async {
    final now = DateTime.now();
    final last = _recent[key];
    if (last != null && now.difference(last) < window) return false;
    // No client yet: do not burn the dedupe window — the key may
    // still arrive (over the next sync) while the call is ringing.
    // Dry-run mode is the exception: tests record pushes with no key.
    if (!dryRun && _client == null) return false;
    _recent[key] = now;
    _prune(now);
    final push = BarkPush(title: title, body: body, url: url);
    if (dryRun) {
      dryRunSent.add(push);
      return true;
    }
    final result = await _client!.push(
      title: title,
      body: body,
      url: url,
      retries: retries,
    );
    AppLogger.i('bark', 'push $key ok=${result.ok}');
    return result.ok;
  }

  void _prune(DateTime now) {
    final longest = callDedupe > smsDedupe ? callDedupe : smsDedupe;
    final cutoff = now.subtract(longest);
    _recent.removeWhere((_, at) => at.isBefore(cutoff));
  }
}
