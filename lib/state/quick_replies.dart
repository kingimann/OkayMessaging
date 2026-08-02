import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Short answers somebody types often, kept so they only type them once.
///
/// On the device and nowhere else. These are the sentences a person uses most,
/// which makes the list itself a fair description of their life — a shop's
/// opening hours, an address, "I'm on my way", "not right now". None of it
/// goes near a server, and it is not in the encrypted backup either: it
/// belongs to the phone the way a keyboard shortcut does.
class QuickReplies extends ChangeNotifier {
  QuickReplies._();
  static final QuickReplies instance = QuickReplies._();

  static const _key = 'quick_replies_v1';

  /// Enough to be useful, few enough to stay a list rather than a search
  /// problem. Past this the picker is worse than typing.
  static const int max = 30;

  final List<String> _replies = [];
  SharedPreferences? _prefs;

  List<String> get all => List.unmodifiable(_replies);
  bool get isEmpty => _replies.isEmpty;
  bool get isFull => _replies.length >= max;

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    _replies.clear();
    final raw = prefs.getStringList(_key);
    if (raw != null) {
      _replies.addAll(raw.where((r) => r.trim().isNotEmpty));
    }
    notifyListeners();
  }

  /// Saves [text], newest first. Returns false when there was nothing to save
  /// or it is already there — saving the same sentence twice makes the picker
  /// longer without making it more useful.
  Future<bool> add(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || isFull) return false;
    if (_replies.any((r) => r.toLowerCase() == trimmed.toLowerCase())) {
      return false;
    }
    _replies.insert(0, trimmed);
    await _save();
    return true;
  }

  /// Replaces the reply at [index]. Editing to empty removes it, because a
  /// blank quick reply is a row that inserts nothing.
  Future<void> edit(int index, String text) async {
    if (index < 0 || index >= _replies.length) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      _replies.removeAt(index);
    } else {
      _replies[index] = trimmed;
    }
    await _save();
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _replies.length) return;
    _replies.removeAt(index);
    await _save();
  }

  /// Moves a reply, so the ones somebody actually uses can sit at the top.
  ///
  /// [to] is the index AFTER the item has been lifted out, which is what
  /// ReorderableListView's onReorderItem hands over — the older onReorder
  /// passed the index before removal and needed an off-by-one fix that is a
  /// classic way to swap the wrong pair.
  Future<void> reorder(int from, int to) async {
    if (from < 0 || from >= _replies.length) return;
    if (to < 0 || to > _replies.length - 1) return;
    _replies.insert(to, _replies.removeAt(from));
    await _save();
  }

  /// The replies worth offering for what has been typed so far.
  ///
  /// An empty box offers everything — that is the picker. Once there is a
  /// word, only the ones containing it, because a list that ignores what
  /// somebody is typing is a list they have to read every time.
  List<String> matching(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return [
      for (final r in _replies)
        if (r.toLowerCase().contains(q)) r
    ];
  }

  Future<void> _save() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setStringList(_key, _replies);
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _replies.clear();
    _prefs = null;
    notifyListeners();
  }

  /// The starter set, offered only when somebody has never saved one.
  ///
  /// NOT seeded into the list: these are suggestions on an empty screen, and
  /// writing them in would be inventing content in somebody's own words. They
  /// are also not shown in a release build's chat — see the no-fake-data rule
  /// — only as taps on the manage screen, where it is obvious they are
  /// examples rather than something already saved.
  static const List<String> suggestions = [
    'On my way',
    'Can I call you later?',
    'Thanks!',
    'Got it',
    'Running late, sorry',
  ];
}
