import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The store exists here and could not be READ — as opposed to being read
/// and found empty.
///
/// The difference is the whole reason this type exists. `null` from [read]
/// means "there is no such value", which for the identity key means MINT A
/// NEW ONE — so answering null to a keychain that merely refused is how a
/// device silently changes identity, breaks every session it holds, and
/// tells every contact its security code changed.
class SecureUnavailable implements Exception {
  final Object cause;
  const SecureUnavailable(this.cause);
  @override
  String toString() => 'SecureUnavailable: $cause';
}

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

  /// Flips to true only where the keychain does not EXIST — the web build,
  /// and a widget test with no platform channel. That is what this flag was
  /// written for ("one missing platform channel does not cost a try/catch on
  /// every call") and it must not be flipped by anything else.
  ///
  /// It used to flip on ANY error, and that is what made a transient
  /// keychain refusal permanent for the rest of the run: reads and writes
  /// moved to SharedPreferences, where the real key had never been written,
  /// so the app minted a fresh identity and saved it there — and the NEXT
  /// launch, reading the keychain successfully again, got the old key back.
  /// The identity flipped between two values depending on whether one read
  /// happened to succeed, which reads to every contact as a security code
  /// changing over and over, and to this device as messages sealed to a key
  /// it no longer has.
  ///
  /// `first_unlock` accessibility makes that refusal a real, ordinary event:
  /// the item is genuinely unreadable until the phone has been unlocked once
  /// since boot, and a push can wake this app before that.
  bool _fallback = kIsWeb;

  /// Whether [e] means the platform channel is not there at all, which is
  /// the only thing that should retire the keychain for this run. A
  /// PlatformException is the OPPOSITE: the keychain answered, and said no.
  static bool _channelMissing(Object e) =>
      e is MissingPluginException || e is UnimplementedError;

  @visibleForTesting
  static bool debugChannelMissing(Object e) => _channelMissing(e);

  /// Test seam: stands in for the keychain, so both failure shapes can be
  /// driven without a platform.
  @visibleForTesting
  static Future<String?> Function(String key)? debugRead;

  /// Puts the store back to how it starts, so one test's forced failure does
  /// not retire the keychain for every test after it.
  @visibleForTesting
  void resetForTest() {
    _fallback = kIsWeb;
    debugRead = null;
  }

  /// Serializes writes: fire-and-forget callers may overlap, and two
  /// interleaved keychain writes to the same key can land in either order.
  Future<void> _chain = Future.value();

  /// The value, or null when there genuinely is none.
  ///
  /// A store that cannot be reached at all THROWS [SecureUnavailable] rather
  /// than answering null — see that type for why answering null is worse
  /// than throwing. Callers that only cache something may catch it and carry
  /// on; the identity key must not.
  Future<String?> readOrThrow(String key) async {
    if (!_fallback) {
      try {
        final debug = debugRead;
        return await (debug != null ? debug(key) : _keychain.read(key: key));
      } catch (e) {
        if (!_channelMissing(e)) throw SecureUnavailable(e);
        _fallback = true;
      }
    }
    return (await SharedPreferences.getInstance()).getString('sec_$key');
  }

  /// [readOrThrow], with an unreachable store answering null.
  ///
  /// Kept for the callers where that really is harmless — a cached ratchet
  /// or a peer key re-derives — and deliberately NOT used for the identity
  /// key, which is the one place where null means "make a new one".
  Future<String?> read(String key) async {
    try {
      return await readOrThrow(key);
    } on SecureUnavailable {
      return null;
    }
  }

  Future<void> write(String key, String value) async {
    if (!_fallback) {
      try {
        await _keychain.write(key: key, value: value);
        return;
      } catch (e) {
        // Same rule as the read: a keychain that answered and refused must
        // not send every later write to a plist. Rethrown rather than
        // swallowed, so a caller storing something that matters can tell.
        if (!_channelMissing(e)) throw SecureUnavailable(e);
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
    // readOrThrow, not read: this is the identity key's path, and a store
    // that could not be reached must not come back as "there is none".
    final current = await readOrThrow(key);
    if (current != null) return current;
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(legacyPrefsKey);
    if (legacy == null) return null;
    await write(key, legacy);
    await prefs.remove(legacyPrefsKey);
    return legacy;
  }
}
