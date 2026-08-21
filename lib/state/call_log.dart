import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/call.dart';
import '../models/user.dart';
import 'chat_store.dart';

/// The person a call record names, as they are NOW rather than as they were
/// when the call happened.
///
/// A [CallRecord] freezes an [AppUser] and persists it, so its avatar, name
/// and badge are a photograph of the moment the call ended — which is why the
/// Calls tab kept showing a contact's old picture long after the chat list had
/// their new one, reported as "profile picture still not updated". The two
/// screens disagreeing about the same person is the tell.
///
/// Resolved from [ChatStore] by the same tolerant lookup everything else uses,
/// and falls back to the frozen copy when there is no chat — somebody you
/// called once and never messaged still has to draw as somebody.
AppUser liveCallUser(CallRecord record, {ChatStore? store}) =>
    liveCallPeer(record.user, store: store);

/// The same repair for a peer that was never frozen: the stand-in a call
/// SIGNALING event carries.
///
/// An incoming offer, a group offer and a missed-call notice each build their
/// caller from the wire — id, name, username, and a hardcoded colour, because
/// the wire carries no avatar at all. So the ringing screen drew a contact
/// whose picture this device has had all along as a plain coloured circle
/// with their initials, which is the other half of "profile pictures don't
/// show": the Calls TAB was fixed to resolve live and the LIVE call was not.
///
/// Falls back to the stand-in when there is no chat — a stranger calling
/// still has to draw as somebody, and their name and number came off the wire
/// correctly.
AppUser liveCallPeer(AppUser peer, {ChatStore? store}) {
  final s = store ?? ChatStore.instance;
  final chat = s.chatWithContact(peer.id) ??
      (peer.phone.isEmpty ? null : s.chatWithContact(peer.phone));
  final known = chat?.contact;
  // A GROUP pseudo-contact is never the caller — a group call carries its
  // own `group` object separately, and matching one here would draw the
  // group's colour on the person ringing.
  if (known == null || known.isGroup) return peer;
  // A contact with a blank name would draw an empty label, so the wire's
  // name stands in. Every path that creates a contact sets one (falling back
  // to the number), so this is a belt rather than a case seen in practice.
  return known.name.trim().isEmpty ? peer : known;
}

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
