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
  static const _max = 200;

  List<CallRecord> _records = [];
  DateTime _lastSeen = DateTime.fromMillisecondsSinceEpoch(0);
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

  void clear() {
    _records = [];
    _save();
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _records = [];
    _lastSeen = DateTime.fromMillisecondsSinceEpoch(0);
    _prefs = null;
    notifyListeners();
  }
}
