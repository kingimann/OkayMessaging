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
  // 'okayai' and 'newsfeed' are BOTTOM TABS now, not sidebar rows; 'contacts'
  // moved into the Calls tab's app bar and 'notes' was dropped outright (the
  // owner's calls, 2026-08-09) — load() filters stored orders against this
  // list, so an old saved order that still carries any of them drops them on
  // its own. 'store' is NOT here either: like Settings it sits in the fixed
  // block at the bottom of the drawer, so it cannot be hidden or reordered
  // away — the way to pay must not be something you can lose.
  //
  // **The order became a PRIORITY on 2026-08-14**, when the drawer started
  // showing only the first [shownApps] without opening anything. Before that
  // all ten drew and the sequence was just a sequence; now the first five are
  // the ones somebody sees, so leaving Weather and Sports at the top while
  // Servers and the Wallet sat below the fold would have been a bad default
  // rather than a neutral one. The five that lead are the destinations with
  // their own content and their own reasons to come back; what folds is the
  // look-something-up half. It is a DEFAULT, not a ruling — the reorder
  // screen is one tap from the header, and somebody who lives in Weather can
  // put it first.
  static const List<String> defaultOrder = [
    'servers',
    'marketplace',
    'forms',
    'wallet',
    'forum',
    // ── under "Other" by default ──
    'maps',
    'weather',
    'sports',
    'drop',
    'history',
    'watch',
  ];

  /// How many rows the drawer shows before the rest fold away (the owner's
  /// call, 2026-08-14). Ten rows plus a header, Store, Settings and Sign out
  /// was a wall of type you had to read rather than a list you could scan;
  /// five is about what the eye takes in at once.
  ///
  /// It is a CUT, not a filter: the first five of the user's OWN order show,
  /// and everything after them is one tap away under "Other". So the way to
  /// promote a row is the reorder screen that already exists, and nothing is
  /// unreachable — which is the difference between folding a list and hiding
  /// half of it.
  static const int shownApps = 5;

  /// The rows drawn without opening anything.
  List<String> get topApps => visible.take(shownApps).toList();

  /// The rest, behind "Other". Empty when everything already fits, so the
  /// fold does not appear over nothing.
  List<String> get moreApps => visible.skip(shownApps).toList();

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
