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
    'inspections',
    'watch',
  ];

  /// Sidebar destinations only an admin/owner may reach (the owner's call,
  /// 2026-08-16): Maps, Weather, Sports and Watch are hidden from everyone
  /// else, row and screen alike.
  ///
  /// Kept HERE rather than in the drawer because two surfaces have to agree:
  /// the drawer that draws the rows, and the reorder screen that lists every
  /// app by name. A set in one of them would leave the other offering a row
  /// that leads nowhere — which is how a "hidden" feature ends up advertised
  /// in the settings that reorder it.
  ///
  /// These are UNLISTED, not merely locked. Everything else the app
  /// gates (the wallet, posting, the marketplace) shows a padlock and says
  /// what would unlock it, because those are doors a user can open for
  /// themselves. This is a role no user can grant themselves, so a padlock
  /// would only advertise something they can never reach.
  static const Set<String> adminOnly = {
    'maps',
    'weather',
    'sports',
    'watch',
    // Joined them 2026-08-21, the owner's call. Vehicle inspections are a
    // tool for a fleet, not something a messenger's users have any use for.
    'inspections',
  };

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
  ///
  /// INDEXES INTO THE WHOLE ORDER, so it is only safe when the list on
  /// screen IS the whole order. It no longer is — the customize screen hides
  /// the admin-only rows from an ordinary account — so use [reorderBy]
  /// instead wherever the rendered list can be shorter than [order].
  Future<void> reorder(int from, int to) async {
    if (from < 0 || from >= _order.length) return;
    if (to < 0 || to > _order.length - 1) return;
    if (from == to) return;
    _order.insert(to, _order.removeAt(from));
    await _save();
  }

  /// Moves [id] to sit where [shown] says it now sits.
  ///
  /// BY ID, because the rendered list is a SUBSET. Handing a filtered list's
  /// indices to [reorder] moves whichever row happens to occupy that index in
  /// the full order, which is a different row — the exact index-corruption
  /// bug that made "just hide the admin rows from the customize screen" the
  /// wrong fix the first time it was tried, and left them on show.
  ///
  /// The rule is positional and needs no arithmetic to follow: the row lands
  /// immediately AFTER whatever now precedes it in [shown], and at the very
  /// front when nothing does. Rows that are not on screen keep their relative
  /// places around it, which is what an ordinary account moving a row must
  /// not disturb about rows it cannot see.
  Future<void> reorderBy(String id, List<String> shown) async {
    if (!_order.contains(id)) return;
    final at = shown.indexOf(id);
    if (at < 0) return;
    _order.remove(id);
    if (at == 0) {
      _order.insert(0, id);
    } else {
      final after = shown[at - 1];
      final anchor = _order.indexOf(after);
      // An anchor that is somehow not in the order at all would otherwise
      // insert at 0 and silently send the row to the top.
      _order.insert(anchor < 0 ? _order.length : anchor + 1, id);
    }
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
