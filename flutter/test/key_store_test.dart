// Tests for the key store: own key persistence, paired centrals,
// pairing tokens (5-minute TTL, 10-minute repeat grace), peer memory.
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/link/key_store.dart';
import 'package:sim_bridge/src/protocol/protocol.dart';

void main() {
  group('KeyStore', () {
    late KeyStore keys;

    setUp(() async {
      keys = KeyStore(backend: MemoryKeyStoreBackend());
      await keys.init();
    });

    test('generates and persists the own key', () async {
      final first = keys.ownKey;
      expect(first.publicEncoded, hasLength(65));
      expect(first.publicEncoded.first, 0x04);
      // A second store over the same backend loads the same key.
      final again = KeyStore(backend: MemoryKeyStoreBackend());
      // (fresh backend: a different key — the point is init works)
      await again.init();
      expect(again.ownKey.publicEncoded, hasLength(65));
    });

    test('own key survives a reload over the same backend', () async {
      final backend = MemoryKeyStoreBackend();
      final a = KeyStore(backend: backend);
      await a.init();
      final b = KeyStore(backend: backend);
      await b.init();
      expect(b.ownKey.publicEncoded, a.ownKey.publicEncoded);
      expect(b.ownKey.privateScalar, a.ownKey.privateScalar);
    });

    test('paired centrals accumulate and are forgotten one by one',
        () async {
      final k1 = P256.generate().publicEncoded;
      final k2 = P256.generate().publicEncoded;
      expect(keys.isPaired, isFalse);
      await keys.addPairedCentral(PairedCentral(k1, name: 'iPhone'));
      await keys.addPairedCentral(
          PairedCentral(k2, name: 'iPad', kind: 'ipad'));
      expect(keys.isPaired, isTrue);
      expect(keys.pairedCentrals, hasLength(2));
      // Re-adding renames, never duplicates (the renamed entry moves
      // to the end, like Tether's Keys.save).
      await keys.addPairedCentral(
          PairedCentral(k1, name: 'iPhone 17', kind: 'iphone'));
      expect(keys.pairedCentrals, hasLength(2));
      expect(
          keys.pairedCentrals
              .firstWhere((c) => c.matches(k1))
              .name,
          'iPhone 17');
      await keys.removePairedCentral(k1);
      expect(keys.pairedCentrals, hasLength(1));
      expect(keys.pairedCentrals.single.staticKey, k2);
      await keys.clearPairedCentrals();
      expect(keys.isPaired, isFalse);
    });

    test('open pairing token is valid, then closed', () async {
      final code = await keys.openPairing('Galaxy A52');
      expect(code.deviceName, 'Galaxy A52');
      expect(code.peripheralKey, keys.ownKey.publicEncoded);
      expect(code.token, hasLength(16));
      expect(keys.currentToken, code.token);
      expect(keys.tokenFor(P256.generate().publicEncoded),
          code.token); // any central, while open
      await keys.closePairing();
      expect(keys.currentToken, isNull);
      expect(keys.tokenFor(P256.generate().publicEncoded), isNull);
    });

    test('completed pairing grants a 10-minute repeat grace to the '
        'same central only', () async {
      final central = P256.generate().publicEncoded;
      final other = P256.generate().publicEncoded;
      final code = await keys.openPairing('Galaxy A52');
      await keys.completePairing(central);
      // Pairing is closed, but the same central may repeat its HELLO.
      expect(keys.currentToken, isNull);
      expect(keys.tokenFor(central), code.token);
      expect(keys.tokenFor(other), isNull);
    });

    test('peer is remembered and forgotten', () async {
      expect(keys.peer, isNull);
      final peerKey = P256.generate().publicEncoded;
      await keys.savePeer(peerKey, 'Galaxy A52');
      expect(keys.peer?.key, peerKey);
      expect(keys.peer?.name, 'Galaxy A52');
      await keys.clearPeer();
      expect(keys.peer, isNull);
    });

    test('signalling key derives from the pairing token (N6)', () async {
      final backend = MemoryKeyStoreBackend();
      final a = KeyStore(backend: backend);
      await a.init();
      expect(a.signallingKey, isNull);
      // iPhone side: save it from the token in the QR code.
      final token = P256.randomNonce();
      await a.saveSignallingKey(token);
      expect(a.signallingKey, P256.sha256([token]));
      // It survives a reload over the same backend.
      final b = KeyStore(backend: backend);
      await b.init();
      expect(b.signallingKey, P256.sha256([token]));
      // Android side: completing a pairing derives the same key
      // from the same token.
      final c = KeyStore(backend: MemoryKeyStoreBackend());
      await c.init();
      final code = await c.openPairing('Galaxy A52');
      await c.completePairing(P256.generate().publicEncoded);
      expect(c.signallingKey, P256.sha256([code.token]));
      // Clearing everything forgets it too.
      await a.clearAll();
      expect(a.signallingKey, isNull);
    });

    test('clearAll forgets the identity too (finding N8)', () async {
      final backend = MemoryKeyStoreBackend();
      final a = KeyStore(backend: backend);
      await a.init();
      final before = a.ownKey.publicEncoded;
      await a.addPairedCentral(
          PairedCentral(P256.generate().publicEncoded));
      await a.savePeer(P256.generate().publicEncoded, 'Galaxy A52');
      await a.clearAll();
      // The identity is fresh at once (not just on the next init).
      expect(a.ownKey.publicEncoded, isNot(before));
      expect(a.isPaired, isFalse);
      expect(a.peer, isNull);
      // ...and a reload over the same backend loads the new key.
      final b = KeyStore(backend: backend);
      await b.init();
      expect(b.ownKey.publicEncoded, a.ownKey.publicEncoded);
      expect(b.ownKey.privateScalar, a.ownKey.privateScalar);
    });

    test('accessors throw before init', () {
      final fresh = KeyStore(backend: MemoryKeyStoreBackend());
      expect(() => fresh.ownKey, throwsStateError);
      expect(() => fresh.pairedCentrals, throwsStateError);
    });
  });
}
