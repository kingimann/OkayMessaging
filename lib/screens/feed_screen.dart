import 'package:flutter/material.dart';

import '../app_state.dart';
import '../state/feed_store.dart';
import '../state/follow_store.dart';

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
  bool _followingOnly = false;

  @override
  void initState() {
    super.initState();
    FeedStore.instance.seedIfEmpty(widget.communityId);
  }

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

  Future<void> _reply(FeedPost post) async {
    final controller = TextEditingController();
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
            left: 16,
            right: 16,
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Replying to @${post.authorUsername}',
                style: TextStyle(
                    color: Colors.grey.shade600, fontSize: 13.5)),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 4,
              minLines: 1,
              decoration:
                  const InputDecoration(hintText: 'Post your reply'),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(sheetContext).pop(true),
                child: const Text('Reply'),
              ),
            ),
          ],
        ),
      ),
    );
    if (sent == true && controller.text.trim().isNotEmpty) {
      FeedStore.instance.reply(post.id, controller.text);
    }
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.communityName} · Feed'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: SegmentedButton<bool>(
                style: const ButtonStyle(
                    visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: false, label: Text('For you')),
                  ButtonSegment(value: true, label: Text('Following')),
                ],
                selected: {_followingOnly},
                showSelectedIcon: false,
                onSelectionChanged: (s) =>
                    setState(() => _followingOnly = s.first),
              ),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge(
            [FeedStore.instance, FollowStore.instance]),
        builder: (context, _) {
          final posts = FeedStore.instance.postsFor(
            widget.communityId,
            onlyUsernames:
                _followingOnly ? FollowStore.instance.following : null,
          );
          return ListView(
            children: [
              _Composer(controller: _composer, onPost: _post),
              const Divider(height: 1),
              if (posts.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      _followingOnly
                          ? 'Nothing here yet — follow people from their '
                              'profile to build this timeline.'
                          : 'No posts yet. Say something!',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ),
                ),
              for (final post in posts) ...[
                _PostCard(
                  post: post,
                  onLike: () => FeedStore.instance.toggleLike(post.id),
                  onRepost: () => FeedStore.instance.toggleRepost(post.id),
                  onReply: () => _reply(post),
                  // Only your own posts are deletable.
                  onDelete: post.authorUsername == 'you' ||
                          post.authorUsername ==
                              AppState.profile.value.username
                      ? () => FeedStore.instance.deletePost(post.id)
                      : null,
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

  const _PostCard({
    required this.post,
    required this.onLike,
    required this.onRepost,
    required this.onReply,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final grey = Colors.grey.shade600;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FeedAvatar(name: post.authorName, username: post.authorUsername),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(post.authorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15)),
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
                Text(post.text, style: const TextStyle(fontSize: 15)),
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
