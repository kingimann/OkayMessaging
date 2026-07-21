import 'package:flutter/material.dart';

import '../tabs/calls_tab.dart';
import '../tabs/chats_tab.dart';
import '../theme/app_theme.dart';
import 'new_chat_screen.dart';
import 'settings_screen.dart';
import 'starred_messages_screen.dart';

/// The top-level screen: a bottom navigation bar switching between Chats and
/// Calls, styled after WhatsApp's current look.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text(
          'Okay Messaging',
          style: TextStyle(
            color: AppColors.tealGreen,
            fontWeight: FontWeight.bold,
            fontSize: 22,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.camera_alt_outlined),
            onPressed: () {},
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'settings') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              } else if (value == 'starred') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const StarredMessagesScreen()),
                );
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'new_group', child: Text('New group')),
              PopupMenuItem(
                  value: 'new_broadcast', child: Text('New broadcast')),
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
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.call_outlined),
            selectedIcon: Icon(Icons.call),
            label: 'Calls',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _onFabPressed,
        backgroundColor: AppColors.tealGreenDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, animation) =>
              ScaleTransition(scale: animation, child: child),
          child: Icon(_fabIcon, key: ValueKey(_fabIcon), color: Colors.white),
        ),
      ),
    );
  }
}
