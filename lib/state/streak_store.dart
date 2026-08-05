import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'score_store.dart';

/// Per-chat streak bookkeeping. A "streak day" is a calendar day on which you
/// and a contact each sent the other at least one message; the streak is the
/// number of consecutive such days. Missing a day lets the streak lapse.
class StreakData {
  int count;
  String? lastDay; // day the streak was last advanced (yyyy-mm-dd)
  String? today; // the day the sent/recv bits below refer to
  bool sentToday;
  bool recvToday;

  /// The highest this streak ever reached. Kept when the streak lapses, so a
  /// 40-day run that broke is still something you did.
  int best;

  StreakData({
    this.count = 0,
    this.lastDay,
    this.today,
    this.sentToday = false,
    this.recvToday = false,
    this.best = 0,
  });

  Map<String, dynamic> toJson() => {
        'count': count,
        'lastDay': lastDay,
        'today': today,
        'sent': sentToday,
        'recv': recvToday,
        'best': best,
      };

  factory StreakData.fromJson(Map<String, dynamic> j) {
    final count = (j['count'] as num?)?.toInt() ?? 0;
    return StreakData(
      count: count,
      lastDay: j['lastDay'] as String?,
      today: j['today'] as String?,
      sentToday: j['sent'] as bool? ?? false,
      recvToday: j['recv'] as bool? ?? false,
      // Records written before bests were kept still know one thing: the
      // streak got at least as high as it is now.
      best: (j['best'] as num?)?.toInt() ?? count,
    );
  }
}

/// Tracks Snapchat-style conversation streaks, persisted on-device. Nothing is
/// stored on a server; a streak is derived purely from the messages that flow
/// through this device.
class StreakStore extends ChangeNotifier {
  StreakStore._();
  static final StreakStore instance = StreakStore._();

  static const _kData = 'streaks_v1';

  final Map<String, StreakData> _data = {};
  SharedPreferences? _prefs;

  /// The day key (yyyy-mm-dd, local) for [d].
  static String dayKey(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  /// Records a message on [chatId] at [at]; [isMe] marks an outgoing message.
  /// Advances the streak the first time both sides have exchanged a message on
  /// the same calendar day.
  void record(String chatId, {required bool isMe, required DateTime at}) {
    final day = dayKey(at);
    final d = _data.putIfAbsent(chatId, StreakData.new);
    if (d.today != day) {
      d.today = day;
      d.sentToday = false;
      d.recvToday = false;
    }
    if (isMe) {
      d.sentToday = true;
    } else {
      d.recvToday = true;
    }
    if (d.sentToday && d.recvToday && d.lastDay != day) {
      final yesterday = dayKey(at.subtract(const Duration(days: 1)));
      d.count = (d.lastDay == yesterday) ? d.count + 1 : 1;
      d.lastDay = day;
      if (d.count > d.best) d.best = d.count;
      // A week's streak is a badge ('A week straight') — checked on the
      // advance rather than derived later, so it unlocks the day it is true.
      if (d.count >= 7) ScoreStore.instance.recordFlag('streak_7');
    }
    _persist();
    notifyListeners();
  }

  /// The live streak for [chatId] as of [now] (defaults to today). Returns 0
  /// when the streak has lapsed (no qualifying day today or yesterday).
  int streakFor(String chatId, {DateTime? now}) {
    final d = _data[chatId];
    if (d == null || d.lastDay == null) return 0;
    final n = now ?? DateTime.now();
    final today = dayKey(n);
    final yesterday = dayKey(n.subtract(const Duration(days: 1)));
    return (d.lastDay == today || d.lastDay == yesterday) ? d.count : 0;
  }

  /// Reconciles a streak with a peer's broadcast [count] for [chatId] as of a
  /// message received at [at]. Peers only ever broadcast a *live* streak (0 if
  /// lapsed), so adopting the higher value converges both devices on the same
  /// number and keeps it marked alive through the day of this message.
  void reconcile(String chatId, int count, {required DateTime at}) {
    if (count <= 0) return;
    final d = _data.putIfAbsent(chatId, StreakData.new);
    final day = dayKey(at);
    var changed = false;
    if (count > d.count) {
      d.count = count;
      changed = true;
    }
    if (d.count > d.best) {
      d.best = d.count;
      changed = true;
    }
    if (d.lastDay == null || day.compareTo(d.lastDay!) > 0) {
      d.lastDay = day;
      changed = true;
    }
    // The peer's device may be the one that counted day seven — the badge
    // is about the streak, not about whose clock noticed it.
    if (d.count >= 7) ScoreStore.instance.recordFlag('streak_7');
    if (changed) {
      _persist();
      notifyListeners();
    }
  }

  /// Whether [chatId]'s streak is alive but at risk of lapsing: it hasn't yet
  /// been kept up today, so a mutual message is needed before midnight. Drives
  /// the hourglass warning, à la Snapchat.
  bool isExpiringSoon(String chatId, {DateTime? now}) {
    final d = _data[chatId];
    if (d == null || d.lastDay == null) return false;
    final n = now ?? DateTime.now();
    if (streakFor(chatId, now: n) == 0) return false; // not alive
    return d.lastDay != dayKey(n); // last advanced yesterday → act today
  }

  /// Directly sets a chat's streak (used to seed demo data / tests).
  void seed(String chatId, int count, {DateTime? lastDay}) {
    final day = dayKey(lastDay ?? DateTime.now());
    _data[chatId] =
        StreakData(count: count, lastDay: day, today: day, best: count);
    _persist();
    notifyListeners();
  }

  bool get isEmpty => _data.isEmpty;

  /// The longest streak this chat ever reached, live or lapsed.
  int bestFor(String chatId) => _data[chatId]?.best ?? 0;

  /// The longest streak ever reached with anybody. Survives a lapse — the run
  /// happened even if it ended.
  int get bestEver {
    var best = 0;
    for (final d in _data.values) {
      if (d.best > best) best = d.best;
    }
    return best;
  }

  /// How many chats have a live streak right now.
  int activeCount({DateTime? now}) {
    final n = now ?? DateTime.now();
    var count = 0;
    for (final id in _data.keys) {
      if (streakFor(id, now: n) > 0) count++;
    }
    return count;
  }

  /// Live streak days added together — the "you keep this many going" number.
  int totalActiveDays({DateTime? now}) {
    final n = now ?? DateTime.now();
    var total = 0;
    for (final id in _data.keys) {
      total += streakFor(id, now: n);
    }
    return total;
  }

  /// What today still needs on [chatId] for the streak to advance: whether
  /// you've written and whether they have. Drives telling somebody *why* a
  /// streak isn't moving instead of leaving them to guess.
  (bool sent, bool received) todayProgress(String chatId, {DateTime? now}) {
    final d = _data[chatId];
    if (d == null) return (false, false);
    // Yesterday's bits say nothing about today.
    if (d.today != dayKey(now ?? DateTime.now())) return (false, false);
    return (d.sentToday, d.recvToday);
  }

  /// Loads saved streaks at startup.
  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    final raw = prefs.getString(_kData);
    if (raw != null) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _data
          ..clear()
          ..addAll(map.map((k, v) =>
              MapEntry(k, StreakData.fromJson(Map<String, dynamic>.from(v)))));
      } catch (_) {}
    }
    notifyListeners();
  }

  void _persist() {
    _prefs?.setString(
        _kData, jsonEncode(_data.map((k, v) => MapEntry(k, v.toJson()))));
  }

  @visibleForTesting
  void resetForTest() {
    _data.clear();
    _prefs = null;
    notifyListeners();
  }
}
