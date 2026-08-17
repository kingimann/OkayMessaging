import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stops a password being set back to one this account has already used —
/// or to an obvious variation on it.
///
/// **No password is ever stored, in any form that can be read back.** What is
/// kept is a PBKDF2-HMAC-SHA256 digest, the same derivation the chat lock and
/// the encrypted backup use, over a random per-account salt. A history file
/// somebody lifts off the device is a set of slow hashes, not a list of
/// passwords.
///
/// **Which is exactly why "anything similar" needs [skeletonOf].** You cannot
/// compare two hashes for similarity — that is the whole point of a hash. So
/// alongside the digest of the password AS TYPED, a second digest is kept of
/// a NORMALISED form: lowercased, common letter-for-symbol substitutions
/// folded back, everything that is not a letter or digit removed, and trailing
/// digits stripped. `Summer2024!` and `summer2025` both reduce to `summer`, so
/// the second is refused without either ever being written down.
///
/// The honest limits, stated rather than implied:
///
///  * It catches the variation people actually make — a counter on the end, a
///    symbol swapped in — not two unrelated passwords that happen to share a
///    stem.
///  * A skeleton shorter than [_minSkeleton] is not compared at all. `x1y2`
///    reduces to `xiy`, and matching on three letters would refuse half the
///    passwords somebody could pick next — so a password that short is caught
///    only by an EXACT repeat.
///  * It is per DEVICE. The history lives here, so a password reused from
///    another phone is not caught. Supabase holds the real password and offers
///    no history API; keeping one server-side would mean keeping more about
///    somebody's passwords than this app should.
class PasswordHistory {
  PasswordHistory._();
  static final PasswordHistory instance = PasswordHistory._();

  /// How many past passwords are remembered. Enough to stop a rotation
  /// through two or three favourites, short enough that the file is small
  /// and the check is bounded.
  static const int keep = 5;

  /// PBKDF2 rounds. The same cost the chat lock pays, for the same reason: a
  /// file lifted off the device must not be cheap to run a dictionary
  /// through.
  static const int rounds = 120000;

  /// A skeleton shorter than this is too generic to compare on.
  static const int _minSkeleton = 4;

  static const _kSalt = 'password_history_salt_v1';
  static const _kEntries = 'password_history_v1';

  /// Test seam: 120k rounds twice per check is a second of real work, and a
  /// suite that pays it in every password test takes minutes.
  @visibleForTesting
  static int? debugRounds;

  SharedPreferences? _prefs;
  String _salt = '';

  /// `[exactDigest, skeletonDigest]` per remembered password, newest first.
  /// The skeleton digest is empty for one whose skeleton was too short.
  List<List<String>> _entries = [];

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    _salt = prefs.getString(_kSalt) ?? '';
    if (_salt.isEmpty) {
      _salt = base64Url.encode(
          List<int>.generate(16, (_) => Random.secure().nextInt(256)));
      await prefs.setString(_kSalt, _salt);
    }
    _entries = [];
    final raw = prefs.getString(_kEntries);
    if (raw != null) {
      try {
        for (final e in jsonDecode(raw) as List) {
          if (e is List && e.length == 2) {
            _entries.add(['${e[0]}', '${e[1]}']);
          }
        }
      } catch (_) {
        // A corrupt file forgets the history rather than refusing every
        // password somebody tries — failing closed here would lock an account
        // out of its own password change.
      }
    }
  }

  /// The password reduced to what somebody would still recognise as "the same
  /// one" — pure, so the rule is testable without a store or a hash behind it.
  ///
  /// Two steps, and **the order is the whole thing**. Strip the decoration off
  /// the end FIRST: folding `0`→o before that would turn `2024` into `2o2a`
  /// and there would be no counter left to recognise. `Summer2024!` and
  /// `summer2025` both come out `summer`.
  static String skeletonOf(String password) {
    // Whatever is hung on the END is decoration — a year, a counter, a '!' —
    // and it is exactly what changes between one password and "that one
    // again".
    final trimmed =
        password.toLowerCase().replaceFirst(RegExp(r'[^a-z]+$'), '');

    // What is LEFT is a substitution only where it sits BETWEEN two letters:
    // the `0` in `passw0rd` is an o, the `0` in `2024summer` is a zero. The
    // same positional rule settles a symbol — the `@` in `P@ssword` stands in
    // for a letter; a `@` on the end would have been trimmed above.
    const folds = {
      '@': 'a',
      '4': 'a',
      '0': 'o',
      '1': 'i',
      '!': 'i',
      '3': 'e',
      '\$': 's',
      '5': 's',
      '7': 't',
      '+': 't',
    };
    final letter = RegExp(r'[a-z]');
    final keep = RegExp(r'[a-z0-9]');
    final chars = trimmed.split('');
    final buffer = StringBuffer();
    for (var i = 0; i < chars.length; i++) {
      final ch = chars[i];
      final folded = folds[ch];
      final between = i > 0 &&
          i < chars.length - 1 &&
          letter.hasMatch(chars[i - 1]) &&
          letter.hasMatch(chars[i + 1]);
      if (folded != null && between) {
        buffer.write(folded);
      } else if (keep.hasMatch(ch)) {
        buffer.write(ch);
      }
    }
    return buffer.toString();
  }

  /// Why [password] may not be used, or null when it is fine.
  ///
  /// Runs off the UI thread: two PBKDF2 derivations at [rounds] is real work,
  /// and a frozen screen mid-password is what the chat lock's own isolate hop
  /// exists to avoid. Two derivations regardless of how much history there is
  /// — one salt for the account means the candidate is hashed once and
  /// compared against every entry.
  Future<String?> problemFor(String password) async {
    if (_entries.isEmpty) return null;
    final digests = await _digests(password);
    final exact = digests[0];
    final skeleton = digests[1];
    for (final e in _entries) {
      if (_constantTimeEquals(e[0], exact)) {
        return 'You have used that password before. Pick one you have not '
            'used on this account.';
      }
      if (skeleton.isNotEmpty &&
          e[1].isNotEmpty &&
          _constantTimeEquals(e[1], skeleton)) {
        return 'That is too close to a password you have used before — '
            'changing the numbers or symbols on the end is not a new '
            'password. Pick something different.';
      }
    }
    return null;
  }

  /// Records [password] as used. Call only after the change actually landed:
  /// remembering one the server refused would refuse it again later for no
  /// reason.
  Future<void> remember(String password) async {
    // A password set before boot finished loading (or straight after an
    // account switch reset the handle) must still be recorded — otherwise it
    // lives only in memory and is offered back as new on the next launch.
    if (_prefs == null || _salt.isEmpty) await load();
    final digests = await _digests(password);
    _entries.insert(0, digests);
    if (_entries.length > keep) _entries = _entries.sublist(0, keep);
    await _prefs?.setString(_kEntries, jsonEncode(_entries));
  }

  Future<List<String>> _digests(String password) async {
    final skeleton = skeletonOf(password);
    final tooShort = skeleton.length < _minSkeleton;
    if (debugRounds != null) {
      return [
        hashFor(password, _salt),
        tooShort ? '' : hashFor('skeleton:$skeleton', _salt),
      ];
    }
    return compute(_digestJob, [password, skeleton, _salt, tooShort]);
  }

  /// PBKDF2-HMAC-SHA256. Static and pure so a test can check it directly.
  static String hashFor(String value, String salt) {
    final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(
          Uint8List.fromList(utf8.encode('okay-password-history|$salt')),
          debugRounds ?? rounds,
          32));
    return base64.encode(kdf.process(Uint8List.fromList(utf8.encode(value))));
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Forgotten on an account switch, like everything else keyed to one
  /// account: the next person's password history is not this one's.
  void reset() {
    _entries = [];
    _salt = '';
    // The cached handle goes too, or the next `load()` reads the previous
    // account's blob straight back — the exact trap `ChatFolders.resetForTest`
    // records.
    _prefs = null;
  }

  @visibleForTesting
  int get debugCount => _entries.length;
}

List<String> _digestJob(List<Object> args) {
  final password = args[0] as String;
  final skeleton = args[1] as String;
  final salt = args[2] as String;
  final tooShort = args[3] as bool;
  return [
    PasswordHistory.hashFor(password, salt),
    tooShort ? '' : PasswordHistory.hashFor('skeleton:$skeleton', salt),
  ];
}
