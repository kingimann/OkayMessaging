import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the crown jewels live: the iOS Keychain (Android Keystore), not
/// SharedPreferences. The difference is not cosmetic — NSUserDefaults is a
/// plist that rides device backups, so a private key kept there leaves the
/// phone every time the phone is backed up. Keychain items are encrypted by
/// hardware, readable only by this app, and stay on the device.
///
/// What belongs here: the identity private key, Double Ratchet sessions
/// (chain keys), and sender-key chains (chain roots + signing private
/// keys). What does not: peer PUBLIC keys, settings, chats — public or
/// bulky material gains nothing from keychain latency.
///
/// Falls back to SharedPreferences (under a `sec_` prefix) exactly where a
/// keychain does not exist: the web build (browser localStorage is the only
/// storage there is, and a key stored beside the data it protects adds
/// nothing) and widget tests (no platform channel). The fallback keeps one
/// code path everywhere rather than an #if per platform at every call site.
class SecureStore {
  SecureStore._();
  static final SecureStore instance = SecureStore._();

  static const _keychain = FlutterSecureStorage(
    // Readable after the first unlock, like Signal: message delivery in the
    // background needs the keys while the phone sits locked in a pocket.
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Flips to true the first time the keychain proves unusable, so one
  /// missing platform channel does not cost a try/catch on every call.
  bool _fallback = kIsWeb;

  /// Serializes writes: fire-and-forget callers may overlap, and two
  /// interleaved keychain writes to the same key can land in either order.
  Future<void> _chain = Future.value();

  Future<String?> read(String key) async {
    if (!_fallback) {
      try {
        return await _keychain.read(key: key);
      } catch (_) {
        _fallback = true;
      }
    }
    return (await SharedPreferences.getInstance()).getString('sec_$key');
  }

  Future<void> write(String key, String value) async {
    if (!_fallback) {
      try {
        await _keychain.write(key: key, value: value);
        return;
      } catch (_) {
        _fallback = true;
      }
    }
    await (await SharedPreferences.getInstance()).setString('sec_$key', value);
  }

  /// Fire-and-forget [write] for synchronous call sites (the ratchet
  /// persists on every message). Ordered, so the last call wins.
  void writeLater(String key, String value) {
    _chain = _chain.then((_) => write(key, value)).catchError((_) {});
  }

  Future<void> delete(String key) async {
    if (!_fallback) {
      try {
        await _keychain.delete(key: key);
        return;
      } catch (_) {
        _fallback = true;
      }
    }
    await (await SharedPreferences.getInstance()).remove('sec_$key');
  }

  /// Reads [key], migrating a value that predates the keychain: if only the
  /// old SharedPreferences entry exists, it is moved in and REMOVED from
  /// the plist — the whole point is that the next device backup no longer
  /// carries it.
  Future<String?> readMigrating(String key, String legacyPrefsKey) async {
    final current = await read(key);
    if (current != null) return current;
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(legacyPrefsKey);
    if (legacy == null) return null;
    await write(key, legacy);
    await prefs.remove(legacyPrefsKey);
    return legacy;
  }
}
