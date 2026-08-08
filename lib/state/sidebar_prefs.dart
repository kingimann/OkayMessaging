import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which app rows the sidebar shows, and in what order — the user's call.
///
/// Only the Apps section is customizable. The profile header and the
/// Settings row are fixed: Settings is the way back for anything hidden
/// here, and a drawer that can hide its own undo is a trap. On the device
/// and nowhere else, like every other preference about this phone's screen.
class SidebarPrefs extends ChangeNotifier {
  SidebarPrefs._();
  static final SidebarPrefs instance = SidebarPrefs._();

  static const _key = 'sidebar_prefs_v1';

  /// Every row the sidebar knows, in default order. A row added in a later
  /// build shows up by default — visible-by-default is the analog of the
  /// chat list's private-by-default: nobody has to remember to opt in.
  static const List<String> defaultOrder = [
    'okayai',
    'contacts',
    'newsfeed',
    'forum',
    'maps',
    'marketplace',
    'servers',
    'notes',
    'drop',
    'wallet',
  ];

  final List<String> _order = List.of(defaultOrder);
  final Set<String> _hidden = {};
  SharedPreferences? _prefs;

  /// All known rows in the user's order, shown or not — what the customize
  /// screen lists, so a hidden row can be found and turned back on.
  List<String> get order => List.unmodifiable(_order);

  /// The rows the drawer actually draws.
  List<String> get visible =>
      [for (final id in _order) if (!_hidden.contains(id)) id];

  bool isHidden(String id) => _hidden.contains(id);

  /// Whether anything differs from the default, so the customize screen can
  /// offer a reset only when there is something to reset.
  bool get isCustomized =>
      _hidden.isNotEmpty || !listEquals(_order, defaultOrder);

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key);
    if (raw == null) return;
    _order
      ..clear()
      // A stored id this build no longer knows is dropped; a known id the
      // stored list is missing is appended so new rows appear by default.
      ..addAll(raw
          .map((e) => e.startsWith('-') ? e.substring(1) : e)
          .where(defaultOrder.contains))
      ..addAll(defaultOrder.where((id) => !raw
          .map((e) => e.startsWith('-') ? e.substring(1) : e)
          .contains(id)));
    _hidden
      ..clear()
      ..addAll(raw
          .where((e) => e.startsWith('-'))
          .map((e) => e.substring(1))
          .where(defaultOrder.contains));
    notifyListeners();
  }

  Future<void> setHidden(String id, bool hidden) async {
    if (!defaultOrder.contains(id)) return;
    final changed = hidden ? _hidden.add(id) : _hidden.remove(id);
    if (changed) await _save();
  }

  /// Moves a row. [to] is the index AFTER the lift, straight from
  /// ReorderableListView's onReorderItem — same contract as quick replies.
  Future<void> reorder(int from, int to) async {
    if (from < 0 || from >= _order.length) return;
    if (to < 0 || to > _order.length - 1) return;
    if (from == to) return;
    _order.insert(to, _order.removeAt(from));
    await _save();
  }

  Future<void> reset() async {
    _order
      ..clear()
      ..addAll(defaultOrder);
    _hidden.clear();
    await _save();
  }

  Future<void> _save() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    // One list carries both facts: order by position, hidden by a '-' mark.
    await prefs.setStringList(
        _key, [for (final id in _order) _hidden.contains(id) ? '-$id' : id]);
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _order
      ..clear()
      ..addAll(defaultOrder);
    _hidden.clear();
    _prefs = null;
    notifyListeners();
  }
}
