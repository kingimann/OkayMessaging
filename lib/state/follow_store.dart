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

  /// Folds the SERVER's own-following list into this device's set.
  ///
  /// The count has been seeded from the server since the two-device fix; the
  /// LIST never was, and that asymmetry was a real bug (2026-08-16, reported
  /// with a screenshot): the profile said "3 following", the Following list —
  /// which is served straight from the graph — showed those three people, and
  /// every row's button said **Follow**, because the button asks this local
  /// set and the set had never heard of them. It reads as the app inventing
  /// follows, or recommending strangers. A follow made on another device, or
  /// before a reinstall, lands in exactly that state.
  ///
  /// **Adds, never removes**, for two independent reasons: the server window
  /// is capped at 100 rows, so it is a floor rather than the whole truth; and
  /// a follow made offline never reaches the graph at all (the write is
  /// fire-and-forget and is not retried), so treating the server's answer as
  /// complete would quietly delete it. The cost is that an unfollow made on
  /// another device does not remove it here — the displayed count and the
  /// list both come from the server, so what is left is a timeline that keeps
  /// showing somebody one of your other phones dropped.
  void noteServerFollowingList(Iterable<String> usernames) {
    final add = usernames.map(_clean).where((u) => u.isNotEmpty).toSet()
      ..removeAll(_following);
    if (add.isEmpty) return;
    _following.addAll(add);
    _save();
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
