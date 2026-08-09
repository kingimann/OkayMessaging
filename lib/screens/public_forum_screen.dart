import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/community.dart' show forumTags;
import '../state/public_forum_store.dart';
import '../theme/app_theme.dart';
import '../util/photo_prep.dart';
import '../widgets/chat_photo.dart';
import '../widgets/emoji_gif_sheet.dart';
import '../widgets/feed_post_parts.dart';
import '../widgets/phone_gate.dart';
import '../widgets/pull_to_refresh.dart';
import 'forum_screen.dart' show forumTagColor;
import 'public_feed_screen.dart' show openPublicProfile;

extension on PublicForumSort {
  String get label => switch (this) {
        PublicForumSort.hot => 'Hot',
        PublicForumSort.fresh => 'New',
        PublicForumSort.top => 'Top',
      };
}

/// The public forum: a world-readable, Reddit-shaped discussion board that
/// lives OUTSIDE any server, alongside the newsfeed and marketplace. Anyone
/// with the app can read it; posting, commenting and voting need a phone
/// number, the same rule the newsfeed follows.
class PublicForumScreen extends StatefulWidget {
  const PublicForumScreen({super.key, this.fromSidebar = false});

  /// True when opened from the sidebar — shows a ☰ that reopens the sidebar
  /// instead of a back arrow.
  final bool fromSidebar;

  @override
  State<PublicForumScreen> createState() => _PublicForumScreenState();
}

class _PublicForumScreenState extends State<PublicForumScreen> {
  final _store = PublicForumStore.instance;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // Load once; a re-entry keeps whatever is already there.
    if (_store.posts.isEmpty) _store.load();
    _store.loadSections();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >
        _scroll.position.maxScrollExtent - 600) {
      _store.loadMore();
    }
  }

  Future<void> _compose() async {
    // The gate before the composer, so a name-only account is told why rather
    // than typing a post the insert would refuse. Same funnel as the feed.
    if (postNeedsPhone(context)) return;
    await Navigator.of(context).push<bool>(MaterialPageRoute(
      // Default the composer to the board being browsed.
      builder: (_) =>
          CreatePublicForumPostScreen(section: _store.sectionFilter),
    ));
  }

  /// The section picker: switch boards, or create one (Reddit's subreddits).
  Future<void> _pickSection() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) => ListenableBuilder(
        listenable: _store,
        builder: (sheetCtx, _) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('Sections',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700)),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        _createSection();
                      },
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Create'),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.forum_outlined),
                title: const Text('All sections'),
                trailing: _store.sectionFilter.isEmpty
                    ? Icon(Icons.check, color: AppColors.accentOn(sheetCtx))
                    : null,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _store.setSectionFilter('');
                },
              ),
              for (final s in _store.sections)
                ListTile(
                  leading: const Icon(Icons.tag),
                  title: Text(s.label),
                  subtitle: s.description.isEmpty
                      ? Text('f/${s.slug}',
                          style: TextStyle(color: AppColors.subtle(sheetCtx)))
                      : Text(s.description,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: _store.sectionFilter == s.slug
                      ? Icon(Icons.check, color: AppColors.accentOn(sheetCtx))
                      : null,
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _store.setSectionFilter(s.slug);
                  },
                ),
              if (_store.sections.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Text(
                    'No sections yet. Create one to start a board — like a '
                    'subreddit.',
                    style: TextStyle(color: AppColors.subtle(sheetCtx)),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _createSection() async {
    if (postNeedsPhone(context, what: 'Creating a section')) return;
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => const _CreateSectionDialog(),
    );
    if (created == true && mounted) {
      // Jump into the new board.
      final newest = _store.sections.isNotEmpty ? _store.sections.first : null;
      if (newest != null) _store.setSectionFilter(newest.slug);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        // The title is the section switcher — tap to change board or create
        // one, like tapping the community name in Reddit.
        title: ListenableBuilder(
          listenable: _store,
          builder: (context, _) => InkWell(
            onTap: _pickSection,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.forum_rounded, size: 20),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _store.sectionFilter.isEmpty
                          ? 'Forum'
                          : _store.sectionLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const Icon(Icons.arrow_drop_down, size: 22),
                ],
              ),
            ),
          ),
        ),
        actions: [
          // Sort (Hot/New/Top) top-right, like the newsfeed's For you/Following
          // — no chip row under the timeline.
          ListenableBuilder(
            listenable: _store,
            builder: (context, _) => PopupMenuButton<PublicForumSort>(
              tooltip: 'Sort',
              initialValue: _store.sort,
              onSelected: (s) => _store.setSort(s),
              itemBuilder: (context) => [
                for (final s in PublicForumSort.values)
                  PopupMenuItem<PublicForumSort>(
                    value: s,
                    child: Row(
                      children: [
                        Icon(
                          _store.sort == s
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 18,
                          color: _store.sort == s
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
                    Text(_store.sort.label,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const Icon(Icons.arrow_drop_down, size: 20),
                  ],
                ),
              ),
            ),
          ),
          // Compose top-right, exactly like the newsfeed — no FAB.
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'New post',
            onPressed: _compose,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _store,
        builder: (context, _) {
          final posts = _store.posts;
          return posts.isEmpty
              ? (_store.loading
                  ? const Center(child: CircularProgressIndicator())
                  : _empty(context))
              : PullToRefresh(
                  onRefresh: () => _store.load(),
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: posts.length,
                    itemBuilder: (context, i) =>
                        _ForumPostCard(post: posts[i]),
                  ),
                );
        },
      ),
    );
  }

  Widget _empty(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 10),
            Text('No posts yet — start the discussion',
                style: TextStyle(color: AppColors.subtle(context))),
          ],
        ),
      );
}

/// A shared up/down vote pill, Reddit-coloured — the same look as the in-server
/// forum's, so the two boards read as one feature.
class ForumVotePill extends StatelessWidget {
  const ForumVotePill({
    super.key,
    required this.score,
    required this.myVote,
    required this.onVote,
    this.compact = false,
  });

  final int score;
  final int myVote;
  final ValueChanged<int> onVote;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    const up = Color(0xFFFF4500);
    const down = Color(0xFF7193FF);
    final iconSize = compact ? 16.0 : 19.0;
    final pad = compact
        ? const EdgeInsets.symmetric(horizontal: 6, vertical: 4)
        : const EdgeInsets.symmetric(horizontal: 8, vertical: 6);
    Widget arrow(IconData icon, int dir, Color active) => InkWell(
          borderRadius: BorderRadius.circular(20),
          // Pressing the arrow you already chose takes the vote back.
          onTap: () => onVote(myVote == dir ? 0 : dir),
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
                  color: myVote == 1 ? up : (myVote == -1 ? down : null))),
          arrow(Icons.arrow_downward_rounded, -1, down),
        ],
      ),
    );
  }
}

/// A tag chip, matching the in-server forum's.
class _ForumTagChip extends StatelessWidget {
  const _ForumTagChip(this.tag);
  final String tag;
  @override
  Widget build(BuildContext context) {
    if (tag.isEmpty) return const SizedBox.shrink();
    final c = forumTagColor(tag);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(tag,
          style:
              TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
    );
  }
}

/// A post summary card: vote control, title, body preview, footer.
class _ForumPostCard extends StatelessWidget {
  const _ForumPostCard({required this.post});
  final PublicForumPost post;

  Future<void> _vote(BuildContext context, int dir) async {
    if (postNeedsPhone(context, what: 'Voting')) return;
    try {
      await PublicForumStore.instance.vote(post.id, dir);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PublicForumPostScreen(postId: post.id),
        )),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ForumVotePill(
                score: post.score,
                myVote: post.myVote,
                onVote: (d) => _vote(context, d),
                compact: true,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        FeedAvatar(
                            username: post.authorUsername,
                            name: post.authorName,
                            radius: 12),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FeedPostHeader(
                            name: post.authorName,
                            username: post.authorUsername,
                            time: post.createdAt,
                            verified: post.authorVerified,
                            onAuthor: () => openPublicProfile(
                                context, post.authorUsername,
                                name: post.authorName),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(post.title,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    if (post.body.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      FeedBodyText(text: post.body),
                    ],
                    if (post.gifUrl.isNotEmpty || post.imageUrl.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      FeedPostImage(
                        child: ChatPhoto(
                          url: post.gifUrl.isNotEmpty
                              ? post.gifUrl
                              : post.imageUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_) => const SizedBox.shrink(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _ForumTagChip(post.tag),
                        if (post.tag.isNotEmpty) const SizedBox(width: 10),
                        Icon(Icons.mode_comment_outlined,
                            size: 15, color: AppColors.subtle(context)),
                        const SizedBox(width: 4),
                        Text('${post.commentCount}',
                            style: TextStyle(
                                fontSize: 12.5,
                                color: AppColors.subtle(context))),
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

/// A single post with its comments — the same shape as the in-server forum
/// detail and both newsfeeds' thread view.
class PublicForumPostScreen extends StatefulWidget {
  const PublicForumPostScreen({super.key, required this.postId});
  final String postId;

  @override
  State<PublicForumPostScreen> createState() => _PublicForumPostScreenState();
}

class _PublicForumPostScreenState extends State<PublicForumPostScreen> {
  final _store = PublicForumStore.instance;
  List<PublicForumComment> _comments = [];
  bool _loading = true;
  PublicForumComment? _replyingTo;

  PublicForumPost? get _post {
    for (final p in _store.posts) {
      if (p.id == widget.postId) return p;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await _store.commentsOf(widget.postId);
    if (!mounted) return;
    setState(() {
      _comments = list;
      _loading = false;
    });
  }

  Future<bool> _submit(String text, String? gifUrl) async {
    if (postNeedsPhone(context, what: 'Commenting')) return false;
    try {
      await _store.comment(widget.postId, text,
          parentId: _replyingTo?.id, gifUrl: gifUrl);
      await _reload();
      if (mounted) setState(() => _replyingTo = null);
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
      return false;
    }
  }

  /// Top-level comments newest-first, each followed by its replies oldest-first.
  List<(PublicForumComment, bool)> _threaded() {
    final top = _comments.where((c) => c.parentId == null).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final out = <(PublicForumComment, bool)>[];
    for (final c in top) {
      out.add((c, false));
      final replies = _comments.where((r) => r.parentId == c.id).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      for (final r in replies) {
        out.add((r, true));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final post = _post;
        if (post == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('This post is gone.')),
          );
        }
        final rows = _threaded();
        return Scaffold(
          appBar: AppBar(title: const Text('Post')),
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 12),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              FeedAvatar(
                                  username: post.authorUsername,
                                  name: post.authorName,
                                  radius: 18),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FeedPostHeader(
                                  name: post.authorName,
                                  username: post.authorUsername,
                                  time: post.createdAt,
                                  verified: post.authorVerified,
                                  onAuthor: () => openPublicProfile(
                                      context, post.authorUsername,
                                      name: post.authorName),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(post.title,
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.w800)),
                          if (post.tag.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            _ForumTagChip(post.tag),
                          ],
                          if (post.body.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            FeedBodyText(
                                text: post.body,
                                collapse: false,
                                focused: true),
                          ],
                          if (post.gifUrl.isNotEmpty ||
                              post.imageUrl.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            FeedPostImage(
                              child: ChatPhoto(
                                url: post.gifUrl.isNotEmpty
                                    ? post.gifUrl
                                    : post.imageUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_) => const SizedBox.shrink(),
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              ForumVotePill(
                                score: post.score,
                                myVote: post.myVote,
                                onVote: (d) async {
                                  if (postNeedsPhone(context, what: 'Voting')) {
                                    return;
                                  }
                                  try {
                                    await _store.vote(
                                        post.id, post.myVote == d ? 0 : d);
                                  } catch (e) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('$e')));
                                    }
                                  }
                                },
                              ),
                              const SizedBox(width: 14),
                              Icon(Icons.mode_comment_outlined,
                                  size: 17, color: AppColors.subtle(context)),
                              const SizedBox(width: 5),
                              Text('${post.commentCount}',
                                  style: TextStyle(
                                      color: AppColors.subtle(context))),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (rows.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(28),
                        child: Center(
                          child: Text('No comments yet — be the first',
                              style:
                                  TextStyle(color: AppColors.subtle(context))),
                        ),
                      )
                    else
                      for (final (c, isReply) in rows)
                        _CommentTile(
                          comment: c,
                          isReply: isReply,
                          onReply: () => setState(() => _replyingTo = c),
                        ),
                  ],
                ),
              ),
              if (_replyingTo != null)
                Container(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Replying to '
                          '${_replyingTo!.authorName.isEmpty ? '@${_replyingTo!.authorUsername}' : _replyingTo!.authorName}',
                          style: TextStyle(
                              fontSize: 12.5, color: AppColors.subtle(context)),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Cancel reply',
                        onPressed: () => setState(() => _replyingTo = null),
                      ),
                    ],
                  ),
                ),
              FeedReplyBar(
                key: ValueKey(_replyingTo?.id ?? 'root'),
                handle: _replyingTo?.authorUsername ?? '',
                gifEnabled: true,
                onSend: _submit,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    required this.isReply,
    required this.onReply,
  });
  final PublicForumComment comment;
  final bool isReply;
  final VoidCallback onReply;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(isReply ? 40 : 16, 10, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FeedAvatar(
                  username: comment.authorUsername,
                  name: comment.authorName,
                  radius: 12),
              const SizedBox(width: 8),
              Expanded(
                child: FeedPostHeader(
                  name: comment.authorName,
                  username: comment.authorUsername,
                  time: comment.createdAt,
                  verified: comment.authorVerified,
                  onAuthor: () => openPublicProfile(
                      context, comment.authorUsername,
                      name: comment.authorName),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (comment.body.isNotEmpty) FeedBodyText(text: comment.body),
          if (comment.gifUrl.isNotEmpty) ...[
            const SizedBox(height: 6),
            FeedPostImage(
              child: ChatPhoto(
                url: comment.gifUrl,
                fit: BoxFit.cover,
                errorBuilder: (_) => const SizedBox.shrink(),
              ),
            ),
          ],
          // Only a top-level comment can be replied to; a thread of threads is
          // a second place to lose a conversation, exactly as the group chat
          // threads reason about it.
          if (!isReply)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onReply,
                icon: const Icon(Icons.reply, size: 15),
                label: const Text('Reply'),
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: const Size(0, 32),
                    visualDensity: VisualDensity.compact),
              ),
            ),
        ],
      ),
    );
  }
}

/// The new-post composer — a section, title, body, a tag, and one optional
/// photo/GIF. A full screen, like the in-server forum's CreateForumPostScreen,
/// so the two feel the same.
class CreatePublicForumPostScreen extends StatefulWidget {
  const CreatePublicForumPostScreen({super.key, this.section = ''});

  /// The board to post into by default (the one being browsed), '' = General.
  final String section;

  @override
  State<CreatePublicForumPostScreen> createState() =>
      _CreatePublicForumPostScreenState();
}

class _CreatePublicForumPostScreenState
    extends State<CreatePublicForumPostScreen> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  String _tag = '';
  late String _section = widget.section;
  String? _gifUrl;
  Uint8List? _image;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    // Make sure the section list is loaded so the picker has options.
    PublicForumStore.instance.loadSections();
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  String get _sectionLabel {
    if (_section.isEmpty) return 'General';
    for (final s in PublicForumStore.instance.sections) {
      if (s.slug == _section) return s.label;
    }
    return _section;
  }

  Future<void> _pickSection() async {
    final store = PublicForumStore.instance;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('Post to',
                  style:
                      TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.forum_outlined),
              title: const Text('General'),
              onTap: () => Navigator.pop(sheetCtx, ''),
            ),
            for (final s in store.sections)
              ListTile(
                leading: const Icon(Icons.tag),
                title: Text(s.label),
                subtitle: Text('f/${s.slug}',
                    style: TextStyle(color: AppColors.subtle(sheetCtx))),
                onTap: () => Navigator.pop(sheetCtx, s.slug),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Create a new section'),
              onTap: () => Navigator.pop(sheetCtx, ' new'),
            ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    if (chosen == ' new') {
      if (postNeedsPhone(context, what: 'Creating a section')) return;
      final made = await showDialog<bool>(
        context: context,
        builder: (_) => const _CreateSectionDialog(),
      );
      if (made == true && mounted && store.sections.isNotEmpty) {
        setState(() => _section = store.sections.first.slug);
      }
      return;
    }
    setState(() => _section = chosen);
  }

  Future<void> _pickGif() async {
    final picked = await showEmojiGifSheet(context, initialTab: 1);
    final gif = picked?.gif;
    if (gif == null || !mounted) return;
    setState(() {
      _gifUrl = gif.url;
      _image = null;
    });
  }

  Future<void> _pickPhoto() async {
    // Through PhotoPrep, so it inherits the moderation check and the EXIF
    // strip, exactly like the newsfeed composer.
    final dataUri = await PhotoPrep.pickPhoto(maxBase64: 900 * 1024);
    if (dataUri == null || !mounted) return;
    final bytes = PhotoPrep.bytesFromDataUri(dataUri);
    if (bytes == null) return;
    setState(() {
      _image = bytes;
      _gifUrl = null;
    });
  }

  Future<void> _post() async {
    if (_posting) return;
    setState(() => _posting = true);
    try {
      await PublicForumStore.instance.post(
        title: _title.text,
        body: _body.text,
        tag: _tag,
        section: _section,
        gifUrl: _gifUrl,
        image: _image,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _posting = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New post'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _posting ? null : _post,
              child: _posting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Post'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          // Which board this goes to — like choosing a subreddit.
          OutlinedButton.icon(
            onPressed: _pickSection,
            icon: const Icon(Icons.forum_outlined, size: 18),
            label: Text('Posting to: $_sectionLabel'),
            style: OutlinedButton.styleFrom(
                alignment: Alignment.centerLeft,
                minimumSize: const Size(double.infinity, 48)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            maxLength: PublicForumStore.maxTitle,
            decoration: const InputDecoration(
              labelText: 'Title',
              hintText: 'What do you want to talk about?',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _body,
            textCapitalization: TextCapitalization.sentences,
            minLines: 4,
            maxLines: 12,
            maxLength: PublicForumStore.maxBody,
            decoration: const InputDecoration(
              labelText: 'Text (optional)',
              alignLabelWithHint: true,
              hintText: 'Add more, or leave it at the title',
            ),
          ),
          const SizedBox(height: 8),
          Text('Tag', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final t in forumTags)
                ChoiceChip(
                  label: Text(t),
                  selected: _tag == t,
                  selectedColor: forumTagColor(t).withValues(alpha: 0.2),
                  onSelected: (_) =>
                      setState(() => _tag = _tag == t ? '' : t),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (_gifUrl != null || _image != null)
            Stack(
              alignment: Alignment.topRight,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _image != null
                      ? Image.memory(_image!,
                          height: 180,
                          width: double.infinity,
                          fit: BoxFit.cover)
                      : ChatPhoto(
                          url: _gifUrl!,
                          height: 180,
                          fit: BoxFit.cover,
                          errorBuilder: (_) => const SizedBox.shrink(),
                        ),
                ),
                IconButton(
                  icon: const CircleAvatar(
                      radius: 14,
                      backgroundColor: Colors.black54,
                      child: Icon(Icons.close, size: 16, color: Colors.white)),
                  onPressed: () => setState(() {
                    _gifUrl = null;
                    _image = null;
                  }),
                ),
              ],
            )
          else
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _pickPhoto,
                  icon: const Icon(Icons.photo_outlined, size: 18),
                  label: const Text('Photo'),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _pickGif,
                  icon: const Icon(Icons.gif_box_outlined, size: 18),
                  label: const Text('GIF'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Create a new section (subreddit-style board): a name, and an optional blurb.
class _CreateSectionDialog extends StatefulWidget {
  const _CreateSectionDialog();

  @override
  State<_CreateSectionDialog> createState() => _CreateSectionDialogState();
}

class _CreateSectionDialogState extends State<_CreateSectionDialog> {
  final _name = TextEditingController();
  final _desc = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await PublicForumStore.instance
          .createSection(_name.text, description: _desc.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Live preview of the slug the name will become (f/<slug>).
    final slug = PublicForumSection.slugify(_name.text);
    return AlertDialog(
      title: const Text('Create a section'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'e.g. Photography',
            ),
          ),
          const SizedBox(height: 4),
          Text(slug.isEmpty ? 'A board, like a subreddit' : 'f/$slug',
              style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
          const SizedBox(height: 12),
          TextField(
            controller: _desc,
            textCapitalization: TextCapitalization.sentences,
            minLines: 1,
            maxLines: 3,
            maxLength: 300,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _create,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Create'),
        ),
      ],
    );
  }
}
