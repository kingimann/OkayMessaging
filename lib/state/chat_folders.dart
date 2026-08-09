import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Telegram-style chat folders: named tabs above the chat list, each holding
/// the conversations somebody put in it.
///
/// Membership is EXPLICIT — a folder is the chats you chose, not a rule that
/// might quietly start matching something new. Telegram offers both; a rule
/// that silently pulls a conversation into "Work" is the version that
/// surprises people, and a folder you filled yourself always contains exactly
/// what you remember putting there.
///
/// ON THE DEVICE, and only there — the same trade the bookmark folders make.
/// Which conversations somebody groups as "Family" is a statement about their
/// life, not about the chats, and there is no server table for it. The cost is
/// worth naming: folders do not follow you to a new phone.
///
/// Account-scoped, because a folder names THIS account's chats: it is wiped
/// and reloaded on an account switch (see `account_wipe.dart`), or the next
/// person would inherit a set of tabs pointing at conversations they cannot
/// see.
class ChatFolders extends ChangeNotifier {
  ChatFolders._();
  static final ChatFolders instance = ChatFolders._();

  static const _key = 'chat_folders_v1';

  /// How many folders one account may have. Past this the strip stops being
  /// a strip and becomes a second chat list.
  static const int maxFolders = 10;

  /// Folder name → the chat ids in it. Insertion order is the tab order, and
  /// Dart's Map preserves it, so reordering is a rebuild of this map.
  final Map<String, List<String>> _folders = {};
  SharedPreferences? _prefs;

  /// Folder names in tab order.
  List<String> get folders => List.unmodifiable(_folders.keys);

  bool get isEmpty => _folders.isEmpty;
  bool get isFull => _folders.length >= maxFolders;

  /// The chat ids filed under [folder], in the order they were added.
  List<String> idsIn(String folder) =>
      List.unmodifiable(_folders[folder] ?? const []);

  bool contains(String folder, String chatId) =>
      _folders[folder]?.contains(chatId) ?? false;

  /// Every folder [chatId] is in — what the "Add to folder" sheet ticks.
  List<String> foldersFor(String chatId) =>
      [for (final e in _folders.entries) if (e.value.contains(chatId)) e.key];

  /// Trims and rejects a name that is empty or already taken. Returns the
  /// stored name, or null when it was refused.
  static String? cleanName(String raw) {
    final name = raw.trim();
    if (name.isEmpty || name.length > 24) return null;
    return name;
  }

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _folders.clear();
    final raw = _prefs!.getString(_key);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            final v = e.value;
            if (v is List) {
              _folders[e.key as String] = [
                for (final id in v)
                  if (id is String) id
              ];
            }
          }
        }
      } catch (_) {
        // A corrupt blob costs the folders, never the chats.
      }
    }
    notifyListeners();
  }

  Future<bool> create(String raw) async {
    final name = cleanName(raw);
    if (name == null || isFull || _folders.containsKey(name)) return false;
    _folders[name] = [];
    await _save();
    return true;
  }

  Future<void> delete(String folder) async {
    if (_folders.remove(folder) == null) return;
    await _save();
  }

  /// Renaming keeps the folder's POSITION, which a remove-and-re-add would
  /// lose — the tab would jump to the end of the strip for a typo fix.
  Future<bool> rename(String folder, String raw) async {
    final name = cleanName(raw);
    if (name == null || !_folders.containsKey(folder)) return false;
    if (name == folder) return true;
    if (_folders.containsKey(name)) return false;
    final rebuilt = <String, List<String>>{};
    for (final e in _folders.entries) {
      rebuilt[e.key == folder ? name : e.key] = e.value;
    }
    _folders
      ..clear()
      ..addAll(rebuilt);
    await _save();
    return true;
  }

  /// [newIndex] is the index AFTER the lift, matching `onReorderItem` — the
  /// same convention the sidebar reorder settled on, so there is no
  /// off-by-one to compensate for.
  Future<void> reorder(int oldIndex, int newIndex) async {
    final names = _folders.keys.toList();
    if (oldIndex < 0 || oldIndex >= names.length) return;
    if (newIndex < 0 || newIndex >= names.length) return;
    final moved = names.removeAt(oldIndex);
    names.insert(newIndex, moved);
    final rebuilt = <String, List<String>>{
      for (final n in names) n: _folders[n]!
    };
    _folders
      ..clear()
      ..addAll(rebuilt);
    await _save();
  }

  Future<void> setInFolder(String folder, String chatId, bool inIt) async {
    final ids = _folders[folder];
    if (ids == null) return;
    final has = ids.contains(chatId);
    if (has == inIt) return;
    if (inIt) {
      ids.add(chatId);
    } else {
      ids.remove(chatId);
    }
    await _save();
  }

  /// Drops [chatId] from every folder — called when a conversation is
  /// deleted, so no tab counts a chat that is gone.
  Future<void> forget(String chatId) async {
    var touched = false;
    for (final ids in _folders.values) {
      if (ids.remove(chatId)) touched = true;
    }
    if (touched) await _save();
  }

  Future<void> _save() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(_folders));
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _folders.clear();
    _prefs = null;
  }
}
