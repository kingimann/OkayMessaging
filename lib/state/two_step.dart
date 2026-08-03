import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// WhatsApp-style **two-step verification**: an extra PIN required to sign in
/// on this device, with an optional recovery email. The PIN is never stored in
/// the clear — only a salted SHA-256 hash — so the stored value can't be
/// reversed. It persists across sign-out, so signing back in requires it.
class TwoStepVerification {
  TwoStepVerification._();
  static final TwoStepVerification instance = TwoStepVerification._();

  static const _kHash = 'twostep_hash_v1';
  static const _kSalt = 'twostep_salt_v1';
  static const _kEmail = 'twostep_email_v1';
  static const _kFails = 'twostep_fails_v1';
  static const _kLock = 'twostep_lock_v1';

  /// Wrong guesses before the first cooldown. A second factor that can be
  /// guessed at full speed is theatre: six digits fall to a script in
  /// minutes without this.
  static const int maxAttempts = 5;

  SharedPreferences? _prefs;

  /// Whether two-step verification is enabled (a PIN is set).
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  /// The recovery email address (empty when none set).
  String email = '';

  int _fails = 0;
  DateTime? _lockUntil;

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    enabled.value = prefs.getString(_kHash) != null;
    email = prefs.getString(_kEmail) ?? '';
    // Persisted so killing the app is not a way around the cooldown.
    _fails = prefs.getInt(_kFails) ?? 0;
    final lock = prefs.getString(_kLock);
    _lockUntil = lock == null ? null : DateTime.tryParse(lock);
  }

  /// How much longer guessing is refused, or zero when it isn't.
  Duration get lockedFor {
    final until = _lockUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Wrong guesses left before the next cooldown starts.
  int get attemptsLeft =>
      _fails >= maxAttempts ? 0 : maxAttempts - _fails;

  static String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt|$pin')).toString();

  /// A PIN is a 6-digit code.
  static bool isValidPin(String pin) => RegExp(r'^\d{6}$').hasMatch(pin);

  /// Sets (or changes) the PIN and, optionally, the recovery [recoveryEmail].
  Future<void> setPin(String pin, {String? recoveryEmail}) async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    var salt = prefs.getString(_kSalt);
    if (salt == null) {
      final rng = Random.secure();
      salt = base64.encode(List.generate(16, (_) => rng.nextInt(256)));
      await prefs.setString(_kSalt, salt);
    }
    await prefs.setString(_kHash, _hash(pin, salt));
    if (recoveryEmail != null) {
      email = recoveryEmail.trim();
      await prefs.setString(_kEmail, email);
    }
    enabled.value = true;
  }

  /// Updates just the recovery email.
  Future<void> setEmail(String recoveryEmail) async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    email = recoveryEmail.trim();
    await prefs.setString(_kEmail, email);
  }

  /// Verifies [pin] against the stored hash, counting wrong guesses.
  ///
  /// After [maxAttempts] wrong guesses a cooldown starts (30s, doubling per
  /// further miss, capped at 5 minutes), during which even the RIGHT PIN is
  /// refused — accepting it would let a guesser use the lock as an oracle.
  /// A correct PIN outside a cooldown clears the count.
  bool verify(String pin) {
    final prefs = _prefs;
    final hash = prefs?.getString(_kHash);
    final salt = prefs?.getString(_kSalt);
    if (hash == null || salt == null) return true; // nothing to verify
    if (lockedFor > Duration.zero) return false;
    if (_hash(pin, salt) == hash) {
      _fails = 0;
      _lockUntil = null;
      prefs?.remove(_kFails);
      prefs?.remove(_kLock);
      return true;
    }
    _fails += 1;
    prefs?.setInt(_kFails, _fails);
    if (_fails >= maxAttempts) {
      final over = _fails - maxAttempts;
      final seconds = 30 * (1 << (over > 4 ? 4 : over));
      final capped = seconds > 300 ? 300 : seconds;
      _lockUntil = DateTime.now().add(Duration(seconds: capped));
      prefs?.setString(_kLock, _lockUntil!.toIso8601String());
    }
    return false;
  }

  /// Turns two-step verification off and forgets the PIN and email.
  Future<void> disable() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.remove(_kHash);
    await prefs.remove(_kSalt);
    await prefs.remove(_kEmail);
    await prefs.remove(_kFails);
    await prefs.remove(_kLock);
    email = '';
    _fails = 0;
    _lockUntil = null;
    enabled.value = false;
  }

  @visibleForTesting
  void resetForTest() {
    enabled.value = false;
    email = '';
    _fails = 0;
    _lockUntil = null;
    _prefs = null;
  }
}
