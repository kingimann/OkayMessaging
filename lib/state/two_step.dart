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

  SharedPreferences? _prefs;

  /// Whether two-step verification is enabled (a PIN is set).
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  /// The recovery email address (empty when none set).
  String email = '';

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    enabled.value = prefs.getString(_kHash) != null;
    email = prefs.getString(_kEmail) ?? '';
  }

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

  /// Verifies [pin] against the stored hash.
  bool verify(String pin) {
    final prefs = _prefs;
    final hash = prefs?.getString(_kHash);
    final salt = prefs?.getString(_kSalt);
    if (hash == null || salt == null) return true; // nothing to verify
    return _hash(pin, salt) == hash;
  }

  /// Turns two-step verification off and forgets the PIN and email.
  Future<void> disable() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.remove(_kHash);
    await prefs.remove(_kSalt);
    await prefs.remove(_kEmail);
    email = '';
    enabled.value = false;
  }

  @visibleForTesting
  void resetForTest() {
    enabled.value = false;
    email = '';
    _prefs = null;
  }
}
