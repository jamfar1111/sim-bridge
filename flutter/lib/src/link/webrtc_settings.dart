/// Persistence for the WebRTC settings (finding N3): the Cloudflare
/// Worker signalling URL and the TURN credentials. The URL is not
/// secret (shared preferences); the TURN credentials are (secure
/// storage) and expire after 24 hours, so the Link tab can fetch
/// fresh ones from the Cloudflare API.
library;

import 'dart:convert' show jsonDecode, utf8;
import 'dart:io' show HttpClient, HttpException, HttpHeaders;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the WebRTC settings. The URL and the credentials are
/// separate calls so a test can fake one without the other.
abstract class WebrtcSettingsStore {
  Future<String?> readSignallingUrl();
  Future<void> writeSignallingUrl(String url);

  /// The TURN username + credential, or `null` when not set.
  Future<(String, String)?> readTurnCredentials();
  Future<void> writeTurnCredentials(String username, String credential);
  Future<void> clearTurnCredentials();
}

/// In-memory store (tests).
class MemoryWebrtcSettingsStore implements WebrtcSettingsStore {
  String? _url;
  (String, String)? _turn;

  @override
  Future<String?> readSignallingUrl() async => _url;

  @override
  Future<void> writeSignallingUrl(String url) async {
    _url = url;
  }

  @override
  Future<(String, String)?> readTurnCredentials() async => _turn;

  @override
  Future<void> writeTurnCredentials(String username, String credential) async {
    _turn = (username, credential);
  }

  @override
  Future<void> clearTurnCredentials() async {
    _turn = null;
  }
}

/// Production store: the signalling URL in shared preferences, the
/// TURN credentials in secure storage (they are secrets).
class SharedPrefsWebrtcSettingsStore implements WebrtcSettingsStore {
  SharedPrefsWebrtcSettingsStore({
    SharedPreferencesAsync? prefs,
    FlutterSecureStorage? storage,
  })  : _prefs = prefs ?? SharedPreferencesAsync(),
        _storage = storage ?? const FlutterSecureStorage();

  static const String urlKey = 'sim_bridge_signalling_url';
  static const String turnUsernameKey = 'sim_bridge_turn_username';
  static const String turnCredentialKey = 'sim_bridge_turn_credential';

  final SharedPreferencesAsync _prefs;
  final FlutterSecureStorage _storage;

  @override
  Future<String?> readSignallingUrl() => _prefs.getString(urlKey);

  @override
  Future<void> writeSignallingUrl(String url) =>
      _prefs.setString(urlKey, url);

  @override
  Future<(String, String)?> readTurnCredentials() async {
    final username = await _storage.read(key: turnUsernameKey);
    final credential = await _storage.read(key: turnCredentialKey);
    if (username == null || credential == null) return null;
    return (username, credential);
  }

  @override
  Future<void> writeTurnCredentials(String username, String credential) async {
    await _storage.write(key: turnUsernameKey, value: username);
    await _storage.write(key: turnCredentialKey, value: credential);
  }

  @override
  Future<void> clearTurnCredentials() async {
    await _storage.delete(key: turnUsernameKey);
    await _storage.delete(key: turnCredentialKey);
  }
}

/// Fetches fresh TURN credentials from the Cloudflare API.
///
/// The credentials last 24 hours, so the Link tab has a button for
/// this: the user pastes their Cloudflare API token (created at
/// dash.cloudflare.com with the "Turn" permission) and their TURN
/// key id. The token is **never persisted**: it is only used for
/// this one call, then dropped. The returned username + credential
/// are stored in secure storage by the caller.
abstract final class CloudflareTurn {
  static Future<(String, String)> fetch({
    required String apiToken,
    required String keyId,
    Uri? baseUri, // tests only: point at a local stub server
    HttpClient? client,
  }) async {
    final base = baseUri ?? Uri.parse('https://rtc.live.cloudflare.com');
    final uri = base.resolve(
        '/v1/turn/keys/$keyId/credentials/generate-ice-servers');
    final http = client ?? HttpClient();
    try {
      final request = await http.postUrl(uri);
      request.headers
          .set(HttpHeaders.authorizationHeader, 'Bearer $apiToken');
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.write('{}');
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) {
        throw HttpException(
            'TURN credentials ${response.statusCode}: $text');
      }
      final decoded = jsonDecode(text);
      final result = decoded is Map<String, dynamic>
          ? (decoded['result'] as Map<String, dynamic>?) ?? decoded
          : null;
      final servers = result?['iceServers'];
      if (servers is List) {
        for (final server in servers) {
          if (server is Map<String, dynamic>) {
            final username = server['username'];
            final credential = server['credential'];
            if (username is String && credential is String) {
              return (username, credential);
            }
          }
        }
      }
      throw const FormatException('no TURN iceServers in the response');
    } finally {
      if (client == null) http.close();
    }
  }
}
