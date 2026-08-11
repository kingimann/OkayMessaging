import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

import '../app_state.dart';
import '../models/community.dart';
import '../state/community_store.dart';
import '../util/file_moderation.dart';
import '../util/photo_prep.dart';
import '../utils/date_formatter.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/chat_photo.dart';
import '../widgets/emoji_gif_sheet.dart';
import '../widgets/feed_post_parts.dart';
import '../widgets/pull_to_refresh.dart';

/// How a forum channel's posts are ordered.
enum ForumSort { hot, newest, top }

extension on ForumSort {
  String get label => switch (this) {
        ForumSort.hot => 'Hot',
        ForumSort.newest => 'New',
        ForumSort.top => 'Top',
      };
}

/// Orders [posts] by the chosen [sort], with pinned posts always floated to
/// the top. "Hot" blends score with recency.
List<ForumPost> sortPosts(List<ForumPost> posts, ForumSort sort,
    {DateTime? now}) {
  final list = [...posts];
  switch (sort) {
    case ForumSort.newest:
      list.sort((a, b) => b.time.compareTo(a.time));
    case ForumSort.top:
      list.sort((a, b) => b.score.compareTo(a.score));
    case ForumSort.hot:
      final n = now ?? DateTime.now();
      double hot(ForumPost p) =>
          p.score - n.difference(p.time).inHours / 12.0;
      list.sort((a, b) => hot(b).compareTo(hot(a)));
  }
  // Stable partition: pinned posts first, keeping the sorted order within each.
  final pinned = list.where((p) => p.pinned).toList();
  final rest = list.where((p) => !p.pinned).toList();
  return [...pinned, ...rest];
}

/// Case-insensitively filters [posts] by title, body, or author. Pure.
///
/// The board no longer carries its own magnifier — this is what the app-wide
/// search (`ChatSearchDelegate`, the bottom bar's Search) matches forum posts
/// with, so a board's posts are found the same way they always were.
List<ForumPost> filterPosts(List<ForumPost> posts, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return posts;
  return posts
      .where((p) =>
          p.title.toLowerCase().contains(q) ||
          p.body.toLowerCase().contains(q) ||
          p.authorName.toLowerCase().contains(q))
      .toList();
}

/// Keeps only posts carrying [tag] ('' = all posts). Pure.
List<ForumPost> filterPostsByTag(List<ForumPost> posts, String tag) =>
    tag.isEmpty ? posts : posts.where((p) => p.tag == tag).toList();

/// The accent color a forum tag chip renders in.
Color forumTagColor(String tag) => switch (tag) {
      'Question' => const Color(0xFFE67E22),
      'Help' => const Color(0xFFE74C3C),
      'News' => const Color(0xFF7A5CFF),
      _ => const Color(0xFF1E88E5),
    };

/// Flattens a post's comments into render order: top-level comments in
/// [sortTop] order, each followed by its replies oldest-first. Returns
/// (comment, isReply) pairs. Pure.
List<(ForumComment, bool)> threadComments(
    List<ForumComment> comments, ForumSort sortTop) {
  final top = comments.where((c) => c.parentId == null).toList();
  switch (sortTop) {
    case ForumSort.newest:
      top.sort((a, b) => b.time.compareTo(a.time));
    case ForumSort.top:
    case ForumSort.hot:
      top.sort((a, b) => b.score.compareTo(a.score));
  }
  final out = <(ForumComment, bool)>[];
  for (final t in top) {
    out.add((t, false));
    final replies = comments.where((c) => c.parentId == t.id).toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    for (final r in replies) {
      out.add((r, true));
    }
  }
  // Replies whose parent vanished (shouldn't happen — deletes cascade) still
  // render rather than silently disappearing.
  final seen = out.map((e) => e.$1.id).toSet();
  for (final c in comments) {
    if (!seen.contains(c.id)) out.add((c, true));
  }
  return out;
}

/// Whether [authorId] is the local user (posts they created, or the seeded
/// `me` member).
bool isMineAuthor(String authorId) =>
    authorId == 'me' || authorId == AppState.profile.value.id;

/// A stable avatar color for a forum author, derived from the name so the
/// same person reads as the same color everywhere without a roster lookup.
Color forumAvatarColor(String name) {
  const palette = <Color>[
    Color(0xFF1E88E5),
    Color(0xFF43A047),
    Color(0xFF8E24AA),
    Color(0xFFF4511E),
    Color(0xFF00897B),
    Color(0xFF3949AB),
    Color(0xFFD81B60),
    Color(0xFF6D4C41),
  ];
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return palette[h % palette.length];
}

/// A small round author avatar: their initial on their stable color.
class _AuthorDot extends StatelessWidget {
  final String name;
  final double radius;
  const _AuthorDot({required this.name, this.radius = 11});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: forumAvatarColor(name),
      child: Text(
        name.isEmpty ? '?' : name[0].toUpperCase(),
        style: TextStyle(
            color: Colors.white,
            fontSize: radius * 0.95,
            fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// The horizontal up / score / down pill — one control, three surfaces
/// (post card, thread header, comment), so voting looks the same everywhere.
class _VotePill extends StatelessWidget {
  final int score;
  final int myVote;
  final ValueChanged<int> onVote;
  final bool compact;
  const _VotePill(
      {required this.score,
      required this.myVote,
      required this.onVote,
      this.compact = false});

  @override
  Widget build(BuildContext context) {
    const up = Color(0xFFFF4500); // Reddit orange-red
    const down = Color(0xFF7193FF);
    final iconSize = compact ? 16.0 : 19.0;
    final pad = compact
        ? const EdgeInsets.symmetric(horizontal: 6, vertical: 4)
        : const EdgeInsets.symmetric(horizontal: 8, vertical: 6);
    Widget arrow(IconData icon, int dir, Color active) => InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => onVote(dir),
          child: Padding(
            padding: pad,
            child: Icon(icon,
                size: iconSize,
                color: myVote == dir ? active : AppColors.subtle(context)),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          arrow(Icons.arrow_upward_rounded, 1, up),
          Text('$score',
              style: TextStyle(
                  fontSize: compact ? 12.5 : 13.5,
                  fontWeight: FontWeight.w700,
                  color: myVote == 1
                      ? up
                      : (myVote == -1 ? down : null))),
          arrow(Icons.arrow_downward_rounded, -1, down),
        ],
      ),
    );
  }
}

/// A Reddit-style forum channel: a sorted feed of posts you can vote on and
/// open to read comments.
class ForumChannelScreen extends StatefulWidget {
  final String communityId;
  final String channelId;
  const ForumChannelScreen(
      {super.key, required this.communityId, required this.channelId});

  @override
  State<ForumChannelScreen> createState() => _ForumChannelScreenState();
}

class _ForumChannelScreenState extends State<ForumChannelScreen> {
  ForumSort _sort = ForumSort.hot;

  Future<void> _newPost() async {
    await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => CreateForumPostScreen(
          communityId: widget.communityId, channelId: widget.channelId),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CommunityStore.instance,
      builder: (context, _) {
        final community = CommunityStore.instance.byId(widget.communityId);
        final channel = community?.channels
            .cast<Channel?>()
            .firstWhere((c) => c?.id == widget.channelId, orElse: () => null);
        if (channel == null) {
          return const Scaffold(body: Center(child: Text('Channel not found')));
        }
        // Muted members' posts stay out of your feed.
        final muted = community!.mutedIds.toSet();
        final posts = sortPosts(
            channel.posts.where((p) => !muted.contains(p.authorId)).toList(),
            _sort);
        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                const Icon(Icons.forum_rounded, size: 20),
                const SizedBox(width: 6),
                Text(channel.name),
              ],
            ),
            actions: [
              // No magnifier here: the bottom bar's Search already walks
              // every server's forum posts (the Posts filter), so this was
              // the same search scoped to one board. One way in, X-shaped.
              // Sort (Hot/New/Top) top-right, like the newsfeed's control — no
              // chip row under the header any more.
              PopupMenuButton<ForumSort>(
                  tooltip: 'Sort',
                  initialValue: _sort,
                  onSelected: (s) => setState(() => _sort = s),
                  itemBuilder: (context) => [
                    for (final s in ForumSort.values)
                      PopupMenuItem<ForumSort>(
                        value: s,
                        child: Row(
                          children: [
                            Icon(
                              _sort == s
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              size: 18,
                              color: _sort == s
                                  ? AppColors.accentOn(context)
                                  : AppColors.subtle(context),
                            ),
                            const SizedBox(width: 10),
                            Text(s.label),
                          ],
                        ),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_sort.label,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                        const Icon(Icons.arrow_drop_down, size: 20),
                      ],
                    ),
                  ),
                ),
              // Compose lives top-right, exactly like the newsfeed — no FAB.
              // Members lose it when posting is admin-only.
              if (CommunityStore.instance.canPost(widget.communityId))
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'New post',
                  onPressed: _newPost,
                ),
            ],
          ),
          body: Column(
            children: [
              if (channel.topic.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.4),
                  child: Text(channel.topic,
                      style:
                          TextStyle(fontSize: 13, color: AppColors.subtle(context))),
                ),
              Expanded(
                child: posts.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.forum_outlined,
                                size: 48, color: Colors.grey.shade400),
                            const SizedBox(height: 10),
                            Text('No posts yet — start the discussion',
                                style: TextStyle(color: AppColors.subtle(context))),
                          ],
                        ),
                      )
                    : PullToRefresh(
                      child: ListView.builder(
                          padding: const EdgeInsets.only(bottom: 88),
                          itemCount: posts.length,
                          itemBuilder: (context, i) => _PostCard(
                            communityId: widget.communityId,
                            channelId: widget.channelId,
                            post: posts[i],
                          ),
                        ),
                    ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A post summary card in the feed: vote control, title, body preview, and a
/// footer with author, age, and comment count.
class _PostCard extends StatelessWidget {
  final String communityId;
  final String channelId;
  final ForumPost post;
  const _PostCard(
      {required this.communityId,
      required this.channelId,
      required this.post});

  @override
  Widget build(BuildContext context) {
    final canManage = isMineAuthor(post.authorId) ||
        CommunityStore.instance.canModerate(communityId);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ForumPostScreen(
              communityId: communityId,
              channelId: channelId,
              postId: post.id),
        )),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The newsfeed's header: real avatar, name, age, pin — with the
              // forum's lock and overflow menu kept to its right.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FeedAvatar(
                      username: post.authorId, name: post.authorName, radius: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FeedPostHeader(
                      name: post.authorName,
                      username: '',
                      time: post.time,
                      edited: post.edited,
                      pinned: post.pinned,
                    ),
                  ),
                  if (post.locked)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Icon(Icons.lock,
                          size: 14, color: AppColors.subtle(context)),
                    ),
                  if (canManage)
                    _PostMenu(
                        communityId: communityId,
                        channelId: channelId,
                        post: post),
                ],
              ),
              const SizedBox(height: 8),
              Text(post.title,
                  style: const TextStyle(
                      fontSize: 16.5, fontWeight: FontWeight.w700, height: 1.2)),
              if (post.tag.isNotEmpty) ...[
                const SizedBox(height: 6),
                _TagChip(tag: post.tag),
              ],
              if (post.body.isNotEmpty) ...[
                const SizedBox(height: 6),
                FeedBodyText(text: post.body),
              ],
              if (post.gifUrl.isNotEmpty) ...[
                const SizedBox(height: 10),
                FeedPostImage(
                  child: ChatPhoto(
                    url: post.gifUrl,
                    width: double.infinity,
                    height: 180,
                    fit: BoxFit.cover,
                    errorBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  _VotePill(
                    score: post.score,
                    myVote: post.myVote,
                    onVote: (dir) => CommunityStore.instance
                        .voteForumPost(communityId, channelId, post.id, dir),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.mode_comment_outlined,
                            size: 15, color: AppColors.subtle(context)),
                        const SizedBox(width: 5),
                        Text(
                            post.comments.isEmpty
                                ? 'Comment'
                                : '${post.comments.length}',
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.subtle(context))),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small colored chip naming a post's tag.
class _TagChip extends StatelessWidget {
  final String tag;
  const _TagChip({required this.tag});

  @override
  Widget build(BuildContext context) {
    final color = forumTagColor(tag);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(tag,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

/// Confirms and performs deletion of a post or comment.
Future<bool> _confirmDelete(BuildContext context, String what) =>
    showAppConfirmDialog(
      context,
      icon: Icons.delete_outline,
      title: 'Delete $what?',
      message: 'This permanently removes the $what.',
      confirmLabel: 'Delete',
      destructive: true,
    );

/// Overflow menu for a post: pin/unpin (moderators) and delete.
class _PostMenu extends StatelessWidget {
  final String communityId;
  final String channelId;
  final ForumPost post;

  /// When set, called after a successful delete (e.g. to pop the detail view).
  final VoidCallback? onDeleted;

  const _PostMenu({
    required this.communityId,
    required this.channelId,
    required this.post,
    this.onDeleted,
  });

  @override
  Widget build(BuildContext context) {
    final mod = CommunityStore.instance.canModerate(communityId);
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_horiz, size: 18, color: AppColors.subtle(context)),
      padding: EdgeInsets.zero,
      onSelected: (v) async {
        if (v == 'pin') {
          CommunityStore.instance
              .togglePinForumPost(communityId, channelId, post.id);
        } else if (v == 'lock') {
          CommunityStore.instance
              .toggleLockForumPost(communityId, channelId, post.id);
        } else if (v == 'edit') {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => CreateForumPostScreen(
                communityId: communityId,
                channelId: channelId,
                existing: post),
          ));
        } else if (v == 'delete') {
          if (await _confirmDelete(context, 'post')) {
            CommunityStore.instance
                .deleteForumPost(communityId, channelId, post.id);
            onDeleted?.call();
          }
        }
      },
      itemBuilder: (context) => [
        if (isMineAuthor(post.authorId))
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
        if (mod) ...[
          PopupMenuItem(
              value: 'pin', child: Text(post.pinned ? 'Unpin' : 'Pin')),
          PopupMenuItem(
              value: 'lock',
              child: Text(post.locked ? 'Unlock thread' : 'Lock thread')),
        ],
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
  }
}

/// Full post view with body and a thread of comments.
class ForumPostScreen extends StatefulWidget {
  final String communityId;
  final String channelId;
  final String postId;
  const ForumPostScreen(
      {super.key,
      required this.communityId,
      required this.channelId,
      required this.postId});

  @override
  State<ForumPostScreen> createState() => _ForumPostScreenState();
}

class _ForumPostScreenState extends State<ForumPostScreen> {
  ForumSort _commentSort = ForumSort.top;

  /// The top-level comment the composer is replying to, if any.
  ForumComment? _replyingTo;

  /// Posts a comment (or a reply) — text and/or a GIF, the same shape the
  /// newsfeed's reply bar hands back. Returns whether it was accepted, so the
  /// bar keeps what was typed on a refusal (a locked thread, a word filter).
  Future<bool> _submitComment(String text, String? gifUrl) async {
    final body = text.trim();
    final gif = gifUrl ?? '';
    // A GIF alone is a complete comment, the same as it is in chat.
    if (body.isEmpty && gif.isEmpty) return false;
    final hit = CommunityStore.instance.filterHit(widget.communityId, body);
    if (hit != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('"$hit" is blocked by this server\'s word filter')));
      return false;
    }
    final me = AppState.profile.value;
    final added = CommunityStore.instance.addForumComment(
      widget.communityId,
      widget.channelId,
      widget.postId,
      ForumComment(
        id: 'fc_${DateTime.now().microsecondsSinceEpoch}',
        authorId: me.id,
        authorName: me.name,
        time: DateTime.now(),
        body: body,
        score: 1,
        myVote: 1,
        parentId: _replyingTo?.id,
        gifUrl: gif,
      ),
    );
    if (!added) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('This thread is locked — no new comments.')));
      return false;
    }
    if (mounted) setState(() => _replyingTo = null);
    return true;
  }

  Future<void> _editComment(ForumComment c) async {
    final body = await showAppTextPrompt(
      context,
      icon: Icons.edit_outlined,
      title: 'Edit comment',
      initial: c.body,
      maxLines: 4,
      capitalization: TextCapitalization.sentences,
    );
    if (body == null || body.trim().isEmpty) return;
    CommunityStore.instance.editForumComment(
        widget.communityId, widget.channelId, widget.postId, c.id, body);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CommunityStore.instance,
      builder: (context, _) {
        final community = CommunityStore.instance.byId(widget.communityId);
        final channel = community?.channels
            .cast<Channel?>()
            .firstWhere((c) => c?.id == widget.channelId, orElse: () => null);
        final post = channel?.posts
            .cast<ForumPost?>()
            .firstWhere((p) => p?.id == widget.postId, orElse: () => null);
        if (post == null) {
          return const Scaffold(body: Center(child: Text('Post not found')));
        }
        // Muted members' comments are hidden along with their posts.
        final muted = community!.mutedIds.toSet();
        final visibleComments = post.comments
            .where((c) => !muted.contains(c.authorId))
            .toList();
        final comments = threadComments(visibleComments, _commentSort);
        final canManagePost = isMineAuthor(post.authorId) ||
            CommunityStore.instance.canModerate(widget.communityId);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Post'),
            actions: [
              if (canManagePost)
                _PostMenu(
                  communityId: widget.communityId,
                  channelId: widget.channelId,
                  post: post,
                  onDeleted: () => Navigator.of(context).pop(),
                ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FeedAvatar(
                                username: post.authorId,
                                name: post.authorName,
                                radius: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FeedPostHeader(
                                name: post.authorName,
                                username: '',
                                time: post.time,
                                edited: post.edited,
                              ),
                            ),
                            if (post.tag.isNotEmpty) _TagChip(tag: post.tag),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(post.title,
                            style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                height: 1.25)),
                        if (post.body.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          // The thread's own post reads a size up and never
                          // folds — the same treatment the newsfeed gives the
                          // post a thread is about. #tags, @mentions and links
                          // are live.
                          FeedBodyText(
                              text: post.body,
                              collapse: false,
                              focused: true),
                        ],
                        if (post.gifUrl.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          FeedPostImage(
                            child: ChatPhoto(
                              url: post.gifUrl,
                              width: double.infinity,
                              fit: BoxFit.cover,
                              errorBuilder: (_) => const SizedBox.shrink(),
                            ),
                          ),
                        ],
                        const SizedBox(height: 14),
                        _VotePill(
                          score: post.score,
                          myVote: post.myVote,
                          onVote: (dir) => CommunityStore.instance
                              .voteForumPost(widget.communityId,
                                  widget.channelId, post.id, dir),
                        ),
                      ],
                    ),
                    const Divider(height: 28),
                    Row(
                      children: [
                        Text('${visibleComments.length} '
                            '${visibleComments.length == 1 ? 'comment' : 'comments'}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        const Spacer(),
                        // Sort just the top-level thread order.
                        for (final s in [ForumSort.top, ForumSort.newest])
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: ChoiceChip(
                              label: Text(s.label,
                                  style: const TextStyle(fontSize: 12)),
                              selected: _commentSort == s,
                              visualDensity: VisualDensity.compact,
                              onSelected: (_) =>
                                  setState(() => _commentSort = s),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (comments.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Center(
                          child: Text('No comments yet — be the first',
                              style: TextStyle(color: AppColors.subtle(context))),
                        ),
                      )
                    else
                      for (final (c, isReply) in comments)
                        _CommentTile(
                          comment: c,
                          isReply: isReply,
                          onVote: (dir) => CommunityStore.instance
                              .voteForumComment(widget.communityId,
                                  widget.channelId, post.id, c.id, dir),
                          onReply: isReply
                              ? null
                              : () => setState(() => _replyingTo = c),
                          onEdit: isMineAuthor(c.authorId)
                              ? () => _editComment(c)
                              : null,
                          onDelete: (isMineAuthor(c.authorId) ||
                                  CommunityStore.instance
                                      .canModerate(widget.communityId))
                              ? () async {
                                  if (await _confirmDelete(
                                      context, 'comment')) {
                                    CommunityStore.instance
                                        .deleteForumComment(widget.communityId,
                                            widget.channelId, post.id, c.id);
                                  }
                                }
                              : null,
                        ),
                  ],
                ),
              ),
              if (post.locked)
                SafeArea(
                  top: false,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.lock_outline,
                            size: 18, color: AppColors.subtle(context)),
                        const SizedBox(width: 8),
                        Text('This thread is locked',
                            style: TextStyle(
                                color: AppColors.subtle(context), fontSize: 13.5)),
                      ],
                    ),
                  ),
                )
              else
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The "Replying to X" context, with the way out, above the
                    // same reply bar the newsfeed thread uses.
                    if (_replyingTo != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 6, 8, 0),
                        child: Row(
                          children: [
                            Icon(Icons.subdirectory_arrow_right,
                                size: 16,
                                color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Replying to ${_replyingTo!.authorName}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 16),
                              tooltip: 'Cancel reply',
                              visualDensity: VisualDensity.compact,
                              onPressed: () =>
                                  setState(() => _replyingTo = null),
                            ),
                          ],
                        ),
                      ),
                    // The exact newsfeed reply bar: text + GIF + send.
                    FeedReplyBar(
                      key: ValueKey(_replyingTo?.id ?? 'root'),
                      handle: '',
                      gifEnabled: true,
                      onSend: _submitComment,
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

class _CommentTile extends StatelessWidget {
  final ForumComment comment;

  /// Replies indent under their parent and can't be replied to again.
  final bool isReply;
  final ValueChanged<int> onVote;
  final VoidCallback? onReply;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  const _CommentTile({
    required this.comment,
    required this.onVote,
    this.isReply = false,
    this.onReply,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _AuthorDot(name: comment.authorName, radius: 10),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                  '${comment.authorName}  ·  ${DateFormatter.callLabel(comment.time)}'
                  '${comment.edited ? ' · edited' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.subtle(context))),
            ),
            if (onEdit != null)
              InkWell(
                onTap: onEdit,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Icon(Icons.edit_outlined,
                      size: 16, color: AppColors.subtle(context)),
                ),
              ),
            if (onDelete != null)
              InkWell(
                onTap: onDelete,
                child: Icon(Icons.delete_outline,
                    size: 17, color: AppColors.subtle(context)),
              ),
          ],
        ),
        const SizedBox(height: 4),
        if (comment.body.isNotEmpty) FeedBodyText(text: comment.body),
        if (comment.gifUrl.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ChatPhoto(
                url: comment.gifUrl,
                width: 200,
                fit: BoxFit.cover,
                errorBuilder: (_) => const SizedBox.shrink(),
              ),
            ),
          ),
        const SizedBox(height: 6),
        Row(
          children: [
            _VotePill(
                score: comment.score,
                myVote: comment.myVote,
                onVote: onVote,
                compact: true),
            if (onReply != null)
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: onReply,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.reply,
                          size: 14, color: AppColors.subtle(context)),
                      const SizedBox(width: 4),
                      Text('Reply',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.subtle(context))),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
    if (!isReply) {
      return Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 6), child: content);
    }
    // A reply hangs off its parent's thread line, the way every threaded
    // UI draws belonging — indentation alone reads as accident.
    return Padding(
      padding: const EdgeInsets.fromLTRB(9, 2, 0, 6),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 2,
              margin: const EdgeInsets.only(right: 16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }
}

/// Compose a new forum post, or edit an [existing] one.
class CreateForumPostScreen extends StatefulWidget {
  final String communityId;
  final String channelId;
  final ForumPost? existing;
  const CreateForumPostScreen(
      {super.key,
      required this.communityId,
      required this.channelId,
      this.existing});

  @override
  State<CreateForumPostScreen> createState() => _CreateForumPostScreenState();
}

class _CreateForumPostScreenState extends State<CreateForumPostScreen> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _body = TextEditingController(text: widget.existing?.body ?? '');
  late String _tag = widget.existing?.tag ?? '';

  /// A GIF (or an attached photo as a data: URI) going out with the post.
  /// Editing starts from what the post already carries.
  late String _gifUrl = widget.existing?.gifUrl ?? '';

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  /// Opens the shared emoji/GIF sheet on the GIF tab; an emoji picked from
  /// the other tab lands in the body text.
  Future<void> _pickGif() async {
    final picked = await showEmojiGifSheet(context, initialTab: 1);
    if (picked == null || !mounted) return;
    final gif = picked.gif;
    if (gif != null) setState(() => _gifUrl = gif.url);
    final emoji = picked.emoji;
    if (emoji != null) _body.text += emoji;
  }

  Future<void> _attachPhoto() async {
    String? dataUri;
    try {
      dataUri = await PhotoPrep.pickPhoto();
    } on FileRejected catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.reason)));
      }
      return;
    }
    if (dataUri == null || !mounted) return;
    setState(() => _gifUrl = dataUri!);
  }

  void _post() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final hit = CommunityStore.instance
        .filterHit(widget.communityId, '$title\n${_body.text}');
    if (hit != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('"$hit" is blocked by this server\'s word filter')));
      return;
    }
    if (_isEdit) {
      CommunityStore.instance.editForumPost(
          widget.communityId, widget.channelId, widget.existing!.id, title,
          _body.text.trim(),
          tag: _tag, gifUrl: _gifUrl);
    } else {
      final me = AppState.profile.value;
      CommunityStore.instance.addForumPost(
        widget.communityId,
        widget.channelId,
        ForumPost(
          id: 'fp_${DateTime.now().microsecondsSinceEpoch}',
          authorId: me.id,
          authorName: me.name,
          time: DateTime.now(),
          title: title,
          body: _body.text.trim(),
          score: 1,
          myVote: 1,
          tag: _tag,
          gifUrl: _gifUrl,
        ),
      );
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit post' : 'New post'),
        actions: [
          TextButton(
            onPressed: _title.text.trim().isEmpty ? null : _post,
            child: Text(_isEdit ? 'Save' : 'Post'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _title,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            maxLength: 300,
            decoration: const InputDecoration(
              labelText: 'Title',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _body,
            minLines: 5,
            maxLines: 12,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Body (optional)',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          if (_gifUrl.isNotEmpty) ...[
            Stack(
              alignment: Alignment.topRight,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ChatPhoto(
                    url: _gifUrl,
                    width: double.infinity,
                    height: 180,
                    fit: BoxFit.cover,
                    errorBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.cancel, color: Colors.white),
                  tooltip: 'Remove attachment',
                  onPressed: () => setState(() => _gifUrl = ''),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _pickGif,
                icon: const Icon(Icons.gif_box_outlined, size: 20),
                label: const Text('GIF'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _attachPhoto,
                icon: const Icon(Icons.image_outlined, size: 20),
                label: const Text('Photo'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text('TAG (OPTIONAL)',
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: AppColors.subtle(context))),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              // Tapping the chosen tag again leaves the post untagged.
              for (final t in forumTags)
                FilterChip(
                  label: Text(t),
                  selected: _tag == t,
                  selectedColor: forumTagColor(t).withValues(alpha: 0.2),
                  checkmarkColor: forumTagColor(t),
                  onSelected: (_) =>
                      setState(() => _tag = _tag == t ? '' : t),
                ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _title.text.trim().isEmpty ? null : _post,
            icon: Icon(_isEdit ? Icons.save : Icons.send),
            label: Text(_isEdit ? 'Save' : 'Post'),
          ),
        ],
      ),
    );
  }
}
