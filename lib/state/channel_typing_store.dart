import 'dart:async';

import 'package:flutter/foundation.dart';

/// Who is typing in which server channel, right now.
///
/// Like voice presence this is a live-only signal: never persisted, never
/// queued to the offline mailbox, and it expires on its own. A "typing"
/// replayed from a mailbox an hour later would claim someone is mid-sentence
/// in a channel they left long ago.
class ChannelTypingStore extends ChangeNotifier {
  ChannelTypingStore._();
  static final ChannelTypingStore instance = ChannelTypingStore._();

  /// How long a ping keeps someone shown as typing. The sender re-pings while
  /// they keep going, so this only has to outlast the throttle below.
  static const Duration linger = Duration(seconds: 6);

  /// The most often this device tells the server it is typing. One broadcast
  /// per keystroke would be a lot of traffic for a cosmetic hint.
  static const Duration throttle = Duration(seconds: 3);

  /// channelId -> digits -> (name, when we last heard)
  final Map<String, Map<String, ({String name, DateTime at})>> _typing = {};

  final Map<String, DateTime> _lastSent = {};
  Timer? _expiry;

  /// Broadcasts that the local user is typing. Wired to the relay at startup.
  void Function(String communityId, String channelId)? onTyping;

  /// The names of everyone typing in [channelId], most recent last.
  List<String> typistsIn(String channelId) {
    _expire();
    final map = _typing[channelId];
    if (map == null || map.isEmpty) return const [];
    final entries = map.values.toList()..sort((a, b) => a.at.compareTo(b.at));
    return [for (final e in entries) e.name];
  }

  /// "Ada is typing…", "Ada and Grace are typing…", "3 people are typing…"
  String? labelFor(String channelId) {
    final names = typistsIn(channelId);
    if (names.isEmpty) return null;
    if (names.length == 1) return '${names.first} is typing…';
    if (names.length == 2) {
      return '${names.first} and ${names.last} are typing…';
    }
    return '${names.length} people are typing…';
  }

  /// Called as the local user types. Throttled, so holding down a key doesn't
  /// flood the bus.
  void noteLocalTyping(String communityId, String channelId) {
    final now = DateTime.now();
    final last = _lastSent[channelId];
    if (last != null && now.difference(last) < throttle) return;
    _lastSent[channelId] = now;
    onTyping?.call(communityId, channelId);
  }

  /// Stops the throttle from suppressing the next ping — called when a message
  /// is actually sent, so typing again right after still announces.
  void clearLocal(String channelId) => _lastSent.remove(channelId);

  void noteRemote({
    required String channelId,
    required String digits,
    required String name,
  }) {
    if (digits.isEmpty) return;
    _typing.putIfAbsent(channelId, () => {})[digits] =
        (name: name.isEmpty ? 'Someone' : name, at: DateTime.now());
    notifyListeners();
    // One timer, rescheduled — the indicator has to disappear on its own even
    // if nothing else ever rebuilds the screen.
    _expiry?.cancel();
    _expiry = Timer(linger, () {
      _expire();
      notifyListeners();
    });
  }

  void _expire({DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(linger);
    for (final map in _typing.values) {
      map.removeWhere((_, v) => v.at.isBefore(cutoff));
    }
    _typing.removeWhere((_, v) => v.isEmpty);
  }

  @visibleForTesting
  void expireNow(DateTime now) {
    // Supersedes the pending timer rather than racing it.
    _expiry?.cancel();
    _expiry = null;
    _expire(now: now);
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _expiry?.cancel();
    _expiry = null;
    _typing.clear();
    _lastSent.clear();
    onTyping = null;
    notifyListeners();
  }
}
