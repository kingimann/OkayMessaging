import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/platform_role.dart';
import '../state/platform_moderation.dart';
import '../state/public_feed_store.dart';
import '../utils/date_formatter.dart';
import '../widgets/sanction_notice.dart';
import '../widgets/verified_badge.dart';
import 'feed_screen.dart' show showPersonSheet;

/// The public newsfeed: one timeline everybody shares, outside any server.
///
/// Unlike a server's feed, there is no shared key here and no membership —
/// which is the point, and also means everything on this screen is public. The
/// composer says so, once, where somebody is about to type.
class PublicFeedScreen extends StatefulWidget {
  const PublicFeedScreen({super.key});

  @override
  State<PublicFeedScreen> createState() => _PublicFeedScreenState();
}

class _PublicFeedScreenState extends State<PublicFeedScreen> {
  final _store = PublicFeedStore.instance;

  @override
  void initState() {
    super.initState();
    if (_store.isConfigured) _store.load();
  }

  Future<void> _refresh() => _store.load();

  Future<void> _compose({String? replyTo, String? replyingToName}) async {
    final silenced = PlatformModeration.instance.isSilenced;
    if (silenced) {
      final s = PlatformModeration.instance.sanction!;
      final left = sanctionRemaining(s.until, DateTime.now().toUtc());
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(left.isEmpty
              ? '${sanctionKindLabel(s.kind)} — you can\'t post right now'
              : '${sanctionKindLabel(s.kind)} — you can post again in '
                  '$left')));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _Composer(replyTo: replyTo, replyingToName: replyingToName),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Newsfeed'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _compose(),
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Post'),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([_store, PlatformModeration.instance]),
        builder: (context, _) {
          final posts = _store.posts;
          return Column(
            children: [
              // Above everything, including the no-server case: an account
              // that has been sanctioned needs to know that before it works
              // out why nothing it types is accepted.
              const SanctionNotice(),
              if (!_store.isConfigured)
                Expanded(
                  child: _empty(Icons.cloud_off,
                      'The newsfeed needs a server connection.'),
                )
              else
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: _store.loading && posts.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : _store.error != null && posts.isEmpty
                          ? ListView(children: [
                              const SizedBox(height: 80),
                              _empty(Icons.error_outline, _store.error!),
                            ])
                          : posts.isEmpty
                              ? ListView(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  children: [
                                    const SizedBox(height: 80),
                                    _empty(Icons.forum_outlined,
                                        'Nothing here yet. Be the first to '
                                        'post — everyone will see it.'),
                                  ],
                                )
                              : ListView.separated(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  padding: const EdgeInsets.only(bottom: 96),
                                  itemCount: posts.length,
                                  separatorBuilder: (_, __) =>
                                      const Divider(height: 1),
                                  itemBuilder: (context, i) => _PostTile(
                                    post: posts[i],
                                    onReply: () => _compose(
                                        replyTo: posts[i].id,
                                        replyingToName:
                                            posts[i].authorName),
                                    onOpen: () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => _ThreadScreen(
                                            postId: posts[i].id),
                                      ),
                                    ),
                                  ),
                                ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _empty(IconData icon, String text) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: Colors.grey.shade400),
              const SizedBox(height: 14),
              Text(text,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600)),
            ],
          ),
        ),
      );
}

/// One post, plus its like / reply / more actions.
class _PostTile extends StatelessWidget {
  final PublicPost post;
  final VoidCallback onReply;
  final VoidCallback onOpen;

  const _PostTile(
      {required this.post, required this.onReply, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = (post.authorName.isEmpty ? '?' : post.authorName[0])
        .toUpperCase();
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: scheme.primary.withValues(alpha: 0.18),
              child: Text(initial,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                            post.authorName.isEmpty
                                ? '@${post.authorUsername}'
                                : post.authorName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      if (post.authorVerified) ...[
                        const SizedBox(width: 4),
                        const VerifiedBadge(size: 14),
                      ],
                      if (post.authorUsername.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text('@${post.authorUsername}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: Colors.grey.shade500)),
                        ),
                      ],
                      const SizedBox(width: 6),
                      Text('· ${DateFormatter.chatListLabel(post.createdAt)}',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade500)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(post.body, style: const TextStyle(fontSize: 15)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _action(
                        context,
                        icon: Icons.chat_bubble_outline,
                        label: post.replyCount == 0
                            ? 'Reply'
                            : '${post.replyCount}',
                        onTap: onReply,
                      ),
                      const SizedBox(width: 4),
                      _action(
                        context,
                        icon: post.liked
                            ? Icons.favorite
                            : Icons.favorite_border,
                        label:
                            post.likeCount == 0 ? '' : '${post.likeCount}',
                        color: post.liked ? Colors.pink : null,
                        onTap: () =>
                            PublicFeedStore.instance.toggleLike(post.id),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.more_horiz, size: 18),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _more(context),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _action(BuildContext context,
      {required IconData icon,
      required String label,
      required VoidCallback onTap,
      Color? color}) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 17, color: color ?? Colors.grey.shade500),
      label: Text(label,
          style: TextStyle(
              fontSize: 12.5, color: color ?? Colors.grey.shade500)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  void _more(BuildContext context) {
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
                Clipboard.setData(ClipboardData(text: post.body));
                Navigator.of(sheetContext).pop();
              },
            ),
            if (post.authorUsername.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text('@${post.authorUsername}'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  showPersonSheet(context,
                      username: post.authorUsername, name: post.authorName);
                },
              ),
            if (post.mine)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Delete post',
                    style: TextStyle(color: Colors.red)),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  try {
                    await PublicFeedStore.instance.delete(post.id);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text('$e')));
                    }
                  }
                },
              )
            else
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Report'),
                subtitle: const Text('Sends it to the app\'s moderators'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  showReportSheet(
                    context,
                    context_: 'newsfeed post: ${post.body}',
                    targetHandle: post.authorUsername,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// A post and its replies.
class _ThreadScreen extends StatelessWidget {
  final String postId;
  const _ThreadScreen({required this.postId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Post')),
      body: ListenableBuilder(
        listenable: PublicFeedStore.instance,
        builder: (context, _) {
          final post = PublicFeedStore.instance.byId(postId);
          if (post == null) {
            return const Center(child: Text('This post was removed.'));
          }
          final replies = PublicFeedStore.instance.repliesTo(postId);
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _PostTile(
                post: post,
                onReply: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (_) => _Composer(
                      replyTo: post.id, replyingToName: post.authorName),
                ),
                onOpen: () {},
              ),
              const Divider(height: 1),
              if (replies.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text('No replies yet.',
                        style: TextStyle(color: Colors.grey.shade500)),
                  ),
                )
              else
                for (final r in replies)
                  Padding(
                    padding: const EdgeInsets.only(left: 20),
                    child: _PostTile(
                        post: r, onReply: () {}, onOpen: () {}),
                  ),
            ],
          );
        },
      ),
    );
  }
}

/// The composer. Says out loud that a post here is public, because this is the
/// one place in the app where that is true.
class _Composer extends StatefulWidget {
  final String? replyTo;
  final String? replyingToName;
  const _Composer({this.replyTo, this.replyingToName});

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _text = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      await PublicFeedStore.instance
          .post(_text.text, replyTo: widget.replyTo);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = AppState.profile.value;
    final left = PublicFeedStore.maxLength - _text.text.trim().length;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            left: 20,
            right: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                widget.replyTo == null
                    ? 'New post'
                    : 'Reply to ${widget.replyingToName ?? 'post'}',
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            // The one thing worth saying here, and the only screen in the app
            // where it applies: this is not a private message.
            Text(
                me.username.isEmpty
                    ? 'Everyone using OkayMessenger can see this. Set a '
                        'username in your profile so people know who posted.'
                    : 'Everyone using OkayMessenger can see this, posted as '
                        '@${me.username}.',
                style:
                    TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
            const SizedBox(height: 14),
            TextField(
              controller: _text,
              autofocus: true,
              maxLines: 6,
              minLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'What\'s happening?',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('$left',
                    style: TextStyle(
                        fontSize: 12.5,
                        color: left < 0 ? Colors.red : Colors.grey.shade500)),
                const Spacer(),
                FilledButton(
                  onPressed: _sending ||
                          _text.text.trim().isEmpty ||
                          left < 0
                      ? null
                      : _send,
                  child: Text(_sending
                      ? 'Posting…'
                      : (widget.replyTo == null ? 'Post' : 'Reply')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
