import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The device's anti-abuse layer: it refuses link-shortener URLs, throttles
/// spammy or inhumanly-fast messaging, caps how many accounts one device can
/// mint, and notices when an account first signs in on a device.
///
/// **Honest about the ceiling.** OkayMessenger is local-first and delivers over
/// the anon key, so these run ON THE DEVICE and a hand-modified client could
/// skip them — the same shape as the AI client rate limit. They stop the
/// ordinary cases (accidental floods, a script pasting a bit.ly to everyone, a
/// tap-farm minting accounts) rather than a determined attacker rebuilding the
/// app; a true ceiling needs server-side limits, which the anon-key transport
/// can't enforce without a backend follow-up.
///
/// The counters that must survive an account switch (accounts minted here,
/// accounts seen here) are DEVICE-scoped — they belong to the phone, not to
/// whichever account is signed in — so their keys are on [AccountWipe.keepKeys]
/// and this file is listed device-scoped in the account-switch test.
class AbuseGuard {
  AbuseGuard._();
  static final AbuseGuard instance = AbuseGuard._();

  // --- Blocked URLs ------------------------------------------------------

  /// Link shorteners and redirectors that HIDE where a link actually leads —
  /// the shape spam and phishing hide behind. Deliberately excludes hosts a
  /// legitimate message routinely carries (e.g. Twitter's t.co), so this
  /// refuses the abuse pattern, not ordinary links.
  static const blockedUrlHosts = <String>[
    'bit.ly',
    'tinyurl.com',
    'goo.gl',
    'ow.ly',
    'is.gd',
    'buff.ly',
    'rebrand.ly',
    'cutt.ly',
    'shorturl.at',
    'rb.gy',
    't.ly',
    'tiny.cc',
    'bit.do',
    'adf.ly',
    'shorte.st',
  ];

  /// The blocked host present in [text], or null. Matches a host on its own
  /// boundary so "bit.ly" hits but "orbit.lyric.com" does not.
  static String? blockedUrlIn(String text) {
    final lower = text.toLowerCase();
    for (final host in blockedUrlHosts) {
      final re = RegExp(
          r'(^|[^a-z0-9.])' + RegExp.escape(host) + r'([/:?#]|$|[^a-z0-9.])');
      if (re.hasMatch(lower)) return host;
    }
    return null;
  }

  // --- Message rate limit ------------------------------------------------

  /// Outgoing sends this session, each with the recipient key and time. In
  /// memory only — a rate limit that resets on relaunch is fine (a spammer
  /// restarting the app for every message is throttled by the relaunch), and
  /// it keeps the message graph off disk.
  final List<({String to, DateTime at})> _sends = [];

  static const rateWindow = Duration(minutes: 1);
  static const maxToOneRecipient = 20; // to one person within the window
  static const maxNewRecipients = 8; // distinct NEW people within the window
  static const burstWindow = Duration(seconds: 4);
  static const maxBurst = 6; // sends within the burst window ≈ not a human

  /// Why a message to [toDigits] should be refused now, or null to allow it.
  /// Pure over the recorded history + [now].
  String? messageBlockReason(String toDigits, {DateTime? now}) {
    final t = now ?? DateTime.now();
    // Inhuman burst — the "non-human interaction" signal: nobody types six
    // separate messages in four seconds.
    final burst = _sends.where((s) => t.difference(s.at) < burstWindow).length;
    if (burst >= maxBurst) {
      return 'You\'re sending faster than a person can — slow down for a moment.';
    }
    final recent = _sends.where((s) => t.difference(s.at) < rateWindow).toList();
    // Hammering ONE person.
    final toOne = recent.where((s) => s.to == toDigits).length;
    if (toOne >= maxToOneRecipient) {
      return 'Too many messages to this person in a short time. Wait a minute.';
    }
    // Spraying MANY people — only counts when this is a NEW recipient, so
    // staying in your existing conversations is never throttled.
    final alreadyTalking = recent.any((s) => s.to == toDigits);
    if (!alreadyTalking) {
      final distinct = recent.map((s) => s.to).toSet()..add(toDigits);
      if (distinct.length > maxNewRecipients) {
        return 'You\'re messaging a lot of new people very quickly. Wait a minute.';
      }
    }
    return null;
  }

  /// Records a send to [toDigits] and prunes anything older than the window.
  void noteSend(String toDigits, {DateTime? now}) {
    final t = now ?? DateTime.now();
    _sends.add((to: toDigits, at: t));
    _sends.removeWhere((s) => t.difference(s.at) > const Duration(minutes: 5));
  }

  /// The one call the send path makes: refuse a blocked URL first, then the
  /// rate limits. Returns a human reason to refuse, or null to allow. Does NOT
  /// record the send — call [noteSend] once the message is actually going out.
  String? outgoingBlockReason(String text, String toDigits, {DateTime? now}) {
    final host = blockedUrlIn(text);
    if (host != null) {
      return 'Links from $host aren\'t allowed here — they hide where they '
          'lead. Share the full link instead.';
    }
    return messageBlockReason(toDigits, now: now);
  }

  // --- Persistence (device-scoped) ---------------------------------------

  static const _kCreates = 'abuse_account_creates_v1';
  static const _kSeen = 'abuse_accounts_seen_v1';

  SharedPreferences? _prefs;
  final List<int> _creates = []; // epoch ms of accounts minted on this device
  final Set<String> _seen = {}; // account digits that have signed in here

  static const accountWindow = Duration(hours: 24);
  static const maxAccountsPerWindow = 3;

  Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
    _creates
      ..clear()
      ..addAll((_prefs!.getStringList(_kCreates) ?? const [])
          .map(int.tryParse)
          .whereType<int>());
    _seen
      ..clear()
      ..addAll(_prefs!.getStringList(_kSeen) ?? const []);
  }

  /// Whether another account may be created on this device right now: fewer
  /// than [maxAccountsPerWindow] in the last [accountWindow]. Pure over the
  /// recorded history + [now].
  bool accountCreateAllowed({DateTime? now}) {
    final t = now ?? DateTime.now();
    final recent = _creates
        .where((ms) =>
            t.difference(DateTime.fromMillisecondsSinceEpoch(ms)) <
            accountWindow)
        .length;
    return recent < maxAccountsPerWindow;
  }

  /// Records that an account was just minted on this device.
  Future<void> noteAccountCreated({DateTime? now}) async {
    final t = now ?? DateTime.now();
    _creates.add(t.millisecondsSinceEpoch);
    // Keep the list from growing forever — a week is plenty of history.
    _creates.removeWhere((ms) =>
        t.difference(DateTime.fromMillisecondsSinceEpoch(ms)) >
        const Duration(days: 7));
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setStringList(_kCreates, _creates.map((e) => '$e').toList());
  }

  /// Registers a sign-in for [digits] and reports whether this account is
  /// signing in on a device it has NOT been on before — the new-device flag.
  /// A fresh signup passes [isSignup] true so its own first sign-in never
  /// reads as a suspicious new device.
  Future<bool> registerSignIn(String digits, {required bool isSignup}) async {
    if (digits.isEmpty) return false;
    final wasSeen = _seen.contains(digits);
    if (!wasSeen) {
      _seen.add(digits);
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setStringList(_kSeen, _seen.toList());
    }
    return !isSignup && !wasSeen;
  }

  @visibleForTesting
  void resetForTest() {
    _sends.clear();
    _creates.clear();
    _seen.clear();
    _prefs = null;
  }
}
