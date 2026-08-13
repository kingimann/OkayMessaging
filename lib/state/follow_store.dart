import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'public_feed_store.dart';

/// Who the user follows, by username (no '@'). This device's list is the
/// source of truth for YOUR follows — it filters your timeline. Since
/// 2026-08-05 (the owner's call) each change is ALSO recorded on the server
/// graph, best-effort, which is what makes follower and following counts
/// real on everybody's profile. That server write needs a real Supabase
/// session, so — like every other write this app makes — it does NOT work
/// for a name-only (numberless) account; every UI call site gates on
/// `postNeedsPhone` first, and `PublicFeedStore.serverSetFollow` skips the
/// doomed round trip as a backstop. (An earlier version of this comment
/// claimed it worked numberless — it never did; the button just updated
/// this device's own local state and the server write silently failed.)
class FollowStore extends ChangeNotifier {
  FollowStore._();
  static final FollowStore instance = FollowStore._();
  static const _kKey = 'following_v1';

  final Set<String> _following = {};

  /// The server graph's count of how many people YOU follow, once it has
  /// answered. The local set ([_following]) is per-device — a follow made on
  /// one phone never lands in another phone's set — so using its length for
  /// the "Following" number made two devices on the same account disagree.
  /// The server graph is the one thing every device shares, so it is the
  /// source of truth for the DISPLAYED count; the local set still drives the
  /// timeline filter and works offline. Null until the server answers, then
  /// nudged optimistically on each toggle so the number moves at once.
  int? _serverFollowingCount;

  /// Usernames the user follows (lowercase, no '@').
  Set<String> get following => Set.unmodifiable(_following);

  /// The RAW local count — how many follows this device knows about. Kept for
  /// the timeline filter and as the first-frame fallback; not what the profile
  /// or sidebar should show (see [followingCountDisplay]).
  int get followingCount => _following.length;

  /// What the profile and sidebar show: the server graph's count when known,
  /// the local set's size until it answers. The same value in both places, and
  /// the same value on every device once the server has replied.
  int get followingCountDisplay => _serverFollowingCount ?? _following.length;

  /// Records the server graph's own-following count (from public_follow_counts),
  /// so the displayed number matches across devices. Ignores a negative.
  void noteServerFollowing(int count) {
    if (count < 0 || _serverFollowingCount == count) return;
    _serverFollowingCount = count;
    notifyListeners();
  }

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
    // Move the displayed (server-backed) count at once, so the profile and
    // sidebar don't wait for the round-trip; the next real fetch corrects it.
    if (_serverFollowingCount != null) {
      _serverFollowingCount =
          (_serverFollowingCount! + (nowFollowing ? 1 : -1)).clamp(0, 1 << 30);
    }
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
    _serverFollowingCount = null;
    notifyListeners();
  }
}
