import 'package:flutter/material.dart';

import '../data/mock_data.dart';
import '../models/call.dart';
import '../models/chat.dart';
import '../models/community.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../state/call_log.dart';
import '../state/chat_store.dart';
import '../state/community_store.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/chat_list_tile.dart';
import '../widgets/linkable_text.dart';
import '../widgets/user_avatar.dart';
import 'communities.dart';
import 'chat_screen.dart';

/// A message that matched, with the chat it belongs to.
class _MessageHit {
  final Chat chat;
  final Message message;
  const _MessageHit(this.chat, this.message);
}

class _ChannelHit {
  final Community community;
  final Channel channel;
  const _ChannelHit(this.community, this.channel);
}

/// Filters shown as chips above the results.
enum _Filter { all, people, messages, servers, calls, links }

extension on _Filter {
  String get label => switch (this) {
        _Filter.all => 'All',
        _Filter.people => 'People',
        _Filter.messages => 'Messages',
        _Filter.servers => 'Servers',
        _Filter.calls => 'Calls',
        _Filter.links => 'Links',
      };
}

/// Universal search: finds people, messages (jump to the exact one), servers &
/// channels, recent calls, and shared links — with type filters and a short
/// preview when idle.
class ChatSearchDelegate extends SearchDelegate<void> {
  ChatSearchDelegate() : super(searchFieldLabel: 'Search everything…');

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
              icon: const Icon(Icons.clear), onPressed: () => query = ''),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildResults(BuildContext context) => _SearchBody(query: query);

  @override
  Widget buildSuggestions(BuildContext context) => _SearchBody(query: query);
}

class _SearchBody extends StatefulWidget {
  final String query;
  const _SearchBody({required this.query});

  @override
  State<_SearchBody> createState() => _SearchBodyState();
}

class _SearchBodyState extends State<_SearchBody> {
  _Filter _filter = _Filter.all;

  bool _show(_Filter f) => _filter == _Filter.all || _filter == f;

  // --- Data gathering ----------------------------------------------------

  List<AppUser> _people(String q) {
    final seen = <String>{};
    final out = <AppUser>[];
    void add(AppUser u) {
      final key = u.id;
      if (seen.add(key) &&
          (u.name.toLowerCase().contains(q) ||
              u.username.toLowerCase().contains(q) ||
              u.phone.replaceAll(RegExp(r'\D'), '').contains(q))) {
        out.add(u);
      }
    }

    for (final c in ChatStore.instance.allChats) {
      add(c.contact);
    }
    for (final u in MockData.contacts()) {
      add(u);
    }
    return out;
  }

  List<_MessageHit> _messages(String q, {bool linksOnly = false}) {
    final hits = <_MessageHit>[];
    for (final chat in ChatStore.instance.allChats) {
      for (final m in chat.messages) {
        if (m.text.isEmpty) continue;
        if (linksOnly && !LinkableText.urlPattern.hasMatch(m.text)) continue;
        if (m.text.toLowerCase().contains(q)) hits.add(_MessageHit(chat, m));
      }
    }
    hits.sort((a, b) => b.message.time.compareTo(a.message.time));
    return hits;
  }

  List<Community> _servers(String q) => CommunityStore.instance.communities
      .where((c) => c.name.toLowerCase().contains(q))
      .toList();

  List<_ChannelHit> _channels(String q) {
    final out = <_ChannelHit>[];
    for (final c in CommunityStore.instance.communities) {
      for (final ch in c.channels) {
        if (ch.name.toLowerCase().contains(q)) out.add(_ChannelHit(c, ch));
      }
    }
    return out;
  }

  List<CallRecord> _calls(String q) => CallLog.instance.records
      .where((r) => r.user.name.toLowerCase().contains(q))
      .toList();

  // --- Navigation --------------------------------------------------------

  void _openChat(Chat chat, {String? messageId}) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ChatScreen(chat: chat, initialMessageId: messageId)));
  }

  void _startChat(AppUser contact) {
    final store = ChatStore.instance;
    var chat = store.chatWithContact(contact.id);
    if (chat == null) {
      chat = Chat(id: 'chat_${contact.id}', contact: contact, messages: const []);
      store.upsert(chat);
    } else if (chat.isArchived) {
      store.setArchived(chat.id, false);
    }
    _openChat(chat);
  }

  void _openCommunity(String id) => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CommunityScreen(communityId: id)));

  void _openChannel(_ChannelHit h) => Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => ChannelScreen(
              communityId: h.community.id, channelId: h.channel.id)));

  // --- Build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final q = widget.query.trim().toLowerCase();
    if (q.isEmpty) return _idle();

    final people = _show(_Filter.people) ? _people(q) : const <AppUser>[];
    final messages = _show(_Filter.messages) ? _messages(q) : const [];
    final servers = _show(_Filter.servers) ? _servers(q) : const <Community>[];
    final channels =
        _show(_Filter.servers) ? _channels(q) : const <_ChannelHit>[];
    final calls = _show(_Filter.calls) ? _calls(q) : const <CallRecord>[];
    final links = _filter == _Filter.links
        ? _messages(q, linksOnly: true)
        : const <_MessageHit>[];

    final total = people.length +
        messages.length +
        servers.length +
        channels.length +
        calls.length +
        links.length;

    return Column(
      children: [
        _filterBar(),
        if (total == 0)
          Expanded(
            child: Center(
              child: Text('No results for "${widget.query}"',
                  style: TextStyle(color: Colors.grey.shade500)),
            ),
          )
        else
          Expanded(
            child: ListView(
              children: [
                if (people.isNotEmpty) ...[
                  const _Header('People'),
                  for (final p in people) _PersonTile(user: p, onTap: () => _startChat(p)),
                ],
                if (servers.isNotEmpty) ...[
                  const _Header('Servers'),
                  for (final s in servers)
                    _ServerTile(community: s, onTap: () => _openCommunity(s.id)),
                ],
                if (channels.isNotEmpty) ...[
                  const _Header('Channels'),
                  for (final h in channels)
                    _ChannelTile(hit: h, onTap: () => _openChannel(h)),
                ],
                if (messages.isNotEmpty) ...[
                  _Header('Messages (${messages.length})'),
                  for (final hit in messages)
                    _MessageResultTile(
                      hit: hit,
                      query: q,
                      onTap: () =>
                          _openChat(hit.chat, messageId: hit.message.id),
                    ),
                ],
                if (links.isNotEmpty) ...[
                  _Header('Links (${links.length})'),
                  for (final hit in links)
                    _MessageResultTile(
                      hit: hit,
                      query: q,
                      onTap: () =>
                          _openChat(hit.chat, messageId: hit.message.id),
                    ),
                ],
                if (calls.isNotEmpty) ...[
                  const _Header('Calls'),
                  for (final r in calls)
                    _CallTile(record: r, onTap: () => _startChat(r.user)),
                ],
                const SizedBox(height: 24),
              ],
            ),
          ),
      ],
    );
  }

  Widget _filterBar() {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          for (final f in _Filter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(f.label),
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
              ),
            ),
        ],
      ),
    );
  }

  /// Idle state: quick tips + your most recent chats to tap into.
  Widget _idle() {
    final recents = ChatStore.instance.chats.take(6).toList();
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: Colors.grey.shade500),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Search people, messages, servers, channels, calls and links',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        if (recents.isNotEmpty) ...[
          const _Header('Recent chats'),
          for (final chat in recents)
            ChatListTile(chat: chat, onTap: () => _openChat(chat)),
        ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final String label;
  const _Header(this.label);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Text(label,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.tealGreenDark)),
      );
}

class _PersonTile extends StatelessWidget {
  final AppUser user;
  final VoidCallback onTap;
  const _PersonTile({required this.user, required this.onTap});

  @override
  Widget build(BuildContext context) => ListTile(
        leading: UserAvatar(user: user, radius: 22),
        title: Text(user.name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(user.username.isNotEmpty ? '@${user.username}' : user.phone,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chat_bubble_outline, size: 20),
        onTap: onTap,
      );
}

class _ServerTile extends StatelessWidget {
  final Community community;
  final VoidCallback onTap;
  const _ServerTile({required this.community, required this.onTap});

  Color get _color =>
      Color(int.parse(community.color.replaceFirst('#', 'ff'), radix: 16));

  @override
  Widget build(BuildContext context) => ListTile(
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: _color,
          child: Text(community.name[0].toUpperCase(),
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700)),
        ),
        title: Text(community.name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${community.channels.length} channels · '
            '${community.members.length} members'),
        onTap: onTap,
      );
}

class _ChannelTile extends StatelessWidget {
  final _ChannelHit hit;
  final VoidCallback onTap;
  const _ChannelTile({required this.hit, required this.onTap});

  @override
  Widget build(BuildContext context) => ListTile(
        leading: const Icon(Icons.tag, color: Colors.grey),
        title: Text(hit.channel.name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('in ${hit.community.name}'),
        onTap: onTap,
      );
}

class _CallTile extends StatelessWidget {
  final CallRecord record;
  final VoidCallback onTap;
  const _CallTile({required this.record, required this.onTap});

  @override
  Widget build(BuildContext context) => ListTile(
        leading: UserAvatar(user: record.user, radius: 22),
        title: Text(record.user.name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Row(children: [
          Icon(
              record.type == CallType.video ? Icons.videocam : Icons.call,
              size: 15,
              color: record.isMissed ? Colors.red : Colors.green),
          const SizedBox(width: 4),
          Text(DateFormatter.callLabel(record.time)),
        ]),
        onTap: onTap,
      );
}

class _MessageResultTile extends StatelessWidget {
  final _MessageHit hit;
  final String query;
  final VoidCallback onTap;

  const _MessageResultTile(
      {required this.hit, required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) => ListTile(
        leading: UserAvatar(user: hit.chat.contact, radius: 22),
        title: Text(hit.chat.contact.name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: _Highlighted(text: hit.message.text, query: query),
        trailing: Text(DateFormatter.callLabel(hit.message.time),
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
        onTap: onTap,
      );
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
      if (index > start) spans.add(TextSpan(text: text.substring(start, index)));
      spans.add(TextSpan(
        text: text.substring(index, index + query.length),
        style: const TextStyle(
            color: AppColors.tealGreenDark, fontWeight: FontWeight.w700),
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
