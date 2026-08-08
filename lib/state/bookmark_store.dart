import 'dart:convert';

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
  static const _foldersKey = 'public_feed_bookmark_folders';

  /// Newest first, which is the order somebody expects to find them in.
  List<String> _ids = [];
  // Folder name → the post ids filed under it (newest first). A post can sit in
  // any number of folders; the flat [_ids] above stays the master list of
  // everything saved, so "All" is always the whole set and a folder is a view
  // onto it. Insertion order is preserved (Dart Maps keep it), which is the
  // order folders were made.
  final Map<String, List<String>> _folders = {};
  SharedPreferences? _prefs;

  List<String> get ids => List.unmodifiable(_ids);
  int get count => _ids.length;

  /// The folder names, in the order they were created.
  List<String> get folders => List.unmodifiable(_folders.keys);

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _ids = _prefs!.getStringList(_key) ?? [];
    _folders.clear();
    final raw = _prefs!.getString(_foldersKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            final v = e.value;
            if (v is List) {
              _folders[e.key as String] = [for (final id in v) id as String];
            }
          }
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  bool contains(String postId) => _ids.contains(postId);

  /// The ids filed under [folder], newest first — only those still bookmarked.
  List<String> idsInFolder(String folder) =>
      [for (final id in (_folders[folder] ?? const [])) if (_ids.contains(id)) id];

  /// How many saved posts are filed under [folder].
  int folderCount(String folder) => idsInFolder(folder).length;

  /// The folders [postId] is filed under.
  Set<String> foldersFor(String postId) => {
        for (final e in _folders.entries)
          if (e.value.contains(postId)) e.key
      };

  /// Creates an (empty) folder. A blank or duplicate name is a no-op.
  Future<void> createFolder(String name) async {
    final n = name.trim();
    if (n.isEmpty || _folders.containsKey(n)) return;
    _folders[n] = [];
    notifyListeners();
    await _saveFolders();
  }

  /// Deletes a folder. The posts themselves stay bookmarked (in [_ids]); only
  /// the grouping is removed.
  Future<void> deleteFolder(String name) async {
    if (_folders.remove(name) == null) return;
    notifyListeners();
    await _saveFolders();
  }

  /// Renames a folder, keeping its contents and its place in the order. A blank
  /// or clashing new name is a no-op.
  Future<void> renameFolder(String from, String to) async {
    final t = to.trim();
    if (t.isEmpty || from == t || !_folders.containsKey(from) ||
        _folders.containsKey(t)) {
      return;
    }
    // Rebuild to keep insertion order rather than moving the entry to the end.
    final rebuilt = <String, List<String>>{};
    for (final e in _folders.entries) {
      rebuilt[e.key == from ? t : e.key] = e.value;
    }
    _folders
      ..clear()
      ..addAll(rebuilt);
    notifyListeners();
    await _saveFolders();
  }

  /// Files [postId] into [folder] (or removes it). Filing also bookmarks the
  /// post if it wasn't already — you can't file what you haven't saved.
  Future<void> setInFolder(String folder, String postId, bool inIt) async {
    if (!_folders.containsKey(folder)) {
      if (!inIt) return;
      _folders[folder] = [];
    }
    final list = _folders[folder]!;
    if (inIt) {
      if (!_ids.contains(postId)) {
        _ids = [postId, ..._ids];
        await _prefs?.setStringList(_key, _ids);
      }
      if (!list.contains(postId)) list.insert(0, postId);
    } else {
      list.remove(postId);
    }
    notifyListeners();
    await _saveFolders();
  }

  Future<void> _saveFolders() async =>
      _prefs?.setString(_foldersKey, jsonEncode(_folders));

  /// Saves or unsaves [postId]. Returns whether it is now saved, so a caller
  /// can say which of the two happened without asking again.
  Future<bool> toggle(String postId) async {
    final saved = _ids.contains(postId);
    _ids = saved
        ? [for (final id in _ids) if (id != postId) id]
        : [postId, ..._ids];
    // Unsaving a post also drops it from every folder it was filed under —
    // a folder pointing at a post that is no longer saved is a dead entry.
    if (saved) {
      var touched = false;
      for (final list in _folders.values) {
        touched = list.remove(postId) || touched;
      }
      if (touched) await _saveFolders();
    }
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
    for (final list in _folders.values) {
      list.removeWhere(gone.contains);
    }
    notifyListeners();
    await _prefs?.setStringList(_key, _ids);
    await _saveFolders();
  }

  @visibleForTesting
  void resetForTest() {
    _ids = [];
    _folders.clear();
    _prefs = null;
  }
}
