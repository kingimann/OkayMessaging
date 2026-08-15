import 'package:flutter/material.dart';

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
        listenable: prefs,
        builder: (context, _) {
          final order = prefs.order;
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
                  onReorderItem: prefs.reorder,
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
