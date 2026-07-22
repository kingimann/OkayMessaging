import 'package:flutter/material.dart';

import '../tabs/calls_tab.dart';
import '../tabs/chats_tab.dart';
import '../theme/app_theme.dart';
import 'archived_chats_screen.dart';
import 'chat_search_delegate.dart';
import 'new_chat_screen.dart';
import 'settings_screen.dart';
import 'starred_messages_screen.dart';

/// The top-level screen: a modern pill bottom bar switching between Chats and
/// Calls, with a compose FAB.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  IconData get _fabIcon => _index == 1 ? Icons.add_call : Icons.chat;

  void _onFabPressed() {
    if (_index == 0) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const NewChatScreen()),
      );
    }
  }

  void _onMenuSelected(String value) {
    switch (value) {
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
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Text(
          'Okay Messaging',
          style: TextStyle(
            color: isDark ? Colors.white : AppColors.tealGreen,
            fontWeight: FontWeight.bold,
            fontSize: 22,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search',
            onPressed: () =>
                showSearch(context: context, delegate: ChatSearchDelegate()),
          ),
          PopupMenuButton<String>(
            onSelected: _onMenuSelected,
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'archived', child: Text('Archived chats')),
              PopupMenuItem(value: 'starred', child: Text('Starred messages')),
              PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
          ),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: const [
          ChatsTab(),
          CallsTab(),
        ],
      ),
      bottomNavigationBar: _ModernNavBar(
        index: _index,
        onSelect: (i) => setState(() => _index = i),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _onFabPressed,
        backgroundColor: isDark ? Colors.white : AppColors.tealGreenDark,
        foregroundColor: isDark ? Colors.black : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, animation) =>
              ScaleTransition(scale: animation, child: child),
          child: Icon(_fabIcon, key: ValueKey(_fabIcon)),
        ),
      ),
    );
  }
}

/// A sleek, minimal bottom bar with an animated "pill" behind the selected
/// destination — the label slides in only for the active tab.
class _ModernNavBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;

  const _ModernNavBar({required this.index, required this.onSelect});

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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
              const SizedBox(width: 8),
              _NavPill(
                icon: Icons.call_outlined,
                activeIcon: Icons.call,
                label: 'Calls',
                selected: index == 1,
                onTap: () => onSelect(1),
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
  final VoidCallback onTap;

  const _NavPill({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
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
          horizontal: selected ? 20 : 18,
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
            Icon(selected ? activeIcon : icon,
                size: 24, color: selected ? ink : idle),
            AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
              child: selected
                  ? Padding(
                      padding: const EdgeInsets.only(left: 9),
                      child: Text(
                        label,
                        style: TextStyle(
                          color: ink,
                          fontSize: 14.5,
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
