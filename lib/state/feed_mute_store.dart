import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'user_items.dart';

/// People whose posts this device stops showing on the public timeline.
///
/// WHY THIS HAS TO EXIST. The newsfeed is one timeline everybody shares, so
/// there is no membership to leave and no server to unsubscribe from. Without a
/// way to stop seeing somebody, the only options left to a person being pestered
/// are to report them and wait, or to stop opening the feed. Reporting asks a
/// moderator to make a decision about everyone; muting is a decision about
/// yourself, and it should not need anybody's permission.
///
/// ON THE SERVER SINCE 2026-08-23, and the trade that changed is worth stating
/// rather than leaving to be discovered. A mute used to live on one device
/// only, so it was invisible to everybody including us — and it did not follow
/// anybody to a new phone, which meant reinstalling handed somebody back every
/// account they had chosen to stop reading. It now rides [UserItems] as a row
/// of its own, so it syncs. What that row holds is a handle and nothing else:
/// no reason, no timestamp anybody sees, no post. Its RLS scopes it to the
/// account that wrote it, so the muted person cannot read it — which was
/// always the part that mattered.
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

  /// The `user_items` kind this store's rows are filed under.
  static const kind = 'mute';

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _muted = (_prefs!.getStringList(_key) ?? []).toSet();
    notifyListeners();
    // Then whatever other devices have done. Not awaited by callers: the
    // local list is on screen immediately and the server's answer folds in
    // when it arrives.
    unawaited(pull());
  }

  /// Folds the server's copy in, per row.
  ///
  /// A mute is the clearest case for per-row sync: under the blob's
  /// whole-document last-writer-wins, a device that had not caught up could
  /// UNMUTE somebody by uploading its older list — and being un-muted by a
  /// sync is a real harm, not a lost preference. Here the worst a stale
  /// device can do is fail to add one.
  ///
  /// Tombstones are applied as REMOVALS, which is the whole reason [pull]
  /// returns them: without that an unmute made on another device would be
  /// invisible for ever.
  Future<void> pull() async {
    final items = await UserItems.instance.pull(kind);
    if (items.isEmpty) return;
    final next = {..._muted};
    for (final item in items) {
      if (item.id.isEmpty) continue;
      if (item.deleted) {
        next.remove(item.id);
      } else {
        next.add(item.id);
      }
    }
    if (next.length == _muted.length && next.containsAll(_muted)) return;
    _muted = next;
    notifyListeners();
    await _prefs?.setStringList(_key, _muted.toList());
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
    // The server copy, per row — so the other device learns about this one
    // mute rather than about a whole document that might be older than its
    // own. Fire-and-forget: the local change has already taken, and a mute
    // that fails to upload must not fail to mute.
    unawaited(wasMuted
        ? UserItems.instance.remove(kind, u)
        : UserItems.instance.put(kind, u));
    return !wasMuted;
  }

  @visibleForTesting
  void resetForTest() {
    _muted = {};
    _prefs = null;
  }
}
