import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// People whose posts this device stops showing on the public timeline.
///
/// WHY THIS HAS TO EXIST. The newsfeed is one timeline everybody shares, so
/// there is no membership to leave and no server to unsubscribe from. Without a
/// way to stop seeing somebody, the only options left to a person being pestered
/// are to report them and wait, or to stop opening the feed. Reporting asks a
/// moderator to make a decision about everyone; muting is a decision about
/// yourself, and it should not need anybody's permission.
///
/// ON THE DEVICE, like bookmarks and for the same reason: who you would rather
/// not read is nobody else's business, least of all the muted person's. There is
/// no table, so a mute is invisible — which is the point. It also means mutes do
/// not follow somebody to a new device, and that trade is the honest one.
///
/// WHAT IT DOES NOT DO: it hides posts from the timeline. It does not hide a
/// profile somebody deliberately opens, and it does not touch what they already
/// bookmarked — both of those are things the person asked to see.
class FeedMuteStore extends ChangeNotifier {
  FeedMuteStore._();
  static final FeedMuteStore instance = FeedMuteStore._();

  static const _key = 'public_feed_muted';

  Set<String> _muted = {};
  SharedPreferences? _prefs;

  /// Lowercased usernames, so a mute survives somebody changing their
  /// capitalisation.
  Set<String> get muted => Set.unmodifiable(_muted);
  int get count => _muted.length;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _muted = (_prefs!.getStringList(_key) ?? []).toSet();
    notifyListeners();
  }

  static String _norm(String username) =>
      username.trim().toLowerCase().replaceFirst('@', '');

  bool isMuted(String username) {
    final u = _norm(username);
    return u.isNotEmpty && _muted.contains(u);
  }

  /// Mutes or unmutes [username]. Returns whether they are now muted.
  Future<bool> toggle(String username) async {
    final u = _norm(username);
    if (u.isEmpty) return false;
    final wasMuted = _muted.contains(u);
    _muted = wasMuted
        ? {for (final m in _muted) if (m != u) m}
        : {..._muted, u};
    notifyListeners();
    await _prefs?.setStringList(_key, _muted.toList());
    return !wasMuted;
  }

  @visibleForTesting
  void resetForTest() {
    _muted = {};
    _prefs = null;
  }
}
