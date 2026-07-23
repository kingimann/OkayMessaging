import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/community.dart';
import '../state/community_store.dart';
import '../utils/date_formatter.dart';

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

/// Whether [authorId] is the local user (posts they created, or the seeded
/// `me` member).
bool isMineAuthor(String authorId) =>
    authorId == 'me' || authorId == AppState.profile.value.id;

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
        final posts = sortPosts(channel.posts, _sort);
        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                const Icon(Icons.forum_rounded, size: 20),
                const SizedBox(width: 6),
                Text(channel.name),
              ],
            ),
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _newPost,
            icon: const Icon(Icons.edit_outlined),
            label: const Text('New post'),
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
                          TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(
                  children: [
                    for (final s in ForumSort.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(s.label),
                          selected: _sort == s,
                          onSelected: (_) => setState(() => _sort = s),
                        ),
                      ),
                  ],
                ),
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
                                style: TextStyle(color: Colors.grey.shade500)),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 88),
                        itemCount: posts.length,
                        itemBuilder: (context, i) => _PostCard(
                          communityId: widget.communityId,
                          channelId: widget.channelId,
                          post: posts[i],
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
          padding: const EdgeInsets.fromLTRB(6, 8, 14, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _VoteControl(
                score: post.score,
                myVote: post.myVote,
                onVote: (dir) => CommunityStore.instance
                    .voteForumPost(communityId, channelId, post.id, dir),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 4),
                    if (post.pinned) ...[
                      Row(
                        children: [
                          const Icon(Icons.push_pin,
                              size: 13, color: Color(0xFF43B581)),
                          const SizedBox(width: 3),
                          Text('Pinned',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.green.shade700)),
                        ],
                      ),
                      const SizedBox(height: 2),
                    ],
                    Text(post.title,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    if (post.body.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(post.body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13.5, color: Colors.grey.shade600)),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(post.authorName,
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w600)),
                        Text(
                            '  ·  ${DateFormatter.callLabel(post.time)}'
                            '${post.edited ? ' · edited' : ''}',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade500)),
                        const Spacer(),
                        Icon(Icons.mode_comment_outlined,
                            size: 15, color: Colors.grey.shade500),
                        const SizedBox(width: 4),
                        Text('${post.comments.length}',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade500)),
                        if (isMineAuthor(post.authorId) ||
                            CommunityStore.instance.canModerate(communityId))
                          _PostMenu(
                              communityId: communityId,
                              channelId: channelId,
                              post: post),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Confirms and performs deletion of a post or comment.
Future<bool> _confirmDelete(BuildContext context, String what) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text('Delete $what?'),
      content: Text('This permanently removes the $what.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.red))),
      ],
    ),
  );
  return ok == true;
}

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
      icon: Icon(Icons.more_horiz, size: 18, color: Colors.grey.shade500),
      padding: EdgeInsets.zero,
      onSelected: (v) async {
        if (v == 'pin') {
          CommunityStore.instance
              .togglePinForumPost(communityId, channelId, post.id);
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
        if (mod)
          PopupMenuItem(
              value: 'pin', child: Text(post.pinned ? 'Unpin' : 'Pin')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
  }
}

/// The vertical up / score / down voting control.
class _VoteControl extends StatelessWidget {
  final int score;
  final int myVote;
  final ValueChanged<int> onVote;
  const _VoteControl(
      {required this.score, required this.myVote, required this.onVote});

  @override
  Widget build(BuildContext context) {
    const up = Color(0xFFFF4500); // Reddit orange-red
    const down = Color(0xFF7193FF);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 22,
          icon: Icon(Icons.arrow_upward, color: myVote == 1 ? up : Colors.grey),
          onPressed: () => onVote(1),
        ),
        Text('$score',
            style: TextStyle(
                fontWeight: FontWeight.w700,
                color: myVote == 1
                    ? up
                    : (myVote == -1 ? down : null))),
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 22,
          icon: Icon(Icons.arrow_downward,
              color: myVote == -1 ? down : Colors.grey),
          onPressed: () => onVote(-1),
        ),
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
  final _comment = TextEditingController();

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  void _addComment() {
    final body = _comment.text.trim();
    if (body.isEmpty) return;
    final me = AppState.profile.value;
    CommunityStore.instance.addForumComment(
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
      ),
    );
    _comment.clear();
    FocusScope.of(context).unfocus();
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
        final comments = [...post.comments]
          ..sort((a, b) => b.score.compareTo(a.score));
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
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _VoteControl(
                          score: post.score,
                          myVote: post.myVote,
                          onVote: (dir) => CommunityStore.instance
                              .voteForumPost(widget.communityId,
                                  widget.channelId, post.id, dir),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Text(post.title,
                                  style: const TextStyle(
                                      fontSize: 19,
                                      fontWeight: FontWeight.w700)),
                              const SizedBox(height: 6),
                              Text(
                                  '${post.authorName}  ·  ${DateFormatter.callLabel(post.time)}'
                                  '${post.edited ? ' · edited' : ''}',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade500)),
                              if (post.body.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Text(post.body,
                                    style: const TextStyle(
                                        fontSize: 15, height: 1.35)),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 28),
                    Text('${comments.length} '
                        '${comments.length == 1 ? 'comment' : 'comments'}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    if (comments.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Center(
                          child: Text('No comments yet — be the first',
                              style: TextStyle(color: Colors.grey.shade500)),
                        ),
                      )
                    else
                      for (final c in comments)
                        _CommentTile(
                          comment: c,
                          onVote: (dir) => CommunityStore.instance
                              .voteForumComment(widget.communityId,
                                  widget.channelId, post.id, c.id, dir),
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
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _comment,
                          minLines: 1,
                          maxLines: 4,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            hintText: 'Add a comment…',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.send_rounded),
                        color: Theme.of(context).colorScheme.primary,
                        onPressed: _addComment,
                      ),
                    ],
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

class _CommentTile extends StatelessWidget {
  final ForumComment comment;
  final ValueChanged<int> onVote;
  final VoidCallback? onDelete;
  const _CommentTile(
      {required this.comment, required this.onVote, this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _VoteControl(
              score: comment.score, myVote: comment.myVote, onVote: onVote),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                          '${comment.authorName}  ·  ${DateFormatter.callLabel(comment.time)}',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade600)),
                    ),
                    if (onDelete != null)
                      InkWell(
                        onTap: onDelete,
                        child: Icon(Icons.delete_outline,
                            size: 17, color: Colors.grey.shade500),
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(comment.body, style: const TextStyle(fontSize: 14.5)),
              ],
            ),
          ),
        ],
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

  void _post() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    if (_isEdit) {
      CommunityStore.instance.editForumPost(widget.communityId,
          widget.channelId, widget.existing!.id, title, _body.text.trim());
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
