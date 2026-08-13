import 'package:flutter/foundation.dart';

/// Who is CURRENTLY looking at a group chat or a server text channel,
/// right now.
///
/// A live signal only — like [VoicePresenceStore], it is never persisted and
/// never queued to the offline mailbox: a "viewing" ping replayed hours later
/// would show a ghost sitting in a chat nobody has open. Each device that has a
/// group chat (or a channel) on screen heartbeats to the other members; an
/// entry is swept when it goes quiet, so a force-quit or a backgrounded app
/// clears itself instead of lingering as "here".
///
/// Keyed by an arbitrary conversation id (a group `Chat.id`, the same id
/// typing scopes to, OR a `Channel.id` — the two id spaces never collide,
/// so one store serves both rather than a second, identical copy of it) →
/// member digits → when we last heard from them. Names are resolved by the
/// screen from its own roster, so no name rides the wire.
class GroupPresenceStore extends ChangeNotifier {
  GroupPresenceStore._();
  static final GroupPresenceStore instance = GroupPresenceStore._();

  /// How often a viewing device re-announces itself (see chat_screen).
  static const Duration heartbeat = Duration(seconds: 15);

  /// How long an entry survives unheard-from — comfortably over two
  /// heartbeats, so one dropped ping doesn't evict anybody.
  static const Duration staleAfter = Duration(seconds: 40);

  /// groupId -> memberDigits -> last heard.
  final Map<String, Map<String, DateTime>> _byGroup = {};

  /// Records that [digits] is viewing group [groupId] right now.
  void applyRemote(String groupId, String digits, {DateTime? now}) {
    if (groupId.isEmpty || digits.isEmpty) return;
    _byGroup.putIfAbsent(groupId, () => {})[digits] = now ?? DateTime.now();
    notifyListeners();
  }

  /// The digits of everyone currently in [groupId] (not stale). The local
  /// user is never in here — this device knows perfectly well it's looking.
  List<String> hereIn(String groupId, {DateTime? now}) {
    final map = _byGroup[groupId];
    if (map == null || map.isEmpty) return const [];
    final cutoff = (now ?? DateTime.now()).subtract(staleAfter);
    return [
      for (final e in map.entries)
        if (e.value.isAfter(cutoff)) e.key
    ];
  }

  /// Whether [digits] is currently viewing [groupId].
  bool isHere(String groupId, String digits, {DateTime? now}) =>
      hereIn(groupId, now: now).contains(digits);

  int countIn(String groupId, {DateTime? now}) =>
      hereIn(groupId, now: now).length;

  /// Drops anyone we haven't heard from within [staleAfter].
  void sweep({DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(staleAfter);
    var changed = false;
    for (final map in _byGroup.values) {
      final gone = [
        for (final e in map.entries)
          if (e.value.isBefore(cutoff)) e.key
      ];
      for (final k in gone) {
        map.remove(k);
        changed = true;
      }
    }
    if (_byGroup.values.any((m) => m.isEmpty)) {
      _byGroup.removeWhere((_, v) => v.isEmpty);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _byGroup.clear();
    notifyListeners();
  }
}
