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

  /// What an account that already existed before this rule gets: one week
  /// from the first time it is TOLD, not from whenever it signed up.
  ///
  /// Backdating would delete accounts belonging to people who were never
  /// warned, which is the one thing the rest of this file exists to prevent.
  /// So the week starts on the launch that first shows them the notice — and
  /// somebody who does not open the app for a month simply starts their week
  /// then. An account the server does not know about cannot be expired while
  /// the app is closed, and pretending otherwise would only mean deleting
  /// data behind somebody's back.
  static const int existingAccountDays = 7;

  static const String _prefix = 'numberless_grace_';
  static const String _daysPrefix = 'numberless_grace_days_';
  static const String _toldPrefix = 'numberless_grace_told_';

  /// How many days THIS account was given — 14 for one created under the
  /// rule, 7 for one adopted into it.
  int _days = graceDays;
  int get days => _days;

  /// True when this account was already here before the rule and was given
  /// the shorter week. Shown in the banner, because "7 days" under a promise
  /// of 14 needs a reason beside it.
  bool get adopted => running && _days != graceDays;

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
  Future<void> start(String accountCode, {int days = graceDays}) async {
    if (accountCode.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final key = '$_prefix$accountCode';
    final saved = prefs.getString(key);
    final existing = saved == null ? null : DateTime.tryParse(saved);
    if (existing != null) {
      _startedAt = existing;
      _days = prefs.getInt('$_daysPrefix$accountCode') ?? graceDays;
    } else {
      _startedAt = _now();
      _days = days;
      await prefs.setString(key, _startedAt!.toIso8601String());
      await prefs.setInt('$_daysPrefix$accountCode', days);
    }
    notifyListeners();
  }

  /// Brings an account that pre-dates the rule under it, with
  /// [existingAccountDays] starting NOW. A no-op once it has a clock, so the
  /// week is granted once and never renewed by relaunching.
  Future<void> adoptExisting(String accountCode) =>
      start(accountCode, days: existingAccountDays);

  /// Whether this account has already been told, so the notice is sent once
  /// rather than on every launch.
  Future<bool> markTold(String accountCode, String milestone) async {
    if (accountCode.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    final key = '$_toldPrefix${accountCode}_$milestone';
    if (prefs.getBool(key) == true) return false;
    await prefs.setBool(key, true);
    return true;
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
    _days = prefs.getInt('$_daysPrefix$accountCode') ?? graceDays;
    notifyListeners();
  }

  /// Stops the clock for good — the account has a number now.
  Future<void> clear(String accountCode) async {
    _startedAt = null;
    _days = graceDays;
    if (accountCode.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_prefix$accountCode');
      await prefs.remove('$_daysPrefix$accountCode');
    }
    notifyListeners();
  }

  bool get running => _startedAt != null;

  /// The moment the account is deleted.
  DateTime? get deadline => _startedAt?.add(Duration(days: _days));

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
    if (left == null) return _days;
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

  /// The one-off notice an adopted account gets: what changed, how long it
  /// has, and what stops it.
  String get noticeBody =>
      'Name-only accounts are now deleted after $graceDays days. Yours has '
      '$existingAccountDays days from today. Add a phone number to keep it — '
      'your chats stay, and you can choose your own username.';

  @visibleForTesting
  void resetForTest() {
    _startedAt = null;
    _days = graceDays;
    debugNow = null;
  }
}
