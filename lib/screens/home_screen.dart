import 'package:flutter/material.dart';

import '../tabs/calls_tab.dart';
import '../tabs/chats_tab.dart';
import '../tabs/status_tab.dart';
import '../theme/app_theme.dart';
import 'chat_search_delegate.dart';
import 'new_chat_screen.dart';
import 'settings_screen.dart';

/// The top-level screen hosting the Chats / Status / Calls tabs.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  final _tabs = const [
    Tab(text: 'Chats'),
    Tab(text: 'Status'),
    Tab(text: 'Calls'),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  IconData get _fabIcon {
    switch (_tabController.index) {
      case 1:
        return Icons.camera_alt;
      case 2:
        return Icons.add_call;
      default:
        return Icons.chat;
    }
  }

  void _onFabPressed() {
    // Only the Chats tab has a fully wired action in this demo.
    if (_tabController.index == 0) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const NewChatScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Okay Messaging'),
        bottom: TabBar(controller: _tabController, tabs: _tabs),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => showSearch(
              context: context,
              delegate: ChatSearchDelegate(),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'settings') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
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
      body: TabBarView(
        controller: _tabController,
        children: const [
          ChatsTab(),
          StatusTab(),
          CallsTab(),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _onFabPressed,
        backgroundColor: AppColors.tealGreenDark,
        child: Icon(_fabIcon, color: Colors.white),
      ),
    );
  }
}
