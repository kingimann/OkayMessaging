import 'package:flutter/material.dart';

import 'communities.dart';
import 'home_screen.dart' show HomeNavBar;
import 'server_discover_screen.dart';

/// Servers as a PUSHED screen (the owner's call): opened from the sidebar row,
/// left with a normal back arrow. Wraps the same [CommunitiesTab] the old
/// bottom tab hosted, and carries the actions home's app bar used to offer for
/// it — search, Discover, Join with a code, New server.
class ServersScreen extends StatelessWidget {
  const ServersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Servers'),
        actions: [
          // No magnifier: this opened the very delegate the bottom bar's
          // Search pill now carries, so it was the same search twice.
          IconButton(
            icon: const Icon(Icons.explore_outlined),
            tooltip: 'Discover servers',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const ServerDiscoverScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.vpn_key_outlined),
            tooltip: 'Join with a code',
            onPressed: () => joinByCodeFlow(context),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New server',
            onPressed: () => createCommunityFlow(context),
          ),
        ],
      ),
      body: const CommunitiesTab(),
      // A pushed screen used to be a dead end you could only leave backwards.
      // The bar comes with it (nothing selected — this is not a tab), so a
      // server is one tap from Chats like everywhere else.
      bottomNavigationBar: const HomeNavBar(),
    );
  }
}
