import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'user_items.dart';

/// Posts somebody saved to come back to.
///
/// ON THE SERVER SINCE 2026-08-23, as a row per bookmark in [UserItems].
///
/// It used to be device-only, on the reasoning that a table of who saved what
/// is a record of reading habits. That reasoning was real and it lost to the
/// cost: a bookmark is the one thing in a feed somebody deliberately keeps,
/// and losing the lot on a new phone is the failure people actually report.
/// What the row holds is a POST ID and nothing else — never the post, never
/// why — and its RLS scopes it to the account that wrote it, so no other
/// account can read what this one saved.
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
    // Then whatever other devices have saved. Not awaited by callers: the
    // local list is on screen immediately and the server's answer folds in
    // when it arrives.
    unawaited(pull());
  }

  /// The `user_items` kind this store's rows are filed under.
  static const kind = 'bookmark';

  /// Folds the server's copy in, per row.
  ///
  /// Under the blob's whole-document last-writer-wins, a device that had not
  /// caught up could wipe a batch of saves by uploading its older list. Per
  /// row the worst a stale device can do is fail to add one, and both sides'
  /// saves survive.
  ///
  /// Tombstones are applied as REMOVALS — the whole reason [UserItems.pull]
  /// returns them. Without that, unsaving on another device would be
  /// invisible for ever.
  ///
  /// **Newest-first is preserved by construction:** new ids go on the FRONT,
  /// which is where this store already puts a fresh save, so a batch arriving
  /// from another device does not shuffle the local order.
  Future<void> pull() async {
    final items = await UserItems.instance.pull(kind);
    if (items.isEmpty) return;
    final have = _ids.toSet();
    final incoming = <String>[];
    final gone = <String>{};
    for (final item in items) {
      if (item.id.isEmpty) continue;
      if (item.deleted) {
        gone.add(item.id);
      } else if (!have.contains(item.id)) {
        incoming.add(item.id);
      }
    }
    final next = [
      ...incoming,
      for (final id in _ids)
        if (!gone.contains(id)) id,
    ];
    if (next.length == _ids.length && incoming.isEmpty && gone.isEmpty) return;
    _ids = next;
    // A folder pointing at a post that is no longer saved is a dead entry —
    // the same cleanup [toggle] does when unsaving locally.
    if (gone.isNotEmpty) {
      var touched = false;
      for (final list in _folders.values) {
        for (final id in gone) {
          touched = list.remove(id) || touched;
        }
      }
      if (touched) await _saveFolders();
    }
    notifyListeners();
    await _prefs?.setStringList(_key, _ids);
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
    // The server copy, per row — so another device learns about this one
    // save rather than about a whole document that might be older than its
    // own list. Fire-and-forget: the local change has already taken, and a
    // bookmark that fails to upload must not fail to save.
    unawaited(saved
        ? UserItems.instance.remove(kind, postId)
        : UserItems.instance.put(kind, postId));
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
