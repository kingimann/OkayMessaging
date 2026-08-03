import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the reader shapes their own timelines — muted words and whether
/// reposts show — applied to BOTH feeds (the public one and every server's),
/// because "I don't want to read about X" is about the reader, not about
/// which timeline X appeared on.
///
/// On the device and nowhere else, like the mute lists beside it: what
/// somebody chooses not to see is nobody's business, least of all a server's.
class FeedPrefs extends ChangeNotifier {
  FeedPrefs._();
  static final FeedPrefs instance = FeedPrefs._();

  static const _kWords = 'feed_muted_words_v1';
  static const _kHideReposts = 'feed_hide_reposts_v1';

  SharedPreferences? _prefs;

  List<String> _mutedWords = [];
  bool _hideReposts = false;

  /// Lowercased words and phrases whose posts stay out of the timelines.
  List<String> get mutedWords => List.unmodifiable(_mutedWords);

  /// Whether reposts are dropped from the timelines — some people want only
  /// what the people around them actually wrote.
  bool get hideReposts => _hideReposts;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _mutedWords = _prefs!.getStringList(_kWords) ?? [];
    _hideReposts = _prefs!.getBool(_kHideReposts) ?? false;
    notifyListeners();
  }

  static String _norm(String word) => word.trim().toLowerCase();

  /// Adds a word or phrase. Returns false for blanks and duplicates.
  Future<bool> muteWord(String word) async {
    final w = _norm(word);
    if (w.isEmpty || _mutedWords.contains(w)) return false;
    _mutedWords = [..._mutedWords, w];
    notifyListeners();
    await _prefs?.setStringList(_kWords, _mutedWords);
    return true;
  }

  Future<void> unmuteWord(String word) async {
    final w = _norm(word);
    _mutedWords = [for (final m in _mutedWords) if (m != w) m];
    notifyListeners();
    await _prefs?.setStringList(_kWords, _mutedWords);
  }

  Future<void> setHideReposts(bool value) async {
    if (_hideReposts == value) return;
    _hideReposts = value;
    notifyListeners();
    await _prefs?.setBool(_kHideReposts, value);
  }

  /// Whether [text] trips any of [words]. Pure and case-insensitive; a
  /// phrase matches as a phrase ("crypto tips" only hides posts saying
  /// exactly that, not every post with "crypto" in it).
  static bool hidesText(String text, List<String> words) {
    if (words.isEmpty || text.isEmpty) return false;
    final lower = text.toLowerCase();
    return words.any((w) => w.isNotEmpty && lower.contains(w));
  }

  /// Whether a post with [text] stays off this reader's timelines.
  bool hides(String text) => hidesText(text, _mutedWords);

  @visibleForTesting
  void resetForTest() {
    _mutedWords = [];
    _hideReposts = false;
    notifyListeners();
  }
}
