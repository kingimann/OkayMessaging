import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../models/message.dart';
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/chat_list_tile.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';

/// A single message that matched the query, with the chat it belongs to.
class _MessageHit {
  final Chat chat;
  final Message message;
  const _MessageHit(this.chat, this.message);
}

/// Global search: matches conversations by contact name and, separately, every
/// message whose text contains the query — each shown with a highlighted
/// snippet, WhatsApp-style.
class ChatSearchDelegate extends SearchDelegate<void> {
  ChatSearchDelegate() : super(searchFieldLabel: 'Search...');

  List<Chat> _chatMatches(String q) => ChatStore.instance.allChats
      .where((c) => c.contact.name.toLowerCase().contains(q))
      .toList();

  List<_MessageHit> _messageMatches(String q) {
    final hits = <_MessageHit>[];
    for (final chat in ChatStore.instance.allChats) {
      for (final m in chat.messages) {
        if (m.text.toLowerCase().contains(q)) {
          hits.add(_MessageHit(chat, m));
        }
      }
    }
    hits.sort((a, b) => b.message.time.compareTo(a.message.time));
    return hits;
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

  void _open(BuildContext context, Chat chat) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
    );
  }

  Widget _buildList(BuildContext context) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return const Center(child: Text('Search for chats and messages'));
    }
    final chats = _chatMatches(q);
    final messages = _messageMatches(q);
    if (chats.isEmpty && messages.isEmpty) {
      return Center(child: Text('No results for "$query"'));
    }

    return ListView(
      children: [
        if (chats.isNotEmpty) ...[
          const _SectionHeader('Chats'),
          for (final chat in chats)
            ChatListTile(chat: chat, onTap: () => _open(context, chat)),
        ],
        if (messages.isNotEmpty) ...[
          _SectionHeader('Messages (${messages.length})'),
          for (final hit in messages)
            _MessageResultTile(
              hit: hit,
              query: q,
              onTap: () => _open(context, hit.chat),
            ),
        ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.tealGreenDark,
        ),
      ),
    );
  }
}

class _MessageResultTile extends StatelessWidget {
  final _MessageHit hit;
  final String query;
  final VoidCallback onTap;

  const _MessageResultTile({
    required this.hit,
    required this.query,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: UserAvatar(user: hit.chat.contact, radius: 22),
      title: Text(
        hit.chat.contact.name,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: _Highlighted(text: hit.message.text, query: query),
      trailing: Text(
        DateFormatter.callLabel(hit.message.time),
        style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
      ),
      onTap: onTap,
    );
  }
}

/// Renders [text] with each case-insensitive occurrence of [query] highlighted.
class _Highlighted extends StatelessWidget {
  final String text;
  final String query;

  const _Highlighted({required this.text, required this.query});

  @override
  Widget build(BuildContext context) {
    final baseColor =
        Theme.of(context).textTheme.bodyMedium?.color?.withValues(alpha: 0.7);
    if (query.isEmpty) {
      return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    final lower = text.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final index = lower.indexOf(query, start);
      if (index < 0) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }
      spans.add(TextSpan(
        text: text.substring(index, index + query.length),
        style: const TextStyle(
          color: AppColors.tealGreenDark,
          fontWeight: FontWeight.w700,
        ),
      ));
      start = index + query.length;
    }
    return Text.rich(
      TextSpan(style: TextStyle(color: baseColor), children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
