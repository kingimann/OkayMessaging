import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../state/chat_store.dart';
import '../state/community_store.dart';
import '../state/feed_store.dart';
import '../state/follow_store.dart';
import '../util/file_moderation.dart';
import '../util/photo_prep.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/chat_photo.dart';
import '../widgets/emoji_gif_sheet.dart';
import '../widgets/poll_widgets.dart';
import '../widgets/pull_to_refresh.dart';
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

/// The @mention being typed at the end of [text] (without the '@'), or null
/// when the text doesn't end in one. Pure.
String? activeMentionPrefix(String text) =>
    RegExp(r'@([A-Za-z0-9_]*)$').firstMatch(text)?.group(1);

/// Known usernames starting with [prefix], case-insensitive, first five,
/// deduped. Pure over the given sources.
List<String> mentionMatches(String prefix, Iterable<String> known) {
  final p = prefix.toLowerCase();
  final seen = <String>{};
  final out = <String>[];
  for (final u in known) {
    final lu = u.toLowerCase();
    if (lu.isEmpty || lu == 'you' || !lu.startsWith(p)) continue;
    if (!seen.add(lu)) continue;
    out.add(u);
    if (out.length == 5) break;
  }
  return out;
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

  /// False = newest first; true = most liked/reposted first.
  bool _top = false;

  /// Show only bookmarked posts.
  bool _savedOnly = false;

  /// Active trending-hashtag filter ('' = whole timeline).
  String _tag = '';

  /// Free-text search over the timeline, open from the app bar.
  final TextEditingController _search = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _composer.dispose();
    _search.dispose();
    super.dispose();
  }

  void _post({String? gifUrl}) {
    final text = _composer.text.trim();
    if (text.isEmpty && gifUrl == null) return;
    // The server's word filter guards its feed like its channels.
    final hit = CommunityStore.instance.filterHit(widget.communityId, text);
    if (hit != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('"$hit" is blocked by this server\'s word filter')));
      return;
    }
    FeedStore.instance.add(widget.communityId, text, gifUrl: gifUrl);
    _composer.clear();
    FocusScope.of(context).unfocus();
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
    // A photo posts like a GIF: an image with whatever was typed as caption.
    _post(gifUrl: dataUri);
  }

  /// The composer, opened from the app bar's pencil.
  ///
  /// A full screen rather than a bottom sheet: the sheet gave the text field
  /// one cramped line squeezed between an avatar and four buttons, so the
  /// placeholder wrapped onto two lines before a single character was typed.
  /// Writing is the whole job of this screen; it gets the whole screen.
  void _openComposer() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (pageContext) => FeedComposerScreen(
        controller: _composer,
        mentionCandidates: (prefix) => mentionMatches(prefix, [
          ...FeedStore.instance.usernamesFor(widget.communityId),
          for (final c in ChatStore.instance.allChats)
            if (c.contact.username.isNotEmpty) c.contact.username,
        ]),
        onPost: () {
          _post();
          Navigator.pop(pageContext);
        },
        onPostGif: (url) {
          _post(gifUrl: url);
          Navigator.pop(pageContext);
        },
        onCreatePoll: () async {
          Navigator.pop(pageContext);
          await _createPoll();
        },
        onAttachPhoto: () async {
          await _attachPhoto();
          if (pageContext.mounted) Navigator.pop(pageContext);
        },
      ),
    ));
  }

  void _openThread(FeedPost post) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FeedPostScreen(postId: post.id),
    ));
  }

  /// Tapping an author: follow/unfollow them, or jump to your chat.
  void _authorSheet(FeedPost post) => showPersonSheet(context,
      username: post.authorUsername, name: post.authorName);

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
            if (CommunityStore.instance.canModerate(widget.communityId))
              ListTile(
                leading: Icon(
                    post.pinned ? Icons.push_pin : Icons.push_pin_outlined),
                title: Text(post.pinned ? 'Unpin from feed' : 'Pin to feed'),
                onTap: () {
                  final pinned = FeedStore.instance.togglePinned(post.id);
                  Navigator.of(sheetContext).pop();
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(pinned
                        ? 'Pinned to the top of the feed.'
                        : 'Unpinned.'),
                  ));
                },
              ),
            if (mine) ...[
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit post'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _editPost(post);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Delete post',
                    style: TextStyle(color: Colors.red)),
                onTap: () {
                  FeedStore.instance.deletePost(post.id);
                  Navigator.of(sheetContext).pop();
                },
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Posts a poll to the feed, using the same composer sheet as channels.
  Future<void> _createPoll() async {
    final result =
        await showModalBottomSheet<({String question, List<String> options})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const PollComposerSheet(),
    );
    if (result == null || !mounted) return;
    final hit =
        CommunityStore.instance.filterHit(widget.communityId, result.question);
    if (hit != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('"$hit" is blocked by this server\'s word filter')));
      return;
    }
    FeedStore.instance
        .addPoll(widget.communityId, result.question, result.options);
  }

  /// A quote post: the quoter's own card, with the quoted post in a bordered
  /// card underneath.
  Widget _quoteTile(FeedPost entry) {
    final original = FeedStore.instance.postById(entry.repostOfId!);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _postTile(entry),
        Padding(
          padding: const EdgeInsets.fromLTRB(64, 0, 16, 12),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(14),
            ),
            child: original == null
                ? Text('This post isn\'t available.',
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 13.5))
                : InkWell(
                    onTap: () => _openThread(original),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${original.authorName} · @${original.authorUsername}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                        if (original.text.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(original.text,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13.5)),
                        ],
                      ],
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  /// Tapping repost offers the plain repeat or a quote with your own words.
  void _repostOptions(FeedPost post) {
    final reposted = post.reposted ||
        (FeedStore.instance.postById(post.repostOfId ?? post.id)?.reposted ??
            false);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.repeat),
              title: Text(reposted ? 'Undo repost' : 'Repost'),
              onTap: () {
                FeedStore.instance.toggleRepost(post.id);
                Navigator.of(sheetContext).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.format_quote),
              title: const Text('Quote'),
              subtitle: const Text('Repost with your own comment'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _quotePost(post);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _quotePost(FeedPost post) async {
    final text = await showAppTextPrompt(
      context,
      icon: Icons.format_quote,
      title: 'Quote post',
      hint: 'Add a comment',
      confirmLabel: 'Post',
      capitalization: TextCapitalization.sentences,
      maxLines: 4,
    );
    if (text == null || text.trim().isEmpty) return;
    // The server's word filter guards quotes like any other post.
    final hit = CommunityStore.instance.filterHit(widget.communityId, text);
    if (hit != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('"$hit" is blocked by this server\'s word filter')));
      return;
    }
    FeedStore.instance.quoteRepost(post.id, text);
  }

  /// Rewrites one of your own posts, keeping its replies and likes intact.
  Future<void> _editPost(FeedPost post) async {
    final text = await showAppTextPrompt(
      context,
      icon: Icons.edit_outlined,
      title: 'Edit post',
      initial: post.text,
      hint: 'Say something',
      capitalization: TextCapitalization.sentences,
      maxLines: 5,
    );
    if (text == null) return;
    FeedStore.instance.editPost(post.id, text);
  }

  /// One regular timeline entry with its full action row.
  Widget _postTile(FeedPost post) {
    return InkWell(
      onTap: () => _openThread(post),
      onLongPress: () => _postOptions(post),
      child: _PostCard(
        post: post,
        onLike: () => FeedStore.instance.toggleLike(post.id),
        onRepost: () => _repostOptions(post),
        onReply: () => _openThread(post),
        onAuthor: () => _authorSheet(post),
        saved: FeedStore.instance.isSaved(post.id),
        onSave: () => FeedStore.instance.toggleSaved(post.id),
        // Tags filter the timeline in place; mentions open the person.
        onTag: (t) => setState(() => _tag = _tag == t ? '' : t),
        onMention: (u) => showPersonSheet(context, username: u),
        // Deleting lives in the long-press options — no standing trash
        // icon cluttering every own post.
      ),
    );
  }

  /// A repost entry: a slim "reposted" header over the original post (whose
  /// actions all target the original).
  Widget _repostTile(FeedPost entry) {
    // A quote carries its own words, so it reads as the quoter's post with the
    // original embedded beneath — not as a bare "X reposted" header.
    if (FeedStore.isQuote(entry)) return _quoteTile(entry);
    final original = FeedStore.instance.postById(entry.repostOfId!);
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(48, 8, 16, 0),
      child: Row(
        children: [
          Icon(Icons.repeat, size: 14, color: grey),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '${entry.authorName} reposted',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600, color: grey),
            ),
          ),
        ],
      ),
    );
    if (original == null) {
      // The original hasn't reached this device (or was deleted).
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text('This post isn\'t available.',
                style: TextStyle(color: grey, fontSize: 13.5)),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [header, _postTile(original)],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search posts, or @someone',
                  border: InputBorder.none,
                ),
                onChanged: (_) => setState(() {}),
              )
            : Text('${widget.communityName} · Feed'),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            tooltip: _searching ? 'Close search' : 'Search posts',
            onPressed: () => setState(() {
              if (_searching) _search.clear();
              _searching = !_searching;
            }),
          ),
          if (!_searching) ...[
            IconButton(
              icon: const Icon(Icons.person_add_alt),
              tooltip: 'Add and follow people',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PeopleScreen()),
              ),
            ),
            // Composing lives up here now — the timeline keeps the screen.
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'New post',
              onPressed: _openComposer,
            ),
          ],
        ],
      ),
      body: ListenableBuilder(
        listenable: FeedStore.instance,
        builder: (context, _) {
          // One timeline for everyone in the server — no For-you/Following
          // split.
          final all = FeedStore.instance.postsFor(widget.communityId);
          final tags = trendingTags(all);
          var posts = sortFeed(filterFeedByTag(all, _tag), top: _top);
          if (_savedOnly) {
            posts = posts
                .where((p) => FeedStore.instance
                    .isSaved(p.repostOfId ?? p.id))
                .toList();
          }
          // Search narrows whatever the chips already selected.
          if (_searching) {
            posts = FeedStore.searchPosts(posts, _search.text);
          }
          return PullToRefresh(
            child: ListView(
              children: [
                // Three tabs across the width rather than three chips huddled
                // in the corner. The timeline has exactly one of these on at
                // a time, and a tab says that where a chip only implies it.
                if (all.isNotEmpty) ...[
                  Row(
                    children: [
                      _FeedTab(
                        label: 'Latest',
                        selected: !_top && !_savedOnly,
                        onTap: () => setState(() {
                          _top = false;
                          _savedOnly = false;
                        }),
                      ),
                      _FeedTab(
                        label: 'Top',
                        selected: _top && !_savedOnly,
                        onTap: () => setState(() {
                          _top = true;
                          _savedOnly = false;
                        }),
                      ),
                      _FeedTab(
                        label: 'Saved',
                        selected: _savedOnly,
                        onTap: () => setState(() => _savedOnly = true),
                      ),
                    ],
                  ),
                  const Divider(height: 1),
                  // Trending: what the server is talking about, as one-tap
                  // filters. Its own row — a scrolling strip of hashtags
                  // inside the tab row would have hidden the tabs.
                  if (tags.isNotEmpty)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
                      child: Row(
                        children: [
                          for (final (tag, n) in tags)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: FilterChip(
                                label: Text(n > 1 ? '$tag · $n' : tag),
                                selected: _tag == tag,
                                visualDensity: VisualDensity.compact,
                                onSelected: (_) => setState(
                                    () => _tag = _tag == tag ? '' : tag),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
                if (posts.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Text(
                        _searching && _search.text.trim().isNotEmpty
                            ? 'No posts match "${_search.text.trim()}"'
                            : 'No posts yet. Tap the pencil up top to say '
                                'something!',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                for (final post in posts) ...[
                  if (post.repostOfId != null)
                    _repostTile(post)
                  else
                    _postTile(post),
                  const Divider(height: 1),
                ],
                const SizedBox(height: 24),
              ],
            ),
          );
        },
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
  final VoidCallback? onAuthor;
  final bool saved;
  final VoidCallback? onSave;

  /// Tapping a #hashtag / @mention in the text.
  final ValueChanged<String>? onTag;
  final ValueChanged<String>? onMention;

  const _PostCard({
    required this.post,
    required this.onLike,
    required this.onRepost,
    required this.onReply,
    this.onAuthor,
    this.saved = false,
    this.onSave,
    this.onTag,
    this.onMention,
  });

  @override
  Widget build(BuildContext context) {
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
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
                if (post.pinned)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Row(
                      children: [
                        const Icon(Icons.push_pin,
                            size: 12, color: Color(0xFF43B581)),
                        const SizedBox(width: 4),
                        Text('Pinned',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.green.shade700)),
                      ],
                    ),
                  ),
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
                          '@${post.authorUsername} · ${feedAge(post.time)}'
                          '${post.edited ? ' · edited' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: grey, fontSize: 13.5)),
                    ),
                    const Spacer(),
                  ],
                ),
                const SizedBox(height: 3),
                if (post.text.isNotEmpty)
                  _FeedRichText(
                    text: post.text,
                    base: const TextStyle(fontSize: 15.5, height: 1.35),
                    accent: TextStyle(
                      fontSize: 15.5,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    onTag: onTag,
                    onMention: onMention,
                  ),
                if (post.isPoll)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, right: 8),
                    child: PollBody(
                      question: post.pollQuestion,
                      options: post.pollOptions,
                      votes: post.pollVotes,
                      myVote: post.pollMyVote,
                      textColor:
                          Theme.of(context).colorScheme.onSurface,
                      metaColor:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                      onVote: (i) => FeedStore.instance.votePoll(post.id, i),
                    ),
                  ),
                if (post.gifUrl != null) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    // ChatPhoto also decodes attached photos (data: URIs),
                    // not just GIF links.
                    child: ChatPhoto(
                      url: post.gifUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_) => const SizedBox.shrink(),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                // The three conversation actions sit together on the left,
                // save and share against the right edge. Spreading all five
                // evenly across the row made every one of them equally far
                // from the thumb and equally important, which they are not:
                // reply, repost and like are what a timeline is for.
                Row(
                  children: [
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 240),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _PostAction(
                              icon: Icons.chat_bubble_outline,
                              count: post.replies,
                              onTap: onReply,
                              tooltip: 'Reply',
                            ),
                            _PostAction(
                              icon: Icons.repeat,
                              count: post.reposts,
                              active: post.reposted,
                              activeColor: const Color(0xFF00BA7C),
                              onTap: onRepost,
                              tooltip: 'Repost',
                            ),
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
                      ),
                    ),
                    if (onSave != null)
                      _PostAction(
                        icon: saved ? Icons.bookmark : Icons.bookmark_border,
                        count: 0,
                        active: saved,
                        activeColor: const Color(0xFFF5A623),
                        tooltip: saved ? 'Unsave' : 'Save',
                        onTap: onSave!,
                      ),
                    const SizedBox(width: 10),
                    _PostAction(
                      icon: Icons.ios_share,
                      count: 0,
                      tooltip: 'Copy text',
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: post.text));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Post copied')),
                        );
                      },
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

/// One timeline tab: a label with a short bar under the selected one.
///
/// The bar is centred on the label rather than filling the segment, which is
/// what keeps three tabs reading as a row of choices instead of three
/// buttons welded together.
class _FeedTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FeedTab(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 13, 4, 11),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
            ),
            // Always laid out, only painted when selected — otherwise the
            // labels would shift by three pixels every time a tab changed.
            Container(
              height: 3,
              width: 44,
              decoration: BoxDecoration(
                color: selected ? scheme.primary : Colors.transparent,
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(2)),
              ),
            ),
          ],
        ),
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
    final color = active ? activeColor : Theme.of(context).colorScheme.onSurfaceVariant;
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
                child: PullToRefresh(
                  child: ListView(
                    children: [
                      // Threading: a reply-of-a-reply shows where it hangs.
                      if (post.parentId != null)
                        Builder(builder: (context) {
                          final parent =
                              FeedStore.instance.postById(post.parentId!);
                          return InkWell(
                            onTap: parent == null
                                ? null
                                : () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                        builder: (_) => FeedPostScreen(
                                            postId: parent.id))),
                            child: Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 10, 16, 0),
                              child: Row(
                                children: [
                                  Icon(Icons.subdirectory_arrow_left,
                                      size: 15,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      parent == null
                                          ? 'In reply to an unavailable post'
                                          : 'In reply to @${parent.authorUsername} — view thread',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      _PostCard(
                        post: post,
                        onLike: () => FeedStore.instance.toggleLike(post.id),
                        onRepost: () =>
                            FeedStore.instance.toggleRepost(post.id),
                        onReply: () {},
                        saved: FeedStore.instance.isSaved(post.id),
                        onSave: () =>
                            FeedStore.instance.toggleSaved(post.id),
                        onMention: (u) =>
                            showPersonSheet(context, username: u),
                      ),
                      if (post.likes > 0 ||
                          post.reposts > 0 ||
                          replies.isNotEmpty)
                        Padding(
                          padding:
                              const EdgeInsets.fromLTRB(64, 0, 16, 10),
                          child: Text(
                            [
                              if (replies.isNotEmpty)
                                '${replies.length} '
                                    '${replies.length == 1 ? 'reply' : 'replies'}',
                              if (post.reposts > 0)
                                '${post.reposts} '
                                    '${post.reposts == 1 ? 'repost' : 'reposts'}',
                              if (post.likes > 0)
                                '${post.likes} '
                                    '${post.likes == 1 ? 'like' : 'likes'}',
                            ].join(' · '),
                            style: TextStyle(
                                fontSize: 12.5,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant),
                          ),
                        ),
                      const Divider(height: 1),
                      if (replies.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(28),
                          child: Center(
                            child: Text('No replies yet.',
                                style:
                                    TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                          ),
                        ),
                      for (final r in replies) ...[
                        Padding(
                          padding: const EdgeInsets.only(left: 16),
                          // A reply is a post: open its own thread to read
                          // or continue its sub-conversation.
                          child: InkWell(
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        FeedPostScreen(postId: r.id))),
                            child: _PostCard(
                              post: r,
                              onLike: () =>
                                  FeedStore.instance.toggleLike(r.id),
                              onRepost: () =>
                                  FeedStore.instance.toggleRepost(r.id),
                              onReply: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          FeedPostScreen(postId: r.id))),
                              onMention: (u) =>
                                  showPersonSheet(context, username: u),
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                      ],
                    ],
                  ),
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

/// The profile sheet for any @username — post authors and text mentions
/// alike: follow/unfollow them, or jump to your chat.
void showPersonSheet(BuildContext context,
    {required String username, String? name}) {
  // Best display name we know: the given one, a post by them, or the handle.
  final displayName =
      name ?? FeedStore.instance.authorNameFor(username) ?? '@$username';
  final mine =
      username == 'you' || username == AppState.profile.value.username;
  final contact = ChatStore.instance.chats
      .map((c) => c.contact)
      .where((u) => u.username.toLowerCase() == username.toLowerCase())
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
            _FeedAvatar(name: displayName, username: username),
            const SizedBox(height: 8),
            Text(displayName,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700)),
            Text('@$username',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 14),
            if (mine)
              Text('This is you.',
                  style: TextStyle(
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant))
            else
              ListenableBuilder(
                listenable: FollowStore.instance,
                builder: (context, _) {
                  final following =
                      FollowStore.instance.isFollowing(username);
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      following
                          ? OutlinedButton.icon(
                              onPressed: () =>
                                  FollowStore.instance.toggle(username),
                              icon: const Icon(Icons.check, size: 18),
                              label: const Text('Following'),
                            )
                          : FilledButton.icon(
                              onPressed: () =>
                                  FollowStore.instance.toggle(username),
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
                              Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => ChatScreen(chat: chat)));
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

/// Post text with live #hashtags, @mentions, and links: tags filter the
/// timeline, mentions open the person, links open the browser.
class _FeedRichText extends StatefulWidget {
  final String text;
  final TextStyle base;
  final TextStyle accent;
  final ValueChanged<String>? onTag;
  final ValueChanged<String>? onMention;

  const _FeedRichText({
    required this.text,
    required this.base,
    required this.accent,
    this.onTag,
    this.onMention,
  });

  @override
  State<_FeedRichText> createState() => _FeedRichTextState();
}

class _FeedRichTextState extends State<_FeedRichText> {
  final List<TapGestureRecognizer> _recognizers = [];

  void _clearRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  TapGestureRecognizer? _recognizerFor(String token) {
    VoidCallback? action;
    if (token.startsWith('#') && widget.onTag != null) {
      action = () => widget.onTag!(token);
    } else if (token.startsWith('@') && widget.onMention != null) {
      action = () => widget.onMention!(token.substring(1));
    } else if (token.startsWith('http')) {
      action = () async {
        try {
          await launchUrl(Uri.parse(token));
        } catch (_) {}
      };
    }
    if (action == null) return null;
    final r = TapGestureRecognizer()..onTap = action;
    _recognizers.add(r);
    return r;
  }

  @override
  Widget build(BuildContext context) {
    _clearRecognizers();
    final pattern = RegExp(r'(@[A-Za-z0-9_]+|#[A-Za-z0-9_]+|https?://\S+)');
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in pattern.allMatches(widget.text)) {
      if (m.start > last) {
        spans.add(TextSpan(
            text: widget.text.substring(last, m.start), style: widget.base));
      }
      final token = m.group(0)!;
      spans.add(TextSpan(
          text: token,
          style: widget.accent,
          recognizer: _recognizerFor(token)));
      last = m.end;
    }
    if (last < widget.text.length) {
      spans.add(
          TextSpan(text: widget.text.substring(last), style: widget.base));
    }
    return Text.rich(TextSpan(
        children: spans.isEmpty
            ? [TextSpan(text: widget.text, style: widget.base)]
            : spans));
  }
}

/// Writing a post, on its own screen.
///
/// This used to be a bottom sheet: one line of text field wedged between an
/// avatar and four icon buttons and a Post button, which left the field so
/// narrow that "What's happening?" wrapped onto two lines before anything was
/// typed. Composing is the only thing happening here, so it gets the screen —
/// Cancel and Post in the bar, the text at a size worth reading back, and the
/// attachments on a row of their own above the keyboard.
class FeedComposerScreen extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onPost;

  /// Posts a GIF straight to the feed, with whatever has been typed as its
  /// caption.
  final ValueChanged<String>? onPostGif;

  /// Opens the poll composer; null hides the poll button.
  final VoidCallback? onCreatePoll;

  /// Opens the photo picker and posts the shot the same way.
  final VoidCallback? onAttachPhoto;

  /// Usernames matching the @prefix being typed, for tag-a-person chips.
  final List<String> Function(String prefix)? mentionCandidates;

  /// The longest a post may be.
  static const int maxLength = 280;

  const FeedComposerScreen({
    super.key,
    required this.controller,
    required this.onPost,
    this.onPostGif,
    this.onCreatePoll,
    this.onAttachPhoto,
    this.mentionCandidates,
  });

  @override
  State<FeedComposerScreen> createState() => _FeedComposerScreenState();
}

class _FeedComposerScreenState extends State<FeedComposerScreen> {
  Future<void> _pick() async {
    final picked = await showEmojiGifSheet(context);
    if (picked == null) return;
    final gif = picked.gif;
    if (gif != null) {
      widget.onPostGif?.call(gif.url);
      return;
    }
    final emoji = picked.emoji;
    if (emoji == null) return;
    final controller = widget.controller;
    final sel = controller.selection;
    final text = controller.text;
    if (sel.start < 0) {
      controller.text = text + emoji;
      return;
    }
    controller.value = controller.value.copyWith(
      text: text.replaceRange(sel.start, sel.end, emoji),
      selection: TextSelection.collapsed(offset: sel.start + emoji.length),
    );
  }

  /// Closing throws the draft away. Asked first when there is one — losing
  /// something you wrote to a mis-tap is the worst thing a composer can do.
  Future<void> _close() async {
    if (widget.controller.text.trim().isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await showAppConfirmDialog(
      context,
      icon: Icons.delete_outline,
      title: 'Discard post?',
      message: 'What you have written will be lost.',
      confirmLabel: 'Discard',
      destructive: true,
    );
    if (!mounted || !discard) return;
    widget.controller.clear();
    if (mounted) Navigator.of(context).pop();
  }

  Widget _tool(IconData icon, String tip, VoidCallback? onTap) => IconButton(
        icon: Icon(icon, size: 22),
        tooltip: tip,
        color: Theme.of(context).colorScheme.primary,
        onPressed: onTap,
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      // The system back gesture has to ask about the draft too, not just the
      // Cancel button.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          leadingWidth: 92,
          leading: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _close,
              child: const Text('Cancel'),
            ),
          ),
          actions: [
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (context, value, _) {
                final length = value.text.characters.length;
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: FilledButton(
                    onPressed: value.text.trim().isEmpty ||
                            length > FeedComposerScreen.maxLength
                        ? null
                        : widget.onPost,
                    style: FilledButton.styleFrom(
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                    ),
                    child: const Text('Post'),
                  ),
                );
              },
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _FeedAvatar(name: 'You', username: 'you'),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: widget.controller,
                          autofocus: true,
                          // No cap on lines: the field grows with the post and
                          // the scroll view carries it, rather than the text
                          // scrolling inside four fixed lines.
                          maxLines: null,
                          minLines: 4,
                          textCapitalization: TextCapitalization.sentences,
                          keyboardType: TextInputType.multiline,
                          style: const TextStyle(fontSize: 19, height: 1.35),
                          // Every border spelled out. InputDecoration.collapsed
                          // only nulls `border`, so the app theme's
                          // focusedBorder still applied — and this field is
                          // autofocused, which drew a rounded box around an
                          // empty composer the moment it opened.
                          decoration: InputDecoration(
                            hintText: "What's happening?",
                            hintStyle: TextStyle(
                              fontSize: 19,
                              color: scheme.onSurfaceVariant,
                            ),
                            filled: false,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            errorBorder: InputBorder.none,
                            focusedErrorBorder: InputBorder.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Tag-a-person chips while an @mention is being typed. They sit
              // against the toolbar, where a suggestion belongs — next to the
              // keyboard, not at the far end of the post.
              if (widget.mentionCandidates != null)
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: widget.controller,
                  builder: (context, value, _) {
                    final prefix = activeMentionPrefix(value.text);
                    final matches = prefix == null
                        ? const <String>[]
                        : widget.mentionCandidates!(prefix);
                    if (matches.isEmpty) return const SizedBox.shrink();
                    return SizedBox(
                      height: 46,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        children: [
                          for (final u in matches)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ActionChip(
                                avatar: const Icon(Icons.alternate_email,
                                    size: 14),
                                label: Text(u),
                                visualDensity: VisualDensity.compact,
                                onPressed: () {
                                  final text = value.text.replaceFirst(
                                      RegExp(r'@[A-Za-z0-9_]*$'), '@$u ');
                                  widget.controller.value = TextEditingValue(
                                    text: text,
                                    selection: TextSelection.collapsed(
                                        offset: text.length),
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                child: Row(
                  children: [
                    if (widget.onAttachPhoto != null)
                      _tool(Icons.image_outlined, 'Attach photo',
                          widget.onAttachPhoto),
                    _tool(Icons.gif_box_outlined, 'Emoji & GIFs', _pick),
                    if (widget.onCreatePoll != null)
                      _tool(Icons.poll_outlined, 'Create poll',
                          widget.onCreatePoll),
                    const Spacer(),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: widget.controller,
                      builder: (context, value, _) => _CountRing(
                        length: value.text.characters.length,
                        max: FeedComposerScreen.maxLength,
                      ),
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

/// How much of the post's length is used, as a ring that fills up.
///
/// A running "12/280" is noise for the first two hundred characters; a ring
/// says the same thing without asking to be read. It only turns into a number
/// near the limit, which is the only point at which the exact count matters.
class _CountRing extends StatelessWidget {
  final int length;
  final int max;
  const _CountRing({required this.length, required this.max});

  @override
  Widget build(BuildContext context) {
    if (length == 0) return const SizedBox(width: 26, height: 26);
    final scheme = Theme.of(context).colorScheme;
    final remaining = max - length;
    final over = remaining < 0;
    final colour = over
        ? scheme.error
        : remaining <= 20
            ? const Color(0xFFE0A000)
            : scheme.primary;
    return SizedBox(
      width: 30,
      height: 30,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              value: (length / max).clamp(0.0, 1.0),
              strokeWidth: 2.4,
              backgroundColor: scheme.onSurface.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation<Color>(colour),
            ),
          ),
          if (remaining <= 20)
            Text(
              '$remaining',
              style: TextStyle(
                fontSize: over ? 10 : 9.5,
                fontWeight: FontWeight.w600,
                color: colour,
              ),
            ),
        ],
      ),
    );
  }
}
