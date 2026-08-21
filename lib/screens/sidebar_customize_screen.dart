import 'package:flutter/material.dart';

import '../state/platform_moderation.dart';
import '../state/sidebar_prefs.dart';
import '../theme/app_theme.dart';

/// Rearrange the sidebar: drag rows into the order you use them, switch off
/// the ones you don't. Settings itself is not on the list — it is the way
/// back, and a drawer that can hide its own undo is a trap.
class SidebarCustomizeScreen extends StatelessWidget {
  const SidebarCustomizeScreen({super.key, this.fromSidebar = false});

  /// True when opened from the sidebar — shows a ☰ that reopens the sidebar
  /// instead of a back arrow.
  final bool fromSidebar;

  // Only ids in SidebarPrefs.defaultOrder can reach this — retired rows
  // (okayai, newsfeed, contacts, notes) are filtered out on load. 'forum'
  // was missing and fell through to the raw-id fallback, so the customize
  // screen labelled the row "forum".
  static (IconData, String) metaFor(String id) => switch (id) {
        'forum' => (Icons.forum_outlined, 'Forum'),
        'weather' => (Icons.wb_sunny_outlined, 'Weather'),
        'sports' => (Icons.sports_soccer_outlined, 'Sports'),
        'maps' => (Icons.map_outlined, 'Maps'),
        'marketplace' => (Icons.storefront_outlined, 'Marketplace'),
        'servers' => (Icons.groups_outlined, 'Servers'),
        'drop' => (Icons.wifi_tethering, 'Okay Drop'),
        'wallet' => (Icons.account_balance_wallet_outlined, 'Wallet'),
        'forms' => (Icons.assignment_outlined, 'Forms'),
        'history' => (Icons.history, 'History'),
        'inspections' =>
          (Icons.local_shipping_outlined, 'Inspections'),
        'watch' => (Icons.smart_display_outlined, 'Watch'),
        _ => (Icons.apps, id),
      };

  @override
  Widget build(BuildContext context) {
    final prefs = SidebarPrefs.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Customize sidebar'),
        actions: [
          ListenableBuilder(
            listenable: prefs,
            builder: (context, _) => prefs.isCustomized
                ? TextButton(
                    onPressed: prefs.reset,
                    child: const Text('Reset'),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      body: ListenableBuilder(
        // The role loads asynchronously, so listening to prefs alone would
        // show an admin the short list until something unrelated rebuilt the
        // tree — the same merge the drawer itself already does.
        listenable: Listenable.merge([prefs, PlatformModeration.instance]),
        builder: (context, _) {
          // FILTERED SINCE 2026-08-21 (the owner's: "the customize sidebar
          // still shows apps that the regular user shouldn't see"). It used
          // to list every row including the admin-only ones, and the reason
          // recorded here was a real one: `onReorderItem: prefs.reorder`
          // hands the RENDERED list's indices straight to the full order, so
          // a shorter list makes every drag move a different row — an index
          // bug traded for a cosmetic leak. That is now closed at the source
          // rather than worked around: `reorderBy` moves a row by ID, so the
          // list on screen may be any subset of the order.
          //
          // The drawer gate is still what keeps these shut. This only stops
          // the screen from naming things the account can never open.
          final order = [
            for (final id in prefs.order)
              if (!SidebarPrefs.adminOnly.contains(id) ||
                  PlatformModeration.instance.canAdminister)
                id
          ];
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  // The cut is named here, where the order is set, because
                  // it is the only thing reordering now DOES beyond changing
                  // the sequence: it decides which five you see without
                  // opening anything. Silently dropping row six into a fold
                  // would read as a row that had vanished.
                  'Drag to reorder. The first '
                  '${SidebarPrefs.shownApps} show in the sidebar; the rest '
                  'fold under "Other". Switch a row off to keep it out '
                  'entirely — everything stays reachable from here, and '
                  'Settings always stays put.',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.subtle(context)),
                ),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  itemCount: order.length,
                  // BY ID, not by index — see `reorderBy`. The list above is
                  // a subset for anyone who is not an admin.
                  onReorderItem: (from, to) {
                    if (from < 0 || from >= order.length) return;
                    // `to` is the index AFTER the lift, so remove-then-insert
                    // is the whole of it and there is no off-by-one to
                    // compensate for — the same contract quick replies and
                    // chat folders already follow.
                    final moved = List<String>.of(order);
                    final id = moved.removeAt(from);
                    moved.insert(to.clamp(0, moved.length), id);
                    prefs.reorderBy(id, moved);
                  },
                  itemBuilder: (context, i) {
                    final id = order[i];
                    final (icon, title) = metaFor(id);
                    final hidden = prefs.isHidden(id);
                    return ListTile(
                      key: ValueKey('sidebar_$id'),
                      leading: Icon(icon,
                          color: hidden ? Colors.grey : null),
                      title: Text(title,
                          style: hidden
                              ? const TextStyle(color: Colors.grey)
                              : null),
                      trailing: Switch(
                        value: !hidden,
                        onChanged: (on) => prefs.setHidden(id, !on),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
