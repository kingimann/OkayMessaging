import 'package:flutter/material.dart';

import '../data/mock_data.dart';
import '../models/chat.dart';
import '../screens/chat_screen.dart';
import '../widgets/chat_list_tile.dart';

/// The primary "Chats" tab showing all conversations.
class ChatsTab extends StatefulWidget {
  const ChatsTab({super.key});

  @override
  State<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<ChatsTab> {
  late List<Chat> _chats;

  @override
  void initState() {
    super.initState();
    _chats = MockData.chats();
    _sort();
  }

  void _sort() {
    _chats.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      final at = a.lastMessage?.time ?? DateTime(0);
      final bt = b.lastMessage?.time ?? DateTime(0);
      return bt.compareTo(at);
    });
  }

  void _openChat(Chat chat) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)))
        .then((_) {
      // Clear unread badge after visiting the conversation.
      final idx = _chats.indexWhere((c) => c.id == chat.id);
      if (idx != -1 && _chats[idx].unreadCount > 0) {
        setState(() {
          _chats[idx] = _chats[idx].copyWith(unreadCount: 0);
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_chats.isEmpty) {
      return const Center(child: Text('No chats yet'));
    }
    return ListView.separated(
      itemCount: _chats.length,
      separatorBuilder: (_, __) => const Divider(
        height: 1,
        indent: 84,
        thickness: 0.4,
      ),
      itemBuilder: (context, index) {
        final chat = _chats[index];
        return ChatListTile(chat: chat, onTap: () => _openChat(chat));
      },
    );
  }
}
