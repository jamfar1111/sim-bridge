/// Where the iPhone's Bark device key lives.
///
/// The key is a bearer credential (anyone holding it can push to the
/// phone), so it belongs in secure storage: iOS Keychain / Android
/// EncryptedSharedPreferences via `flutter_secure_storage`. The
/// in-memory store is for tests and for runs where secure storage is
/// unavailable.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class BarkKeyStore {
  /// The stored device key, or `null` when none was saved.
  Future<String?> read();

  /// Saves a device key.
  Future<void> write(String deviceKey);

  /// Forgets the stored key.
  Future<void> clear();
}

/// Volatile store: the key lives only for this run. Used in tests and
/// as a fallback when secure storage is unavailable.
class InMemoryBarkKeyStore implements BarkKeyStore {
  String? _key;

  @override
  Future<String?> read() async => _key;

  @override
  Future<void> write(String deviceKey) async {
    _key = deviceKey;
  }

  @override
  Future<void> clear() async {
    _key = null;
  }
}

/// Secure store: iOS Keychain / Android EncryptedSharedPreferences.
class SecureBarkKeyStore implements BarkKeyStore {
  SecureBarkKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// The key under which the Bark device key is stored.
  static const String storageKey = 'sim_bridge_bark_device_key';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: storageKey);

  @override
  Future<void> write(String deviceKey) =>
      _storage.write(key: storageKey, value: deviceKey);

  @override
  Future<void> clear() => _storage.delete(key: storageKey);
}
