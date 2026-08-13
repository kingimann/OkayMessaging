import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What a parent can turn off. Each id names a surface the gate really
/// covers — nothing is listed here that the app cannot actually block.
enum ParentalRestriction {
  /// Wallet, Send money, tips, paying a request — every path CASH money
  /// leaves by. Enforced at the screens AND inside the one send funnel
  /// (`PaymentService.sendMoney`/`payFromWallet`/`addMoney`/
  /// `topUpCheckoutUrl`), so a surface added later is still caught. Honest
  /// gap, stated rather than hidden: a Spark (bitcoin over Lightning) never
  /// touches that funnel at all — it hands an invoice straight to the
  /// sender's own connected wallet — so this toggle does not yet block a
  /// Lightning send.
  payments,

  /// The marketplace: buying, selling and listings.
  marketplace,

  /// The public newsfeed — the one surface where strangers' posts are
  /// world-readable by design.
  publicFeed,

  /// Servers: community channels, feeds and forums.
  servers,
}

/// Device-level parental controls behind a parent's own PIN.
///
/// The PIN is the parent's, deliberately separate from the app PIN and every
/// chat password: those keep strangers out of the owner's data, this keeps
/// the phone's OWNER out of chosen surfaces. Stored as a salted SHA-256 hash
/// (the two-step pattern); guessing is throttled the same way sign-in is.
/// Everything is local — which controls a family uses is nobody's business,
/// so nothing here touches a server.
class ParentalControls extends ChangeNotifier {
  ParentalControls._();
  static final ParentalControls instance = ParentalControls._();

  static const _kHash = 'parental_hash_v1';
  static const _kSalt = 'parental_salt_v1';
  static const _kFlags = 'parental_flags_v1';
  static const _kFails = 'parental_fails_v1';
  static const _kLock = 'parental_lock_v1';

  /// Wrong guesses before the first cooldown — a gate a child can brute
  /// force is a sticker, not a gate.
  static const int maxAttempts = 5;

  SharedPreferences? _prefs;
  Set<ParentalRestriction> _blocked = {};
  int _fails = 0;
  DateTime? _lockUntil;

  /// Whether a parent PIN exists (controls are set up on this device).
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    enabled.value = prefs.getString(_kHash) != null;
    try {
      _blocked = ((jsonDecode(prefs.getString(_kFlags) ?? '[]') as List))
          .whereType<String>()
          .map((n) => ParentalRestriction.values.firstWhere(
              (r) => r.name == n,
              orElse: () => ParentalRestriction.payments))
          .toSet();
    } catch (_) {}
    _fails = prefs.getInt(_kFails) ?? 0;
    final lock = prefs.getString(_kLock);
    _lockUntil = lock == null ? null : DateTime.tryParse(lock);
    notifyListeners();
  }

  /// Whether [r] is currently turned off by a parent.
  bool blocks(ParentalRestriction r) =>
      enabled.value && _blocked.contains(r);

  /// The restrictions currently on, for the settings screen.
  Set<ParentalRestriction> get blocked => Set.unmodifiable(_blocked);

  static String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt|$pin')).toString();

  /// A parent PIN is 4–6 digits — same shape as the recovery PIN, so the
  /// rule is one sentence everywhere.
  static bool isValidPin(String pin) => RegExp(r'^\d{4,6}$').hasMatch(pin);

  /// Sets (or changes) the parent PIN.
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
    notifyListeners();
  }

  /// How much longer guessing is refused, or zero when it isn't.
  Duration get lockedFor {
    final until = _lockUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Verifies the parent PIN, with the same escalating cooldown as the
  /// two-step sign-in PIN: after [maxAttempts] misses, 30s doubling to a
  /// 5-minute cap, during which even the right PIN is refused.
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

  /// Turns [r] on or off. The settings screen only reaches this after the
  /// PIN check — the store trusts its one caller because the alternative is
  /// every toggle carrying a PIN argument it cannot verify twice.
  Future<void> setBlocked(ParentalRestriction r, bool blocked) async {
    if (blocked) {
      _blocked.add(r);
    } else {
      _blocked.remove(r);
    }
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(
        _kFlags, jsonEncode([for (final b in _blocked) b.name]));
    notifyListeners();
  }

  /// Removes the PIN and every restriction.
  Future<void> disable() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    for (final k in [_kHash, _kSalt, _kFlags, _kFails, _kLock]) {
      await prefs.remove(k);
    }
    _blocked = {};
    _fails = 0;
    _lockUntil = null;
    enabled.value = false;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _blocked = {};
    _fails = 0;
    _lockUntil = null;
    enabled.value = false;
    _prefs = null;
    notifyListeners();
  }
}
