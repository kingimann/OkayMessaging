import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'public_feed_store.dart';

/// Who the user follows, by username (no '@'). This device's list is the
/// source of truth for YOUR follows — it filters your timeline and works
/// numberless. Since 2026-08-05 (the owner's call) each change is ALSO
/// recorded on the server graph, best-effort, which is what makes follower
/// and following counts real on everybody's profile.
class FollowStore extends ChangeNotifier {
  FollowStore._();
  static final FollowStore instance = FollowStore._();
  static const _kKey = 'following_v1';

  final Set<String> _following = {};

  /// Usernames the user follows (lowercase, no '@').
  Set<String> get following => Set.unmodifiable(_following);

  int get followingCount => _following.length;

  bool isFollowing(String username) =>
      _following.contains(_clean(username));

  static String _clean(String u) =>
      u.replaceFirst('@', '').trim().toLowerCase();

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _following
        ..clear()
        ..addAll(prefs.getStringList(_kKey) ?? const []);
      notifyListeners();
    } catch (_) {}
  }

  /// Follows/unfollows [username]; returns true when now following.
  bool toggle(String username) {
    final u = _clean(username);
    if (u.isEmpty) return false;
    final nowFollowing = !_following.remove(u);
    if (nowFollowing) _following.add(u);
    _save();
    notifyListeners();
    // Fire-and-forget: the local change already took, and the server edge
    // is the tally's business, not the button's.
    PublicFeedStore.instance.serverSetFollow(u, nowFollowing);
    return nowFollowing;
  }

  /// Replaces the follow list (from a decrypted cloud backup).
  void setAll(Iterable<String> usernames) {
    _following
      ..clear()
      ..addAll(usernames.map(_clean).where((u) => u.isNotEmpty));
    _save();
    notifyListeners();
  }

  /// Folds a cloud backup's follow list in without dropping anyone followed
  /// since the blob was uploaded — a pull-to-refresh restores on every
  /// screen, and replacement would quietly undo a fresh follow.
  void mergeAll(Iterable<String> usernames) {
    _following.addAll(usernames.map(_clean).where((u) => u.isNotEmpty));
    _save();
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kKey, _following.toList()..sort());
    } catch (_) {}
  }

  @visibleForTesting
  void resetForTest() {
    _following.clear();
    notifyListeners();
  }
}
