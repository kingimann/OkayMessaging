import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/call.dart';

/// The device's call history. Entries are appended when a call reaches a
/// terminal state (ended / declined / missed) and persisted locally — nothing
/// is stored on a server, matching the rest of the app.
class CallLog extends ChangeNotifier {
  CallLog._();
  static final CallLog instance = CallLog._();

  static const _key = 'call_log_v1';
  static const _seenKey = 'call_log_seen_v1';
  static const _alertsKey = 'call_log_alerts_gone_v1';
  static const _max = 200;

  List<CallRecord> _records = [];
  DateTime _lastSeen = DateTime.fromMillisecondsSinceEpoch(0);

  /// Missed calls whose ALERT was swiped away in the notifications tab. The
  /// record itself stays — dismissing an alert about a call and erasing the
  /// call from history are different intents, and a swipe on a notification
  /// must never quietly do the bigger one.
  Set<String> _dismissedAlerts = {};
  SharedPreferences? _prefs;

  /// Most-recent-first list of calls.
  List<CallRecord> get records => List.unmodifiable(_records);

  bool get isEmpty => _records.isEmpty;

  /// Number of missed calls received since the user last opened the Calls tab.
  /// Backs the badge on the Calls navigation destination.
  int get newMissedCount =>
      _records.where((r) => r.isMissed && r.time.isAfter(_lastSeen)).length;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        _records = (jsonDecode(raw) as List)
            .map((c) => CallRecord.fromJson(Map<String, dynamic>.from(c as Map)))
            .toList();
        _sort();
      } catch (_) {
        _records = [];
      }
    }
    final seen = prefs.getString(_seenKey);
    if (seen != null) {
      _lastSeen = DateTime.tryParse(seen) ?? _lastSeen;
    }
    // Only ids that still name a record are worth keeping — the history is
    // capped, so dismissals of long-gone calls would otherwise pile up
    // forever.
    final ids = _records.map((r) => r.id).toSet();
    _dismissedAlerts = (prefs.getStringList(_alertsKey) ?? const [])
        .where(ids.contains)
        .toSet();
    notifyListeners();
  }

  /// Whether this missed call's alert was swiped away in the alerts tab.
  bool alertDismissed(String id) => _dismissedAlerts.contains(id);

  /// The missed calls the alerts tab should still show.
  List<CallRecord> get missedAlerts => _records
      .where((r) => r.isMissed && !_dismissedAlerts.contains(r.id))
      .toList();

  /// Removes one missed call from the alerts tab, keeping the call in the
  /// history — see [_dismissedAlerts] for why these are different things.
  void dismissMissedAlert(String id) {
    if (!_dismissedAlerts.add(id)) return;
    _prefs?.setStringList(_alertsKey, _dismissedAlerts.toList());
    notifyListeners();
  }

  /// Clears every missed-call alert at once ("Clear all alerts").
  void dismissAllMissedAlerts() {
    final missed =
        _records.where((r) => r.isMissed).map((r) => r.id).toList();
    if (_dismissedAlerts.containsAll(missed)) return;
    _dismissedAlerts.addAll(missed);
    _prefs?.setStringList(_alertsKey, _dismissedAlerts.toList());
    notifyListeners();
  }

  /// Marks the current history as seen, clearing the missed-call badge.
  void markSeen() {
    _lastSeen = DateTime.now();
    _prefs?.setString(_seenKey, _lastSeen.toIso8601String());
    notifyListeners();
  }

  void _sort() => _records.sort((a, b) => b.time.compareTo(a.time));

  void _save() {
    _prefs?.setString(
        _key, jsonEncode(_records.map((c) => c.toJson()).toList()));
  }

  /// Records a call, keeping the list newest-first and capped at [_max].
  void add(CallRecord record) {
    _records.add(record);
    _sort();
    if (_records.length > _max) {
      _records = _records.sublist(0, _max);
    }
    _save();
    notifyListeners();
  }

  /// Removes a single entry from the history.
  void remove(String id) {
    _records.removeWhere((r) => r.id == id);
    _save();
    notifyListeners();
  }

  void clear() {
    _records = [];
    _save();
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _records = [];
    _lastSeen = DateTime.fromMillisecondsSinceEpoch(0);
    _dismissedAlerts = {};
    _prefs = null;
    notifyListeners();
  }
}
