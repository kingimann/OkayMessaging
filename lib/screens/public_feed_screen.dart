import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/platform_role.dart';
import '../models/user.dart';
import '../state/chat_store.dart';
import '../state/follow_store.dart';
import '../state/platform_moderation.dart';
import '../state/public_feed_store.dart';
import '../util/file_moderation.dart';
import '../util/photo_prep.dart';
import '../utils/date_formatter.dart';
import '../widgets/sanction_notice.dart';
import '../widgets/verified_badge.dart';
import 'edit_profile_screen.dart';
import 'in_app_web_screen.dart';

/// The colour behind somebody's avatar, derived from their handle.
///
/// Deterministic on purpose: a profile that looked different every time it
/// opened would read as a different profile. Generated rather than uploaded
/// because there is nowhere to put a banner image, and a flat grey bar looks
/// like something failed to load.
Color publicProfileBannerSeed(String username, ColorScheme scheme) {
  if (username.isEmpty) return scheme.primary;
  var hash = 0;
  for (final unit in username.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.45, 0.42).toColor();
}

/// Opens somebody's profile. One helper, so a tap on an avatar, a name, an
/// @mention and the "more" sheet all land in the same place.
void openPublicProfile(BuildContext context, String username, {String? name}) {
  if (username.isEmpty) return;
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => PublicProfileScreen(username: username, name: name),
  ));
}

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
  final _search = TextEditingController();
  final _scroll = ScrollController();
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    if (_store.isConfigured) _store.load();
    // Fetch the next page a little before the bottom, so scrolling doesn't
    // stop dead while it loads.
    _scroll.addListener(() {
      if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
        _store.loadMore();
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
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
      builder: (_) =>
          _Composer(replyTo: replyTo, replyingToName: replyingToName),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        // Your own avatar, top left, going to your own profile — the same
        // gesture the feeds people arrive from use.
        leading: _searching
            ? null
            : ValueListenableBuilder<AppUser>(
                valueListenable: AppState.profile,
                builder: (context, me, _) => Center(
                  child: GestureDetector(
                    onTap: () =>
                        openPublicProfile(context, me.username, name: me.name),
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: publicProfileBannerSeed(
                              me.username, Theme.of(context).colorScheme)
                          .withValues(alpha: 0.25),
                      child: Text(
                          (me.name.isEmpty ? '?' : me.name[0]).toUpperCase(),
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ),
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Search posts',
                  border: InputBorder.none,
                ),
                onSubmitted: (v) => _store.search(v),
              )
            : const Text('Newsfeed'),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            tooltip: _searching ? 'Close search' : 'Search',
            onPressed: () {
              setState(() => _searching = !_searching);
              if (!_searching) {
                _search.clear();
                _store.search('');
              }
            },
          ),
          if (!_searching)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: _refresh,
            ),
        ],
      ),
      // Round and iconic, where the compose button lives on a timeline like
      // this one.
      floatingActionButton: FloatingActionButton(
        onPressed: () => _compose(),
        tooltip: 'New post',
        child: const Icon(Icons.edit_outlined),
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
              else ...[
                _FilterBar(store: _store),
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
                                      _empty(
                                          Icons.forum_outlined,
                                          'Nothing here yet. Be the first to '
                                          'post — everyone will see it.'),
                                    ],
                                  )
                                : ListView.separated(
                                    controller: _scroll,
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    padding: const EdgeInsets.only(bottom: 96),
                                    itemCount: posts.length + 1,
                                    separatorBuilder: (_, __) =>
                                        const Divider(height: 1),
                                    itemBuilder: (context, i) {
                                      if (i == posts.length) {
                                        return _Footer(store: _store);
                                      }
                                      return _PostTile(
                                        post: posts[i],
                                        onReply: () => _compose(
                                            replyTo: posts[i].id,
                                            replyingToName:
                                                posts[i].authorName),
                                        onOpen: () =>
                                            Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => _ThreadScreen(
                                                postId: posts[i].id),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                  ),
                ),
              ],
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

/// Somebody's profile: who they are, and everything they have posted.
///
/// Laid out like the profiles people already know — a banner, an avatar
/// overlapping it, the name and handle, then tabs — because a public feed is
/// the one part of this app that works like the public feeds people arrive
/// from, and inventing a new shape for it would only cost them.
///
/// WHAT IS NOT HERE, ON PURPOSE: a follower count. This app knows who *you*
/// follow, on your own device. It does not know who follows anybody, and there
/// is no table that would tell it — so a number here would have to be made up,
/// and a made-up follower count is the sort of thing this app does not do. Post
/// count is real: it comes from the server.
class PublicProfileScreen extends StatefulWidget {
  final String username;

  /// The display name if the caller already knows it, so the header doesn't
  /// flash the handle before the first post arrives.
  final String? name;

  const PublicProfileScreen({super.key, required this.username, this.name});

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> {
  List<PublicPost>? _posts;
  String? _error;
  ProfileTab _tab = ProfileTab.posts;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final posts = await PublicFeedStore.instance.postsBy(widget.username);
      if (!mounted) return;
      setState(() => _posts = posts);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          e is PublicFeedError ? e.reason : 'Couldn\'t load this profile.');
    }
  }

  /// Whose profile this is, when we happen to know them: a contact, or you.
  AppUser? get _known {
    final me = AppState.profile.value;
    if (me.username.isNotEmpty &&
        me.username.toLowerCase() == widget.username.toLowerCase()) {
      return me;
    }
    for (final chat in ChatStore.instance.chats) {
      if (chat.contact.username.toLowerCase() ==
          widget.username.toLowerCase()) {
        return chat.contact;
      }
    }
    return null;
  }

  bool get _isMe {
    final me = AppState.profile.value.username;
    return me.isNotEmpty && me.toLowerCase() == widget.username.toLowerCase();
  }

  /// The best display name available, in order of how much it is worth.
  String get _displayName {
    final fromPosts =
        _posts?.isNotEmpty == true ? _posts!.first.authorName : '';
    if (fromPosts.isNotEmpty) return fromPosts;
    if (widget.name?.isNotEmpty == true) return widget.name!;
    final known = _known?.name ?? '';
    return known.isNotEmpty ? known : '@${widget.username}';
  }

  bool get _verified {
    if (_posts?.isNotEmpty == true) return _posts!.first.authorVerified;
    return _known?.verified ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final posts = _posts;
    final tabPosts = posts == null
        ? const <PublicPost>[]
        : PublicFeedStore.profileTab(posts, _tab);
    return Scaffold(
      body: ListenableBuilder(
        listenable: PublicFeedStore.instance,
        builder: (context, _) => CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              expandedHeight: 132,
              title: Text(_displayName,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              flexibleSpace: FlexibleSpaceBar(
                background: _Banner(username: widget.username),
              ),
            ),
            SliverToBoxAdapter(
              child: _Header(
                username: widget.username,
                displayName: _displayName,
                verified: _verified,
                known: _known,
                isMe: _isMe,
                postCount: posts?.length,
              ),
            ),
            SliverToBoxAdapter(
              child: _TabStrip(
                labels: [for (final t in ProfileTab.values) t.label],
                active: ProfileTab.values.indexOf(_tab),
                onPick: (i) => setState(() => _tab = ProfileTab.values[i]),
              ),
            ),
            if (_error != null)
              SliverToBoxAdapter(child: _profileMessage(_error!, retry: true))
            else if (posts == null)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (tabPosts.isEmpty)
              SliverToBoxAdapter(
                child: _profileMessage(switch (_tab) {
                  ProfileTab.posts => _isMe
                      ? 'You haven\'t posted anything yet.'
                      : 'No posts yet.',
                  ProfileTab.replies => 'No replies yet.',
                  ProfileTab.media => 'No photos yet.',
                }),
              )
            else
              SliverList.separated(
                itemCount: tabPosts.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) => _PostTile(
                  post: tabPosts[i],
                  onReply: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => _ThreadScreen(postId: tabPosts[i].id))),
                  onOpen: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => _ThreadScreen(postId: tabPosts[i].id))),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }

  Widget _profileMessage(String text, {bool retry = false}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        child: Column(
          children: [
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600)),
            if (retry) ...[
              const SizedBox(height: 14),
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
            ],
          ],
        ),
      );
}

/// The banner behind the avatar. Generated from the handle rather than
/// uploaded: there is nowhere to put a banner image, and a flat grey bar looks
/// like something failed to load.
class _Banner extends StatelessWidget {
  final String username;
  const _Banner({required this.username});

  @override
  Widget build(BuildContext context) {
    final seed =
        publicProfileBannerSeed(username, Theme.of(context).colorScheme);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [seed, seed.withValues(alpha: 0.55)],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String username;
  final String displayName;
  final bool verified;
  final AppUser? known;
  final bool isMe;
  final int? postCount;

  const _Header({
    required this.username,
    required this.displayName,
    required this.verified,
    required this.known,
    required this.isMe,
    required this.postCount,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial =
        (displayName.isEmpty ? '?' : displayName.replaceFirst('@', ''))
            .substring(0, 1)
            .toUpperCase();
    final about = known?.about ?? '';
    final pronouns = known?.pronouns ?? '';
    final link = known?.link ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The avatar rides up over the banner, as it does everywhere else.
          Transform.translate(
            offset: const Offset(0, -30),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      shape: BoxShape.circle),
                  child: CircleAvatar(
                    radius: 34,
                    backgroundColor: publicProfileBannerSeed(username, scheme)
                        .withValues(alpha: 0.25),
                    child: Text(initial,
                        style: const TextStyle(
                            fontSize: 26, fontWeight: FontWeight.w700)),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _ProfileActions(username: username, isMe: isMe),
                ),
              ],
            ),
          ),
          Transform.translate(
            offset: const Offset(0, -18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w800)),
                    ),
                    if (verified) ...[
                      const SizedBox(width: 5),
                      const VerifiedBadge(size: 16),
                    ],
                  ],
                ),
                Row(
                  children: [
                    Text('@$username',
                        style: TextStyle(color: Colors.grey.shade500)),
                    if (pronouns.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(pronouns,
                          style: TextStyle(
                              fontSize: 12.5, color: Colors.grey.shade500)),
                    ],
                  ],
                ),
                // Only for somebody this device actually knows. There is no
                // directory of bios to read, and a placeholder line here would
                // be an invented one.
                if (about.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(about, style: const TextStyle(fontSize: 14.5)),
                ],
                if (link.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: () => InAppWebScreen.open(context, link),
                    child: Row(
                      children: [
                        Icon(Icons.link, size: 15, color: scheme.primary),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(link,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13.5, color: scheme.primary)),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    // Real, from the server. The only count on this screen.
                    _Count(
                        value: postCount,
                        label: postCount == 1 ? 'post' : 'posts'),
                    if (isMe) ...[
                      const SizedBox(width: 18),
                      ListenableBuilder(
                        listenable: FollowStore.instance,
                        builder: (context, _) => _Count(
                          value: FollowStore.instance.following.length,
                          label: 'following',
                        ),
                      ),
                    ],
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

class _Count extends StatelessWidget {
  final int? value;
  final String label;
  const _Count({required this.value, required this.label});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Text(value == null ? '—' : '$value',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: Colors.grey.shade500)),
        ],
      );
}

class _ProfileActions extends StatelessWidget {
  final String username;
  final bool isMe;
  const _ProfileActions({required this.username, required this.isMe});

  @override
  Widget build(BuildContext context) {
    if (isMe) {
      return OutlinedButton(
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const EditProfileScreen())),
        child: const Text('Edit profile'),
      );
    }
    return ListenableBuilder(
      listenable: FollowStore.instance,
      builder: (context, _) {
        final following = FollowStore.instance.isFollowing(username);
        return following
            ? OutlinedButton(
                onPressed: () => FollowStore.instance.toggle(username),
                child: const Text('Following'),
              )
            : FilledButton(
                onPressed: () => FollowStore.instance.toggle(username),
                child: const Text('Follow'),
              );
      },
    );
  }
}

/// The tab row used by both the timeline and a profile: even columns, bold
/// label, short underline under the active one. One widget so the two cannot
/// drift into looking like different apps.
class _TabStrip extends StatelessWidget {
  final List<String> labels;
  final int active;
  final ValueChanged<int> onPick;
  const _TabStrip(
      {required this.labels, required this.active, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              Expanded(
                child: InkWell(
                  onTap: () => onPick(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      children: [
                        Text(labels[i],
                            style: TextStyle(
                              fontWeight: i == active
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: i == active
                                  ? scheme.onSurface
                                  : Colors.grey.shade500,
                            )),
                        const SizedBox(height: 8),
                        Container(
                          height: 3,
                          width: 44,
                          decoration: BoxDecoration(
                            color: i == active
                                ? scheme.primary
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const Divider(height: 1),
      ],
    );
  }
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
    final initial =
        (post.authorName.isEmpty ? '?' : post.authorName[0]).toUpperCase();
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => openPublicProfile(context, post.authorUsername,
                  name: post.authorName),
              child: CircleAvatar(
                radius: 20,
                backgroundColor: scheme.primary.withValues(alpha: 0.18),
                child: Text(initial,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: GestureDetector(
                                onTap: () => openPublicProfile(
                                    context, post.authorUsername,
                                    name: post.authorName),
                                child: Text(
                                    post.authorName.isEmpty
                                        ? '@${post.authorUsername}'
                                        : post.authorName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                              ),
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
                            Text(
                                '· ${DateFormatter.chatListLabel(post.createdAt)}',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey.shade500)),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: () => _more(context),
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8, bottom: 2),
                          child: Icon(Icons.more_horiz,
                              size: 17, color: Colors.grey.shade500),
                        ),
                      ),
                    ],
                  ),
                  // A plain repost has nothing of its own to show; the quoted
                  // post below carries the content.
                  if (post.body.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _Body(text: post.body),
                  ],
                  if (post.hasImage) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(
                        PublicFeedStore.imageUrlFor(post) ?? '',
                        fit: BoxFit.cover,
                        // A broken image should be absent, not a grey box with
                        // an icon in the middle of somebody's post.
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        loadingBuilder: (context, child, progress) =>
                            progress == null
                                ? child
                                : const SizedBox(
                                    height: 160,
                                    child: Center(
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))),
                      ),
                    ),
                  ],
                  if (post.repostOf != null) _Quoted(postId: post.repostOf!),
                  const SizedBox(height: 2),
                  // Four actions, evenly spread across the post's own width
                  // rather than bunched at the left. That is the shape a
                  // timeline like this one has, and it puts every target under
                  // a thumb instead of crowding them into one corner.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _action(
                        context,
                        icon: Icons.chat_bubble_outline,
                        label: post.replyCount == 0 ? '' : '${post.replyCount}',
                        onTap: onReply,
                      ),
                      _action(
                        context,
                        icon: Icons.repeat,
                        label:
                            post.repostCount == 0 ? '' : '${post.repostCount}',
                        color:
                            PublicFeedStore.instance.myRepostOf(post.id) != null
                                ? Colors.green
                                : null,
                        onTap: () async {
                          try {
                            await PublicFeedStore.instance
                                .toggleRepost(post.id);
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(SnackBar(content: Text('$e')));
                            }
                          }
                        },
                      ),
                      _action(
                        context,
                        icon:
                            post.liked ? Icons.favorite : Icons.favorite_border,
                        label: post.likeCount == 0 ? '' : '${post.likeCount}',
                        // The pink a liked heart is everywhere else, so the
                        // gesture reads without being learned.
                        color: post.liked ? const Color(0xFFF91880) : null,
                        onTap: () =>
                            PublicFeedStore.instance.toggleLike(post.id),
                      ),
                      _action(
                        context,
                        icon: Icons.ios_share,
                        label: '',
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: post.body));
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Post copied.')));
                        },
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
          style:
              TextStyle(fontSize: 12.5, color: color ?? Colors.grey.shade500)),
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
                  openPublicProfile(context, post.authorUsername,
                      name: post.authorName);
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
                    child: _PostTile(post: r, onReply: () {}, onOpen: () {}),
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
  Uint8List? _image;

  /// Picks a photo for the post.
  ///
  /// Goes through PhotoPrep so it inherits the moderation check and the EXIF
  /// rotation fix, with a bigger byte budget than a chat message: this is
  /// going into a bucket rather than through the relay, so there is no
  /// broadcast size limit to respect — only the bucket's own 4 MB.
  Future<void> _pickImage() async {
    try {
      final dataUri = await PhotoPrep.pickPhoto(maxBase64: 900 * 1024);
      if (dataUri == null) return;
      final bytes = PhotoPrep.bytesFromDataUri(dataUri);
      if (bytes == null || !mounted) return;
      setState(() => _image = bytes);
    } on FileRejected catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.reason)));
      }
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      await PublicFeedStore.instance
          .post(_text.text, replyTo: widget.replyTo, image: _image);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
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
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
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
            if (_image != null) ...[
              const SizedBox(height: 10),
              Stack(
                alignment: Alignment.topRight,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(_image!,
                        height: 160, width: double.infinity, fit: BoxFit.cover),
                  ),
                  IconButton(
                    icon: const CircleAvatar(
                      radius: 14,
                      backgroundColor: Colors.black54,
                      child: Icon(Icons.close, size: 16, color: Colors.white),
                    ),
                    tooltip: 'Remove photo',
                    onPressed: () => setState(() => _image = null),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.image_outlined),
                  tooltip: 'Add a photo',
                  onPressed: _sending ? null : _pickImage,
                ),
                Text('$left',
                    style: TextStyle(
                        fontSize: 12.5,
                        color: left < 0 ? Colors.red : Colors.grey.shade500)),
                const Spacer(),
                FilledButton(
                  // A photo on its own is a post; text is not required when
                  // something else is attached.
                  onPressed: _sending ||
                          (_text.text.trim().isEmpty && _image == null) ||
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

/// Latest / Top / Following, plus whatever narrowing is currently on.
class _FilterBar extends StatelessWidget {
  final PublicFeedStore store;
  const _FilterBar({required this.store});

  @override
  Widget build(BuildContext context) {
    final tags = PublicFeedStore.trendingTags(store.posts);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Tabs across the top, not chips. Chips read as removable filters;
        // these are the timeline you are on, which is a different thing, and
        // the underline is what says so.
        _TabStrip(
          labels: [for (final f in FeedFilter.values) f.label],
          active: FeedFilter.values.indexOf(store.filter),
          onPick: (i) => store.setFilter(FeedFilter.values[i]),
        ),
        // What is currently narrowing the feed, and how to drop it. A filter
        // you can't see is a feed that looks broken.
        if (store.tag.isNotEmpty || store.query.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Wrap(
              spacing: 8,
              children: [
                if (store.tag.isNotEmpty)
                  InputChip(
                    label: Text('#${store.tag}'),
                    onDeleted: () => store.setTag(''),
                  ),
                if (store.query.isNotEmpty)
                  InputChip(
                    label: Text('"${store.query}"'),
                    onDeleted: () => store.search(''),
                  ),
              ],
            ),
          )
        // Trending only when nothing is already narrowing things, or the row
        // becomes a way to lose track of what you're looking at.
        else if (tags.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: Row(
              children: [
                Text('TRENDING',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        color: Colors.grey.shade500)),
                const SizedBox(width: 12),
                for (final (tag, count) in tags) ...[
                  GestureDetector(
                    onTap: () => store.setTag(tag),
                    child: Text('#$tag',
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.primary)),
                  ),
                  const SizedBox(width: 4),
                  Text('$count',
                      style: TextStyle(
                          fontSize: 11.5, color: Colors.grey.shade500)),
                  const SizedBox(width: 14),
                ],
              ],
            ),
          ),
        if (store.filter == FeedFilter.following && store.posts.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
                'Nothing from people you follow yet. Tap a name to follow '
                'someone.',
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
          ),
      ],
    );
  }
}

/// The end of the list: loading, a nudge to load more, or the end.
class _Footer extends StatelessWidget {
  final PublicFeedStore store;
  const _Footer({required this.store});

  @override
  Widget build(BuildContext context) {
    if (store.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (store.reachedEnd) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text('That\'s everything.',
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: OutlinedButton(
          onPressed: store.loadMore,
          child: const Text('Load more'),
        ),
      ),
    );
  }
}

/// Post text with tappable #hashtags and @mentions.
class _Body extends StatelessWidget {
  final String text;
  const _Body({required this.text});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    const base = TextStyle(fontSize: 15);
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'(#[A-Za-z0-9_]{1,40}|@[A-Za-z0-9_.]{2,})');
    var last = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start), style: base));
      }
      final token = m.group(0)!;
      spans.add(TextSpan(
        text: token,
        style: base.copyWith(color: accent, fontWeight: FontWeight.w600),
        recognizer: TapGestureRecognizer()
          ..onTap = () {
            if (token.startsWith('#')) {
              PublicFeedStore.instance.setTag(token.substring(1));
            } else {
              openPublicProfile(context, token.substring(1));
            }
          },
      ));
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: base));
    }
    return Text.rich(TextSpan(children: spans));
  }
}

/// The post a repost repeats, shown inline. Only what is already loaded — a
/// quoted post from further back reads as unavailable rather than fetching one
/// row at a time while somebody scrolls.
class _Quoted extends StatelessWidget {
  final String postId;
  const _Quoted({required this.postId});

  @override
  Widget build(BuildContext context) {
    final original = PublicFeedStore.instance.byId(postId);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: original == null
          ? Text('This post isn\'t loaded.',
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                          original.authorName.isEmpty
                              ? '@${original.authorUsername}'
                              : original.authorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 13)),
                    ),
                    if (original.authorVerified) ...[
                      const SizedBox(width: 4),
                      const VerifiedBadge(size: 12),
                    ],
                  ],
                ),
                if (original.body.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(original.body,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5)),
                ],
                if (original.hasImage)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('📷 Photo',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade500)),
                  ),
              ],
            ),
    );
  }
}
