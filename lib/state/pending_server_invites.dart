import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Servers somebody has been ADDED to that their own device has not joined.
///
/// **The asymmetry this exists to close.** An admin adding a member puts them
/// on the roster immediately and publishes it — so from every other device's
/// point of view they are already in. Their OWN device refuses to auto-join
/// unless the invite came from an accepted 1:1 (nobody should be forced into
/// a server by somebody messaging them cold — the rule lives in the relay's
/// own auto-join, named there rather than here because a test bans every
/// network identifier from this file), and when it refuses the invite lands
/// as an ordinary message in a chat
/// that is BORN A REQUEST and therefore hidden from the chat list. So the
/// person was a member everywhere except where they could see it, and the
/// only trace was a request they might never open. That is what "servers
/// that a user is added to don't show up" actually was.
///
/// The consent rule is not the thing to remove — being added still requires a
/// tap. What was missing is somewhere to tap. A pending invite is shown on
/// the Servers screen, which is where somebody looks for a server.
///
/// On the device and nowhere else: this is a list of servers somebody was
/// offered, which is a fact about them, and there is no table for it.
/// Account-scoped like [ChatFolders] — an invite is addressed to one account.
class PendingServerInvites extends ChangeNotifier {
  PendingServerInvites._();
  static final PendingServerInvites instance = PendingServerInvites._();

  static const _key = 'pending_server_invites_v1';

  /// A ceiling, oldest dropped. An invite nobody acted on for this long is
  /// noise, and the list is drawn above every server somebody actually has.
  static const int maxPending = 20;

  /// Server id -> the invite snapshot it arrived as.
  final Map<String, Map<String, dynamic>> _byId = {};

  /// Who offered it, by server id — shown so the row can say who added you.
  final Map<String, String> _fromName = {};

  SharedPreferences? _prefs;

  List<String> get ids => List.unmodifiable(_byId.keys);
  bool get isEmpty => _byId.isEmpty;
  int get length => _byId.length;

  Map<String, dynamic>? snapshotFor(String id) => _byId[id];
  String nameFor(String id) => (_byId[id]?['name'] as String?) ?? 'Server';
  String fromFor(String id) => _fromName[id] ?? '';

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    _byId.clear();
    _fromName.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is! Map) continue;
            final snap = e['snapshot'];
            final id = e['id'];
            if (id is! String || snap is! Map) continue;
            _byId[id] = Map<String, dynamic>.from(snap);
            _fromName[id] = (e['from'] as String?) ?? '';
          }
        }
      } catch (_) {
        // A corrupt blob forgets itself rather than refusing every invite
        // after it — the same fail-open the password history takes.
      }
    }
    notifyListeners();
  }

  /// Records an invite the device declined to act on by itself.
  ///
  /// Re-offering the same server REPLACES rather than stacks: an admin who
  /// adds somebody twice has not made two invitations.
  Future<void> remember(Map<String, dynamic> snapshot,
      {String fromName = ''}) async {
    final id = snapshot['id'];
    final name = snapshot['name'];
    if (id is! String || id.isEmpty) return;
    if (name is! String || name.isEmpty) return;
    _byId.remove(id);
    _fromName.remove(id);
    _byId[id] = Map<String, dynamic>.from(snapshot);
    _fromName[id] = fromName;
    while (_byId.length > maxPending) {
      final oldest = _byId.keys.first;
      _byId.remove(oldest);
      _fromName.remove(oldest);
    }
    await _save();
  }

  /// Drops one, whether it was joined or ignored — both mean it is answered.
  Future<void> forget(String id) async {
    if (_byId.remove(id) == null) return;
    _fromName.remove(id);
    await _save();
  }

  Future<void> _save() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(
        _key,
        jsonEncode([
          for (final e in _byId.entries)
            {'id': e.key, 'snapshot': e.value, 'from': _fromName[e.key] ?? ''}
        ]));
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _byId.clear();
    _fromName.clear();
    // The cached handle goes too, or the next load() reads the previous
    // account's blob straight back in — the trap ChatFolders already hit.
    _prefs = null;
    notifyListeners();
  }
}
