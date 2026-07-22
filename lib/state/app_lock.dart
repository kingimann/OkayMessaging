import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An optional PIN lock for the whole app. The PIN is never stored in the
/// clear — only a salted SHA-256 hash is kept on the device, so the stored
/// value can't be reversed back into the PIN.
class AppLock {
  AppLock._();
  static final AppLock instance = AppLock._();

  static const _kHash = 'app_lock_hash_v1';
  static const _kSalt = 'app_lock_salt_v1';

  SharedPreferences? _prefs;

  /// Whether a PIN is set.
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  /// Whether the app is currently locked (a PIN is set and hasn't been entered
  /// this session). The root listens to this to show the lock screen.
  final ValueNotifier<bool> locked = ValueNotifier<bool>(false);

  /// Loads the lock state at startup. If a PIN is set, the app starts locked.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final has = prefs.getString(_kHash) != null;
    enabled.value = has;
    locked.value = has;
  }

  static String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt|$pin')).toString();

  /// Sets (or changes) the PIN and unlocks.
  Future<void> setPin(String pin) async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    var salt = prefs.getString(_kSalt);
    if (salt == null) {
      final rng = Random.secure();
      salt = base64.encode(List.generate(16, (_) => rng.nextInt(256)));
      await prefs.setString(_kSalt, salt);
    }
    await prefs.setString(_kHash, _hash(pin, salt));
    enabled.value = true;
    locked.value = false;
  }

  /// Verifies [pin]; on success, unlocks the app. Returns true when correct.
  bool unlock(String pin) {
    final prefs = _prefs;
    final hash = prefs?.getString(_kHash);
    final salt = prefs?.getString(_kSalt);
    if (hash == null || salt == null) {
      locked.value = false;
      return true;
    }
    final ok = _hash(pin, salt) == hash;
    if (ok) locked.value = false;
    return ok;
  }

  /// Removes the PIN entirely.
  Future<void> disable() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.remove(_kHash);
    await prefs.remove(_kSalt);
    enabled.value = false;
    locked.value = false;
  }

  @visibleForTesting
  void resetForTest() {
    enabled.value = false;
    locked.value = false;
    _prefs = null;
  }
}
