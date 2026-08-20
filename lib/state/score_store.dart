import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A single earnable badge. A badge unlocks when the score reaches [threshold]
/// (when non-null) or when its [flag] has been recorded (a one-off achievement
/// like making a call or getting verified).
@immutable
class Badge {
  final String id;
  final String emoji;
  final String label;
  final String description;
  final int? threshold;
  final String? flag;

  const Badge({
    required this.id,
    required this.emoji,
    required this.label,
    required this.description,
    this.threshold,
    this.flag,
  });
}

/// The Okay Score: a running activity tally (à la Snapchat's Snapscore) plus
/// the badges it unlocks. Persisted on-device and — when cloud sync is set up
/// — kept on the server too, encrypted on this device first, so the score and
/// its badges survive a reinstall and follow you to a new phone. Your own
/// score is broadcast to a contact only when you message them, exactly like
/// your name.
class ScoreStore extends ChangeNotifier {
  ScoreStore._();
  static final ScoreStore instance = ScoreStore._();

  /// Points awarded for each kind of activity.
  static const int pointsPerSend = 2;
  static const int pointsPerReceive = 1;
  static const int pointsPerCall = 5;
  static const int pointsPerReaction = 1;
  static const int pointsPerPollVote = 1;
  static const int pointsPerForumPost = 3;
  static const int pointsPerForumComment = 2;
  static const int pointsPerFeedPost = 3;
  static const int pointsPerListing = 5;
  static const int pointsPerSale = 15;

  /// Level titles and the score at which each unlocks (index 0 = level 1).
  static const List<String> levelTitles = [
    'Newcomer',
    'Rookie',
    'Regular',
    'Pro',
    'Star',
    'Legend',
    'Icon',
  ];
  static const List<int> levelThresholds = [0, 50, 150, 350, 700, 1200, 2000];

  /// The full badge catalog, ordered from easiest to rarest.
  static const List<Badge> catalog = [
    Badge(
        id: 'handoff',
        emoji: '📨',
        label: 'Hand it over',
        description: 'Send a photo straight to somebody standing next to you',
        flag: 'shared_nearby'),
    Badge(
        id: 'nearby',
        emoji: '📡',
        label: 'Off the grid',
        description: 'Send a message over Bluetooth, with no internet',
        flag: 'sent_mesh'),
    Badge(
        id: 'relay',
        emoji: '🔗',
        label: 'Good neighbour',
        description: 'Carry somebody else\'s message to them',
        flag: 'relayed_mesh'),
    Badge(
        id: 'forwarder',
        emoji: '↪️',
        label: 'Passed it on',
        description: 'Forward a message to a chat or a channel',
        flag: 'forwarded'),
    Badge(
        id: 'starter',
        emoji: '🌱',
        label: 'Getting started',
        description: 'Send your first message',
        threshold: 2),
    Badge(
        id: 'caller',
        emoji: '📞',
        label: 'On the line',
        description: 'Place a voice or video call',
        flag: 'made_call'),
    Badge(
        id: 'profile',
        emoji: '🪪',
        label: 'Identity',
        description: 'Set a username or avatar emoji',
        flag: 'profile_set'),
    Badge(
        id: 'call_reactor',
        emoji: '🎈',
        label: 'Crowd pleaser',
        description: 'Send a reaction during a call',
        flag: 'call_reaction'),
    Badge(
        id: 'daily',
        emoji: '📅',
        label: 'Daily driver',
        description: 'Come back on a second day',
        flag: 'daily_2'),
    Badge(
        id: 'checkin_week',
        emoji: '🔥',
        label: 'Week on a roll',
        description: 'Check in seven days in a row',
        flag: 'checkin_week'),
    Badge(
        id: 'chatty',
        emoji: '💬',
        label: 'Chatterbox',
        description: 'Reach 50 points',
        threshold: 50),
    Badge(
        id: 'century',
        emoji: '💯',
        label: 'Century',
        description: 'Reach 100 points',
        threshold: 100),
    Badge(
        id: 'reactor',
        emoji: '😀',
        label: 'Reactor',
        description: 'React to a message',
        flag: 'reacted'),
    Badge(
        id: 'pollster',
        emoji: '📊',
        label: 'Pollster',
        description: 'Vote in a poll',
        flag: 'voted_poll'),
    Badge(
        id: 'poster',
        emoji: '📝',
        label: 'Contributor',
        description: 'Create a forum post',
        flag: 'forum_post'),
    Badge(
        id: 'town_crier',
        emoji: '📣',
        label: 'Town crier',
        description: 'Post on the public newsfeed',
        flag: 'public_post'),
    Badge(
        id: 'merchant',
        emoji: '🏷️',
        label: 'Open for business',
        description: 'Put something up for sale on the Marketplace',
        flag: 'listed_item'),
    Badge(
        id: 'dealmaker',
        emoji: '💰',
        label: 'First sale',
        description: 'Sell something on the Marketplace',
        flag: 'sold_item'),
    Badge(
        id: 'poker',
        emoji: '👉',
        label: 'Hey',
        description: 'Poke somebody',
        flag: 'poked'),
    Badge(
        id: 'streak_week',
        emoji: '🔥',
        label: 'A week straight',
        description: 'Keep a streak going for seven days',
        flag: 'streak_7'),
    Badge(
        id: 'founder',
        emoji: '👥',
        label: 'Bring people together',
        description: 'Start a group chat',
        flag: 'made_group'),
    Badge(
        id: 'social',
        emoji: '🎉',
        label: 'Social butterfly',
        description: 'Reach 250 points',
        threshold: 250),
    Badge(
        id: 'verified',
        emoji: '✅',
        label: 'Verified',
        description: 'Add the blue check to your account',
        flag: 'verified'),
    Badge(
        id: 'pro',
        emoji: '💜',
        label: 'Supporter',
        description: 'Support the developer',
        flag: 'pro'),
    Badge(
        id: 'legend',
        emoji: '🏆',
        label: 'Legend',
        description: 'Reach 500 points',
        threshold: 500),
  ];

  /// One way points are earned, for showing people how the number moves.
  /// The score was previously a figure that went up for unexplained reasons;
  /// this is the same constants above, written down where they can be read.
  static const List<(String, int)> earningRules = [
    ('Open the app on a new day', pointsPerDailyCheckIn),
    ('Sell something on the Marketplace', pointsPerSale),
    ('List something for sale', pointsPerListing),
    ('Place a voice or video call', pointsPerCall),
    ('Post on a newsfeed', pointsPerFeedPost),
    ('Post in a forum', pointsPerForumPost),
    ('Comment on a forum post', pointsPerForumComment),
    ('Send a message', pointsPerSend),
    ('Receive a message', pointsPerReceive),
    ('React to a message', pointsPerReaction),
    ('Vote in a poll', pointsPerPollVote),
  ];

  static Badge? badgeById(String id) {
    for (final b in catalog) {
      if (b.id == id) return b;
    }
    return null;
  }

  static const _kPoints = 'okay_score_points';
  static const _kFlags = 'okay_score_flags';
  static const _kFeatured = 'okay_score_featured';
  static const _kBySource = 'okay_score_by_source';
  static const _kCheckStreak = 'okay_score_checkin_streak';
  static const _kLastDaily = 'score_last_daily';

  /// A human label for each [award] source key, for the "where your points
  /// came from" breakdown. A source not in here is grouped under "Other".
  static const Map<String, String> sourceLabels = {
    'message': 'Messages',
    'call': 'Calls',
    'reaction': 'Reactions',
    'poll': 'Poll votes',
    'feed': 'Newsfeed posts',
    'forum': 'Forum posts',
    'forumComment': 'Forum comments',
    'listing': 'Listings',
    'sale': 'Sales',
    'daily': 'Daily check-ins',
  };

  SharedPreferences? _prefs;

  int _points = 0;
  final Set<String> _flags = <String>{};
  String? _featured;
  // How many points came from each source (see [sourceLabels]); the "where
  // your points came from" breakdown. Only a tally — never gates anything.
  final Map<String, int> _bySource = <String, int>{};
  // Consecutive days the app has been opened, counting the daily check-in. A
  // longer streak pays a bigger check-in bonus (see [dailyCheckIn]). This is
  // the RAW stored run; whether it is still alive is [checkInStreakOn]'s
  // question, since a streak nobody kept up has lapsed whatever the number
  // says.
  int _checkInStreak = 0;
  // The day of the last check-in, as a [_dailyKey]. Read as a field rather
  // than out of prefs on the spot, because the streak above means nothing
  // without it.
  String? _lastDaily;

  /// Fires with the new level number the moment [award] crosses into it, so a
  /// screen can celebrate a level-up. 0 means "nothing since launch".
  final ValueNotifier<int> leveledUpTo = ValueNotifier<int>(0);

  int get points => _points;
  Set<String> get flags => Set.unmodifiable(_flags);

  /// How many consecutive days you've checked in (opened the app), as of
  /// [now]. 0 before the first check-in of the current run — and 0 once the
  /// run has LAPSED, which is the whole reason this takes a day at all: the
  /// stored number is only true while the last check-in was today or
  /// yesterday, and a card claiming a seven-day streak that broke last week
  /// is worse than one claiming none.
  int checkInStreakOn(DateTime now) {
    if (_checkInStreak <= 0) return 0;
    final last = _lastDaily;
    if (last == null) return 0;
    if (last == _dailyKey(now) ||
        last == _dailyKey(now.subtract(const Duration(days: 1)))) {
      return _checkInStreak;
    }
    return 0;
  }

  /// How many consecutive days you've checked in, right now.
  int get checkInStreak => checkInStreakOn(DateTime.now());

  /// Points earned per source, largest first — the breakdown the score screen
  /// shows. Keys are [sourceLabels] keys; an unknown key falls back to "Other".
  List<(String, int)> get pointsBySource {
    final entries = _bySource.entries
        .where((e) => e.value > 0)
        .map((e) => (sourceLabels[e.key] ?? 'Other', e.value))
        .toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return entries;
  }

  /// The current level (1-based) derived from [points].
  int get level {
    var lvl = 1;
    for (var i = 0; i < levelThresholds.length; i++) {
      if (_points >= levelThresholds[i]) lvl = i + 1;
    }
    return lvl;
  }

  /// The title for the current level (e.g. "Regular").
  String get levelTitle => levelTitles[level - 1];

  /// The score at which the next level unlocks, or null at the max level.
  int? get nextLevelAt =>
      level < levelThresholds.length ? levelThresholds[level] : null;

  /// Progress toward the next level in [0, 1] (1.0 at max level).
  double get levelProgress {
    final next = nextLevelAt;
    if (next == null) return 1.0;
    final base = levelThresholds[level - 1];
    return ((_points - base) / (next - base)).clamp(0.0, 1.0);
  }

  /// The badge the user has chosen to show on their profile, if still earned.
  String? get featuredBadge =>
      (_featured != null && isEarned(_featured!)) ? _featured : null;

  /// Whether [badgeId] has been unlocked.
  bool isEarned(String badgeId) {
    final b = badgeById(badgeId);
    if (b == null) return false;
    if (b.threshold != null && _points >= b.threshold!) return true;
    if (b.flag != null && _flags.contains(b.flag)) return true;
    return false;
  }

  /// All currently-unlocked badges, in catalog order.
  List<Badge> get earnedBadges =>
      catalog.where((b) => isEarned(b.id)).toList(growable: false);

  int get earnedCount => earnedBadges.length;

  /// How far along an unearned points badge is, in [0, 1]. 1.0 for anything
  /// already earned, and 0.0 for a badge that isn't about points at all —
  /// a one-off achievement has no partial credit to show.
  double progressToward(String badgeId) {
    final b = badgeById(badgeId);
    if (b == null) return 0;
    if (isEarned(b.id)) return 1;
    final target = b.threshold;
    if (target == null || target <= 0) return 0;
    return (_points / target).clamp(0.0, 1.0);
  }

  /// The next points badge within reach — the nearest unearned threshold. Null
  /// when every points badge is already earned, so the UI can drop the card
  /// rather than invent a goal.
  Badge? get nextBadge {
    Badge? closest;
    for (final b in catalog) {
      final target = b.threshold;
      if (target == null || isEarned(b.id)) continue;
      if (closest == null || target < closest.threshold!) closest = b;
    }
    return closest;
  }

  /// Points still needed for [nextBadge], or null when there is none.
  int? get pointsToNextBadge {
    final b = nextBadge;
    if (b == null) return null;
    final left = b.threshold! - _points;
    return left < 0 ? 0 : left;
  }

  /// Loads the saved score at startup.
  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    _points = prefs.getInt(_kPoints) ?? 0;
    _flags
      ..clear()
      ..addAll(prefs.getStringList(_kFlags) ?? const []);
    _featured = prefs.getString(_kFeatured);
    _history = _decodeHistory(prefs.getString(_kHistory));
    _bySource
      ..clear()
      ..addAll(_decodeHistory(prefs.getString(_kBySource)));
    _checkInStreak = prefs.getInt(_kCheckStreak) ?? 0;
    _lastDaily = prefs.getString(_kLastDaily);
    _trimHistory();
    notifyListeners();
  }

  static Map<String, int> _decodeHistory(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return {};
      return {
        for (final e in json.entries)
          if (e.key is String && e.value is int) e.key as String: e.value as int
      };
    } catch (_) {
      return {};
    }
  }

  /// Points for opening the app on a new day (checked once at startup).
  static const int pointsPerDailyCheckIn = 20;

  /// Extra points per consecutive day of the check-in streak, and the most
  /// days the bonus keeps growing for. Day 1 pays [pointsPerDailyCheckIn];
  /// each further day in a row adds [checkInStreakStep] up to
  /// [checkInStreakCap] days (so a week-long streak pays the most).
  static const int checkInStreakStep = 5;
  static const int checkInStreakCap = 7;

  static String _dailyKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  /// The check-in bonus a streak of [streakDay] consecutive days pays (day 1
  /// is the base). Grows [checkInStreakStep] per day, capped at
  /// [checkInStreakCap] days.
  static int checkInBonusFor(int streakDay) {
    final extraDays = (streakDay.clamp(1, checkInStreakCap)) - 1;
    return pointsPerDailyCheckIn + extraDays * checkInStreakStep;
  }

  /// What the NEXT check-in would pay, given the current streak — shown on the
  /// score screen as an incentive to come back tomorrow. Reads the LIVE
  /// streak, so a run that has already lapsed quotes the base bonus rather
  /// than the one it used to be worth.
  int get nextCheckInBonus => nextCheckInBonusOn(DateTime.now());

  /// [nextCheckInBonus] as of [now].
  int nextCheckInBonusOn(DateTime now) =>
      checkInBonusFor(checkInStreakOn(now) + 1);

  /// Awards the daily check-in bonus at most once per calendar day. Consecutive
  /// days build a STREAK that pays a bigger bonus each day (capped); a missed
  /// day resets it. Unlocks the "Daily driver" badge on the second day. Safe
  /// to call on every launch.
  void dailyCheckIn({DateTime? now}) {
    final today = now ?? DateTime.now();
    final key = _dailyKey(today);
    final last = _lastDaily;
    if (last == key) return;
    // Consecutive if the last check-in was YESTERDAY; otherwise the streak
    // starts over at one.
    final yesterday = _dailyKey(today.subtract(const Duration(days: 1)));
    _checkInStreak = (last == yesterday) ? _checkInStreak + 1 : 1;
    _lastDaily = key;
    _prefs?.setString(_kLastDaily, key);
    _prefs?.setInt(_kCheckStreak, _checkInStreak);
    if (last != null) recordFlag('daily_2');
    if (_checkInStreak >= 7) recordFlag('checkin_week');
    award(checkInBonusFor(_checkInStreak), now: now, source: 'daily');
  }

  /// Points earned per day, keyed `yyyy-mm-dd`, for the last [historyDays].
  ///
  /// A single running total says nothing about whether you are going up. This
  /// is what the score screen draws, and it is bounded rather than kept
  /// forever — a fortnight is as far back as "am I using this more or less"
  /// is a question anyone asks.
  static const int historyDays = 14;
  static const _kHistory = 'okay_score_history';
  Map<String, int> _history = {};

  Map<String, int> get history => Map.unmodifiable(_history);

  static String dayKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  /// Points earned on each of the last [historyDays] days, oldest first, with
  /// zeros for days nothing happened. A chart with gaps in it is a chart that
  /// lies about how long the gap was.
  List<int> recentDays({DateTime? now}) {
    final today = now ?? DateTime.now();
    return [
      for (var i = historyDays - 1; i >= 0; i--)
        _history[dayKey(today.subtract(Duration(days: i)))] ?? 0
    ];
  }

  /// Points earned in the last seven days.
  int get thisWeek =>
      recentDays().sublist(historyDays - 7).fold(0, (a, b) => a + b);

  /// Adds [delta] points (ignoring non-positive deltas) and persists.
  /// [source] tags where the points came from for the breakdown (see
  /// [sourceLabels]); level-ups fire [leveledUpTo].
  void award(int delta, {DateTime? now, String? source}) {
    if (delta <= 0) return;
    final before = level;
    _points += delta;
    final key = dayKey(now ?? DateTime.now());
    _history[key] = (_history[key] ?? 0) + delta;
    if (source != null && source.isNotEmpty) {
      _bySource[source] = (_bySource[source] ?? 0) + delta;
    }
    _trimHistory(now: now);
    _persist();
    notifyListeners();
    if (level > before) leveledUpTo.value = level;
  }

  /// Drops days that have fallen out of the window, so a device left running
  /// for a year does not carry a year of them.
  void _trimHistory({DateTime? now}) {
    final today = now ?? DateTime.now();
    final keep = {
      for (var i = 0; i < historyDays; i++)
        dayKey(today.subtract(Duration(days: i)))
    };
    _history.removeWhere((k, _) => !keep.contains(k));
  }

  /// Records a one-off achievement [flag] (e.g. 'made_call', 'verified').
  void recordFlag(String flag) {
    if (_flags.add(flag)) {
      _persist();
      notifyListeners();
    }
  }

  /// Clears a flag (e.g. when verification is turned off).
  void clearFlag(String flag) {
    if (_flags.remove(flag)) {
      if (_featured == 'verified' && flag == 'verified') _featured = null;
      _persist();
      notifyListeners();
    }
  }

  /// Chooses which earned badge to feature on the profile (null clears it).
  void setFeatured(String? badgeId) {
    if (badgeId != null && !isEarned(badgeId)) return;
    _featured = badgeId;
    _persist();
    notifyListeners();
  }

  /// Compares two [_dailyKey] strings, oldest first. They are NOT zero-padded
  /// (unlike [dayKey]), so a plain string comparison sorts '2026-1-10' before
  /// '2026-1-9'.
  static int compareDayKeys(String a, String b) {
    final x = a.split('-');
    final y = b.split('-');
    for (var i = 0; i < 3; i++) {
      final av = i < x.length ? (int.tryParse(x[i]) ?? 0) : 0;
      final bv = i < y.length ? (int.tryParse(y[i]) ?? 0) : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }

  /// The score as a portable document, for the encrypted server sync.
  ///
  /// The check-in streak, the fortnight of daily totals and the per-source
  /// tally ride along with the points. They used to be left behind, so the
  /// sync whose whole job is to carry the score to a new phone dropped a
  /// seven-day streak back to nothing, took the next check-in from +50 to
  /// +20, and drew an empty chart under a real total.
  Map<String, dynamic> toJson() => {
        'points': _points,
        'flags': _flags.toList()..sort(),
        'featured': _featured,
        'streak': _checkInStreak,
        'lastDaily': _lastDaily,
        'history': _history,
        'bySource': _bySource,
      };

  /// Restores a score document from the server. The points only ever move
  /// up — a device that has been offline and earned more shouldn't be rolled
  /// back by an older snapshot — and flags are merged, since an achievement
  /// once earned is never lost.
  void hydrate(Map<String, dynamic> json) {
    final points = (json['points'] as num?)?.toInt() ?? 0;
    if (points > _points) _points = points;
    final flags = json['flags'];
    if (flags is List) _flags.addAll(flags.whereType<String>());
    final featured = json['featured'];
    if (featured is String && _featured == null) _featured = featured;
    // The streak and the day it was last kept alive travel together: a run
    // is only worth anything beside its last check-in, and [checkInStreakOn]
    // is what decides whether it has since lapsed — so restoring a stale
    // seven from a phone nobody has opened in a month cannot claim a live
    // streak. Take the LATER day, or an older snapshot would let this device
    // check in twice for the same one.
    final streak = (json['streak'] as num?)?.toInt() ?? 0;
    if (streak > _checkInStreak) _checkInStreak = streak;
    final last = json['lastDaily'];
    if (last is String &&
        last.isNotEmpty &&
        (_lastDaily == null || compareDayKeys(last, _lastDaily!) > 0)) {
      _lastDaily = last;
    }
    _mergeTally(_history, json['history']);
    _mergeTally(_bySource, json['bySource']);
    _trimHistory();
    _prefs?.setInt(_kCheckStreak, _checkInStreak);
    if (_lastDaily != null) _prefs?.setString(_kLastDaily, _lastDaily!);
    _persist();
    notifyListeners();
  }

  /// Folds a restored tally into a local one, keeping whichever count is
  /// higher per key — the same only-ever-up rule the points follow, since
  /// neither device's copy is authoritative and a day's earnings can only
  /// have been under-counted by the one that was offline.
  static void _mergeTally(Map<String, int> into, Object? raw) {
    if (raw is! Map) return;
    for (final e in raw.entries) {
      final k = e.key;
      final v = e.value;
      if (k is String && v is int && v > (into[k] ?? 0)) into[k] = v;
    }
  }

  void _persist() {
    _prefs?.setInt(_kPoints, _points);
    _prefs?.setStringList(_kFlags, _flags.toList());
    _prefs?.setString(_kHistory, jsonEncode(_history));
    _prefs?.setString(_kBySource, jsonEncode(_bySource));
    if (_featured == null) {
      _prefs?.remove(_kFeatured);
    } else {
      _prefs?.setString(_kFeatured, _featured!);
    }
  }

  @visibleForTesting
  void resetForTest() {
    _points = 0;
    _flags.clear();
    _featured = null;
    _history = {};
    _bySource.clear();
    _checkInStreak = 0;
    _lastDaily = null;
    leveledUpTo.value = 0;
    _prefs = null;
    notifyListeners();
  }
}
