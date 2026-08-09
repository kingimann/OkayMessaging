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

  static (IconData, String) metaFor(String id) => switch (id) {
        'okayai' => (Icons.auto_awesome, 'Okay AI'),
        'contacts' => (Icons.contacts_outlined, 'Contacts'),
        'newsfeed' => (Icons.public, 'Newsfeed'),
        'maps' => (Icons.map_outlined, 'Maps'),
        'marketplace' => (Icons.storefront_outlined, 'Marketplace'),
        'servers' => (Icons.groups_outlined, 'Servers'),
        'notes' => (Icons.sticky_note_2_outlined, 'Notes'),
        'drop' => (Icons.wifi_tethering, 'Okay Drop'),
        'wallet' => (Icons.account_balance_wallet_outlined, 'Wallet'),
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
                  'Drag to reorder. Switch a row off to keep it out of the '
                  'sidebar — everything stays reachable from here, and '
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
