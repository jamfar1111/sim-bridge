// Tests for the Bark push fallback (lib/src/bark/): the client,
// the device-key stores, and the far wake-up notifier. No native
// code, no Gradle: HTTP is faked through an injected poster, and
// secure storage through the test binding's binary messenger.
// Everything runs on the Dart VM.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/bark/bark.dart';
import 'package:sim_bridge/src/protocol/protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BarkClient', () {
    test('posts to {server}/push with device key, title, body, url',
        () async {
      final posted = <(Uri, Map<String, dynamic>)>[];
      Future<Map<String, dynamic>> poster(
              Uri uri, Map<String, dynamic> body) async {
        posted.add((uri, body));
        return {'code': 200, 'message': 'success'};
      }

      final client = BarkClient(deviceKey: 'dev-key-1', poster: poster);
      final result = await client.push(
        title: 'تماس ورودی',
        body: '+989121234567',
        url: 'simbridge://call?cid=c1',
      );

      expect(result.ok, isTrue);
      expect(result.code, 200);
      expect(posted, hasLength(1));
      expect(posted.single.$1.toString(), 'https://api.day.app/push');
      final body = posted.single.$2;
      expect(body['device_key'], 'dev-key-1');
      expect(body['title'], 'تماس ورودی');
      expect(body['body'], '+989121234567');
      expect(body['level'], 'timeSensitive');
      expect(body['url'], 'simbridge://call?cid=c1');
    });

    test('a self-hosted server replaces api.day.app', () async {
      Uri? seen;
      final client = BarkClient(
        deviceKey: 'k',
        server: Uri.parse('http://192.168.1.5:8080'),
        poster: (uri, _) async {
          seen = uri;
          return {'code': 200};
        },
      );
      await client.push(title: 't', body: 'b');
      expect(seen.toString(), 'http://192.168.1.5:8080/push');
    });

    test('a non-200 code fails with the server message', () async {
      final client = BarkClient(
        deviceKey: 'bad-key',
        poster: (_, _) async =>
            {'code': 400, 'message': 'invalid device key'},
      );
      final result = await client.push(title: 't', body: 'b');
      expect(result.ok, isFalse);
      expect(result.code, 400);
      expect(result.error, 'invalid device key');
    });

    test('push with retries succeeds on the retry', () async {
      var attempts = 0;
      final client = BarkClient(
        deviceKey: 'k',
        poster: (_, _) async {
          attempts++;
          return attempts == 1
              ? {'code': 500, 'message': 'down'}
              : {'code': 200};
        },
      );
      final result =
          await client.push(title: 't', body: 'b', retries: 1);
      expect(result.ok, isTrue);
      expect(attempts, 2);
    });

    test('a poster throwing fails instead of throwing', () async {
      final client = BarkClient(
        deviceKey: 'k',
        poster: (_, _) async => throw Exception('no network'),
      );
      final result = await client.push(title: 't', body: 'b');
      expect(result.ok, isFalse);
      expect(result.error, contains('no network'));
    });
  });

  group('FarWakeNotifier', () {
    BarkClient fakeClient(List<(Uri, Map<String, dynamic>)> posted,
            [String key = 'dev-key-1']) =>
        BarkClient(
          deviceKey: key,
          poster: (uri, body) async {
            posted.add((uri, body));
            return {'code': 200, 'message': 'success'};
          },
        );

    const ringing = (
      cid: 'c1',
      num: '+989121234567',
      name: 'سارا احمدی',
    );
    const sms = Sms(
      id: 42,
      thread: 7,
      addr: '+989121234567',
      body: 'سلام!',
      date: 1000,
      box: 1,
      read: false,
    );

    test('an incoming call pushes once, with caller and app URL',
        () async {
      final posted = <(Uri, Map<String, dynamic>)>[];
      final notifier =
          FarWakeNotifier(client: fakeClient(posted));
      final ok = await notifier.notifyIncomingCall(
          cid: ringing.cid, num: ringing.num, name: ringing.name);

      expect(ok, isTrue);
      expect(posted, hasLength(1));
      final body = posted.single.$2;
      expect(body['device_key'], 'dev-key-1');
      expect(body['title'], 'تماس ورودی');
      expect(body['body'], 'سارا احمدی');
      expect(body['url'], 'simbridge://call?cid=c1');
    });

    test('the same call is never pushed twice', () async {
      final posted = <(Uri, Map<String, dynamic>)>[];
      final notifier =
          FarWakeNotifier(client: fakeClient(posted));
      expect(
          await notifier.notifyIncomingCall(
              cid: 'c1', num: '+98912'),
          isTrue);
      // Re-reported ringing, a state change, a second Hub event —
      // still one push for this call.
      expect(
          await notifier.notifyIncomingCall(
              cid: 'c1', num: '+98912'),
          isFalse);
      expect(posted, hasLength(1));
      // A different call does push.
      expect(
          await notifier.notifyIncomingCall(
              cid: 'c2', num: '+98912'),
          isTrue);
      expect(posted, hasLength(2));
    });

    test('an SMS pushes with sender as title, once per message',
        () async {
      final posted = <(Uri, Map<String, dynamic>)>[];
      final notifier =
          FarWakeNotifier(client: fakeClient(posted));
      expect(await notifier.notifySms(sms), isTrue);
      expect(await notifier.notifySms(sms), isFalse);
      expect(posted, hasLength(1));
      final body = posted.single.$2;
      expect(body['title'], '+989121234567');
      expect(body['body'], 'سلام!');
      expect(body['url'], 'simbridge://sms?thread=7');
    });

    test('without a device key nothing is sent', () async {
      final posted = <(Uri, Map<String, dynamic>)>[];
      final notifier = FarWakeNotifier(
          clientFactory: (_) => fakeClient(posted));
      expect(
          await notifier.notifyIncomingCall(
              cid: 'c1', num: '+98912'),
          isFalse);
      expect(posted, isEmpty);
    });

    test('a call missed for want of a key still pushes once the key arrives',
        () async {
      final posted = <(Uri, Map<String, dynamic>)>[];
      final notifier = FarWakeNotifier(
          clientFactory: (_) => fakeClient(posted));
      expect(
          await notifier.notifyIncomingCall(
              cid: 'c1', num: '+98912'),
          isFalse);
      expect(posted, isEmpty);
      // The key arrives (over the next sync) while the call is still
      // ringing: the dedupe window was not burned, so the push goes out.
      notifier.setDeviceKey('learned-key');
      expect(
          await notifier.notifyIncomingCall(
              cid: 'c1', num: '+98912'),
          isTrue);
      expect(posted, hasLength(1));
    });

    test('dry-run records pushes and sends nothing', () async {
      final posted = <(Uri, Map<String, dynamic>)>[];
      final notifier = FarWakeNotifier(
        client: fakeClient(posted),
        dryRun: true,
      );
      expect(
          await notifier.notifyIncomingCall(
              cid: 'c1', num: '+98912', name: 'Ali'),
          isTrue);
      expect(await notifier.notifySms(sms), isTrue);
      expect(posted, isEmpty);
      expect(notifier.dryRunSent, hasLength(2));
      expect(notifier.dryRunSent[0].title, 'تماس ورودی');
      expect(notifier.dryRunSent[0].body, 'Ali');
      expect(notifier.dryRunSent[0].url, 'simbridge://call?cid=c1');
      expect(notifier.dryRunSent[1].title, '+989121234567');
      expect(notifier.dryRunSent[1].body, 'سلام!');
      // Dedupe still applies in dry-run mode.
      expect(
          await notifier.notifyIncomingCall(
              cid: 'c1', num: '+98912'),
          isFalse);
      expect(notifier.dryRunSent, hasLength(2));
    });

    test('a failed call push is retried once, then deduped', () async {
      var attempts = 0;
      final notifier = FarWakeNotifier(
        client: BarkClient(
          deviceKey: 'k',
          poster: (_, _) async {
            attempts++;
            return {'code': 500, 'message': 'down'};
          },
        ),
      );
      expect(
          await notifier.notifyIncomingCall(
              cid: 'c1', num: '+98912'),
          isFalse);
      expect(attempts, 2); // one try + one retry
      // No retry storm for the same ringing call.
      expect(
          await notifier.notifyIncomingCall(
              cid: 'c1', num: '+98912'),
          isFalse);
      expect(attempts, 2);
    });

    test('setDeviceKey rebuilds the client and persists the key',
        () async {
      final posted = <(Uri, Map<String, dynamic>)>[];
      final store = InMemoryBarkKeyStore();
      final notifier = FarWakeNotifier(
        clientFactory: (key) => fakeClient(posted, key),
        keyStore: store,
      );
      expect(notifier.client, isNull);
      notifier.setDeviceKey('learned-key');
      expect(notifier.client?.deviceKey, 'learned-key');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await store.read(), 'learned-key');
      // Unchanged key: no rebuild, no rewrite.
      final before = notifier.client;
      notifier.setDeviceKey('learned-key');
      expect(identical(notifier.client, before), isTrue);
      expect(
          await notifier.notifyIncomingCall(
              cid: 'c1', num: '+98912'),
          isTrue);
      expect(posted.single.$2['device_key'], 'learned-key');
    });

    test('loadStoredKey restores a key from an earlier run', () async {
      final store = InMemoryBarkKeyStore();
      await store.write('stored-key');
      final notifier = FarWakeNotifier(
        keyStore: store,
        clientFactory: (key) => BarkClient(
          deviceKey: key,
          poster: (_, _) async => {'code': 200},
        ),
      );
      await notifier.loadStoredKey();
      expect(notifier.client?.deviceKey, 'stored-key');
    });
  });

  group('BarkKeyStore', () {
    test('in-memory store round-trips', () async {
      final store = InMemoryBarkKeyStore();
      expect(await store.read(), isNull);
      await store.write('k1');
      expect(await store.read(), 'k1');
      await store.clear();
      expect(await store.read(), isNull);
    });

    test('secure store goes through the platform channel', () async {
      const channel =
          MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      final stored = <String, String>{};
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        final args = call.arguments as Map?;
        switch (call.method) {
          case 'write':
            stored[args!['key'] as String] = args['value'] as String;
            return null;
          case 'read':
            return stored[args!['key'] as String];
          case 'delete':
            stored.remove(args!['key'] as String);
            return null;
          default:
            return null;
        }
      });
      addTearDown(
          () => messenger.setMockMethodCallHandler(channel, null));

      final store = SecureBarkKeyStore();
      await store.write('secret-key');
      expect(await store.read(), 'secret-key');
      expect(
          calls.map((c) => c.method).toList(), ['write', 'read']);
      expect((calls[0].arguments as Map)['key'],
          SecureBarkKeyStore.storageKey);
      await store.clear();
      expect(await store.read(), isNull);
    });
  });
}
