/// Bark push client: sends a push notification to an iPhone running
/// the Bark app, through the Bark server (default `api.day.app`, or a
/// self-hosted server).
///
/// Bark is the free-path fallback that wakes a closed iPhone app for
/// a far-apart call: without a paid Apple Developer account there is
/// no VoIP push, so a Bark alert is the only way to reach the user.
/// Tapping the notification opens the bridge app through its URL
/// scheme (`simbridge://…` — the scheme must be registered in the
/// iOS app's Info.plist; see `FarWakeNotifier`).
///
/// API: POST `{server}/push` with a JSON body
/// `{"device_key", "title", "body", "level", "url"?}`; the server
/// answers `{"code": 200, "message": "success", …}`. The `url` is
/// opened when the notification is tapped.
library;

import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:io' show ContentType, HttpClient;

/// Posts a JSON body to a URI and returns the decoded JSON response.
/// Injected in tests so no real HTTP happens.
typedef BarkPoster = Future<Map<String, dynamic>> Function(
    Uri uri, Map<String, dynamic> body);

/// The result of one Bark push.
class BarkResult {
  const BarkResult({required this.ok, this.code, this.error});

  final bool ok;

  /// The Bark server's `code` (200 on success).
  final int? code;

  /// Human-readable failure, or `null` on success.
  final String? error;
}

class BarkClient {
  BarkClient({
    required this.deviceKey,
    Uri? server,
    BarkPoster? poster,
    this.timeout = const Duration(seconds: 10),
  })  : server = server ?? Uri.parse('https://api.day.app'),
        _poster = poster ?? _postJson;

  /// The iPhone's Bark device key (from the Bark app's device key
  /// page). Anyone holding it can push to that phone — treat it like
  /// a credential: it is stored in secure storage, never logged.
  final String deviceKey;

  /// The Bark server: `https://api.day.app`, or a self-hosted one.
  final Uri server;

  final Duration timeout;
  final BarkPoster _poster;

  Uri get pushUri => server.resolve('/push');

  /// Sends one push. `level` is `active` (default), `timeSensitive`
  /// (breaks through Focus when allowed) or `critical` (needs a
  /// special entitlement — not used here). `url` is opened when the
  /// user taps the notification. `retries` re-sends after a failure
  /// (a transient server hiccup or brief offline): the call path
  /// passes 1, SMS stays at 0.
  Future<BarkResult> push({
    required String title,
    required String body,
    String? url,
    String level = 'timeSensitive',
    int retries = 0,
  }) async {
    final payload = <String, dynamic>{
      'device_key': deviceKey,
      'title': title,
      'body': body,
      'level': level,
      'url': ?url,
    };
    BarkResult? last;
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (attempt > 0) {
        // A short pause before retrying: hammering a struggling
        // server helps nobody.
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      try {
        final json = await _poster(pushUri, payload).timeout(timeout);
        final code = json['code'];
        if (code == 200) return const BarkResult(ok: true, code: 200);
        last = BarkResult(
          ok: false,
          code: code is int ? code : null,
          error: json['message']?.toString() ?? 'Bark error',
        );
      } on TimeoutException {
        last = const BarkResult(ok: false, error: 'timed out');
      } catch (e) {
        last = BarkResult(ok: false, error: e.toString());
      }
    }
    return last!;
  }

  /// Default poster: a plain `dart:io` HTTP client (no extra
  /// dependency). The response body must be JSON.
  static Future<Map<String, dynamic>> _postJson(
      Uri uri, Map<String, dynamic> body) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      return {'code': response.statusCode, 'message': text};
    } finally {
      client.close();
    }
  }
}
