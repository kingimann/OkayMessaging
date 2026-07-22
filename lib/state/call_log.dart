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
  static const _max = 200;

  List<CallRecord> _records = [];
  SharedPreferences? _prefs;

  /// Most-recent-first list of calls.
  List<CallRecord> get records => List.unmodifiable(_records);

  bool get isEmpty => _records.isEmpty;

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
    _prefs = null;
    notifyListeners();
  }
}
