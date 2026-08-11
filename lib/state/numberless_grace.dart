import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The 14-day clock on a name-only account.
///
/// A name-only account is minted in seconds and answers for nothing: no
/// number, no session, nothing to trace abuse to. The app already holds one
/// to tighter anti-spam limits; this puts a limit on how long it can exist
/// unclaimed at all. **After 14 days the account is DELETED and signed out.**
///
/// **This destroys real data and cannot be undone**, so the rule this file
/// exists to enforce is that nobody reaches the deadline uninformed:
///
///  * the sign-up confirmation says the number of days and the word deleted,
///    before the account is created;
///  * a banner names the days remaining for as long as the account is
///    name-only, and gets more urgent as it runs down;
///  * the deletion itself is explained on the way out, not silently.
///
/// Adding a phone number [clear]s the clock for good — the account stops
/// being name-only, keeps every chat, note and server, and its holder can
/// choose a real username instead of the one the app minted.
///
/// The clock is stored per ACCOUNT CODE, so a second name-only account on the
/// same phone gets its own 14 days rather than inheriting a stranger's
/// nearly-expired one.
class NumberlessGrace extends ChangeNotifier {
  NumberlessGrace._();
  static final NumberlessGrace instance = NumberlessGrace._();

  /// How long a name-only account lives unclaimed. The owner's number.
  static const int graceDays = 14;

  static const String _prefix = 'numberless_grace_';

  /// When the account this device is signed into was created, or null when
  /// there is no clock running (a real account, or one already cleared).
  DateTime? _startedAt;
  DateTime? get startedAt => _startedAt;

  /// Test seam for "now", so every boundary is provable without waiting.
  @visibleForTesting
  static DateTime Function()? debugNow;

  static DateTime _now() => (debugNow ?? DateTime.now)();

  /// Starts the clock for [accountCode] if it is not already running.
  ///
  /// Idempotent on purpose: this is called on every launch, and a clock that
  /// restarted each time would never expire — which is the failure mode that
  /// silently turns a 14-day limit into no limit at all.
  Future<void> start(String accountCode) async {
    if (accountCode.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final key = '$_prefix$accountCode';
    final saved = prefs.getString(key);
    final existing = saved == null ? null : DateTime.tryParse(saved);
    if (existing != null) {
      _startedAt = existing;
    } else {
      _startedAt = _now();
      await prefs.setString(key, _startedAt!.toIso8601String());
    }
    notifyListeners();
  }

  /// Loads an already-running clock without starting one. Used at launch,
  /// where starting a clock for an account that never had one would be
  /// inventing a deadline.
  Future<void> load(String accountCode) async {
    if (accountCode.isEmpty) {
      _startedAt = null;
      notifyListeners();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('$_prefix$accountCode');
    _startedAt = saved == null ? null : DateTime.tryParse(saved);
    notifyListeners();
  }

  /// Stops the clock for good — the account has a number now.
  Future<void> clear(String accountCode) async {
    _startedAt = null;
    if (accountCode.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_prefix$accountCode');
    }
    notifyListeners();
  }

  bool get running => _startedAt != null;

  /// The moment the account is deleted.
  DateTime? get deadline =>
      _startedAt?.add(const Duration(days: graceDays));

  /// What is left, floored at zero. Null when no clock is running.
  Duration? get remaining {
    final end = deadline;
    if (end == null) return null;
    final left = end.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Whole days left, ROUNDED UP: with 30 hours to go a person has "2 days",
  /// because rounding down would tell somebody they had 1 day on the morning
  /// of the last one and 0 while the account still worked. 0 means today is
  /// the day.
  int get daysLeft {
    final left = remaining;
    if (left == null) return graceDays;
    return (left.inMinutes / (60 * 24)).ceil();
  }

  /// True once the account should be deleted.
  bool get expired {
    final left = remaining;
    return left != null && left == Duration.zero;
  }

  /// The line shown on the banner. Deliberately names the consequence every
  /// time — "3 days left" alone does not say left until WHAT.
  String get bannerText {
    if (!running) return '';
    if (expired) return 'This account has expired and is being removed.';
    final d = daysLeft;
    if (d <= 1) {
      return 'Last day — add a phone number now or this account is deleted.';
    }
    return '$d days left before this account is deleted.';
  }

  /// True in the final stretch, so the banner can stop being a quiet note.
  /// Three days is the point at which somebody needs to act rather than
  /// intend to.
  bool get urgent => running && daysLeft <= 3;

  /// The one sentence that must appear wherever this is explained: what
  /// happens, when, and what stops it.
  static const String promise =
      'A name-only account is deleted after $graceDays days. Add a phone '
      'number to keep it — your chats and everything else stay, and you can '
      'choose your own username instead of the one we picked.';

  @visibleForTesting
  void resetForTest() {
    _startedAt = null;
    debugNow = null;
  }
}
