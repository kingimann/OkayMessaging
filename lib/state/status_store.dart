import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/status_update.dart';

/// Groups one author's active status updates for the list/viewer.
class StatusThread {
  final String authorId;
  final String authorName;
  final String avatarColor;
  final List<StatusUpdate> updates; // oldest → newest

  const StatusThread({
    required this.authorId,
    required this.authorName,
    required this.avatarColor,
    required this.updates,
  });

  DateTime get latest => updates.last.time;
}

/// Store for ephemeral status updates ("stories"). Your own updates persist on
/// this device; a couple of contact updates are seeded for the demo. An update
/// is "active" for 24 hours after it's posted, then it drops off.
class StatusStore extends ChangeNotifier {
  StatusStore._();
  static final StatusStore instance = StatusStore._();

  static const _key = 'statuses_v1';
  static const Duration ttl = Duration(hours: 24);

  final List<StatusUpdate> _all = [];
  SharedPreferences? _prefs;

  /// Palette offered when composing a status.
  static const List<String> palette = [
    '#7A5CFF', '#E5484D', '#12B76A', '#F79009',
    '#0BA5EC', '#EE46BC', '#475467', '#101828',
  ];

  /// Active (non-expired) updates as of [now].
  List<StatusUpdate> _active(DateTime now) =>
      _all.where((u) => now.difference(u.time) < ttl).toList();

  /// The current user's active updates, oldest first.
  List<StatusUpdate> myActive({DateTime? now, String myId = 'me'}) {
    final n = now ?? DateTime.now();
    final mine = _active(n).where((u) => u.authorId == myId).toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    return mine;
  }

  /// Other people's active updates, grouped by author and sorted most-recent
  /// author first.
  List<StatusThread> otherThreads({DateTime? now, String myId = 'me'}) {
    final n = now ?? DateTime.now();
    final byAuthor = <String, List<StatusUpdate>>{};
    for (final u in _active(n)) {
      if (u.authorId == myId) continue;
      byAuthor.putIfAbsent(u.authorId, () => []).add(u);
    }
    final threads = byAuthor.entries.map((e) {
      final list = [...e.value]..sort((a, b) => a.time.compareTo(b.time));
      final first = list.first;
      return StatusThread(
        authorId: e.key,
        authorName: first.authorName,
        avatarColor: first.avatarColor,
        updates: list,
      );
    }).toList()
      ..sort((a, b) => b.latest.compareTo(a.latest));
    return threads;
  }

  /// Posts a new status for the current user and persists it.
  void post({
    required String text,
    required String bgColor,
    required String authorName,
    required String avatarColor,
    String myId = 'me',
    DateTime? now,
  }) {
    if (text.trim().isEmpty) return;
    _all.add(StatusUpdate(
      id: 'st_${(now ?? DateTime.now()).microsecondsSinceEpoch}',
      authorId: myId,
      authorName: authorName,
      avatarColor: avatarColor,
      text: text.trim(),
      bgColor: bgColor,
      time: now ?? DateTime.now(),
    ));
    _persistMine();
    notifyListeners();
  }

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    _all.clear();
    if (raw != null) {
      try {
        for (final e in jsonDecode(raw) as List) {
          _all.add(StatusUpdate.fromJson(Map<String, dynamic>.from(e as Map)));
        }
      } catch (_) {}
    }
    _seedDemoOthers();
    notifyListeners();
  }

  /// Seeds a couple of recent contact updates (not persisted) so the list has
  /// something to show; skipped if any non-me update already exists.
  void _seedDemoOthers({DateTime? now}) {
    final n = now ?? DateTime.now();
    if (_all.any((u) => u.authorId != 'me')) return;
    _all.addAll([
      StatusUpdate(
        id: 'seed_st_alice',
        authorId: 'u_alice',
        authorName: 'Alice Bennett',
        avatarColor: '#E57373',
        text: 'Sunny day at the beach ☀️',
        bgColor: '#0BA5EC',
        time: n.subtract(const Duration(hours: 2)),
      ),
      StatusUpdate(
        id: 'seed_st_erin',
        authorId: 'u_erin',
        authorName: 'Erin Foster',
        avatarColor: '#FFB74D',
        text: 'Shipped the new release 🚀',
        bgColor: '#12B76A',
        time: n.subtract(const Duration(hours: 5)),
      ),
      StatusUpdate(
        id: 'seed_st_erin2',
        authorId: 'u_erin',
        authorName: 'Erin Foster',
        avatarColor: '#FFB74D',
        text: 'Celebrating tonight 🎉',
        bgColor: '#EE46BC',
        time: n.subtract(const Duration(hours: 4)),
      ),
    ]);
  }

  void _persistMine() {
    final mine = _all.where((u) => u.authorId == 'me').map((u) => u.toJson());
    _prefs?.setString(_key, jsonEncode(mine.toList()));
  }

  @visibleForTesting
  void resetForTest() {
    _all.clear();
    _prefs = null;
    notifyListeners();
  }

  @visibleForTesting
  void seedForTest(List<StatusUpdate> updates) {
    _all
      ..clear()
      ..addAll(updates);
    notifyListeners();
  }
}
