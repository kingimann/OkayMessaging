import 'find_people_screen.dart';
import 'public_feed_screen.dart';
import '../widgets/feed_post_parts.dart';
import '../state/public_feed_store.dart';
import '../state/chat_lock.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/mock_data.dart';
import '../models/call.dart';
import '../models/chat.dart';
import '../models/community.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../state/call_log.dart';
import '../state/chat_store.dart';
import '../state/community_store.dart';
import '../state/feed_store.dart';
import '../state/recent_searches.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/chat_list_tile.dart';
import '../widgets/linkable_text.dart';
import '../widgets/user_avatar.dart';
import 'communities.dart';
import 'chat_screen.dart';
import 'feed_screen.dart';
import 'forum_screen.dart';

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

/// A forum post that matched, with the server & channel it lives in.
class _PostHit {
  final Community community;
  final Channel channel;
  final ForumPost post;
  const _PostHit(this.community, this.channel, this.post);
}

/// Filters shown as chips above the results.
enum _Filter { all, people, messages, posts, servers, calls, links }

extension on _Filter {
  String get label => switch (this) {
        _Filter.all => 'All',
        _Filter.people => 'People',
        _Filter.messages => 'Messages',
        _Filter.posts => 'Posts',
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

  /// Sets [query] and shows results — used when tapping a remembered search.
  void _run(BuildContext context, String q) {
    query = q;
    showResults(context);
  }

  @override
  Widget buildResults(BuildContext context) {
    // A submitted query is worth remembering for one-tap re-runs.
    RecentSearches.instance.add(query);
    return _SearchBody(query: query, onRun: (q) => _run(context, q));
  }

  @override
  Widget buildSuggestions(BuildContext context) =>
      _SearchBody(query: query, onRun: (q) => _run(context, q));
}

/// The way out of a search that found nothing.
///
/// This search only ever looked at what is already on the device — chats,
/// contacts, servers, calls. Looking for somebody you have not met yet
/// therefore returned "No results" and stopped, with nothing to say that a
/// directory exists or how to reach it. It was on the Calls tab, behind a
/// second magnifying glass that meant something different from this one.
class _DirectoryLookup extends StatelessWidget {
  const _DirectoryLookup({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final handle = query.trim().replaceFirst('@', '');
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Nobody on this device matches.',
            style: TextStyle(fontSize: 13, color: AppColors.subtle(context))),
        const SizedBox(height: 10),
        FilledButton.tonalIcon(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => FindPeopleScreen(initialQuery: handle))),
          icon: const Icon(Icons.person_search_outlined, size: 18),
          label: Text(handle.isEmpty
              ? 'Find people by username'
              : 'Look up @$handle'),
        ),
      ],
    );
  }
}

class _SearchBody extends StatefulWidget {
  final String query;

  /// Re-runs a tapped remembered query.
  final void Function(String) onRun;

  const _SearchBody({required this.query, required this.onRun});

  @override
  State<_SearchBody> createState() => _SearchBodyState();
}

class _SearchBodyState extends State<_SearchBody> {
  _Filter _filter = _Filter.all;

  /// Hidden chats the typed query turned out to be the password for.
  ///
  /// This is the ONLY way back to a hidden chat: there is no row, no folder
  /// and no count anywhere, because any of those would announce that hidden
  /// chats exist, which is most of what hiding one is for. The search field
  /// is where somebody types something private already.
  List<Chat> _revealed = const [];
  String _revealedFor = '';

  @override
  void initState() {
    super.initState();
    _tryReveal();
  }

  @override
  void didUpdateWidget(_SearchBody old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _tryReveal();
  }

  /// Tries the query as a password. Short queries are skipped rather than
  /// derived: a password is at least 4 characters, and running PBKDF2 per
  /// hidden chat on every keystroke of a real search would burn an isolate
  /// for nothing.
  Future<void> _tryReveal() async {
    final q = widget.query.trim();
    if (q == _revealedFor) return;
    _revealedFor = q;
    if (q.length < 4 || ChatLock.instance.hiddenCount == 0) {
      if (_revealed.isNotEmpty && mounted) setState(() => _revealed = const []);
      return;
    }
    final ids = await ChatLock.instance.revealHidden(q);
    if (!mounted || q != _revealedFor) return;
    setState(() => _revealed = [
          for (final id in ids)
            if (ChatStore.instance.chatById(id) != null)
              ChatStore.instance.chatById(id)!
        ]);
  }

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

    for (final c in ChatStore.instance.searchableChats) {
      add(c.contact);
    }
    for (final u in MockData.contacts()) {
      add(u);
    }
    return out;
  }

  List<_MessageHit> _messages(String q, {bool linksOnly = false}) {
    final hits = <_MessageHit>[];
    for (final chat in ChatStore.instance.searchableChats) {
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

  List<_PostHit> _forumPosts(String q) {
    final out = <_PostHit>[];
    for (final c in CommunityStore.instance.communities) {
      for (final ch in c.channels) {
        if (ch.type != ChannelType.forum) continue;
        // The board's own filter, so the app-wide search matches exactly what
        // the board's magnifier used to before it was removed.
        for (final p in filterPosts(ch.posts, q)) {
          out.add(_PostHit(c, ch, p));
        }
      }
    }
    out.sort((a, b) => b.post.score.compareTo(a.post.score));
    return out;
  }

  /// Public NEWSFEED posts, which the Posts filter did not reach: it only
  /// walked the in-server forums. That gap mattered the moment the newsfeed
  /// lost its own magnifier and this became the only search in the app —
  /// otherwise a public post would have been findable from nowhere.
  ///
  /// Searches what the store has already loaded, which is what the timeline
  /// is showing; there is no server-side post search to call.
  List<PublicPost> _publicPosts(String q) {
    final out = PublicFeedStore.instance.posts
        .where((p) =>
            p.body.toLowerCase().contains(q) ||
            p.authorName.toLowerCase().contains(q) ||
            p.authorUsername.toLowerCase().contains(q))
        .toList();
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  /// SERVER-feed posts — the third post surface, and the last one this search
  /// could not reach. Listings are left out on purpose: a marketplace item is
  /// found in the marketplace, which has its own search over price, category
  /// and attributes that a text match here would only half-answer.
  List<FeedPost> _serverPosts(String q) {
    final out = FeedStore
        .searchPosts(
            FeedStore.instance.allPosts.where((p) => !p.isListing).toList(), q)
        .toList();
    out.sort((a, b) => b.time.compareTo(a.time));
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
    _openChat(ChatStore.instance.startChatWith(contact,
        myPhone: Session.instance.user.value?.phone,
        myAvatarColor: AppState.profile.value.avatarColor));
  }

  void _openCommunity(String id) => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CommunityScreen(communityId: id)));

  void _openChannel(_ChannelHit h) => Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => ChannelScreen(
              communityId: h.community.id, channelId: h.channel.id)));

  void _openPost(_PostHit h) => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ForumPostScreen(
          communityId: h.community.id,
          channelId: h.channel.id,
          postId: h.post.id)));

  // --- Build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final q = widget.query.trim().toLowerCase();
    if (q.isEmpty) return _idle();

    final people = _show(_Filter.people) ? _people(q) : const <AppUser>[];
    final messages = _show(_Filter.messages) ? _messages(q) : const [];
    final posts = _show(_Filter.posts) ? _forumPosts(q) : const <_PostHit>[];
    final feedPosts =
        _show(_Filter.posts) ? _publicPosts(q) : const <PublicPost>[];
    final serverPosts =
        _show(_Filter.posts) ? _serverPosts(q) : const <FeedPost>[];
    final servers = _show(_Filter.servers) ? _servers(q) : const <Community>[];
    final channels =
        _show(_Filter.servers) ? _channels(q) : const <_ChannelHit>[];
    final calls = _show(_Filter.calls) ? _calls(q) : const <CallRecord>[];
    final links = _filter == _Filter.links
        ? _messages(q, linksOnly: true)
        : const <_MessageHit>[];

    final total = _revealed.length +
        people.length +
        messages.length +
        posts.length +
        // Counted, or a query that ONLY matches a newsfeed or server post
        // renders the empty state over a list that has results in it.
        feedPosts.length +
        serverPosts.length +
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('No results for "${widget.query}"',
                      style: TextStyle(color: AppColors.subtle(context))),
                  const SizedBox(height: 16),
                  _DirectoryLookup(query: widget.query),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView(
              children: [
                if (_revealed.isNotEmpty) ...[
                  const _Header('Hidden'),
                  for (final chat in _revealed)
                    ChatListTile(chat: chat, onTap: () => _openChat(chat)),
                ],
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
                if (posts.isNotEmpty ||
                    feedPosts.isNotEmpty ||
                    serverPosts.isNotEmpty) ...[
                  _Header('Posts (${posts.length + feedPosts.length + serverPosts.length})'),
                  for (final h in posts)
                    _PostHitTile(
                        hit: h, query: q, onTap: () => _openPost(h)),
                  for (final p in feedPosts)
                    _FeedPostTile(
                      post: p,
                      query: q,
                      onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  PublicThreadScreen(postId: p.id))),
                    ),
                  for (final p in serverPosts)
                    _ServerPostTile(
                      post: p,
                      query: q,
                      onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => FeedPostScreen(postId: p.id))),
                    ),
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
                    _CallTile(record: r, onTap: () => _startChat(liveCallUser(r))),
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

  /// Idle state: recent searches, quick tips, and your most recent chats.
  Widget _idle() {
    final recents = ChatStore.instance.chats.take(6).toList();
    return AnimatedBuilder(
      animation: RecentSearches.instance,
      builder: (context, _) {
        final searches = RecentSearches.instance.queries;
        return ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Row(
                children: [
                  Icon(Icons.search, size: 18, color: AppColors.subtle(context)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Search people, messages, servers, channels, calls and links',
                      style:
                          TextStyle(color: AppColors.subtle(context), fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            if (searches.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
                child: Row(
                  children: [
                    const Expanded(child: _Header('Recent searches')),
                    TextButton(
                      onPressed: () => RecentSearches.instance.clear(),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              ),
              for (final q in searches)
                ListTile(
                  dense: true,
                  leading: Icon(Icons.history, color: AppColors.subtle(context)),
                  title: Text(q),
                  trailing: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Remove',
                    onPressed: () => RecentSearches.instance.remove(q),
                  ),
                  onTap: () => widget.onRun(q),
                ),
            ],
            if (recents.isNotEmpty) ...[
              const _Header('Recent chats'),
              for (final chat in recents)
                ChatListTile(chat: chat, onTap: () => _openChat(chat)),
            ],
          ],
        );
      },
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
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.accentOn(context))),
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

class _PostHitTile extends StatelessWidget {
  final _PostHit hit;
  final String query;
  final VoidCallback onTap;
  const _PostHitTile(
      {required this.hit, required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) => ListTile(
        leading: const CircleAvatar(
          radius: 20,
          backgroundColor: Color(0xFFFF4500),
          child: Icon(Icons.forum_rounded, color: Colors.white, size: 20),
        ),
        title: _Highlighted(text: hit.post.title, query: query),
        subtitle: Text(
          '${hit.community.name} · ${hit.post.score} points · '
          '${hit.post.comments.length} comments',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: onTap,
      );
}

class _CallTile extends StatelessWidget {
  final CallRecord record;
  final VoidCallback onTap;
  const _CallTile({required this.record, required this.onTap});

  @override
  Widget build(BuildContext context) => ListTile(
        // Live, not the copy frozen into the record when the call ended.
        leading: UserAvatar(user: liveCallUser(record), radius: 22),
        title: Text(liveCallUser(record).name,
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
            style: TextStyle(color: AppColors.subtle(context), fontSize: 12)),
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
        style: TextStyle(
            color: AppColors.accentOn(context), fontWeight: FontWeight.w700),
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

/// A public-newsfeed post in the universal search. Distinct from
/// [_PostHitTile], which is a forum post inside a server — the two live in
/// different places and open different screens, so telling them apart at a
/// glance matters more than a shared row.
/// A post from a server's feed. Labelled "Server" so it is never mistaken for
/// a public one — the two look identical and are seen by very different sets
/// of people.
class _ServerPostTile extends StatelessWidget {
  final FeedPost post;
  final String query;
  final VoidCallback onTap;
  const _ServerPostTile(
      {required this.post, required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final who = post.authorName.trim().isEmpty
        ? '@${post.authorUsername}'
        : post.authorName;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.secondaryContainer,
        child: Icon(Icons.forum_outlined,
            size: 18, color: scheme.onSecondaryContainer),
      ),
      title: _Highlighted(text: post.text, query: query),
      subtitle: Text('$who · Server',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
      onTap: onTap,
    );
  }
}

class _FeedPostTile extends StatelessWidget {
  final PublicPost post;
  final String query;
  final VoidCallback onTap;
  const _FeedPostTile(
      {required this.post, required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) => ListTile(
        leading: FeedAvatar(
            username: post.authorUsername, name: post.authorName, radius: 20),
        title: _Highlighted(text: post.displayBody, query: query),
        subtitle: Text(
          post.authorName.isEmpty
              ? '@${post.authorUsername} · Newsfeed'
              : '${post.authorName} · Newsfeed',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
        ),
        onTap: onTap,
      );
}
