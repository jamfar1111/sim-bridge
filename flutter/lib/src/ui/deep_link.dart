/// Handles `simbridge://…` deep links.
///
/// The Bark push fallback sends these URLs (see `FarWakeNotifier`):
/// tapping a Bark alert opens the bridge app through its URL scheme
/// (registered in `ios/Runner/Info.plist` as `CFBundleURLSchemes` —
/// finding 5: without it the tap cannot open the app at all), and
/// this handler routes the link to the right place:
///
/// - `simbridge://call?cid=…` — opens the call screen when that call
///   is live; otherwise a notice (the call may already be over).
/// - `simbridge://sms?thread=…` — opens that SMS thread.
///
/// Unknown schemes / hosts are ignored. The `app_links` plugin
/// delivers the links; the stream and the initial link are injected
/// so tests can drive this class without the plugin.
library;

import 'dart:async';

import 'package:app_links/app_links.dart';

import '../log/log.dart';
import 'app_model.dart';

class DeepLinkHandler {
  // The parameters only feed private fields (different names), so
  // initializing formals cannot be used here.
  // ignore: prefer_initializing_formals
  DeepLinkHandler(
    this.model, {
    AppLinks? appLinks,
    this._linkStream,
    this._initialLink,
  })  : _appLinks = appLinks ?? AppLinks();

  final AppModel model;
  final AppLinks _appLinks;
  final Stream<Uri>? _linkStream;
  final Future<Uri?> Function()? _initialLink;

  StreamSubscription<Uri>? _sub;

  /// Starts listening: the initial link (cold start from a tap) and
  /// every later link while the app runs.
  Future<void> start() async {
    final initial =
        await (_initialLink?.call() ?? _appLinks.getInitialLink());
    if (initial != null) handleUri(initial);
    _sub = (_linkStream ?? _appLinks.uriLinkStream)
        .listen(handleUri, onError: (_) {});
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// Routes one `simbridge://…` URI. Unknown schemes / hosts are
  /// ignored.
  void handleUri(Uri uri) {
    AppLogger.i('deeplink', 'received $uri');
    if (uri.scheme != 'simbridge') return;
    switch (uri.host) {
      case 'call':
        final cid = uri.queryParameters['cid'];
        if (cid != null && model.liveCalls.containsKey(cid)) {
          model.openCallScreen();
        } else {
          model.flash('تماس یافت نشد؛ شاید تمام شده باشد.');
        }
      case 'sms':
        final thread =
            int.tryParse(uri.queryParameters['thread'] ?? '');
        if (thread != null) {
          model.openThread(thread);
        } else {
          // An unparseable thread is not silently ignored (finding
          // N11): the user tapped a link that goes nowhere.
          model.flash('پیوند پیامک معتبر نیست.');
        }
    }
  }
}
