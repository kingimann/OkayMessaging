import 'package:flutter/material.dart';

import '../state/call_log.dart';
import '../tabs/calls_tab.dart';
import '../tabs/chats_tab.dart';
import '../theme/app_theme.dart';
import 'archived_chats_screen.dart';
import 'chat_search_delegate.dart';
import 'communities.dart';
import 'new_chat_screen.dart';
import 'settings_screen.dart';
import 'starred_messages_screen.dart';
import 'status_screen.dart';

/// The top-level screen: a modern pill bottom bar switching between Chats and
/// Calls, with a compose FAB.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  void _onMenuSelected(String value) {
    switch (value) {
      case 'filter':
        ChatsTab.filtersVisible.value = !ChatsTab.filtersVisible.value;
        break;
      case 'settings':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SettingsScreen()),
        );
        break;
      case 'starred':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const StarredMessagesScreen()),
        );
        break;
      case 'archived':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ArchivedChatsScreen()),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final onChats = _index == 0;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: _index == 0
            ? Text(
                'Okay Messaging',
                style: TextStyle(
                  color: isDark ? Colors.white : AppColors.tealGreen,
                  fontWeight: FontWeight.bold,
                  fontSize: 22,
                ),
              )
            : Text(_titleForIndex),
        actions: [
          if (onChats) ...[
            IconButton(
              icon: const Icon(Icons.motion_photos_on_outlined),
              tooltip: 'Status',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const StatusScreen()),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add_comment_outlined),
              tooltip: 'New chat',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NewChatScreen()),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Search',
              onPressed: () =>
                  showSearch(context: context, delegate: ChatSearchDelegate()),
            ),
            PopupMenuButton<String>(
              onSelected: _onMenuSelected,
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'filter',
                  child: Text(ChatsTab.filtersVisible.value
                      ? 'Hide filters'
                      : 'Filter chats'),
                ),
                const PopupMenuItem(
                    value: 'archived', child: Text('Archived chats')),
                const PopupMenuItem(
                    value: 'starred', child: Text('Starred messages')),
              ],
            ),
          ] else if (_index == 1)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'New community',
              onPressed: () => createCommunityFlow(context),
            ),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: const [
          ChatsTab(),
          CommunitiesTab(),
          CallsTab(),
          SettingsView(),
        ],
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: CallLog.instance,
        builder: (context, _) => _ModernNavBar(
          index: _index,
          missedCalls: CallLog.instance.newMissedCount,
          onSelect: _onSelectTab,
        ),
      ),
    );
  }

  void _onSelectTab(int i) {
    setState(() => _index = i);
    // Opening the Calls tab clears the missed-call badge.
    if (i == 2) CallLog.instance.markSeen();
  }

  String get _titleForIndex => switch (_index) {
        1 => 'Communities',
        2 => 'Calls',
        3 => 'You',
        _ => 'Okay Messaging',
      };
}

/// A sleek, minimal bottom bar with an animated "pill" behind the selected
/// destination — the label slides in only for the active tab.
class _ModernNavBar extends StatelessWidget {
  final int index;
  final int missedCalls;
  final ValueChanged<int> onSelect;

  const _ModernNavBar({
    required this.index,
    required this.onSelect,
    this.missedCalls = 0,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF16181C) : Colors.white;
    final border = isDark ? const Color(0xFF2F3336) : const Color(0xFFEFF3F4);
    return Container(
      decoration: BoxDecoration(
        color: bg,
        border: Border(top: BorderSide(color: border, width: 0.6)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _NavPill(
                icon: Icons.chat_bubble_outline,
                activeIcon: Icons.chat_bubble,
                label: 'Chats',
                selected: index == 0,
                onTap: () => onSelect(0),
              ),
              const SizedBox(width: 6),
              _NavPill(
                icon: Icons.groups_outlined,
                activeIcon: Icons.groups,
                label: 'Servers',
                selected: index == 1,
                onTap: () => onSelect(1),
              ),
              const SizedBox(width: 6),
              _NavPill(
                icon: Icons.call_outlined,
                activeIcon: Icons.call,
                label: 'Calls',
                selected: index == 2,
                badgeCount: missedCalls,
                onTap: () => onSelect(2),
              ),
              const SizedBox(width: 6),
              _NavPill(
                icon: Icons.person_outline,
                activeIcon: Icons.person,
                label: 'You',
                selected: index == 3,
                onTap: () => onSelect(3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavPill extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final int badgeCount;
  final VoidCallback onTap;

  const _NavPill({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? Colors.white : const Color(0xFF0F1419);
    final idle = isDark ? Colors.grey.shade500 : Colors.grey.shade600;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
        padding: EdgeInsets.symmetric(
          horizontal: selected ? 16 : 13,
          vertical: 11,
        ),
        decoration: BoxDecoration(
          color: selected
              ? ink.withValues(alpha: isDark ? 0.16 : 0.07)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _IconWithBadge(
              icon: selected ? activeIcon : icon,
              color: selected ? ink : idle,
              badgeCount: badgeCount,
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
              child: selected
                  ? Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        label,
                        style: TextStyle(
                          color: ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

/// A nav icon with an optional red count badge (used for missed calls).
class _IconWithBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final int badgeCount;

  const _IconWithBadge({
    required this.icon,
    required this.color,
    required this.badgeCount,
  });

  @override
  Widget build(BuildContext context) {
    final canvas = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF16181C)
        : Colors.white;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon, size: 24, color: color),
        if (badgeCount > 0)
          Positioned(
            right: -6,
            top: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
              decoration: BoxDecoration(
                color: const Color(0xFFE53935),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: canvas, width: 1.5),
              ),
              child: Text(
                badgeCount > 9 ? '9+' : '$badgeCount',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
