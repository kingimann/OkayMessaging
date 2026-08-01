import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What you had typed and did not post.
///
/// Backing out of a composer threw the text away — three paragraphs gone to a
/// mistaken swipe, with nothing to say it had happened. A draft is kept per
/// place you can write from, so a reply half-written to one person does not
/// turn up in the box for another.
///
/// ON THE DEVICE, like everything else here. A draft is the least finished
/// thing a person has; it is nobody's business but theirs, and it does not
/// leave.
class FeedDrafts extends ChangeNotifier {
  FeedDrafts._();

  static final FeedDrafts instance = FeedDrafts._();

  static const _key = 'feed_drafts_v1';

  /// The most drafts to keep. Bounded because the key includes a post id —
  /// every reply anybody starts and abandons would otherwise be a row here
  /// forever.
  static const int maxDrafts = 40;

  /// The longest draft kept. A pasted book is not a draft worth persisting,
  /// and the composer caps a post well below this anyway.
  static const int maxLength = 4000;

  final Map<String, String> _drafts = {};
  SharedPreferences? _prefs;

  /// The composer for the public feed.
  static const String publicKey = 'public';

  /// A reply to one post, kept apart from the main composer.
  static String replyKey(String postId) => 'reply:$postId';

  /// One server's feed composer.
  static String serverKey(String communityId) => 'server:$communityId';

  int get count => _drafts.length;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _drafts
      ..clear()
      ..addAll(_decode(_prefs!.getString(_key)));
    notifyListeners();
  }

  /// What was left in [key]'s box, or an empty string.
  String read(String key) => _drafts[key] ?? '';

  bool has(String key) => (_drafts[key] ?? '').trim().isNotEmpty;

  /// Keeps [text] under [key]. Whitespace-only clears it rather than storing
  /// a blank, so an emptied box does not read as a draft you have to go and
  /// tidy up.
  void write(String key, String text) {
    final trimmed = text.trim().isEmpty
        ? ''
        : (text.length > maxLength ? text.substring(0, maxLength) : text);
    if (trimmed.isEmpty) {
      clear(key);
      return;
    }
    if (_drafts[key] == trimmed) return;
    // Re-inserted rather than updated in place, so the most recently touched
    // draft is last and "drop the oldest" means what it says.
    _drafts.remove(key);
    _drafts[key] = trimmed;
    while (_drafts.length > maxDrafts) {
      _drafts.remove(_drafts.keys.first);
    }
    _persist();
    notifyListeners();
  }

  /// Forgets [key] — the post went, or the box was emptied.
  void clear(String key) {
    if (_drafts.remove(key) == null) return;
    _persist();
    notifyListeners();
  }

  void _persist() => _prefs?.setString(_key, jsonEncode(_drafts));

  static Map<String, String> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return {};
      return {
        for (final e in json.entries)
          if (e.key is String && e.value is String && (e.value as String).isNotEmpty)
            e.key as String: e.value as String
      };
    } catch (_) {
      return {};
    }
  }

  @visibleForTesting
  void resetForTest() {
    _drafts.clear();
    _prefs = null;
    notifyListeners();
  }
}
