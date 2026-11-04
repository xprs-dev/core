/*
 * The OS keychain, as the core uses it: a few small secrets (a profile's
 * device password, its unlock cache) by key. The app backs it with
 * flutter_secure_storage (Android Keystore, Keychain, libsecret). The default
 * keeps nothing, so a profile without a keychain asks for its password, which
 * is the safe failure.
 */

abstract interface class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// No keychain: reads find nothing, writes are dropped.
class NoSecureStore implements SecureStore {
  const NoSecureStore();
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}
