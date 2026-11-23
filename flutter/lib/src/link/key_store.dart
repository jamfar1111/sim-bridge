/// Long-term identity and pairing storage.
///
/// Mirrors Tether's Android `link/Keys.kt`: the static P-256 key pair
/// lives in secure storage (Keychain on iOS, EncryptedSharedPreferences
/// on Android — via `flutter_secure_storage`), the paired centrals are
/// a JSON list, and pairing tokens follow the protocol rules
/// (protocol §1/§3):
///
/// - a pairing code is open for 5 minutes and one use;
/// - a pair-mode HELLO repeated by the same central within 10 minutes
///   of a completed pairing is accepted with that pairing's token
///   (the central may have lost our FIN).
///
/// The store is loaded once with [init] (generating the own key when
/// there is none); after that the accessors are synchronous and the
/// writes persist in the background.
library;

import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../protocol/bytes.dart';
import '../protocol/crypto.dart';

/// Storage backend, so tests can use memory instead of the Keychain.
abstract class KeyStoreBackend {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// Secure storage (Keychain / EncryptedSharedPreferences).
class SecureKeyStoreBackend implements KeyStoreBackend {
  SecureKeyStoreBackend({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory backend (tests, demo mode).
class MemoryKeyStoreBackend implements KeyStoreBackend {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

/// The paired peer (peripheral) this central is paired with.
class PairedPeer {
  const PairedPeer(this.key, this.name);

  /// The peripheral's long-term static public key (65 bytes).
  final List<int> key;

  final String name;
}

class KeyStore {
  KeyStore({KeyStoreBackend? backend})
      : _backend = backend ?? SecureKeyStoreBackend();

  final KeyStoreBackend _backend;

  /// A pairing code is open for 5 minutes (protocol §3).
  static const Duration pairingTtl = Duration(minutes: 5);

  /// A pair-mode HELLO repeated by the same central within 10
  /// minutes of a completed pairing is accepted (protocol §1).
  static const Duration repeatGrace = Duration(minutes: 10);

  static const String _ownKey = 'sim_bridge_own_key';
  static const String _pairedKey = 'sim_bridge_paired';
  static const String _pairingKey = 'sim_bridge_pairing';
  static const String _lastPairingKey = 'sim_bridge_last_pairing';
  static const String _peerKey = 'sim_bridge_peer';
  static const String _signallingKey = 'sim_bridge_signalling_key';

  bool _loaded = false;

  late P256KeyPair _ownKeyPair;
  List<PairedCentral> _paired = [];
  List<int>? _openToken;
  DateTime? _openTokenCreatedAt;
  List<int>? _lastPairingCentral;
  List<int>? _lastPairingToken;
  DateTime? _lastPairingCompletedAt;

  /// The signalling HMAC key: SHA-256 of the pairing token,
  /// persisted at pairing time (finding N6). Both phones derive
  /// the same key from the same token, so either side can
  /// authenticate signalling messages without ever sending the
  /// token itself. `null` until the first pairing.
  List<int>? _signallingKeyValue;

  List<int>? get signallingKey {
    _requireLoaded();
    return _signallingKeyValue;
  }

  /// Persists the signalling key derived from a pairing token.
  /// Called by the iPhone after pairing (it holds the token from
  /// the QR code until the handshake completes).
  Future<void> saveSignallingKey(List<int> token) async {
    _requireLoaded();
    _signallingKeyValue = P256.sha256([token]);
    await _backend.write(_signallingKey, b64url(_signallingKeyValue!));
  }
  PairedPeer? _peer;

  /// Loads (or generates) the own key and the stored pairing state.
  /// Call once at startup, before any accessor.
  Future<void> init() async {
    final own = await _backend.read(_ownKey);
    if (own != null) {
      final map = jsonDecode(own) as Map<String, dynamic>;
      _ownKeyPair = P256.keyPairFromScalar(
        unb64url(map['priv'] as String),
        unb64url(map['pub'] as String),
      );
    } else {
      _ownKeyPair = P256.generate();
      await _backend.write(
          _ownKey,
          jsonEncode({
            'priv': b64url(_ownKeyPair.privateScalar),
            'pub': b64url(_ownKeyPair.publicEncoded),
          }));
    }
    final paired = await _backend.read(_pairedKey);
    if (paired != null) {
      final list = jsonDecode(paired) as List;
      _paired = list
          .map((e) => PairedCentral(
                unb64url((e as Map)['key'] as String),
                name: e['name'] as String? ?? 'iPhone',
                kind: e['kind'] as String? ?? 'iphone',
              ))
          .toList();
    }
    final pairing = await _backend.read(_pairingKey);
    if (pairing != null) {
      final map = jsonDecode(pairing) as Map<String, dynamic>;
      _openToken = unb64url(map['token'] as String);
      _openTokenCreatedAt =
          DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int);
    }
    final last = await _backend.read(_lastPairingKey);
    if (last != null) {
      final map = jsonDecode(last) as Map<String, dynamic>;
      _lastPairingCentral = unb64url(map['key'] as String);
      _lastPairingToken = unb64url(map['token'] as String);
      _lastPairingCompletedAt =
          DateTime.fromMillisecondsSinceEpoch(map['completedAt'] as int);
    }
    final peer = await _backend.read(_peerKey);
    if (peer != null) {
      final map = jsonDecode(peer) as Map<String, dynamic>;
      _peer = PairedPeer(
        unb64url(map['key'] as String),
        map['name'] as String? ?? 'Android',
      );
    }
    final signalling = await _backend.read(_signallingKey);
    if (signalling != null) {
      try {
        _signallingKeyValue = unb64url(signalling);
      } catch (_) {
        _signallingKeyValue = null;
      }
    }
    _loaded = true;
  }

  void _requireLoaded() {
    if (!_loaded) throw StateError('KeyStore.init() not called');
  }

  /// This phone's long-term static P-256 key pair.
  P256KeyPair get ownKey {
    _requireLoaded();
    return _ownKeyPair;
  }

  /// Centrals already paired with this phone.
  List<PairedCentral> get pairedCentrals {
    _requireLoaded();
    return List.unmodifiable(_paired);
  }

  bool get isPaired {
    _requireLoaded();
    return _paired.isNotEmpty;
  }

  /// Adds (or renames) a paired central. Pairing a second device
  /// never forgets the first.
  Future<void> addPairedCentral(PairedCentral central) async {
    _requireLoaded();
    _paired = [
      ..._paired.where((c) => !c.matches(central.staticKey)),
      central,
    ];
    await _savePaired();
  }

  /// Forgets a paired central.
  Future<void> removePairedCentral(List<int> key) async {
    _requireLoaded();
    _paired = _paired.where((c) => !c.matches(key)).toList();
    await _savePaired();
  }

  Future<void> clearPairedCentrals() async {
    _requireLoaded();
    _paired = [];
    await _savePaired();
  }

  Future<void> _savePaired() => _backend.write(
      _pairedKey,
      jsonEncode(_paired
          .map((c) => {
                'key': b64url(c.staticKey),
                'name': c.name,
                'kind': c.kind,
              })
          .toList()));

  /// Opens pairing: a fresh 16-byte token, valid 5 minutes, one use.
  /// Returns the QR code to show on the Android phone.
  Future<PairingCode> openPairing(String deviceName) async {
    _requireLoaded();
    final token = P256.randomNonce();
    _openToken = token;
    _openTokenCreatedAt = DateTime.now();
    await _backend.write(
        _pairingKey,
        jsonEncode({
          'token': b64url(token),
          'createdAt': _openTokenCreatedAt!.millisecondsSinceEpoch,
        }));
    return PairingCode(_ownKeyPair.publicEncoded, token, deviceName);
  }

  /// The open pairing token, or `null` when pairing is closed or
  /// the token expired.
  List<int>? get currentToken {
    _requireLoaded();
    if (_openToken == null || _openTokenCreatedAt == null) return null;
    if (DateTime.now().difference(_openTokenCreatedAt!) > pairingTtl) {
      return null;
    }
    return _openToken;
  }

  /// Closes pairing (the code is used up or expired).
  Future<void> closePairing() async {
    _requireLoaded();
    _openToken = null;
    _openTokenCreatedAt = null;
    await _backend.delete(_pairingKey);
  }

  /// A pairing completed: the code is closed, but the same central
  /// may repeat its pair HELLO for 10 minutes (it may have lost
  /// our FIN).
  Future<void> completePairing(List<int> centralKey) async {
    _requireLoaded();
    final token = currentToken;
    if (token != null) {
      _lastPairingCentral = List<int>.of(centralKey);
      _lastPairingToken = List<int>.of(token);
      _lastPairingCompletedAt = DateTime.now();
      await _backend.write(
          _lastPairingKey,
          jsonEncode({
            'key': b64url(centralKey),
            'token': b64url(token),
            'completedAt': _lastPairingCompletedAt!.millisecondsSinceEpoch,
          }));
      // The same token seeds the signalling HMAC key (finding N6):
      // from now on this phone authenticates signalling messages.
      _signallingKeyValue = P256.sha256([token]);
      await _backend.write(_signallingKey, b64url(_signallingKeyValue!));
    }
    await closePairing();
  }

  /// The token a pair-mode HELLO from [centralKey] must prove: the
  /// open pairing code's, or, for 10 minutes after a pairing
  /// completed, that pairing's token for the same central only.
  List<int>? tokenFor(List<int> centralKey) {
    _requireLoaded();
    final open = currentToken;
    if (open != null) return open;
    if (_lastPairingCentral != null &&
        bytesEqual(_lastPairingCentral!, centralKey) &&
        _lastPairingToken != null &&
        _lastPairingCompletedAt != null &&
        DateTime.now().difference(_lastPairingCompletedAt!) < repeatGrace) {
      return _lastPairingToken;
    }
    return null;
  }

  /// The peripheral this central is paired with, or `null` when
  /// unpaired.
  PairedPeer? get peer {
    _requireLoaded();
    return _peer;
  }

  /// Remembers the paired peripheral.
  Future<void> savePeer(List<int> key, String name) async {
    _requireLoaded();
    _peer = PairedPeer(List<int>.of(key), name);
    await _backend.write(
        _peerKey,
        jsonEncode({'key': b64url(key), 'name': name}));
  }

  /// Forgets the paired peripheral.
  Future<void> clearPeer() async {
    _requireLoaded();
    _peer = null;
    await _backend.delete(_peerKey);
  }

  /// Forgets everything (unpair + fresh identity on next init).
  /// The identity itself is forgotten too: a fresh key pair is
  /// generated and persisted at once, so the in-memory state
  /// matches the doc instead of keeping the old key (finding N8).
  Future<void> clearAll() async {
    _requireLoaded();
    _paired = [];
    _openToken = null;
    _openTokenCreatedAt = null;
    _lastPairingCentral = null;
    _lastPairingToken = null;
    _lastPairingCompletedAt = null;
    _peer = null;
    _signallingKeyValue = null;
    await _backend.delete(_pairedKey);
    await _backend.delete(_pairingKey);
    await _backend.delete(_lastPairingKey);
    await _backend.delete(_peerKey);
    await _backend.delete(_signallingKey);
    _ownKeyPair = P256.generate();
    await _backend.write(
        _ownKey,
        jsonEncode({
          'priv': b64url(_ownKeyPair.privateScalar),
          'pub': b64url(_ownKeyPair.publicEncoded),
        }));
  }
}
