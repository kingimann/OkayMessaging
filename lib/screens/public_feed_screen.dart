import '../theme/app_theme.dart';
import '../widgets/phone_gate.dart';
import '../widgets/feed_prefs_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/platform_role.dart';
import '../models/user.dart';
import '../state/chat_store.dart';
import '../state/follow_store.dart';
import '../state/platform_moderation.dart';
import '../state/session.dart' as local;
import '../state/bookmark_store.dart';
import '../state/community_store.dart';
import '../state/feed_mute_store.dart';
import '../state/feed_store.dart';
import '../state/feed_drafts.dart';
import '../state/public_feed_store.dart';
import '../state/score_store.dart';
import '../util/file_moderation.dart';
import '../util/photo_prep.dart';
import '../utils/date_formatter.dart';
import '../widgets/sanction_notice.dart';
import '../widgets/user_avatar.dart';
import '../widgets/feed_post_actions.dart';
import '../mesh/nearby_pick.dart';
import '../widgets/chat_photo.dart';
import '../widgets/emoji_gif_sheet.dart';
import '../widgets/feed_post_parts.dart';
import '../widgets/feed_video.dart';
import '../widgets/verified_badge.dart';
import 'edit_profile_screen.dart';
import 'feed_screen.dart' show FeedPostScreen;
import 'forward_screen.dart';
import 'my_qr_screen.dart';
import 'people_screen.dart';
import 'profile_screen.dart';
import 'score_screen.dart';
import 'in_app_web_screen.dart';

/// Opens somebody's profile. One helper, so a tap on an avatar, a name, an
/// @mention and the "more" sheet all land in the same place.
void openPublicProfile(BuildContext context, String username, {String? name}) {
  if (username.isEmpty) return;
  // ONE SCREEN, whoever it is about. There used to be two — the "You" tab and
  // this one — with different layouts and different facts on each, so any field
  // added to a profile had to be added twice or it existed on one and not the
  // other. Yours is this screen with the parts only you can act on; everybody
  // else's is this screen without them.
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
    await _openComposer(context,
        replyTo: replyTo, replyingToName: replyingToName);
  }

  @override
  Widget build(BuildContext context) {
    return PhoneGate(
      title: 'Newsfeed',
      reason: 'The public feed is a server the app reads and writes with your '
          'account. An account with no phone number has no session to read it '
          'with, and no name that anybody replying to a post could hold to '
          'account.',
      child: _guarded(context),
    );
  }

  Widget _guarded(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        // Your own avatar, top left — the same gesture the feeds people
        // arrive from use. But ONLY when there is nothing to go back to:
        // `leading` replaces the back arrow, and this screen used to be
        // reachable with no way out at all.
        //
        // The overflow menu that used to carry "Your profile" for the pushed
        // case is gone from this bar by request. That route is not lost: the
        // You tab in the bottom bar opens the same profile, and it is one
        // back-tap away from here.
        leading: _searching || Navigator.of(context).canPop()
            ? null
            : ValueListenableBuilder<AppUser>(
                valueListenable: AppState.profile,
                builder: (context, me, _) => Center(
                  child: GestureDetector(
                    onTap: () =>
                        openPublicProfile(context, me.username, name: me.name),
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: feedHandleSeed(
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
              icon: const Icon(Icons.tune),
              tooltip: 'Shape your feed',
              onPressed: () => showFeedPrefsSheet(
                context,
                mutedPeople: FeedMuteStore.instance.muted,
                onUnmute: (u) {
                  if (FeedMuteStore.instance.isMuted(u)) {
                    FeedMuteStore.instance.toggle(u);
                  }
                },
              ),
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
        // FeedMuteStore is in here because the timeline is filtered by it:
        // without it a mute would not remove the post until something else
        // happened to rebuild the list.
        listenable: Listenable.merge(
            [_store, PlatformModeration.instance, FeedMuteStore.instance]),
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
                                      return _Entry(
                                        post: posts[i],
                                        onReply: (target) => _compose(
                                            replyTo: target.id,
                                            replyingToName: target.authorName),
                                        onOpen: (target) =>
                                            Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => PublicThreadScreen(
                                                postId: target.id),
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
                  style: TextStyle(color: AppColors.subtle(context))),
            ],
          ),
        ),
      );
}

/// Who this device is not showing, and how to undo it.
///
/// THIS SCREEN IS NOT OPTIONAL. Muting somebody hides their posts, which is
/// exactly what makes the mute unreachable afterwards: there is no post left to
/// open a menu on. Without a list, a mute would be permanent by accident.
class MutedAccountsScreen extends StatelessWidget {
  const MutedAccountsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Muted accounts')),
        body: ListenableBuilder(
          listenable: FeedMuteStore.instance,
          builder: (context, _) {
            final muted = FeedMuteStore.instance.muted.toList()..sort();
            if (muted.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(36),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.volume_off_outlined,
                          size: 46, color: Colors.grey.shade400),
                      const SizedBox(height: 14),
                      Text(
                        'Nobody is muted. Use the ··· on a post to hide '
                        'somebody from your timeline — they are not told, and '
                        'it only applies on this device.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.subtle(context)),
                      ),
                    ],
                  ),
                ),
              );
            }
            return ListView.separated(
              itemCount: muted.length + 1,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                if (i == muted.length) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Muting is kept on this device, so it does not follow you '
                      'to a new one — and nobody, including them, can see it.',
                      style: TextStyle(
                          fontSize: 12.5, color: AppColors.subtle(context)),
                    ),
                  );
                }
                final username = muted[i];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: feedHandleSeed(
                            username, Theme.of(context).colorScheme)
                        .withValues(alpha: 0.25),
                    child: Text(
                        username.isEmpty ? '?' : username[0].toUpperCase()),
                  ),
                  title: Text('@$username'),
                  // Their profile is still reachable: muting hides a timeline,
                  // it does not pretend somebody stopped existing.
                  onTap: () => openPublicProfile(context, username),
                  trailing: TextButton(
                    onPressed: () => FeedMuteStore.instance.toggle(username),
                    child: const Text('Unmute'),
                  ),
                );
              },
            );
          },
        ),
      );
}

/// Posts saved on this device.
///
/// The ids are local; the posts are re-read from the public feed, which is
/// public anyway. So a bookmark is a note to yourself that no server holds —
/// and the honest cost is that it does not follow you to a new device.
class BookmarksScreen extends StatefulWidget {
  const BookmarksScreen({super.key});

  @override
  State<BookmarksScreen> createState() => _BookmarksScreenState();
}

class _BookmarksScreenState extends State<BookmarksScreen> {
  List<PublicPost>? _posts;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    final ids = BookmarkStore.instance.ids;
    if (ids.isEmpty) {
      setState(() => _posts = const []);
      return;
    }
    try {
      final (posts, missing) = await PublicFeedStore.instance.postsByIds(ids);
      // A saved post that has been deleted should leave the list rather than
      // sit in it forever pointing at nothing.
      await BookmarkStore.instance.forget(missing);
      if (!mounted) return;
      setState(() => _posts = posts);
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _error = e is PublicFeedError ? e.reason : 'Couldn\'t load these.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final posts = _posts;
    return Scaffold(
      appBar: AppBar(title: const Text('Bookmarks')),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 14),
                    OutlinedButton(
                        onPressed: _load, child: const Text('Try again')),
                  ],
                ),
              ),
            )
          : posts == null
              ? const Center(child: CircularProgressIndicator())
              : posts.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(36),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.bookmark_border,
                                size: 46, color: Colors.grey.shade400),
                            const SizedBox(height: 14),
                            Text(
                              'Nothing saved yet. Use the ··· on a post to '
                              'bookmark it — bookmarks stay on this device.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppColors.subtle(context)),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListenableBuilder(
                      listenable: BookmarkStore.instance,
                      builder: (context, _) {
                        // Unsaving one from in here removes the row, rather
                        // than leaving it on a screen it no longer belongs to.
                        final shown = [
                          for (final p in posts)
                            if (BookmarkStore.instance.contains(p.id)) p
                        ];
                        return ListView.separated(
                          itemCount: shown.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) => _Entry(
                            post: shown[i],
                            onReply: (target) => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => PublicThreadScreen(
                                        postId: target.id))),
                            onOpen: (target) => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => PublicThreadScreen(
                                        postId: target.id))),
                          ),
                        );
                      },
                    ),
    );
  }
}

/// A post's photo, filling the screen.
///
/// Pinch to zoom, and the app bar keeps a way back — a photo that opens with no
/// way out is the reason people learn to distrust tapping them.
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

  /// True when this is the "You" tab rather than a pushed route: no app bar of
  /// its own, because the tab scaffold already has one.
  final bool embedded;

  const PublicProfileScreen(
      {super.key, required this.username, this.name, this.embedded = false});

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> {
  List<PublicPost>? _posts;
  String? _error;
  ProfileTab _tab = ProfileTab.posts;

  /// Servers is yours alone — a server's feed is encrypted with that server's
  /// key, so there is no such thing as seeing a stranger's server posts.
  List<ProfileTab> get _tabs => [
        for (final t in ProfileTab.values)
          if (t != ProfileTab.servers || _isMe) t
      ];

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
        // Pull to refresh, as the profile this replaced had: the posts on it
        // are fetched once when it opens, so without this the only way to see a
        // new one is to leave and come back.
        builder: (context, _) => RefreshIndicator(
          onRefresh: _load,
          child: CustomScrollView(
            // Always scrollable, or a short profile cannot be pulled at all.
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (!widget.embedded)
                SliverAppBar(
                  pinned: true,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  title: Text(_displayName,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              SliverToBoxAdapter(
                child: _AvatarRow(
                  username: widget.username,
                  displayName: _displayName,
                  isMe: _isMe,
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
              // The verification chips used to sit here. They are three
              // settings rows wearing a profile's clothes — what they say is
              // about your account rather than about you, and each one is a
              // door into Settings anyway. They live in Settings now.
              // Pinned, so scrolling a long profile does not take the tabs
              // away with it. Switching from Posts to Media otherwise means
              // scrolling back to the top to find the control you just used.
              SliverPersistentHeader(
                pinned: true,
                delegate: _PinnedTabs(
                  child: FeedTabStrip(
                    labels: [for (final t in _tabs) t.label],
                    icons: [for (final t in _tabs) t.icon],
                    active: _tabs.indexOf(_tab),
                    onPick: (i) => setState(() => _tab = _tabs[i]),
                  ),
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
              // Server posts come from a different store entirely: they are
              // encrypted per server and have nothing to do with the public feed.
              else if (_tab == ProfileTab.servers)
                _serverPosts(context)
              else if (tabPosts.isEmpty)
                SliverToBoxAdapter(child: _emptyTab())
              // Photos are what somebody came to the Media tab to look at, so
              // they are the whole tile. As a column of post tiles they were
              // a caption with a picture attached, three to a screen.
              else if (_tab == ProfileTab.media)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(2, 2, 2, 0),
                  sliver: SliverGrid.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 2,
                      mainAxisSpacing: 2,
                    ),
                    itemCount: tabPosts.length,
                    itemBuilder: (context, i) => _MediaCell(post: tabPosts[i]),
                  ),
                )
              else
                SliverList.separated(
                  itemCount: tabPosts.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => _Entry(
                    post: tabPosts[i],
                    onReply: (target) => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) =>
                                PublicThreadScreen(postId: target.id))),
                    onOpen: (target) => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) =>
                                PublicThreadScreen(postId: target.id))),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          ),
        ),
      ),
    );
  }

  /// This account's posts in the servers it belongs to.
  ///
  /// Only ever your own: a server's feed is encrypted with that server's key,
  /// so a stranger's server posts are not something this device could show even
  /// if it wanted to.
  Widget _serverPosts(BuildContext context) {
    final me = AppState.profile.value;
    final mine = FeedStore.instance
        .recentPosts(limit: 100)
        .where((p) =>
            p.authorUsername == 'you' ||
            (me.username.isNotEmpty && p.authorUsername == me.username))
        .take(20)
        .toList();
    if (mine.isEmpty) {
      return SliverToBoxAdapter(
        child: _profileMessage(
            'Nothing posted in a server yet. Share something in a server\'s '
            'feed and it shows up here.'),
      );
    }
    return SliverList.separated(
      itemCount: mine.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) => ListTile(
        leading: const Icon(Icons.forum_outlined),
        title: Text(mine[i].text, maxLines: 3, overflow: TextOverflow.ellipsis),
        subtitle: Text(
            '${DateFormatter.postAge(mine[i].time)} · ${mine[i].likes} likes '
            '· ${mine[i].replies} replies',
            style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => FeedPostScreen(postId: mine[i].id))),
      ),
    );
  }

  /// What each tab says when it has nothing in it.
  ///
  /// An icon and two lines rather than one sentence in grey: an empty tab and
  /// a tab that failed to load used to look the same, and neither said what to
  /// do about it.
  Widget _emptyTab() {
    final (icon, title, subtitle) = switch (_tab) {
      ProfileTab.posts when _isMe => (
          Icons.edit_outlined,
          'Nothing posted yet',
          'Anything you post to the public timeline shows up here.',
        ),
      ProfileTab.posts => (
          Icons.article_outlined,
          'No posts yet',
          'When this account posts, it appears here.',
        ),
      ProfileTab.replies => (
          Icons.chat_bubble_outline,
          'No replies yet',
          'Replies to other people\'s posts collect here.',
        ),
      ProfileTab.media => (
          Icons.photo_library_outlined,
          'No photos yet',
          'Posts with a picture in them show up here.',
        ),
      // Handled above; a switch over an enum has to be complete.
      ProfileTab.servers => (Icons.forum_outlined, '', ''),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 44, 40, 44),
      child: Column(
        children: [
          Icon(icon, size: 34, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: AppColors.subtle(context))),
        ],
      ),
    );
  }

  Widget _profileMessage(String text, {bool retry = false}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        child: Column(
          children: [
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.subtle(context))),
            if (retry) ...[
              const SizedBox(height: 14),
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
            ],
          ],
        ),
      );
}

/// The avatar, with whatever this profile lets you do about it beside it.
///
/// There used to be a generated colour banner above this — a gradient mixed
/// from the handle, ninety-two points tall, standing in for a cover photo
/// there is nowhere to upload. It was the loudest thing on the screen and the
/// only saturated colour in an app whose whole identity is black and white,
/// and it pushed the name, the bio and the counts down below the fold. What
/// replaced it is the face and the buttons on one line, which is the
/// information the banner was decorating.
class _AvatarRow extends StatelessWidget {
  final String username;
  final String displayName;
  final bool isMe;

  const _AvatarRow(
      {required this.username, required this.displayName, required this.isMe});

  static const double _avatarRadius = 36;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final known = knownUserFor(username);
    final initial =
        (displayName.isEmpty ? '?' : displayName.replaceFirst('@', ''))
            .substring(0, 1)
            .toUpperCase();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 0),
      child: Row(
        children: [
          // Tapping your own face to change it is where people look first,
          // and it costs nothing to put the door there as well as on the
          // button. Somebody else's avatar is not a control.
          GestureDetector(
            onTap: isMe
                ? () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const EditProfileScreen()))
                : null,
            child: known != null
                ? UserAvatar(user: known, radius: _avatarRadius)
                : CircleAvatar(
                    radius: _avatarRadius,
                    backgroundColor: scheme.surfaceContainerHighest,
                    child: Text(initial,
                        style: const TextStyle(
                            fontSize: 28, fontWeight: FontWeight.w700)),
                  ),
          ),
          const SizedBox(width: 12),
          // Expanded-and-aligned rather than a Spacer with a Flexible after
          // it: a Spacer is an Expanded too, so the two of them split the
          // free space and the button was cropped to "Edit …" on a phone with
          // room to spare. This hands the whole remainder to the buttons and
          // lets them use as much of it as they need.
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: _ProfileActions(username: username, isMe: isMe),
            ),
          ),
        ],
      ),
    );
  }
}

/// One photo in the Media grid.
class _MediaCell extends StatelessWidget {
  final PublicPost post;
  const _MediaCell({required this.post});

  @override
  Widget build(BuildContext context) {
    final url = PublicFeedStore.imageUrlFor(post) ?? '';
    final surface = Theme.of(context).colorScheme.surfaceContainerHighest;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PublicThreadScreen(postId: post.id),
      )),
      child: Container(
        color: surface,
        child: Image.network(
          url,
          fit: BoxFit.cover,
          // A cell that cannot load its photo keeps its square — a grid that
          // drops tiles reflows every time one fails.
          errorBuilder: (_, __, ___) =>
              Icon(Icons.broken_image_outlined, color: Colors.grey.shade400),
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : const SizedBox.shrink(),
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
    final about = known?.about ?? '';
    final pronouns = known?.pronouns ?? '';
    final link = known?.link ?? '';
    // One margin and one rhythm. Every block below is 16 from the edge and 14
    // from the one above it — the gaps used to run 3, 8, 10, 12, 14 and 16
    // down a single column, which is what makes a screen look unfinished even
    // when nothing on it is wrong.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
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
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        height: 1.2)),
              ),
              if (verified) ...[
                const SizedBox(width: 6),
                const VerifiedBadge(size: 17),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Text('@$username',
                  style: TextStyle(
                      fontSize: 14.5, color: AppColors.subtle(context))),
              if (pronouns.isNotEmpty) ...[
                Text(' · ',
                    style: TextStyle(
                        fontSize: 14.5, color: AppColors.subtle(context))),
                Text(pronouns,
                    style: TextStyle(
                        fontSize: 14.5, color: AppColors.subtle(context))),
              ],
            ],
          ),
          // Only for somebody this device actually knows. There is no
          // directory of bios to read, and a placeholder line here would be an
          // invented one.
          if (about.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(about, style: const TextStyle(fontSize: 15, height: 1.4)),
          ],
          if (link.isNotEmpty) ...[
            const SizedBox(height: 10),
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
                        style:
                            TextStyle(fontSize: 13.5, color: scheme.primary)),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          // ONE row of counts. There were two — "1 post 0 following" above a
          // second row repeating Following beside Servers and Okay Score —
          // which is the sort of thing that makes somebody check whether the
          // two numbers disagree.
          ListenableBuilder(
            listenable: Listenable.merge(
                [FollowStore.instance, CommunityStore.instance]),
            builder: (context, _) => Wrap(
              spacing: 20,
              runSpacing: 10,
              children: [
                // Real, from the server, and the only count that means
                // anything on somebody else's profile.
                ProfileStat(
                    value: postCount == null ? '—' : '$postCount',
                    label: postCount == 1 ? 'Post' : 'Posts',
                    onTap: null),
                if (isMe) ...[
                  ProfileStat(
                      value: '${FollowStore.instance.followingCount}',
                      label: 'Following',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const PeopleScreen()))),
                  ProfileStat(
                      value: '${CommunityStore.instance.communities.length}',
                      label: 'Servers',
                      onTap: null),
                ],
              ],
            ),
          ),
          // Okay Score used to be the fourth count. Four do not fit a 390pt
          // phone, so the row broke three-and-one, which reads as a mistake
          // rather than a layout. It is also the only one of the four that is
          // a whole screen of its own, so a row with somewhere to go suits it
          // better than a number in a huddle.
          if (isMe) ...[
            const SizedBox(height: 14),
            _ScoreRow(
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ScoreScreen()))),
          ],
        ],
      ),
    );
  }
}

/// The Okay Score, given a row of its own — a number, what it is, and a way
/// in. It is the one profile stat with a screen behind it.
///
/// No box around it any more. An outlined full-width rectangle in the middle
/// of a profile reads as a text field waiting to be filled in, and it was the
/// heaviest element on a screen whose other rows are just text.
class _ScoreRow extends StatelessWidget {
  const _ScoreRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(Icons.local_fire_department, size: 19, color: scheme.primary),
            const SizedBox(width: 8),
            // From ScoreStore, which is where the number lives. It used to
            // read AppUser.score, a field nothing ever writes on your own
            // profile — it is populated from the wire for a CONTACT, so your
            // own always read zero however much you had earned.
            ListenableBuilder(
              listenable: ScoreStore.instance,
              builder: (context, _) => Text('${ScoreStore.instance.points}',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 6),
            Text('Okay Score',
                style: TextStyle(
                    fontSize: 14.5, color: AppColors.subtle(context))),
            const Spacer(),
            Icon(Icons.chevron_right,
                size: 20, color: AppColors.subtle(context)),
          ],
        ),
      ),
    );
  }
}

class _ProfileActions extends StatelessWidget {
  final String username;
  final bool isMe;
  const _ProfileActions({required this.username, required this.isMe});

  @override
  Widget build(BuildContext context) {
    if (isMe) {
      // No "Edit profile" button. Tapping your own face already opens the
      // editor and is where people reach for first, and Settings has a row
      // for it — three doors to one screen, one of them taking the widest
      // thing on the header.
      return IconButton(
        tooltip: 'Share your profile',
        icon: const Icon(Icons.qr_code),
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const MyQrScreen())),
      );
    }
    return ListenableBuilder(
      listenable: FollowStore.instance,
      builder: (context, _) {
        final following = FollowStore.instance.isFollowing(username);
        void toggle() => FollowStore.instance.toggle(username);
        final text = Text(following ? 'Following' : 'Follow',
            maxLines: 1, overflow: TextOverflow.ellipsis);
        return following
            ? OutlinedButton(onPressed: toggle, child: text)
            : FilledButton(onPressed: toggle, child: text);
      },
    );
  }
}

/// Holds the tab strip at the top of a profile while the posts scroll under it.
///
/// The strip is a fixed height, so min and max are the same and there is no
/// collapsing behaviour to get wrong. It paints the scaffold's own background:
/// without that, posts would show through it as they passed underneath.
class _PinnedTabs extends SliverPersistentHeaderDelegate {
  final Widget child;
  const _PinnedTabs({required this.child});

  // The strip's own height: 12 padding, the glyph or the label, 8, the
  // 3-pixel underline, 12 padding, and the hairline divider. Guessed at 49,
  // then 53; both clipped it. A pinned header cannot measure its child, so
  // this is a number that has to be right — the test asserts nothing
  // overflows, and it reports by how much when it does. Went to 57 when the
  // profile's tabs became 21-point icons, which are a pixel taller than the
  // line of text they replaced.
  static const double _height = 57;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SizedBox(height: _height, child: child),
      );

  @override
  bool shouldRebuild(_PinnedTabs old) => old.child != child;
}

/// One row of a timeline: a post, or somebody's repeat of one.
///
/// A PLAIN REPOST HAS NOTHING OF ITS OWN TO SAY, so it is drawn as the
/// original with a line above it naming who passed it on — the shape every
/// timeline uses, and the one a server feed here already used. Drawn the way
/// it was, as a post by the reposter with an empty body and the original in a
/// quote box, it read as somebody posting nothing.
///
/// A QUOTE is the opposite and keeps the shape it had: the quoter wrote
/// something, so it is their post with the original embedded beneath.
///
/// The actions belong to the post they are drawn on. Liking a repeat of
/// somebody's post likes THAT post, which is the only reading that makes a
/// count mean anything.
class _Entry extends StatelessWidget {
  const _Entry({
    required this.post,
    required this.onReply,
    required this.onOpen,
    this.collapseLongBody = true,
    this.threadedBelow = false,
    this.offerSelfThread = true,
    this.focused = false,
  });

  final PublicPost post;
  final void Function(PublicPost target) onReply;
  final void Function(PublicPost target) onOpen;
  final bool collapseLongBody;

  /// True for the one post a thread screen is about — larger body type, so
  /// the post and its replies stop reading as the same thing.
  final bool focused;

  /// Draws a line from this post's avatar down to the next one — what makes
  /// a chain of replies read as one conversation rather than a list of
  /// unrelated posts stacked up.
  final bool threadedBelow;

  /// Passed straight through to [_PostTile.offerSelfThread].
  final bool offerSelfThread;

  @override
  Widget build(BuildContext context) {
    // Only when the original is loaded. A header over a post that is not
    // there would be worse than the row it replaces.
    final original = post.isPlainRepost
        ? PublicFeedStore.instance.byId(post.repostOf!)
        : null;
    if (original == null) {
      final tile = _PostTile(
        post: post,
        offerSelfThread: offerSelfThread,
        onReply: () => onReply(post),
        onOpen: () => onOpen(post),
        collapseLongBody: collapseLongBody,
        focused: focused,
      );
      return threadedBelow ? _ThreadSpine(child: tile) : tile;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FeedRepostHeader(
            by: post.authorName.trim().isEmpty
                ? '@${post.authorUsername}'
                : post.authorName),
        _PostTile(
          post: original,
          onReply: () => onReply(original),
          onOpen: () => onOpen(original),
          collapseLongBody: collapseLongBody,
        ),
      ],
    );
  }
}

/// One post, plus its like / reply / more actions.
class _PostTile extends StatelessWidget {
  final PublicPost post;
  final VoidCallback onReply;
  final VoidCallback onOpen;

  /// Whether a long body folds to a "Show more". False where the post is the
  /// whole screen — a thread — because there is nothing under it to protect.
  final bool collapseLongBody;

  /// Whether to offer "Show this thread" when the author continued their own
  /// post. False where the post is already the thread being read — a line
  /// offering to open the screen you are on is a door back into the room you
  /// are standing in.
  final bool offerSelfThread;

  /// Larger body type for the one post a thread screen is about.
  final bool focused;

  const _PostTile(
      {required this.post,
      required this.onReply,
      required this.onOpen,
      this.collapseLongBody = true,
      this.offerSelfThread = true,
      this.focused = false});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: FeedPostMetrics.tilePadding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FeedAvatar(
              username: post.authorUsername,
              name: post.authorName,
              onTap: () => openPublicProfile(context, post.authorUsername,
                  name: post.authorName),
            ),
            const SizedBox(width: FeedPostMetrics.gutter),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FeedPostHeader(
                    name: post.authorName,
                    username: post.authorUsername,
                    time: post.createdAt,
                    verified: post.authorVerified,
                    onAuthor: () => openPublicProfile(
                        context, post.authorUsername,
                        name: post.authorName),
                    onMore: () => _more(context),
                  ),
                  // What this is a reply to. Only when the parent is loaded —
                  // a wrong handle here would be worse than no line at all.
                  if (PublicFeedStore.instance.replyingTo(post)
                      case final String parent) ...[
                    const SizedBox(height: 2),
                    GestureDetector(
                      onTap: () => openPublicProfile(context, parent),
                      child: Text('Replying to @$parent',
                          style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context).colorScheme.primary)),
                    ),
                  ],
                  // A plain repost has nothing of its own to show; the quoted
                  // post below carries the content.
                  if (post.body.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    FeedBodyText(
                      text: post.body,
                      collapse: collapseLongBody,
                      focused: focused,
                      onTag: (t) =>
                          PublicFeedStore.instance.setTag(t.substring(1)),
                      onMention: (u) => openPublicProfile(context, u),
                    ),
                  ],
                  if (post.hasImage) ...[
                    const SizedBox(height: 8),
                    FeedPostImage(
                      onOpen: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => FeedPhotoScreen(
                            url: PublicFeedStore.imageUrlFor(post) ?? '',
                            by: post.authorName.isEmpty
                                ? '@${post.authorUsername}'
                                : post.authorName),
                      )),
                      child: Image.network(
                        PublicFeedStore.imageUrlFor(post) ?? '',
                        fit: BoxFit.cover,
                        // A broken image should be absent, not a grey box
                        // with an icon in the middle of somebody's post.
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
                  if (post.hasGif) ...[
                    const SizedBox(height: 8),
                    // ChatPhoto, so an animated GIF served from the
                    // provider's CDN and a data: URI both work through one
                    // path — the same widget the server feed draws its GIFs
                    // with.
                    FeedPostImage(
                      onOpen: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => FeedPhotoScreen(
                            url: post.gifUrl,
                            by: post.authorName.isEmpty
                                ? '@${post.authorUsername}'
                                : post.authorName),
                      )),
                      child: ChatPhoto(
                        url: post.gifUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_) => const SizedBox.shrink(),
                      ),
                    ),
                  ],
                  if (post.hasVideo) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(
                          FeedPostMetrics.imageRadius),
                      child: FeedVideo(
                          url: PublicFeedStore.videoUrlFor(post) ?? ''),
                    ),
                  ],
                  if (post.isPoll) ...[
                    const SizedBox(height: 10),
                    _Poll(post: post),
                  ],
                  if (post.repostOf != null) _Quoted(postId: post.repostOf!),
                  // X's move, and the right one: somebody continuing their
                  // own post is one piece of writing that ran past a post's
                  // length, not strangers answering it. Offering to open it
                  // is different from the reply count, which is everybody.
                  if (offerSelfThread &&
                      PublicFeedStore.instance.selfThreadOf(post.id).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: InkWell(
                        onTap: onOpen,
                        child: Text('Show this thread',
                            style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.accentOn(context))),
                      ),
                    ),
                  const SizedBox(height: 2),
                  FeedPostActions(
                    replyCount: post.replyCount,
                    repostCount: post.repostCount,
                    likeCount: post.likeCount,
                    liked: post.liked,
                    reposted:
                        PublicFeedStore.instance.myRepostOf(post.id) != null,
                    onReply: onReply,
                    // A repeat is two different intentions — pass it on as it
                    // is, or pass it on with something to say — so it asks
                    // which rather than picking one.
                    onRepost: () => _repostMenu(context),
                    onLike: () => PublicFeedStore.instance.toggleLike(post.id),
                    onShare: () {
                      Clipboard.setData(ClipboardData(text: post.body));
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Post copied.')));
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Repost, or quote it with something of your own.
  void _repostMenu(BuildContext context) {
    final mine = PublicFeedStore.instance.myRepostOf(post.id) != null;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(mine ? Icons.close : Icons.repeat),
              title: Text(mine ? 'Undo repost' : 'Repost'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                try {
                  await PublicFeedStore.instance.toggleRepost(post.id);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text('$e')));
                  }
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.format_quote),
              title: const Text('Quote post'),
              subtitle: const Text('Add your own words above it'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _openComposer(context, quoteOf: post.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _more(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Bookmark, mute, forward, copy, report — with subtitles they no
      // longer fit the default half-height sheet, and what falls off the
      // bottom is silently unreachable.
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListenableBuilder(
                listenable: BookmarkStore.instance,
                builder: (context, _) {
                  final saved = BookmarkStore.instance.contains(post.id);
                  return ListTile(
                    leading: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
                    title: Text(saved ? 'Remove bookmark' : 'Bookmark'),
                    subtitle: const Text('Kept on this device only'),
                    onTap: () async {
                      Navigator.of(sheetContext).pop();
                      final now = await BookmarkStore.instance.toggle(post.id);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content:
                              Text(now ? 'Bookmarked.' : 'Bookmark removed.')));
                    },
                  );
                },
              ),
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
              // A post that interests somebody is a post they want to send to
              // somebody. Copying the text and pasting it into a chat was the
              // only way, on both feeds.
              if (post.body.trim().isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.forward),
                  title: const Text('Forward'),
                  subtitle: const Text('To a chat or a server channel, '
                      'encrypted like any other message'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ForwardScreen(text: post.body)));
                  },
                ),
              // The public feed is the one surface with a real moderator behind
              // it — a world-readable table, a reports queue, and people with
              // the power to act on it. It was also the only surface with no way
              // to report anything.
              if (!post.mine)
                ListTile(
                  leading: const Icon(Icons.flag_outlined),
                  title: const Text('Report post'),
                  subtitle: const Text('Sends it to the moderators'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _reportPost(context, post);
                  },
                ),
              if (!post.mine && post.authorUsername.isNotEmpty)
                ListenableBuilder(
                  listenable: FeedMuteStore.instance,
                  builder: (context, _) {
                    final muted =
                        FeedMuteStore.instance.isMuted(post.authorUsername);
                    return ListTile(
                      leading: Icon(muted
                          ? Icons.volume_up_outlined
                          : Icons.volume_off_outlined),
                      title: Text(muted
                          ? 'Unmute @${post.authorUsername}'
                          : 'Mute @${post.authorUsername}'),
                      subtitle: Text(muted
                          ? 'Their posts come back to your timeline'
                          : 'Hides their posts from your timeline, on this '
                              'device. They are not told.'),
                      onTap: () async {
                        Navigator.of(sheetContext).pop();
                        final now = await FeedMuteStore.instance
                            .toggle(post.authorUsername);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(now
                                ? 'Muted @${post.authorUsername}.'
                                : 'Unmuted @${post.authorUsername}.')));
                      },
                    );
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
      ),
    );
  }
}

/// A post and its replies.
/// One post and its replies.
///
/// Public because a profile links to it: your own posts are listed on the
/// profile the app already had, and tapping one has to land somewhere.
class PublicThreadScreen extends StatelessWidget {
  final String postId;
  const PublicThreadScreen({super.key, required this.postId});

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
          final ancestors = PublicFeedStore.instance.ancestorsOf(postId);
          return Column(
            children: [
              Expanded(
                child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              // THE CONVERSATION ABOVE THIS POST, root first. Without it a
              // reply four levels down is a sentence with no idea what it is
              // answering — you could descend a thread but never see where
              // you were. Each one opens its own thread, so the chain is a
              // way back up as well as context.
              for (final a in ancestors)
                _Entry(
                  post: a,
                  threadedBelow: true,
                  onReply: (target) => _openComposer(context,
                      replyTo: target.id, replyingToName: target.authorName),
                  onOpen: (target) => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => PublicThreadScreen(postId: target.id)),
                  ),
                ),
              _Entry(
                post: post,
                collapseLongBody: false,
                offerSelfThread: false,
                focused: true,
                onReply: (target) => _openComposer(context,
                    replyTo: target.id, replyingToName: target.authorName),
                onOpen: (_) {},
              ),
              const Divider(height: 1),
              if (replies.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text('No replies yet.',
                        style: TextStyle(color: AppColors.subtle(context))),
                  ),
                )
              else ...[
                // Said, not implied: without the label the replies read as
                // more posts, and nothing on the screen says which one
                // everything else is answering.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                  child: Text('Replies',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.subtle(context))),
                ),
                // A REPLY IS A POST. Its own reply button opens the composer
                // for it and tapping it opens its thread — both were wired to
                // empty callbacks, so answering somebody's comment did
                // nothing at all and there was no way to reach the
                // conversation under it.
                //
                // Flush and divided, like the timeline, rather than indented:
                // an indent implies a tree that keeps going, and the next
                // level down is a tap away on its own screen.
                for (final r in replies) ...[
                  _Entry(
                    post: r,
                    onReply: (target) => _openComposer(context,
                        replyTo: target.id,
                        replyingToName: target.authorName),
                    onOpen: (target) => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) =>
                              PublicThreadScreen(postId: target.id)),
                    ),
                  ),
                  const Divider(height: 1),
                ],
              ],
            ],
                ),
              ),
              // The same bar a server's thread has, because it is the same
              // screen doing the same job: the next thing somebody does here
              // is almost always say something back.
              FeedReplyBar(
                handle: post.authorUsername,
                onSend: (text) async {
                  try {
                    await PublicFeedStore.instance
                        .post(text, replyTo: post.id);
                    return true;
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text('$e')));
                    }
                    return false;
                  }
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Reports a public post to the moderation queue.
///
/// Sends the post's id and its author's handle, not its text. A moderator
/// reads the post itself from the table — it is public, so there is nothing to
/// copy across, and a report carrying a snippet would be a second copy of
/// something that can be deleted from the first.
Future<void> _reportPost(BuildContext context, PublicPost post) async {
  const reasons = [
    'Spam or scam',
    'Harassment or bullying',
    'Inappropriate content',
    'Impersonation',
    'Something else',
  ];
  var alsoMute = false;
  final reason = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: Text('Report this post',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                  'A moderator reads the post itself. Nothing about your own '
                  'account is shown to whoever posted it.',
                  style:
                      TextStyle(fontSize: 13, color: AppColors.subtle(context))),
            ),
            for (final r in reasons)
              ListTile(
                title: Text(r),
                onTap: () => Navigator.pop(sheetContext, r),
              ),
            if (post.authorUsername.isNotEmpty)
              CheckboxListTile(
                value: alsoMute,
                onChanged: (v) => setSheet(() => alsoMute = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                title: Text('Also mute @${post.authorUsername}'),
                subtitle: const Text('Hides their posts for you, on this '
                    'device. They are not told.'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
  if (reason == null) return;

  final sent = await PlatformModeration.instance.report(
    reason: reason,
    targetHandle: post.authorUsername,
    context: 'public_post:${post.id}',
    reporterPhone: local.Session.instance.user.value?.phone ?? '',
  );
  if (alsoMute &&
      post.authorUsername.isNotEmpty &&
      !FeedMuteStore.instance.isMuted(post.authorUsername)) {
    await FeedMuteStore.instance.toggle(post.authorUsername);
  }
  if (!context.mounted) return;
  // Says which of the two happened. Claiming a report landed when the insert
  // was refused is the kind of thing somebody only finds out by nothing ever
  // being done about it.
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(sent
        ? 'Reported. A moderator will look at it.'
        : 'Couldn\'t send that report — you may be offline. Try again.'),
  ));
}

/// Opens the composer.
///
/// A full-screen route rather than a bottom sheet. The composer grew a poll
/// editor and a photo preview, and a sheet that has to grow past half the
/// screen while the keyboard is up is a sheet fighting the keyboard — every
/// timeline this one is modelled on opens a page instead.
Future<void> _openComposer(BuildContext context,
        {String? replyTo, String? replyingToName, String? quoteOf}) =>
    Navigator.of(context).push<void>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _Composer(
          replyTo: replyTo, replyingToName: replyingToName, quoteOf: quoteOf),
    ));

/// The post being answered, above the composer.
///
/// Plain rather than in a quote box: a quote card says "this is being carried
/// along with what I write", which is what a quote post does. This is
/// context — the thing you are talking back to — so it is drawn as the post
/// it is, with a line running down from it to your own avatar.
class _ReplyingTo extends StatelessWidget {
  const _ReplyingTo({required this.postId});

  final String postId;

  @override
  Widget build(BuildContext context) {
    final post = PublicFeedStore.instance.byId(postId);
    // Only what is loaded. A blank card claiming to be somebody's post is
    // worse than starting straight at the field.
    if (post == null) return const SizedBox.shrink();
    final subtle = AppColors.subtle(context);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              FeedAvatar(
                  username: post.authorUsername,
                  name: post.authorName,
                  radius: 20),
              // The thread line, joining what is being answered to the person
              // answering it.
              Expanded(
                child: Container(
                  width: 2,
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  color: subtle.withValues(alpha: 0.3),
                ),
              ),
            ],
          ),
          const SizedBox(width: FeedPostMetrics.gutter),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FeedPostHeader(
                    name: post.authorName,
                    username: post.authorUsername,
                    time: post.createdAt,
                    verified: post.authorVerified,
                  ),
                  if (post.body.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(post.body,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: FeedPostMetrics.body),
                  ],
                  const SizedBox(height: 8),
                  Text(
                      'Replying to '
                      '@${post.authorUsername.isEmpty ? 'them' : post.authorUsername}',
                      style: TextStyle(fontSize: 13.5, color: subtle)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The composer. Says out loud that a post here is public, because this is the
/// one place in the app where that is true.
class _Composer extends StatefulWidget {
  final String? replyTo;
  final String? replyingToName;

  /// The post being quoted, when this is a quote post rather than a new one.
  /// A quote carries the original below whatever gets typed, so empty text is
  /// allowed — that is a plain repost, and the table says so too.
  final String? quoteOf;

  const _Composer({this.replyTo, this.replyingToName, this.quoteOf});

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _text = TextEditingController();
  bool _sending = false;
  Uint8List? _image;
  String? _gifUrl;
  Uint8List? _video;
  String _videoName = '';

  /// One piece of media at a time — the store refuses more, and two would
  /// have to share the width anyway.
  bool get _hasMedia => _image != null || _gifUrl != null || _video != null;

  /// Which box this is: a reply is kept apart from the main composer, so a
  /// half-written reply to one person does not appear in the box for another.
  String get _draftKey => widget.replyTo == null
      ? FeedDrafts.publicKey
      : FeedDrafts.replyKey(widget.replyTo!);

  @override
  void initState() {
    super.initState();
    _text.text = FeedDrafts.instance.read(_draftKey);
    _text.addListener(_saveDraft);
  }

  void _saveDraft() => FeedDrafts.instance.write(_draftKey, _text.text);

  final _focus = FocusNode();

  /// Non-null once a poll is being written. Two answer fields to start with,
  /// because two is the fewest a poll can have.
  List<TextEditingController>? _pollFields;
  Duration _pollRunsFor = const Duration(days: 1);

  bool get _isPoll => _pollFields != null;

  void _togglePoll() {
    setState(() {
      if (_isPoll) {
        for (final c in _pollFields!) {
          c.dispose();
        }
        _pollFields = null;
      } else {
        _pollFields = [TextEditingController(), TextEditingController()];
        // A photo and a poll in one post would have to share the space and
        // the question, and no timeline does it. The poll wins because it is
        // the thing just asked for.
        _image = null;
      }
    });
  }

  void _addPollField() {
    if (_pollFields == null ||
        _pollFields!.length >= PublicFeedStore.maxPollOptions) {
      return;
    }
    setState(() => _pollFields!.add(TextEditingController()));
  }

  void _removePollField(int i) {
    if (_pollFields == null ||
        _pollFields!.length <= PublicFeedStore.minPollOptions) {
      return;
    }
    setState(() => _pollFields!.removeAt(i).dispose());
  }

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
      setState(() {
        _image = bytes;
        _gifUrl = null;
        _video = null;
      });
    } on FileRejected catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.reason)));
      }
    }
  }

  /// Picks a GIF from the provider. Nothing is uploaded — a GIF already lives
  /// on their CDN, and the post carries its address.
  Future<void> _pickGif() async {
    // Opened straight on the GIF tab: this button says GIF, so landing on
    // emoji would be answering a different question.
    final picked = await showEmojiGifSheet(context, initialTab: 1);
    final gif = picked?.gif;
    if (gif == null || !mounted) return;
    setState(() {
      _gifUrl = gif.url;
      _image = null;
      _video = null;
    });
  }

  /// Picks a video. Bytes this time, because unlike a GIF there is nobody
  /// else already hosting it.
  Future<void> _pickVideo() async {
    try {
      final picked = await NearbyPick.pick(limit: PublicFeedStore.maxVideoBytes);
      if (picked == null || !mounted) return;
      if (picked.kind != 'video') {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Pick a video file.')));
        return;
      }
      final bytes = PhotoPrep.bytesFromDataUri(picked.dataUri);
      if (bytes == null || !mounted) return;
      setState(() {
        _video = bytes;
        _videoName = picked.fileName;
        _image = null;
        _gifUrl = null;
      });
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
    _focus.dispose();
    for (final c in _pollFields ?? const <TextEditingController>[]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      await PublicFeedStore.instance.post(_text.text,
          replyTo: widget.replyTo,
          repostOf: widget.quoteOf,
          image: _image,
          gifUrl: _gifUrl,
          video: _video,
          pollOptions: [for (final c in _pollFields ?? const []) c.text],
          pollRunsFor: _isPoll ? _pollRunsFor : null);
      // Cleared only once it is actually posted. A send that throws leaves
      // the draft exactly where it was, which is the whole point of having
      // one.
      _text.removeListener(_saveDraft);
      FeedDrafts.instance.clear(_draftKey);
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
    final typed = _text.text.trim().length;
    final left = PublicFeedStore.maxLength - typed;
    final accent = Theme.of(context).colorScheme.primary;
    final postable = !_sending &&
        left >= 0 &&
        (typed > 0 || _hasMedia || widget.quoteOf != null) &&
        (!_isPoll ||
            (typed > 0 &&
                PublicFeedStore.validatePoll(
                        [for (final c in _pollFields!) c.text]) ==
                    null));

    return Scaffold(
      appBar: AppBar(
        // Close on the left and the action on the right, the way every
        // timeline's composer is laid out — the button you are reaching for is
        // where your thumb already is, not at the bottom of a sheet whose
        // height changes with the keyboard.
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: widget.replyTo == null && widget.quoteOf == null
            ? null
            : Text(widget.quoteOf != null
                ? 'Quote post'
                : 'Reply to ${widget.replyingToName ?? 'post'}'),
        actions: [
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
            child: FilledButton(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
              ),
              // A photo on its own is a post; text is not required when
              // something else is attached. A poll is the exception — answers
              // with no question is not a poll.
              onPressed: postable ? _send : null,
              child: Text(_sending
                  ? 'Posting…'
                  : (widget.replyTo == null ? 'Post' : 'Reply')),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              // Most of this screen is blank, and on a page whose whole point
              // is writing, blank space that does nothing when tapped reads as
              // a dead screen. Tapping anywhere brings the cursor back.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _focus.requestFocus,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // WHAT IS BEING ANSWERED, above what you are writing.
                      // A title alone says who; a reply written blind to the
                      // post it answers is one written from memory.
                      if (widget.replyTo != null) ...[
                        _ReplyingTo(postId: widget.replyTo!),
                        const SizedBox(height: 4),
                      ],
                      Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Your own face beside what you are writing, so a post
                      // reads as coming from somebody before it is sent.
                      UserAvatar(user: me, radius: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              controller: _text,
                              focusNode: _focus,
                              autofocus: true,
                              maxLines: null,
                              // Sized to what is written, so a photo or a poll
                              // sits directly under the words rather than after
                              // a reserved block of empty lines.
                              minLines: 1,
                              style:
                                  const TextStyle(fontSize: 18, height: 1.35),
                              textCapitalization: TextCapitalization.sentences,
                              // No box. The page is the field — a bordered
                              // rectangle inside a screen that is nothing else
                              // reads as a form.
                              //
                              // All four of these are needed. The theme fills
                              // every field and gives it a focused outline, and
                              // `border` alone overrides NEITHER: `filled` is a
                              // separate flag, and enabledBorder/focusedBorder
                              // take precedence over `border` whenever they are
                              // set. This shipped as a pill around
                              // "What's happening?" for exactly that reason.
                              decoration: InputDecoration(
                                // What a reply is called, where a reply is
                                // being written.
                                hintText: widget.replyTo == null
                                    ? 'What\'s happening?'
                                    : 'Post your reply',
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                            if (widget.quoteOf != null) ...[
                              const SizedBox(height: 10),
                              _Quoted(postId: widget.quoteOf!),
                            ],
                            if (_isPoll) ...[
                              const SizedBox(height: 12),
                              _PollEditor(
                                fields: _pollFields!,
                                runsFor: _pollRunsFor,
                                onAdd: _addPollField,
                                onRemove: _removePollField,
                                onDuration: (d) =>
                                    setState(() => _pollRunsFor = d),
                                onChanged: () => setState(() {}),
                              ),
                            ],
                            if (_image != null) ...[
                              const SizedBox(height: 10),
                              Stack(
                                alignment: Alignment.topRight,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: Image.memory(_image!,
                                        height: 200,
                                        width: double.infinity,
                                        fit: BoxFit.cover),
                                  ),
                                  IconButton(
                                    icon: const CircleAvatar(
                                      radius: 14,
                                      backgroundColor: Colors.black54,
                                      child: Icon(Icons.close,
                                          size: 16, color: Colors.white),
                                    ),
                                    tooltip: 'Remove photo',
                                    onPressed: () =>
                                        setState(() => _image = null),
                                  ),
                                ],
                              ),
                            ],
                            if (_gifUrl != null) ...[
                              const SizedBox(height: 10),
                              Stack(
                                alignment: Alignment.topRight,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: ChatPhoto(
                                      url: _gifUrl!,
                                      height: 200,
                                      width: double.infinity,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                  IconButton(
                                    icon: const CircleAvatar(
                                      radius: 14,
                                      backgroundColor: Colors.black54,
                                      child: Icon(Icons.close,
                                          size: 16, color: Colors.white),
                                    ),
                                    tooltip: 'Remove GIF',
                                    onPressed: () =>
                                        setState(() => _gifUrl = null),
                                  ),
                                ],
                              ),
                            ],
                            if (_video != null) ...[
                              const SizedBox(height: 10),
                              // The file, named and weighed, rather than a
                              // frame of it: decoding a poster image here
                              // would mean playing the video to show that
                              // the video is attached.
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.movie_outlined),
                                title: Text(
                                  _videoName.isEmpty ? 'Video' : _videoName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                    '${(_video!.length / (1024 * 1024)).toStringAsFixed(1)} MB'),
                                trailing: IconButton(
                                  icon: const Icon(Icons.close),
                                  tooltip: 'Remove video',
                                  onPressed: () => setState(() {
                                    _video = null;
                                    _videoName = '';
                                  }),
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            // Who can see it, said where the timelines people
                            // arrive from say who can reply. This is the one
                            // screen in the app where a post is not private, and
                            // it is the one line that has to be read.
                            Row(
                              children: [
                                Icon(Icons.public, size: 15, color: accent),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    me.username.isEmpty
                                        ? 'Everyone can see this — set a username '
                                            'so people know who posted'
                                        : 'Everyone can see this, as '
                                            '@${me.username}',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: accent),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            // The tools, on one row above the keyboard.
            Padding(
              // No viewInsets padding here: the Scaffold already shrinks the
              // body for the keyboard, and adding it again would push the row
              // a keyboard's height off the bottom of the screen.
              padding: const EdgeInsets.only(left: 6, right: 12),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.image_outlined),
                    color: accent,
                    tooltip: 'Add a photo',
                    onPressed: _sending || _isPoll ? null : _pickImage,
                  ),
                  // Both hidden until the server's feed has the columns for
                  // them. Offering a button whose post the insert would
                  // reject is worse than not offering it — see
                  // PublicFeedStore.mediaSupported.
                  if (PublicFeedStore.instance.mediaSupported) ...[
                    IconButton(
                      icon: const Icon(Icons.gif_box_outlined),
                      color: accent,
                      tooltip: 'Add a GIF',
                      onPressed: _sending || _isPoll ? null : _pickGif,
                    ),
                    IconButton(
                      icon: const Icon(Icons.movie_outlined),
                      color: accent,
                      tooltip: 'Add a video',
                      onPressed: _sending || _isPoll ? null : _pickVideo,
                    ),
                  ],
                  IconButton(
                    icon: Icon(_isPoll ? Icons.poll : Icons.poll_outlined),
                    color: accent,
                    tooltip: _isPoll ? 'Remove poll' : 'Add a poll',
                    // A poll is a post of its own — it cannot be a reply or a
                    // quote, and the table refuses those too.
                    onPressed: _sending ||
                            widget.replyTo != null ||
                            widget.quoteOf != null ||
                            !PublicFeedStore.instance.pollsSupported
                        ? null
                        : _togglePoll,
                  ),
                  const Spacer(),
                  _CharacterRing(used: typed, limit: PublicFeedStore.maxLength),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The answer fields, split out of the composer's build so that method reads as
/// a layout rather than as two screens sharing one function.
class _PollEditor extends StatelessWidget {
  const _PollEditor({
    required this.fields,
    required this.runsFor,
    required this.onAdd,
    required this.onRemove,
    required this.onDuration,
    required this.onChanged,
  });

  final List<TextEditingController> fields;
  final Duration runsFor;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;
  final ValueChanged<Duration> onDuration;
  final VoidCallback onChanged;

  static String _durationLabel(Duration d) {
    if (d.inHours < 24) return '${d.inHours} hour${d.inHours == 1 ? '' : 's'}';
    return '${d.inDays} day${d.inDays == 1 ? '' : 's'}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.8)),
      ),
      child: Column(
        children: [
          for (var i = 0; i < fields.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: fields[i],
                      maxLength: PublicFeedStore.maxPollOptionLength,
                      decoration: InputDecoration(
                        labelText: 'Answer ${i + 1}',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        counterText: '',
                      ),
                      onChanged: (_) => onChanged(),
                    ),
                  ),
                  // Only past the minimum: removing an answer down to one
                  // would leave a poll nobody can answer.
                  if (fields.length > PublicFeedStore.minPollOptions)
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      tooltip: 'Remove answer',
                      onPressed: () => onRemove(i),
                    ),
                ],
              ),
            ),
          Row(
            children: [
              if (fields.length < PublicFeedStore.maxPollOptions)
                TextButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add answer'),
                ),
              const Spacer(),
              DropdownButton<Duration>(
                value: runsFor,
                underline: const SizedBox.shrink(),
                onChanged: (d) => d == null ? null : onDuration(d),
                items: [
                  for (final d in PublicFeedStore.pollDurations)
                    DropdownMenuItem(value: d, child: Text(_durationLabel(d))),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// How much of the limit is gone, as a ring that fills.
///
/// A bare number counting down is only read once somebody is already near the
/// end. The ring is legible from the corner of an eye the whole way, and it
/// only spells the number out for the last twenty characters — which is when
/// the number is the thing you want.
class _CharacterRing extends StatelessWidget {
  const _CharacterRing({required this.used, required this.limit});

  final int used;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final left = limit - used;
    final over = left < 0;
    final close = left <= 20;
    final colour = over
        ? const Color(0xFFD92D20)
        : close
            ? const Color(0xFFF79009)
            : Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 34,
      height: 34,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: close ? 26 : 22,
            height: close ? 26 : 22,
            child: CircularProgressIndicator(
              // Past the limit the ring stays full and turns red rather than
              // wrapping around to look nearly empty again.
              value: (used / limit).clamp(0.0, 1.0),
              strokeWidth: 2.5,
              backgroundColor: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation<Color>(colour),
            ),
          ),
          if (close)
            Text('$left',
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w700, color: colour)),
        ],
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
        FeedTabStrip(
          labels: [for (final f in FeedFilter.values) f.label],
          active: FeedFilter.values.indexOf(store.filter),
          onPick: (i) => store.setFilter(FeedFilter.values[i]),
        ),
        FeedTrendingBar(
          tags: tags,
          tag: store.tag,
          query: store.query,
          onTag: store.setTag,
          onClearQuery: () => store.search(''),
        ),
        if (store.filter == FeedFilter.following && store.posts.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
                'Nothing from people you follow yet. Tap a name to follow '
                'someone.',
                style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
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
    if (store.reachedEnd) return const FeedEndOfList();
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

/// A poll: buttons until you answer, bars afterwards.
///
/// Which way round it renders is the post's own state, not this widget's —
/// [PublicPost.showPollResults] is true once you have voted or once it has
/// closed, and the server refuses a vote in either case, so the two cannot
/// disagree about whether voting is still open.
class _Poll extends StatelessWidget {
  const _Poll({required this.post});

  /// One answer's height, whether it is still a button or already a bar.
  /// Comfortably a tap target, and the same either way so nothing reflows.
  static const double optionHeight = 44;

  final PublicPost post;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final total = post.pollTotalVotes;
    final leaders = post.pollLeaders;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < post.pollOptions.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: post.showPollResults
                ? _Result(
                    label: post.pollOptions[i],
                    share: post.pollShare(i),
                    mine: post.myVote == i,
                    leading: leaders.contains(i),
                    accent: accent,
                  )
                : OutlinedButton(
                    onPressed: () => PublicFeedStore.instance.vote(post.id, i),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: accent,
                      // THE SAME HEIGHT AS THE RESULT IT TURNS INTO. Voting
                      // used to shrink a three-option poll by thirty points,
                      // so the timeline jumped under the thumb that had just
                      // tapped — and an unvoted poll took more room than the
                      // post it belonged to. Not smaller than this: it is a
                      // target, and shrinkWrap means the button IS its box.
                      minimumSize: const Size.fromHeight(_Poll.optionHeight),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(post.pollOptions[i],
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
          ),
        Text(
          '${_votes(total)} · ${_timeLeft(post)}',
          style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
        ),
      ],
    );
  }

  static String _votes(int n) => n == 1 ? '1 vote' : '$n votes';

  /// How long is left, in the words somebody would use. A closed poll says so
  /// rather than counting down past zero.
  static String _timeLeft(PublicPost post) {
    if (post.pollClosed) return 'Final result';
    final mins = post.pollClosesAt!.difference(DateTime.now()).inMinutes;
    if (mins < 60) return '$mins min left';
    // Rounded, not truncated. A poll set to run five hours is read a
    // millisecond later, and truncating turns that into "4 hours left" — the
    // one number somebody checks against what they just chose.
    final hours = (mins / 60).round();
    if (hours < 24) return '$hours hour${hours == 1 ? '' : 's'} left';
    final days = (hours / 24).round();
    return '$days day${days == 1 ? '' : 's'} left';
  }
}

/// One answer with its share of the vote drawn behind it.
class _Result extends StatelessWidget {
  const _Result({
    required this.label,
    required this.share,
    required this.mine,
    required this.leading,
    required this.accent,
  });

  final String label;
  final double share;
  final bool mine;
  final bool leading;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => Stack(
        children: [
          Container(
            height: _Poll.optionHeight,
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          // The bar, animated from wherever it was — a tally that jumps on a
          // vote reads as a different poll rather than as your own answer
          // landing.
          AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            height: _Poll.optionHeight,
            width: box.maxWidth * share.clamp(0.0, 1.0),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: leading ? 0.22 : 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          SizedBox(
            height: _Poll.optionHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight:
                              leading ? FontWeight.w700 : FontWeight.w500),
                    ),
                  ),
                  // Your own answer is marked. Nobody else's is: the server
                  // will not say who voted for what, and this is the client
                  // side of the same promise.
                  if (mine) ...[
                    Icon(Icons.check_circle, size: 15, color: accent),
                    const SizedBox(width: 6),
                  ],
                  Text('${(share * 100).round()}%',
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Post text with tappable #hashtags and @mentions.
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
              style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context)))
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
                            fontSize: 12, color: AppColors.subtle(context))),
                  ),
              ],
            ),
    );
  }
}


/// A post in an ancestor chain, with the connector down its left.
///
/// The line sits under the avatar and runs the height of the tile, so the
/// column of faces reads as one conversation. Drawn behind the post rather
/// than around it: wrapping each tile in padding would shift the whole
/// thread right of the timeline it came from, and the same post would sit in
/// two different places depending on which screen you reached it from.
class _ThreadSpine extends StatelessWidget {
  final Widget child;
  const _ThreadSpine({required this.child});

  @override
  Widget build(BuildContext context) {
    final left = FeedPostMetrics.tilePadding.left +
        FeedPostMetrics.avatarRadius -
        1;
    return Stack(
      children: [
        // Starts below the avatar, not at the top of the tile: a line across
        // somebody's face is a rendering accident, not a thread.
        Positioned(
          left: left,
          top: FeedPostMetrics.tilePadding.top +
              FeedPostMetrics.avatarRadius * 2 +
              4,
          bottom: 0,
          child: Container(
            width: 2,
            color: Theme.of(context).dividerColor,
          ),
        ),
        child,
      ],
    );
  }
}
