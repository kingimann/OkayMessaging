import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../state/chat_store.dart';
import '../widgets/chat_list_tile.dart';
import 'chat_screen.dart';

/// Search across conversations by contact name and message content.
class ChatSearchDelegate extends SearchDelegate<void> {
  ChatSearchDelegate() : super(searchFieldLabel: 'Search...');

  List<Chat> _matches() {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return ChatStore.instance.allChats.where((c) {
      if (c.contact.name.toLowerCase().contains(q)) return true;
      return c.messages.any((m) => m.text.toLowerCase().contains(q));
    }).toList();
  }

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () => query = '',
          ),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildResults(BuildContext context) => _buildList(context);

  @override
  Widget buildSuggestions(BuildContext context) => _buildList(context);

  Widget _buildList(BuildContext context) {
    if (query.trim().isEmpty) {
      return const Center(child: Text('Search for chats and messages'));
    }
    final results = _matches();
    if (results.isEmpty) {
      return Center(child: Text('No results for "$query"'));
    }
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, index) {
        final chat = results[index];
        return ChatListTile(
          chat: chat,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
            );
          },
        );
      },
    );
  }
}
