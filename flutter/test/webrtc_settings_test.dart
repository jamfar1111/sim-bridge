// Tests for the WebRTC settings store (finding N3) and the
// Cloudflare TURN credential fetch — against a local HTTP server,
// never the real Cloudflare API.
import 'dart:convert' show jsonEncode;
import 'dart:io' show ContentType, HttpServer, InternetAddress;

import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/link/link.dart';

void main() {
  group('MemoryWebrtcSettingsStore', () {
    test('round-trips the URL and the TURN credentials', () async {
      final store = MemoryWebrtcSettingsStore();
      expect(await store.readSignallingUrl(), isNull);
      expect(await store.readTurnCredentials(), isNull);
      await store.writeSignallingUrl('https://x.workers.dev');
      await store.writeTurnCredentials('user', 'cred');
      expect(await store.readSignallingUrl(), 'https://x.workers.dev');
      expect(await store.readTurnCredentials(), ('user', 'cred'));
      await store.clearTurnCredentials();
      expect(await store.readTurnCredentials(), isNull);
      // Clearing the credentials keeps the URL.
      expect(await store.readSignallingUrl(), 'https://x.workers.dev');
    });
  });

  group('CloudflareTurn.fetch', () {
    test('parses the result.iceServers envelope', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      String? auth;
      server.listen((request) async {
        auth = request.headers.value('authorization');
        expect(request.method, 'POST');
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'success': true,
            'result': {
              'iceServers': [
                {
                  'urls': [
                    'turn:turn.cloudflare.com:3478?transport=udp',
                    'turns:turn.cloudflare.com:5349?transport=tcp',
                  ],
                  'username': 'fresh-user',
                  'credential': 'fresh-cred',
                },
              ],
            },
          }));
        await request.response.close();
      });
      final creds = await CloudflareTurn.fetch(
        apiToken: 'token-123',
        keyId: 'key-456',
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      expect(creds, ('fresh-user', 'fresh-cred'));
      expect(auth, 'Bearer token-123');
      await server.close();
    });

    test('parses a top-level iceServers list too', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'iceServers': [
              {'username': 'u2', 'credential': 'c2'},
            ],
          }));
        await request.response.close();
      });
      final creds = await CloudflareTurn.fetch(
        apiToken: 't',
        keyId: 'k',
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      expect(creds, ('u2', 'c2'));
      await server.close();
    });

    test('throws on an API error and on a missing iceServers list',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var calls = 0;
      server.listen((request) async {
        calls++;
        if (calls == 1) {
          request.response.statusCode = 403;
          request.response.write('forbidden');
          await request.response.close();
          return;
        }
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'success': true, 'result': {}}));
        await request.response.close();
      });
      final base = Uri.parse('http://127.0.0.1:${server.port}');
      await expectLater(
        CloudflareTurn.fetch(apiToken: 't', keyId: 'k', baseUri: base),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        CloudflareTurn.fetch(apiToken: 't', keyId: 'k', baseUri: base),
        throwsA(isA<FormatException>()),
      );
      await server.close();
    });
  });
}
