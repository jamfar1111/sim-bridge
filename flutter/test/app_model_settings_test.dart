// Model-level tests for the Bark setup flow (finding N1) and the
// WebRTC settings (finding N3): persistence through the stores and
// the static `WebrtcSettings` the transports read.
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/bark/bark.dart';
import 'package:sim_bridge/src/link/link.dart';
import 'package:sim_bridge/src/ui/ui.dart';

void main() {
  group('AppModel Bark key (N1)', () {
    test('save persists the key and clears it again', () async {
      final model = AppModel.real();
      final store = InMemoryBarkKeyStore();
      await model.attachBarkKeyStore(store);
      expect(model.barkKey, isNull);
      expect(model.hasBarkKey, isFalse);
      await model.saveBarkKey('  bark-key-123  ');
      expect(model.barkKey, 'bark-key-123');
      expect(await store.read(), 'bark-key-123');
      expect(model.hasBarkKey, isTrue);
      // A blank key is ignored, not saved.
      await model.saveBarkKey('   ');
      expect(model.barkKey, 'bark-key-123');
      await model.clearBarkKey();
      expect(model.barkKey, isNull);
      expect(await store.read(), isNull);
      expect(model.hasBarkKey, isFalse);
    });

    test('attach loads the saved key', () async {
      final store = InMemoryBarkKeyStore();
      await store.write('saved-key');
      final model = AppModel.real();
      await model.attachBarkKeyStore(store);
      expect(model.barkKey, 'saved-key');
    });
  });

  group('AppModel WebRTC settings (N3)', () {
    setUp(() {
      WebrtcSettings.signallingUrl = '';
      WebrtcSettings.turnUsername = null;
      WebrtcSettings.turnCredential = null;
    });

    tearDown(() {
      WebrtcSettings.signallingUrl = '';
      WebrtcSettings.turnUsername = null;
      WebrtcSettings.turnCredential = null;
    });

    test('save persists the URL and TURN credentials', () async {
      final model = AppModel.real();
      final store = MemoryWebrtcSettingsStore();
      await model.attachWebrtcSettingsStore(store);
      await model.saveSignallingUrl('https://x.workers.dev');
      expect(WebrtcSettings.signallingUrl, 'https://x.workers.dev');
      expect(await store.readSignallingUrl(), 'https://x.workers.dev');
      await model.saveTurnCredentials('u', 'c');
      expect(WebrtcSettings.turnUsername, 'u');
      expect(WebrtcSettings.turnCredential, 'c');
      expect(await store.readTurnCredentials(), ('u', 'c'));
      // Blank values clear the credentials.
      await model.saveTurnCredentials('', '');
      expect(WebrtcSettings.turnUsername, isNull);
      expect(WebrtcSettings.turnCredential, isNull);
      expect(await store.readTurnCredentials(), isNull);
    });

    test('attach loads persisted settings', () async {
      final store = MemoryWebrtcSettingsStore();
      await store.writeSignallingUrl('https://y.workers.dev');
      await store.writeTurnCredentials('u2', 'c2');
      final model = AppModel.real();
      await model.attachWebrtcSettingsStore(store);
      expect(WebrtcSettings.signallingUrl, 'https://y.workers.dev');
      expect(WebrtcSettings.turnUsername, 'u2');
      expect(WebrtcSettings.turnCredential, 'c2');
    });

    test('attach tolerates a failing store and keeps the model usable',
        () async {
      // Regression (2026-11-23): the manual build dropped
      // package:jni's PortContinuation, so the first read threw and
      // the whole wiring fell back to demo mode even though the link
      // service had started fine. A failing settings store must
      // never kill the link.
      final store = ThrowingWebrtcSettingsStore();
      final model = AppModel.real();
      await model.attachWebrtcSettingsStore(store);
      expect(WebrtcSettings.signallingUrl, '');
      expect(WebrtcSettings.turnUsername, isNull);
      expect(WebrtcSettings.turnCredential, isNull);
      // The store stays attached, so later saves still work.
      await model.saveSignallingUrl('https://z.workers.dev');
      expect(WebrtcSettings.signallingUrl, 'https://z.workers.dev');
      expect(store.writtenUrl, 'https://z.workers.dev');
    });

    test('one failing read does not block the other', () async {
      final store = _UrlThrowingWebrtcSettingsStore();
      await store.writeTurnCredentials('u3', 'c3');
      final model = AppModel.real();
      await model.attachWebrtcSettingsStore(store);
      expect(WebrtcSettings.signallingUrl, '');
      expect(WebrtcSettings.turnUsername, 'u3');
      expect(WebrtcSettings.turnCredential, 'c3');
    });
  });
}

/// A settings store whose reads fail (like the missing-JNI-class
/// failure on the phone) but whose writes work.
class ThrowingWebrtcSettingsStore implements WebrtcSettingsStore {
  String? writtenUrl;

  @override
  Future<String?> readSignallingUrl() async =>
      throw StateError('simulated read failure');

  @override
  Future<void> writeSignallingUrl(String url) async {
    writtenUrl = url;
  }

  @override
  Future<(String, String)?> readTurnCredentials() async =>
      throw StateError('simulated read failure');

  @override
  Future<void> writeTurnCredentials(String username, String credential) =>
      throw StateError('simulated read failure');

  @override
  Future<void> clearTurnCredentials() async {}
}

/// Reads the URL fail; TURN reads/writes work.
class _UrlThrowingWebrtcSettingsStore extends MemoryWebrtcSettingsStore {
  @override
  Future<String?> readSignallingUrl() async =>
      throw StateError('simulated URL read failure');
}
