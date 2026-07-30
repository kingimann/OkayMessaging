import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Posts somebody saved to come back to.
///
/// ON THE DEVICE, and only there. A bookmark says "this interested me", which is
/// a statement about a person rather than about the post — exactly the kind of
/// thing this app keeps local. There is no server table and no column: the list
/// is post ids in shared preferences, and the posts themselves are re-read from
/// the public feed, which is public anyway.
///
/// The consequence is worth stating: bookmarks do not follow somebody to a new
/// device. That is the same trade the rest of this app makes, and the honest
/// alternative — a table of who saved what — would be a record of reading
/// habits that nobody asked us to keep.
class BookmarkStore extends ChangeNotifier {
  BookmarkStore._();
  static final BookmarkStore instance = BookmarkStore._();

  static const _key = 'public_feed_bookmarks';

  /// Newest first, which is the order somebody expects to find them in.
  List<String> _ids = [];
  SharedPreferences? _prefs;

  List<String> get ids => List.unmodifiable(_ids);
  int get count => _ids.length;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _ids = _prefs!.getStringList(_key) ?? [];
    notifyListeners();
  }

  bool contains(String postId) => _ids.contains(postId);

  /// Saves or unsaves [postId]. Returns whether it is now saved, so a caller
  /// can say which of the two happened without asking again.
  Future<bool> toggle(String postId) async {
    final saved = _ids.contains(postId);
    _ids = saved
        ? [for (final id in _ids) if (id != postId) id]
        : [postId, ..._ids];
    notifyListeners();
    await _prefs?.setStringList(_key, _ids);
    return !saved;
  }

  /// Forgets a post that no longer exists. Called when the server says a saved
  /// id is gone, so a deleted post does not sit in the list forever.
  Future<void> forget(Iterable<String> missing) async {
    if (missing.isEmpty) return;
    final gone = missing.toSet();
    final kept = [for (final id in _ids) if (!gone.contains(id)) id];
    if (kept.length == _ids.length) return;
    _ids = kept;
    notifyListeners();
    await _prefs?.setStringList(_key, _ids);
  }

  @visibleForTesting
  void resetForTest() {
    _ids = [];
    _prefs = null;
  }
}
