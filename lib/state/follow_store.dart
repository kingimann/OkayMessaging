import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Who the user follows, by username (no '@'). Kept on this device — the
/// social graph, like everything else here, stores nothing on a server.
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
    return nowFollowing;
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

/// A believable follower count for a demo profile: stable per username, and
/// +1 while you follow them.
int followerCountFor(String username, {required bool youFollow}) {
  final u = username.replaceFirst('@', '').trim().toLowerCase();
  var h = 0;
  for (final c in u.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return 24 + (h % 380) + (youFollow ? 1 : 0);
}
