import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What Okay AI remembers about THIS user — the way it "learns as it talks".
///
/// A short list of durable, useful facts (a name, a preference, an ongoing
/// project) the assistant picked out of the conversation. It is included as
/// context on the next message, so the assistant gets more personal the more
/// you use it.
///
/// ON THE DEVICE, PER USER. The memory lives only here; the `ai-chat` function
/// is stateless and never stores it, so one person's memory can never surface
/// in another's answers — the failure mode that makes "an AI that learns from
/// everyone" a bad idea on a private app. It is built only from what the user
/// typed TO THE ASSISTANT (which already went to the model), never from a
/// human-to-human chat, and the user can see and delete every item.
class AiMemory extends ChangeNotifier {
  AiMemory._();
  static final AiMemory instance = AiMemory._();

  static const _kKey = 'ai_memory_v1';

  /// A ceiling so memory can't grow without bound and blow the context window;
  /// the oldest fall off when new ones arrive.
  static const int maxItems = 60;

  /// One remembered fact can't be a pasted essay.
  static const int maxLen = 200;

  final List<String> _items = [];

  List<String> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        _items
          ..clear()
          ..addAll(list.map((e) => e.toString()));
      }
      notifyListeners();
    } catch (_) {}
  }

  /// Folds in facts the assistant chose to remember, trimmed, deduped
  /// case-insensitively, and capped. Returns whether anything new was kept.
  Future<bool> addAll(Iterable<String> facts) async {
    var changed = false;
    for (final raw in facts) {
      final f = raw.trim();
      if (f.isEmpty || f.length > maxLen) continue;
      final dup =
          _items.any((e) => e.toLowerCase() == f.toLowerCase());
      if (dup) continue;
      _items.add(f);
      changed = true;
    }
    if (!changed) return false;
    // Keep the most recent when over the cap.
    if (_items.length > maxItems) {
      _items.removeRange(0, _items.length - maxItems);
    }
    await _save();
    notifyListeners();
    return true;
  }

  Future<void> remove(String item) async {
    _items.remove(item);
    await _save();
    notifyListeners();
  }

  Future<void> clear() async {
    _items.clear();
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kKey, jsonEncode(_items));
    } catch (_) {}
  }

  @visibleForTesting
  void resetForTest() {
    _items.clear();
  }
}
