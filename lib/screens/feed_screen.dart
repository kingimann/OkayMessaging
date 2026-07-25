import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../state/chat_store.dart';
import '../state/feed_store.dart';
import '../state/follow_store.dart';
import 'chat_screen.dart';
import 'people_screen.dart';

/// Splits post text into styled spans: @mentions, #tags, and links pop in
/// the accent colour. Pure, so it's easy to test.
List<TextSpan> feedSpans(String text, TextStyle base, TextStyle accent) {
  final spans = <TextSpan>[];
  final pattern =
      RegExp(r'(@[A-Za-z0-9_]+|#[A-Za-z0-9_]+|https?://\S+)');
  var last = 0;
  for (final m in pattern.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start), style: base));
    }
    spans.add(TextSpan(text: m.group(0), style: accent));
    last = m.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last), style: base));
  }
  return spans.isEmpty ? [TextSpan(text: text, style: base)] : spans;
}

/// An X-style feed for a server: a composer up top, then a timeline of
/// short posts with reply / repost / like actions. "Following" narrows the
/// timeline to people you follow (plus your own posts).
class FeedScreen extends StatefulWidget {
  final String communityId;
  final String communityName;

  const FeedScreen({
    super.key,
    required this.communityId,
    required this.communityName,
  });

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  final TextEditingController _composer = TextEditingController();

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  void _post() {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    FeedStore.instance.add(widget.communityId, text);
    _composer.clear();
    FocusScope.of(context).unfocus();
  }

  void _openThread(FeedPost post) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FeedPostScreen(postId: post.id),
    ));
  }

  /// Tapping an author: follow/unfollow them, or jump to your chat.
  void _authorSheet(FeedPost post) {
    final mine = post.authorUsername == 'you' ||
        post.authorUsername == AppState.profile.value.username;
    final contact = ChatStore.instance.chats
        .map((c) => c.contact)
        .where((u) =>
            u.username.toLowerCase() == post.authorUsername.toLowerCase())
        .toList();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FeedAvatar(
                  name: post.authorName, username: post.authorUsername),
              const SizedBox(height: 8),
              Text(post.authorName,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
              Text('@${post.authorUsername}',
                  style: TextStyle(color: Colors.grey.shade600)),
              const SizedBox(height: 14),
              if (mine)
                Text('This is you.',
                    style: TextStyle(color: Colors.grey.shade600))
              else
                ListenableBuilder(
                  listenable: FollowStore.instance,
                  builder: (context, _) {
                    final following = FollowStore.instance
                        .isFollowing(post.authorUsername);
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        following
                            ? OutlinedButton.icon(
                                onPressed: () => FollowStore.instance
                                    .toggle(post.authorUsername),
                                icon: const Icon(Icons.check, size: 18),
                                label: const Text('Following'),
                              )
                            : FilledButton.icon(
                                onPressed: () => FollowStore.instance
                                    .toggle(post.authorUsername),
                                icon: const Icon(Icons.person_add_alt_1,
                                    size: 18),
                                label: const Text('Follow'),
                              ),
                        if (contact.isNotEmpty) ...[
                          const SizedBox(width: 10),
                          OutlinedButton.icon(
                            onPressed: () {
                              Navigator.of(sheetContext).pop();
                              final chat = ChatStore.instance
                                  .chatWithContact(contact.first.id);
                              if (chat != null) {
                                Navigator.of(context).push(
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            ChatScreen(chat: chat)));
                              }
                            },
                            icon: const Icon(Icons.chat_bubble_outline,
                                size: 16),
                            label: const Text('Message'),
                          ),
                        ],
                      ],
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _postOptions(FeedPost post) {
    final mine = post.authorUsername == 'you' ||
        post.authorUsername == AppState.profile.value.username;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy text'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: post.text));
                Navigator.of(sheetContext).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.forum_outlined),
              title: const Text('View thread'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _openThread(post);
              },
            ),
            if (!mine) ...[
              ListTile(
                leading: const Icon(Icons.visibility_off_outlined),
                title: const Text('Hide post'),
                onTap: () {
                  FeedStore.instance.hidePost(post.id);
                  Navigator.of(sheetContext).pop();
                },
              ),
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Report post'),
                onTap: () {
                  FeedStore.instance.hidePost(post.id);
                  Navigator.of(sheetContext).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content:
                            Text('Reported — the post is hidden for you.')),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.volume_off_outlined),
                title: Text(
                    FeedStore.instance.isMuted(post.authorUsername)
                        ? 'Unmute @${post.authorUsername}'
                        : 'Mute @${post.authorUsername}'),
                onTap: () {
                  FeedStore.instance.toggleMute(post.authorUsername);
                  Navigator.of(sheetContext).pop();
                },
              ),
            ],
            if (mine)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Delete post',
                    style: TextStyle(color: Colors.red)),
                onTap: () {
                  FeedStore.instance.deletePost(post.id);
                  Navigator.of(sheetContext).pop();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.communityName} · Feed'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt),
            tooltip: 'Add and follow people',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PeopleScreen()),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: FeedStore.instance,
        builder: (context, _) {
          // One timeline for everyone in the server — no For-you/Following
          // split.
          final posts = FeedStore.instance.postsFor(widget.communityId);
          return ListView(
            children: [
              _Composer(controller: _composer, onPost: _post),
              const Divider(height: 1),
              if (posts.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      'No posts yet. Be the first to say something!',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ),
                ),
              for (final post in posts) ...[
                InkWell(
                  onTap: () => _openThread(post),
                  onLongPress: () => _postOptions(post),
                  child: _PostCard(
                    post: post,
                    onLike: () => FeedStore.instance.toggleLike(post.id),
                    onRepost: () => FeedStore.instance.toggleRepost(post.id),
                    onReply: () => _openThread(post),
                    onAuthor: () => _authorSheet(post),
                    // Only your own posts are deletable.
                    onDelete: post.authorUsername == 'you' ||
                            post.authorUsername ==
                                AppState.profile.value.username
                        ? () => FeedStore.instance.deletePost(post.id)
                        : null,
                  ),
                ),
                const Divider(height: 1),
              ],
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

/// The "What's happening?" box at the top of the feed.
class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onPost;

  const _Composer({required this.controller, required this.onPost});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _FeedAvatar(name: 'You', username: 'you'),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              maxLength: 280,
              buildCounter: (context,
                      {required currentLength,
                      required isFocused,
                      maxLength}) =>
                  currentLength > 200
                      ? Text('$currentLength/$maxLength',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600))
                      : null,
              decoration: const InputDecoration(
                hintText: "What's happening?",
                border: InputBorder.none,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: onPost, child: const Text('Post')),
        ],
      ),
    );
  }
}

/// One X-style post row.
class _PostCard extends StatelessWidget {
  final FeedPost post;
  final VoidCallback onLike;
  final VoidCallback onRepost;
  final VoidCallback onReply;
  final VoidCallback? onDelete;
  final VoidCallback? onAuthor;

  const _PostCard({
    required this.post,
    required this.onLike,
    required this.onRepost,
    required this.onReply,
    this.onDelete,
    this.onAuthor,
  });

  @override
  Widget build(BuildContext context) {
    final grey = Colors.grey.shade600;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: onAuthor,
            child: _FeedAvatar(
                name: post.authorName, username: post.authorUsername),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: GestureDetector(
                        onTap: onAuthor,
                        child: Text(post.authorName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 15)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                          '@${post.authorUsername} · ${feedAge(post.time)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: grey, fontSize: 13.5)),
                    ),
                    const Spacer(),
                    if (onDelete != null)
                      SizedBox(
                        height: 28,
                        width: 28,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 16,
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete post',
                          onPressed: onDelete,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text.rich(
                  TextSpan(
                    children: feedSpans(
                      post.text,
                      const TextStyle(fontSize: 15),
                      TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _PostAction(
                      icon: Icons.chat_bubble_outline,
                      count: post.replies,
                      onTap: onReply,
                      tooltip: 'Reply',
                    ),
                    const SizedBox(width: 28),
                    _PostAction(
                      icon: Icons.repeat,
                      count: post.reposts,
                      active: post.reposted,
                      activeColor: const Color(0xFF00BA7C),
                      onTap: onRepost,
                      tooltip: 'Repost',
                    ),
                    const SizedBox(width: 28),
                    _PostAction(
                      icon: post.liked
                          ? Icons.favorite
                          : Icons.favorite_border,
                      count: post.likes,
                      active: post.liked,
                      activeColor: const Color(0xFFF91880),
                      onTap: onLike,
                      tooltip: 'Like',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PostAction extends StatelessWidget {
  final IconData icon;
  final int count;
  final bool active;
  final Color? activeColor;
  final VoidCallback onTap;
  final String tooltip;

  const _PostAction({
    required this.icon,
    required this.count,
    required this.onTap,
    required this.tooltip,
    this.active = false,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? activeColor : Colors.grey.shade600;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              Icon(icon, size: 17, color: color),
              if (count > 0) ...[
                const SizedBox(width: 4),
                Text('$count',
                    style: TextStyle(fontSize: 12.5, color: color)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A post opened as a thread: the post up top, its replies below, and a
/// reply composer pinned to the bottom.
class FeedPostScreen extends StatefulWidget {
  final String postId;
  const FeedPostScreen({super.key, required this.postId});

  @override
  State<FeedPostScreen> createState() => _FeedPostScreenState();
}

class _FeedPostScreenState extends State<FeedPostScreen> {
  final TextEditingController _reply = TextEditingController();

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  void _send() {
    final text = _reply.text.trim();
    if (text.isEmpty) return;
    FeedStore.instance.reply(widget.postId, text);
    _reply.clear();
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Post')),
      body: ListenableBuilder(
        listenable: FeedStore.instance,
        builder: (context, _) {
          final post = FeedStore.instance.postById(widget.postId);
          if (post == null) {
            return const Center(child: Text('This post was deleted.'));
          }
          final replies = FeedStore.instance.repliesTo(post.id);
          return Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    _PostCard(
                      post: post,
                      onLike: () => FeedStore.instance.toggleLike(post.id),
                      onRepost: () =>
                          FeedStore.instance.toggleRepost(post.id),
                      onReply: () {},
                    ),
                    const Divider(height: 1),
                    if (replies.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(28),
                        child: Center(
                          child: Text('No replies yet.',
                              style:
                                  TextStyle(color: Colors.grey.shade600)),
                        ),
                      ),
                    for (final r in replies) ...[
                      Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: _PostCard(
                          post: r,
                          onLike: () =>
                              FeedStore.instance.toggleLike(r.id),
                          onRepost: () =>
                              FeedStore.instance.toggleRepost(r.id),
                          onReply: () {},
                        ),
                      ),
                      const Divider(height: 1),
                    ],
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 12, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _reply,
                          minLines: 1,
                          maxLines: 3,
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(
                            hintText:
                                'Reply to @${post.authorUsername}',
                            filled: true,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        icon: const Icon(Icons.send, size: 18),
                        tooltip: 'Send reply',
                        onPressed: _send,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A small initials avatar coloured stably from the username.
class _FeedAvatar extends StatelessWidget {
  final String name;
  final String username;

  const _FeedAvatar({required this.name, required this.username});

  @override
  Widget build(BuildContext context) {
    var h = 0;
    for (final c in username.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    final color =
        Colors.primaries[h % Colors.primaries.length].shade600;
    final initials = name.isEmpty
        ? '?'
        : name
            .trim()
            .split(RegExp(r'\s+'))
            .take(2)
            .map((w) => w[0].toUpperCase())
            .join();
    return CircleAvatar(
      radius: 19,
      backgroundColor: color,
      child: Text(initials,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 13.5,
              fontWeight: FontWeight.w700)),
    );
  }
}
