import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the last few search queries (most-recent first) so they can be
/// re-run with a tap. Stored on-device only. Two instances exist: [instance]
/// for the universal chat search and [maps] for place searches in Maps.
class RecentSearches extends ChangeNotifier {
  RecentSearches._(this._kKey);
  static final RecentSearches instance = RecentSearches._('recent_searches_v1');
  static final RecentSearches maps =
      RecentSearches._('recent_map_searches_v1');

  final String _kKey;
  static const _max = 8;

  final List<String> _queries = [];
  SharedPreferences? _prefs;

  List<String> get queries => List.unmodifiable(_queries);
  bool get isEmpty => _queries.isEmpty;

  /// Loads saved queries at startup.
  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    _queries
      ..clear()
      ..addAll(prefs.getStringList(_kKey) ?? const []);
    notifyListeners();
  }

  /// Records [raw] as the most-recent query (de-duplicated case-insensitively,
  /// capped at [_max]). Blank queries are ignored.
  void add(String raw) {
    final q = raw.trim();
    if (q.isEmpty) return;
    _queries.removeWhere((e) => e.toLowerCase() == q.toLowerCase());
    _queries.insert(0, q);
    if (_queries.length > _max) _queries.removeRange(_max, _queries.length);
    _persist();
    notifyListeners();
  }

  /// Removes a single remembered query.
  void remove(String q) {
    if (_queries.remove(q)) {
      _persist();
      notifyListeners();
    }
  }

  /// Clears the whole history.
  void clear() {
    if (_queries.isEmpty) return;
    _queries.clear();
    _persist();
    notifyListeners();
  }

  void _persist() => _prefs?.setStringList(_kKey, _queries);

  @visibleForTesting
  void resetForTest() {
    _queries.clear();
    _prefs = null;
    notifyListeners();
  }
}
