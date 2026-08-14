import '../theme/app_theme.dart';
import '../ads/ad_service.dart';
import 'home_screen.dart' show AppBottomNavBar, HomeNavBar, HomeScreen;
import 'marketplace_screen.dart' show SellerShopButton, openSellerChat;
import '../state/parental_controls.dart';
import '../widgets/brand_mark.dart';
import '../widgets/parental_gate.dart';
import '../widgets/phone_gate.dart';
import '../widgets/feed_prefs_sheet.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/platform_role.dart';
import '../models/user.dart';
import '../state/chat_store.dart';
import '../state/account_verification.dart';
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
import '../util/media_prep.dart';
import '../util/photo_prep.dart';
import '../utils/date_formatter.dart';
import '../widgets/sanction_notice.dart';
import '../widgets/sidebar_menu_button.dart';
import '../widgets/user_avatar.dart';
import '../widgets/feed_post_actions.dart';
import '../widgets/spark_sheet.dart';
import '../widgets/chat_photo.dart';
import '../widgets/emoji_gif_sheet.dart';
import '../widgets/encryption_note.dart';
import '../widgets/feed_post_parts.dart';
import '../widgets/feed_video.dart';
import '../widgets/verified_badge.dart';
import '../widgets/subscribe_sheet.dart';
import '../state/creator_sub_store.dart';
import 'community_notes_screen.dart';
import 'edit_profile_screen.dart';
import 'follow_list_screen.dart';
import 'feed_screen.dart'
    show FeedPostScreen, activeMentionPrefix, mentionMatches;
import 'forward_screen.dart';
import 'my_qr_screen.dart';
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

/// Sparks are no longer offered ON a post (2026-08-09).
///
/// Money attached to one piece of content is a payment for digital content,
/// which is the shape Apple made Damus strip out of its posts. Tipping is
/// something you do to a PERSON: on their profile, or in a chat. The post
/// card still shows what a post was sparked before the change — that money
/// really moved, and hiding it would be the lie.

class PublicFeedScreen extends StatefulWidget {
  const PublicFeedScreen(
      {super.key, this.fromSidebar = false, this.asTab = false});

  /// True when opened from the sidebar — shows a ☰ that reopens the sidebar
  /// instead of a back arrow.
  final bool fromSidebar;

  /// True when this screen IS the home shell's Newsfeed tab: the home Scaffold
  /// already renders the app's bottom bar, so this screen must not mount its
  /// own copy (the ad banner stays — it belongs to the feed, not the bar).
  final bool asTab;

  @override
  State<PublicFeedScreen> createState() => _PublicFeedScreenState();
}

class _PublicFeedScreenState extends State<PublicFeedScreen> {
  final _store = PublicFeedStore.instance;
  final _scroll = ScrollController();

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
    // A name-only account may READ the feed — the timeline is served by the
    // anon key, the same as browsing the marketplace. What it can't do is
    // POST: every write needs a session, gated per-action inside (see
    // postNeedsPhone), so the door is open and only the pen is held.
    return ParentalGate(
      restriction: ParentalRestriction.publicFeed,
      title: 'Newsfeed',
      child: _guarded(context),
    );
  }

  Widget _guarded(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        // As the home shell's Newsfeed TAB there is nothing to go back to and
        // home's app bar (with the drawer hamburger) is hidden — so the ☰
        // lives here, opening home's drawer in place over the tab. Pushed as
        // a route it keeps the normal back arrow (the owner's call — every
        // pushed screen goes back the way every app goes back). The avatar
        // shortcut this slot used to carry lives on as the drawer's profile
        // card (and openPublicProfile still serves every mention/row).
        //
        // Deliberately ModalRoute.of(context)?.canPop, not
        // Navigator.of(context).canPop() — the latter asks "can the WHOLE
        // stack pop", so pushing the ONE app-wide search on top (showSearch)
        // made it answer true for this hidden tab too. Dismissing the
        // keyboard while search was open fired an unrelated rebuild here
        // (MediaQuery) that read canPop() wrong and cleared the leading —
        // and closing search back down never forces this tab to rebuild
        // again, so the wrong answer stuck. canPop on THIS route asks
        // whether there is anything below the tab's own route, which is
        // never true for the home shell no matter what gets pushed above it.
        leading: (ModalRoute.of(context)?.canPop ?? false)
            ? null
            : const HomeDrawerButton(),
        // The app icon, centred, and nothing else. The owner's call: the
        // word "Newsfeed" told you what you were already looking at, and the
        // feed picker, the search field and the compose pencil have all moved
        // — search to the bottom bar (the ONE search in the app, which walks
        // public posts too), compose to the floating button, and the For you
        // / Following choice out of the product entirely.
        centerTitle: true,
        // The mark itself, in the bar's own ink — not the icon TILE, which
        // read as a sticker stuck on the bar (see BrandMark). Bigger than the
        // tile was, because without a dark square around it the bubble is the
        // only thing carrying the space.
        title: const BrandMark(size: 34, opacity: 0.9),
        actions: [
          // Notifications moved off the bottom bar to here (the owner's
          // call), keeping its unread badge. The bar it left made room for
          // Search in the middle.
          ListenableBuilder(
            listenable: AppBottomNavBar.badgeListenable,
            builder: (context, _) {
              final n = AppBottomNavBar.activityCountNow;
              return IconButton(
                tooltip: 'Notifications',
                onPressed: () => HomeScreen.goToTab(context, 3),
                icon: material.Badge.count(
                  count: n,
                  isLabelVisible: n > 0,
                  child: Icon(
                      n > 0 ? Icons.notifications : Icons.notifications_none),
                ),
              );
            },
          ),
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
      // New post is a hovering button again, bottom right (the owner's
      // call — it was moved to a top-right pencil earlier, and the app bar
      // is now just the icon). endFloat keeps it clear of the bottom nav
      // pill, which floats over the content on its own.
      // As the home shell's TAB, home renders the bottom bar and it FLOATS
      // over this screen — so this Scaffold knows nothing about it and put
      // the compose button underneath it, half behind the glass and half off
      // the bottom-right corner. The padding is what lifts it clear; it is
      // the widget's own, so the button keeps its normal size and hit box.
      // Pushed as a full screen the bar is laid out below (not over) the
      // content, so there is nothing to clear.
      floatingActionButton: Padding(
        padding: EdgeInsets.only(
            bottom: widget.asTab
                ? AppBottomNavBar.overlayHeightFor(context) +
                    AppBottomNavBar.floatingGap
                : 0),
        child: FloatingActionButton(
          onPressed: () => _compose(),
          tooltip: 'New post',
          // A CIRCLE, not Material 3's rounded square. The square sat over
          // the bar's own rounded end as a white slab crowding the last two
          // pills; a circle keeps its distance from that curve and reads as
          // something hovering rather than something stuck on. (The app's one
          // radius scale exempts circles — see AppRadius.)
          shape: const CircleBorder(),
          child: const Icon(Icons.edit_outlined),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      // As the home shell's TAB, the shell renders the bar — only the ad
      // banner is this screen's own. Pushed as a full screen, it carries a
      // copy of the bar too, so the tabs stay reachable.
      bottomNavigationBar: widget.asTab
          ? const AdBannerSlot()
          : const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AdBannerSlot(),
                HomeNavBar(),
              ],
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
                                : Builder(builder: (context) {
                                    // Native ads ride between posts on this
                                    // one surface — the layout is a pure
                                    // function so tests pin where they may
                                    // sit (and where they may not).
                                    final layout = AdService.timelineWithAds(
                                        posts.length,
                                        adsEnabled:
                                            AdService.instance.nativeEnabled);
                                    return ListView.separated(
                                    controller: _scroll,
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    padding: const EdgeInsets.only(bottom: 96),
                                    itemCount: layout.length + 1,
                                    separatorBuilder: (_, __) =>
                                        const Divider(height: 1),
                                    itemBuilder: (context, i) {
                                      if (i == layout.length) {
                                        return _Footer(store: _store);
                                      }
                                      final v = layout[i];
                                      if (v < 0) {
                                        return NativeAdCard(
                                            key: ValueKey('feed-ad-${-1 - v}'));
                                      }
                                      return _Entry(
                                        post: posts[v],
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
                                  );
                                  }),
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
/// Prompts for a folder name (create or rename). Returns the trimmed name, or
/// null if cancelled/blank.
Future<String?> _promptFolderName(BuildContext context,
    {String title = 'New folder', String initial = ''}) async {
  final controller = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 40,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
            hintText: 'Folder name', counterText: ''),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save')),
      ],
    ),
  );
  controller.dispose();
  return (name == null || name.isEmpty) ? null : name;
}

/// The sheet that files [postId] into folders (with checkboxes) and makes new
/// ones. Filing into a folder also bookmarks the post.
Future<void> showBookmarkFolderPicker(
    BuildContext context, String postId) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ListenableBuilder(
        listenable: BookmarkStore.instance,
        builder: (context, _) {
          final store = BookmarkStore.instance;
          final inFolders = store.foldersFor(postId);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text('Add to folder',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final f in store.folders)
                      CheckboxListTile(
                        value: inFolders.contains(f),
                        title: Text(f),
                        subtitle: Text('${store.folderCount(f)} saved'),
                        onChanged: (v) =>
                            store.setInFolder(f, postId, v ?? false),
                      ),
                    ListTile(
                      leading: const Icon(Icons.create_new_folder_outlined),
                      title: const Text('New folder'),
                      onTap: () async {
                        final name = await _promptFolderName(context);
                        if (name == null) return;
                        await store.createFolder(name);
                        await store.setInFolder(name, postId, true);
                      },
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// Everything saved, liked or reposted, in one screen with three tabs.
///
/// Bookmarks keeps its own folders/search, unchanged. Likes and Reposts are
/// each a merge of two very different kinds of answer: the PUBLIC feed has a
/// real, durable, server-side record (`myLikedPosts()`, and this account's
/// own posts filtered to reposts) — asking again after a reinstall gets the
/// same list back. A SERVER feed is end-to-end encrypted, so there is no
/// table anywhere to ask "what has this account liked" — `FeedPost.liked`/
/// `.reposted` are the only record, held only in this device's own local
/// post cache. What shows here for a server post is exactly what this phone
/// still holds, never more — the same honest limit `BookmarksScreen`'s
/// server rows, and the profile's own Servers tab, already state.
class HistoryScreen extends StatefulWidget {
  final int initialTab;
  const HistoryScreen({super.key, this.initialTab = 0});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
      length: 3, vsync: this, initialIndex: widget.initialTab);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        bottom: TabBar(controller: _tabs, tabs: const [
          Tab(text: 'Bookmarks'),
          Tab(text: 'Likes'),
          Tab(text: 'Reposts'),
        ]),
      ),
      body: TabBarView(controller: _tabs, children: const [
        _BookmarksTab(),
        _LikesTab(),
        _RepostsTab(),
      ]),
    );
  }
}

/// The Settings → Bookmarks entry point. Unchanged route and widget type —
/// existing tests and the Settings row both still find `BookmarksScreen` —
/// it just opens the shared History screen on the Bookmarks tab.
class BookmarksScreen extends StatelessWidget {
  const BookmarksScreen({super.key});

  @override
  Widget build(BuildContext context) => const HistoryScreen(initialTab: 0);
}

/// A message with a retry button, for a tab that failed to load.
class _HistoryError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _HistoryError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 14),
              OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      );
}

/// The empty state for a History tab — same shape for all three, a
/// different icon and sentence each.
class _HistoryEmpty extends StatelessWidget {
  final IconData icon;
  final String message;
  const _HistoryEmpty({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 46, color: Colors.grey.shade400),
              const SizedBox(height: 14),
              Text(message,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.subtle(context))),
            ],
          ),
        ),
      );
}

class _BookmarksTab extends StatefulWidget {
  const _BookmarksTab();

  @override
  State<_BookmarksTab> createState() => _BookmarksTabState();
}

class _BookmarksTabState extends State<_BookmarksTab> {
  // Each item is a PublicPost (newsfeed) or a FeedPost (server feed) — the two
  // places a post can be bookmarked, shown together in one list.
  List<Object>? _items;
  String? _error;
  // Null = the "All" view; otherwise the folder being browsed.
  String? _folder;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    final ids = BookmarkStore.instance.ids;
    if (ids.isEmpty) {
      setState(() => _items = const []);
      return;
    }
    try {
      final (posts, missing) = await PublicFeedStore.instance.postsByIds(ids);
      final byId = {for (final p in posts) p.id: p};
      // Resolve each saved id from whichever feed has it — the public timeline
      // first, then the server feed. Order follows the bookmark list (newest
      // first). A saved post that BOTH feeds say is gone leaves the list rather
      // than sitting in it forever; a server post that just isn't loaded yet is
      // kept (never forgotten just because its server feed hasn't opened).
      final items = <Object>[];
      final trulyGone = <String>[];
      for (final id in ids) {
        final pub = byId[id];
        if (pub != null) {
          items.add(pub);
          continue;
        }
        final srv = FeedStore.instance.postById(id);
        if (srv != null) {
          items.add(srv);
        } else if (missing.contains(id)) {
          trulyGone.add(id);
        }
      }
      await BookmarkStore.instance.forget(trulyGone);
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _error = e is PublicFeedError ? e.reason : 'Couldn\'t load these.');
    }
  }

  // Uniform accessors so the folder/search filter works across both post types.
  String _itemId(Object it) =>
      it is PublicPost ? it.id : (it as FeedPost).id;
  bool _itemMatches(Object it, String q) {
    if (q.isEmpty) return true;
    final (text, name, handle) = it is PublicPost
        ? (it.body, it.authorName, it.authorUsername)
        : ((it as FeedPost).text, it.authorName, it.authorUsername);
    return text.toLowerCase().contains(q) ||
        name.toLowerCase().contains(q) ||
        handle.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return _error != null
        ? _HistoryError(message: _error!, onRetry: _load)
        : items == null
            ? const Center(child: CircularProgressIndicator())
            : items.isEmpty
                ? const _HistoryEmpty(
                    icon: Icons.bookmark_border,
                    message: 'Nothing saved yet. Use the ··· on a post to '
                        'bookmark it — bookmarks stay on this device.',
                  )
                : ListenableBuilder(
                    listenable: BookmarkStore.instance,
                    builder: (context, _) {
                      final store = BookmarkStore.instance;
                      // The folder may have been deleted from the picker; fall
                      // back to All rather than showing an empty ghost folder.
                      final folder = (_folder != null &&
                              store.folders.contains(_folder))
                          ? _folder
                          : null;
                      final q = _query.trim().toLowerCase();
                      // Unsaving one from in here removes the row, rather than
                      // leaving it on a screen it no longer belongs to; the
                      // folder and search narrow it further. Items are public
                      // OR server posts, so membership/search go through the
                      // type-agnostic helpers.
                      final shown = [
                        for (final it in items)
                          if (store.contains(_itemId(it)) &&
                              (folder == null ||
                                  store
                                      .foldersFor(_itemId(it))
                                      .contains(folder)) &&
                              _itemMatches(it, q))
                            it
                      ];
                      return Column(
                        children: [
                          _bookmarkHeader(context, store),
                          Expanded(
                              child: shown.isEmpty
                                  ? Center(
                                      child: Padding(
                                        padding: const EdgeInsets.all(32),
                                        child: Text(
                                          q.isNotEmpty
                                              ? 'Nothing matches "$_query".'
                                              : 'Nothing in this folder yet.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                              color: AppColors.subtle(context)),
                                        ),
                                      ),
                                    )
                                  : ListView.separated(
                                      itemCount: shown.length,
                                      separatorBuilder: (_, __) =>
                                          const Divider(height: 1),
                                      itemBuilder: (context, i) {
                                        final it = shown[i];
                                        if (it is PublicPost) {
                                          return _Entry(
                                            post: it,
                                            onReply: (t) => Navigator.of(context)
                                                .push(MaterialPageRoute(
                                                    builder: (_) =>
                                                        PublicThreadScreen(
                                                            postId: t.id))),
                                            onOpen: (t) => Navigator.of(context)
                                                .push(MaterialPageRoute(
                                                    builder: (_) =>
                                                        PublicThreadScreen(
                                                            postId: t.id))),
                                          );
                                        }
                                        return _ServerBookmarkTile(
                                            post: it as FeedPost);
                                      },
                                    ),
                            ),
                          ],
                        );
                      },
                    );
  }

  /// The search field + folder chips above the saved list.
  Widget _bookmarkHeader(BuildContext context, BookmarkStore store) {
    final folders = store.folders;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: 'Search bookmarks',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24)),
            ),
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _folderChip(context, label: 'All', selected: _folder == null,
                  onTap: () => setState(() => _folder = null)),
              for (final f in folders)
                _folderChip(context,
                    label: '$f · ${store.folderCount(f)}',
                    selected: _folder == f,
                    onTap: () => setState(() => _folder = f),
                    onLongPress: () => _manageFolder(context, store, f)),
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: const Text('New'),
                  onPressed: () async {
                    final name = await _promptFolderName(context);
                    if (name != null) await store.createFolder(name);
                  },
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _folderChip(BuildContext context,
      {required String label,
      required bool selected,
      required VoidCallback onTap,
      VoidCallback? onLongPress}) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onLongPress: onLongPress,
        child: ChoiceChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => onTap(),
        ),
      ),
    );
  }

  Future<void> _manageFolder(
      BuildContext context, BookmarkStore store, String folder) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename folder'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete folder'),
              subtitle: const Text('The saved posts stay in All'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'rename') {
      final name = await _promptFolderName(context,
          title: 'Rename folder', initial: folder);
      if (name != null) await store.renameFolder(folder, name);
      if (mounted && _folder == folder) setState(() => _folder = name);
    } else if (action == 'delete') {
      await store.deleteFolder(folder);
      if (mounted && _folder == folder) setState(() => _folder = null);
    }
  }
}

/// Everything this account has liked — the public feed's durable
/// server-backed likes, plus whatever server-feed posts this device has
/// marked liked locally. Sorted newest first.
///
/// Server-feed likes are honest about their limit: a server's feed is
/// end-to-end encrypted, so there is no table anywhere to ask "what has this
/// account liked" — the only answer this device can give is whatever is
/// sitting in its own local cache right now ([FeedStore.allPosts]), the same
/// limit the profile's own Servers tab already states.
class _LikesTab extends StatefulWidget {
  const _LikesTab();

  @override
  State<_LikesTab> createState() => _LikesTabState();
}

class _LikesTabState extends State<_LikesTab> {
  List<Object>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final public = await PublicFeedStore.instance.myLikedPosts();
      final server = [
        for (final p in FeedStore.instance.allPosts) if (p.liked) p
      ];
      final items = <Object>[...public, ...server]
        ..sort((a, b) => _timeOf(b).compareTo(_timeOf(a)));
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _error = e is PublicFeedError ? e.reason : 'Couldn\'t load these.');
    }
  }

  DateTime _timeOf(Object it) =>
      it is PublicPost ? it.createdAt : (it as FeedPost).time;

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (_error != null) return _HistoryError(message: _error!, onRetry: _load);
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) {
      return const _HistoryEmpty(
        icon: Icons.favorite_border,
        message: 'Nothing liked yet.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final it = items[i];
          if (it is PublicPost) {
            return _Entry(
              post: it,
              onReply: (t) => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PublicThreadScreen(postId: t.id))),
              onOpen: (t) => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PublicThreadScreen(postId: t.id))),
            );
          }
          return _ServerHistoryTile(post: it as FeedPost);
        },
      ),
    );
  }
}

/// Everything this account has reposted — the public feed's durable
/// reposts, plus server-feed posts marked reposted locally. Same honest
/// server-feed limit as [_LikesTab]: only what this device currently holds.
class _RepostsTab extends StatefulWidget {
  const _RepostsTab();

  @override
  State<_RepostsTab> createState() => _RepostsTabState();
}

class _RepostsTabState extends State<_RepostsTab> {
  List<Object>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final me = AppState.profile.value.username;
      final mine = me.isEmpty
          ? const <PublicPost>[]
          : await PublicFeedStore.instance.postsBy(me);
      final public = PublicFeedStore.profileTab(mine, ProfileTab.reposts);
      final server = [
        for (final p in FeedStore.instance.allPosts) if (p.reposted) p
      ];
      final items = <Object>[...public, ...server]
        ..sort((a, b) => _timeOf(b).compareTo(_timeOf(a)));
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _error = e is PublicFeedError ? e.reason : 'Couldn\'t load these.');
    }
  }

  DateTime _timeOf(Object it) =>
      it is PublicPost ? it.createdAt : (it as FeedPost).time;

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (_error != null) return _HistoryError(message: _error!, onRetry: _load);
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) {
      return const _HistoryEmpty(
        icon: Icons.repeat,
        message: 'Nothing reposted yet.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final it = items[i];
          if (it is PublicPost) {
            return _Entry(
              post: it,
              onReply: (t) => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PublicThreadScreen(postId: t.id))),
              onOpen: (t) => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PublicThreadScreen(postId: t.id))),
            );
          }
          return _ServerHistoryTile(post: it as FeedPost);
        },
      ),
    );
  }
}

/// A server-feed post shown in Likes/Reposts — read-only, unlike
/// [_ServerBookmarkTile]: a liked or reposted post isn't necessarily
/// bookmarked, so there's no folder/remove menu to offer here.
class _ServerHistoryTile extends StatelessWidget {
  final FeedPost post;
  const _ServerHistoryTile({required this.post});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final who = post.authorName.trim().isEmpty
        ? '@${post.authorUsername}'
        : post.authorName;
    final snippet = post.text.trim();
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.secondaryContainer,
        child: Icon(Icons.forum_outlined,
            size: 18, color: scheme.onSecondaryContainer),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(who,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('Server',
                style: TextStyle(
                    fontSize: 10.5, color: AppColors.subtle(context))),
          ),
        ],
      ),
      subtitle: Text(snippet.isEmpty ? 'Server post' : snippet,
          maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => FeedPostScreen(postId: post.id)),
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
  /// key, so there is no such thing as seeing a stranger's server posts. So
  /// is Likes: the likes table shows nobody's rows but your own, and what
  /// somebody else liked is their business.
  List<ProfileTab> get _tabs => [
        for (final t in ProfileTab.values)
          if ((t != ProfileTab.servers && t != ProfileTab.likes) || _isMe) t
      ];

  /// The own-profile Likes tab's content, loaded on first open. Null while
  /// never loaded; empty when loaded and there is nothing.
  List<PublicPost>? _liked;
  bool _loadingLiked = false;

  Future<void> _loadLiked() async {
    if (_loadingLiked) return;
    setState(() => _loadingLiked = true);
    try {
      final liked = await PublicFeedStore.instance.myLikedPosts();
      if (!mounted) return;
      setState(() {
        _liked = liked;
        _loadingLiked = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingLiked = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// (followers, following) from the server graph; null until it answers,
  /// and stays null when it can't — shown as absence, never as zero.
  (int, int)? _followCounts;

  /// Whether this device followed [widget.username] at the moment
  /// [_followCounts] was fetched — the baseline the header's live ±1 delta
  /// compares against (see _Header.followedAtFetch).
  bool _followedAtFetch = false;

  Future<void> _load() async {
    setState(() => _error = null);
    // Alongside the posts, not after them — the header shouldn't wait.
    PublicFeedStore.instance.followCounts(widget.username).then((c) {
      if (mounted && c != null) {
        setState(() {
          _followCounts = c;
          _followedAtFetch =
              FollowStore.instance.isFollowing(widget.username);
        });
      }
      // On your OWN profile, seed the follow store with the server's count so
      // the sidebar and every other device show the same number, not this
      // device's local set size.
      if (c != null && _isMe) FollowStore.instance.noteServerFollowing(c.$2);
    });
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
                  // Name over post count, X's app bar. The count is worth
                  // repeating here precisely because this bar is what is
                  // left once the header has scrolled away.
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(fontWeight: FontWeight.w700)),
                      // Absent, not "0 posts", until the count is known —
                      // the same rule the stat itself follows.
                      if (posts != null)
                        Text(
                          '${posts.length} '
                          '${posts.length == 1 ? 'post' : 'posts'}',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w400,
                              color: AppColors.subtle(context)),
                        ),
                    ],
                  ),
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
                  followCounts: _followCounts,
                  followedAtFetch: _followedAtFetch,
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
                    onPick: (i) {
                      setState(() => _tab = _tabs[i]);
                      if (_tab == ProfileTab.likes && _liked == null) {
                        _loadLiked();
                      }
                    },
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
              // Own likes come from their own fetch, not this person's posts.
              else if (_tab == ProfileTab.likes)
                _likedPosts(context)
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

  /// The posts you liked — your own likes are the only ones the server
  /// lets anyone read, and the only ones a profile should show.
  Widget _likedPosts(BuildContext context) {
    final liked = _liked;
    if (liked == null) {
      // Never loaded (e.g. the tab restored mid-session): kick it off.
      if (!_loadingLiked) _loadLiked();
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (liked.isEmpty) {
      return SliverToBoxAdapter(
        child: _profileMessage(
            'Nothing liked yet. Posts you like on the newsfeed collect '
            'here — only you can see this tab.'),
      );
    }
    return SliverList.separated(
      itemCount: liked.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) => _Entry(
        post: liked[i],
        onReply: (target) => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PublicThreadScreen(postId: target.id))),
        onOpen: (target) => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PublicThreadScreen(postId: target.id))),
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
      ProfileTab.reposts when _isMe => (
          Icons.repeat,
          'Nothing reposted yet',
          'Posts you pass along show up here.',
        ),
      ProfileTab.reposts => (
          Icons.repeat,
          'No reposts yet',
          'When this account passes a post along, it appears here.',
        ),
      // Handled above; a switch over an enum has to be complete.
      ProfileTab.likes => (Icons.favorite_border, '', ''),
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
/// The X header: a band across the top, the face hanging over its bottom-left
/// corner, and the buttons on the line below.
///
/// **This reverses the 2026-08-09 removal of the banner, at the owner's
/// direction (2026-08-14) — do not "restore" the flat row.** The objection
/// then was real and is answered rather than ignored: what was removed was a
/// GENERATED gradient mixed from the handle, a saturated colour nobody chose,
/// in an app whose identity is black and white. The band here is the
/// scaffold's own surface tint by default; a colour appears only when the
/// person actually picked one in Edit profile, and then it is theirs.
///
/// The other half of that objection — that the banner pushed the name, the
/// bio and the counts below the fold — turned out to cost three points, not
/// seventy, because the action buttons moved INSIDE the header instead of
/// taking a row of their own. `type_metrics_test.dart` measures it.
class _AvatarRow extends StatelessWidget {
  final String username;
  final String displayName;
  final bool isMe;

  const _AvatarRow(
      {required this.username, required this.displayName, required this.isMe});

  /// X's proportions: a big face, half of it below the band.
  static const double _avatarRadius = 40;

  /// Short for a banner — X's is nearer 1:3 — because the fold is still a
  /// budget and the name matters more than the decoration. It came down from
  /// 84 when sizing the strip honestly (below) pushed the tab bar one point
  /// past its own guard: the band is the part of this that decorates, so the
  /// band is the part that pays.
  static const double _bandHeight = 68;

  /// How much of the avatar hangs below the band.
  static const double _overhang = 30;

  /// A real tap target for the buttons beside the overhang.
  static const double _actionsHeight = 48;

  /// Between the band and the buttons.
  static const double _actionsGap = 6;

  /// The strip is as tall as the tallest thing standing in it, which is the
  /// BUTTONS — not the overhang, which is shorter than a tap target and was
  /// the first guess. Sizing it to the overhang left the button's own centre
  /// exactly on the box's bottom edge, and a `Stack` child hanging past its
  /// parent still DRAWS under `Clip.none` while refusing to hit test: the
  /// button was visible and dead, which an unrelated Settings test caught by
  /// tapping it. The avatar's ring overhung for the same reason, painting
  /// over the display name under it.
  static double get _height => _bandHeight + _actionsGap + _actionsHeight;

  /// The ring's own stroke, kept as a name because the avatar's real bottom
  /// edge is the radius plus this on each side.
  static const double _ringWidth = 3.5;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final known = knownUserFor(username);
    final bannerHex = known?.bannerColor ?? '';
    final initial =
        (displayName.isEmpty ? '?' : displayName.replaceFirst('@', ''))
            .substring(0, 1)
            .toUpperCase();
    // Tapping your own face to change it is where people look first, and it
    // costs nothing to put the door there as well as on the button.
    // Somebody else's avatar is not a control.
    final avatar = GestureDetector(
      onTap: isMe
          ? () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EditProfileScreen()))
          : null,
      child: known != null
          ? UserAvatar(user: known, radius: _avatarRadius)
          : CircleAvatar(
              radius: _avatarRadius,
              backgroundColor: scheme.surfaceContainerHighest,
              child: Text(initial,
                  style: const TextStyle(
                      fontSize: 30, fontWeight: FontWeight.w700)),
            ),
    );
    // Picked → their two colours. Not picked → the surface tint, which is
    // what keeps this from being the saturated block that was removed.
    final Gradient band = bannerHex.isEmpty
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.surfaceContainerHighest,
              scheme.surfaceContainerHigh,
            ],
          )
        : LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              UserAvatar.parseHex(bannerHex),
              UserAvatar.parseHex((known?.avatarColor2.isNotEmpty ?? false)
                  ? known!.avatarColor2
                  : bannerHex),
            ],
          );
    return SizedBox(
      height: _height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Edge to edge, no rounding: X's band runs the full width, and a
          // rounded card floating inside a margin reads as a widget on the
          // page rather than the top of it.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Container(
                key: const ValueKey('profileBand'),
                height: _bandHeight,
                decoration: BoxDecoration(gradient: band)),
          ),
          Positioned(
            left: 16,
            top: _bandHeight - _avatarRadius * 2 + _overhang,
            // Ringed in the page's own colour so the face reads as placed ON
            // the page, not pasted on the band — and so it still reads when
            // the band behind it is dark.
            child: Container(
              key: const ValueKey('profileAvatarRing'),
              padding: const EdgeInsets.all(_ringWidth),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                shape: BoxShape.circle,
              ),
              child: avatar,
            ),
          ),
          // The buttons take the free width beside the overhang, level with
          // it — X's Edit profile / Follow sits exactly here.
          //
          // BOTH edges are given, not just `right`. A `Positioned` with one
          // horizontal edge is handed UNBOUNDED width, and `_ProfileActions`
          // is a `Wrap` — which never wraps when it is allowed to be as wide
          // as it likes, so a creator carrying Message + Follow + Subscribe +
          // Spark + Tip would have run off the screen instead of dropping a
          // line. `left` starts clear of the avatar's ring.
          Positioned(
            left: 16 + (_avatarRadius + _ringWidth) * 2 + 8,
            right: 12,
            top: _bandHeight + _actionsGap,
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

/// How somebody is verified — phone, email, ID — as chips.
///
/// The join DATE is the sibling fact and belongs on the metadata row beside
/// the location and the link (X's shape), so this widget owns the question
/// through [joinedFor] and [joinedLabel] but does not draw it. One place
/// decides who is allowed to know; one place decides how it reads.
///
/// **Only ever what this device can honestly answer.** These facts ride the
/// sealed profile share, which means a CONTACT carries them and a stranger
/// resolved from the username directory does not: the directory has no
/// column for any of it. So a stranger's profile shows this section not at
/// all, rather than three grey "not verified" chips that would read as a
/// finding about them when they are really a finding about us. Same rule
/// [knownBusinessSeller] follows in the marketplace.
///
/// On your OWN profile it reads from [AccountVerification] instead, which
/// already owns all three answers for this account — no round trip, and no
/// second copy of the logic.
class ProfileTrust extends StatelessWidget {
  const ProfileTrust({super.key, required this.user, required this.isMe});

  final AppUser? user;
  final bool isMe;

  /// When they joined, or null when this device cannot honestly say — which
  /// is every stranger, and every account from before the field existed.
  static DateTime? joinedFor({required AppUser? user, required bool isMe}) =>
      user?.joinedAt;

  /// A month and a year, never a day. "Joined August 2026" is what a
  /// profile is for; the exact date is a fact about somebody that nothing
  /// on this screen needs.
  static String joinedLabel(DateTime at) =>
      'Joined ${DateFormat('MMMM yyyy').format(at)}';

  @override
  Widget build(BuildContext context) {
    final u = user;
    final bool phone;
    final bool email;
    final bool id;
    if (isMe) {
      phone = AccountVerification.phoneVerified;
      email = AccountVerification.emailVerified;
      id = AccountVerification.idVerified;
    } else if (u != null) {
      phone = u.phoneVerified;
      email = u.emailVerified;
      id = u.verified;
    } else {
      return const SizedBox.shrink();
    }
    final chips = [
      if (phone) 'Phone',
      if (email) 'Email',
      if (id) 'ID',
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 11),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [for (final c in chips) _TrustChip(label: c)],
      ),
    );
  }
}

/// One item on the profile's metadata row — an icon and a few words, sized
/// to its own content so several share a line.
class _MetaItem extends StatelessWidget {
  const _MetaItem(
      {required this.icon, required this.label, this.color, this.onTap});

  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? AppColors.subtle(context);
    return InkWell(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: tint),
          const SizedBox(width: 4),
          // Bounded so one very long link cannot push the row wider than the
          // screen — a Wrap gives its children unbounded width, so a bare
          // Text here would overflow rather than ellipsize.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, color: tint)),
          ),
        ],
      ),
    );
  }
}

/// One "Phone verified" / "Email verified" / "ID verified" chip.
///
/// Only ever drawn for something that IS verified. An unverified chip would
/// be an accusation on a profile, and — since a stranger's flags simply are
/// not known here — very often a wrong one.
class _TrustChip extends StatelessWidget {
  const _TrustChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF12B76A).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle,
                size: 13, color: Color(0xFF12B76A)),
            const SizedBox(width: 4),
            Text('$label verified',
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF12B76A))),
          ],
        ),
      );
}

class _Header extends StatelessWidget {
  final String username;
  final String displayName;
  final bool verified;
  final AppUser? known;
  final bool isMe;
  final int? postCount;

  /// (followers, following) from the server graph; null when it hasn't
  /// answered (or can't), which renders as absence rather than zero.
  final (int, int)? followCounts;

  /// Whether THIS device was following [username] when [followCounts] was
  /// fetched. The Follow button toggles the local store instantly, but the
  /// fetched follower number is a snapshot — comparing the live state against
  /// this lets the stat move with the button (+1/-1) with no timer and no
  /// race; the next real fetch replaces both.
  final bool followedAtFetch;

  const _Header({
    required this.username,
    required this.displayName,
    required this.verified,
    required this.known,
    required this.isMe,
    required this.postCount,
    required this.followCounts,
    required this.followedAtFetch,
  });

  /// Who follows them / who they follow — the X-shaped tabbed screen
  /// (avatar, name, handle, Follow button per row), replacing the old bare
  /// bottom sheet of names.
  void _openFollowList(BuildContext context, {required bool followers}) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => FollowListScreen(
              username: username,
              displayName: displayName,
              showFollowers: followers,
            )));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final about = known?.about ?? '';
    final pronouns = known?.pronouns ?? '';
    final link = known?.link ?? '';
    final location = known?.location.trim() ?? '';
    // One margin and one rhythm. Every block below is 16 from the edge and 17
    // from the one above it — the gaps used to run 3, 8, 10, 12, 14 and 16
    // down a single column, which is what makes a screen look unfinished even
    // when nothing on it is wrong. Widened from 14 (2026-08-13, the owner's
    // "too compact" report) — a bio and four stat counts are the whole
    // identity of the screen and were sitting closer together than the posts
    // below them. Kept modest on purpose: `type_metrics_test.dart`'s "a
    // profile spends its first screen on the person" pins the tab strip
    // under 520pt so the header can never again eat the fold the way the
    // old banner did — the first, wider pass (18/16/16/10) measured 537 and
    // failed it.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 8),
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
          if (known?.isBusiness ?? false) ...[
            const SizedBox(height: 11),
            Row(
              children: [
                Icon(Icons.storefront_outlined,
                    size: 15, color: AppColors.subtle(context)),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    [
                      known!.businessCategory.trim().isEmpty
                          ? 'Business'
                          : known!.businessCategory.trim(),
                      if (known!.businessHours.trim().isNotEmpty)
                        known!.businessHours.trim(),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.subtle(context)),
                  ),
                ),
              ],
            ),
            SellerShopButton(
                username: known!.username, sellerName: known!.name),
          ],
          if (about.isNotEmpty) ...[
            const SizedBox(height: 17),
            Text(about, style: const TextStyle(fontSize: 15, height: 1.45)),
          ],
          // ONE wrapped row of metadata, X's shape — where you are, your
          // link and when you joined sit together and flow onto a second
          // line only when they have to. They used to be three stacked
          // rows, each spending a whole line on a handful of words, which
          // is what pushed the counts down the page.
          Builder(builder: (context) {
            final joined = ProfileTrust.joinedFor(user: known, isMe: isMe);
            final items = <Widget>[
              if (location.isNotEmpty)
                _MetaItem(icon: Icons.place_outlined, label: location),
              if (link.isNotEmpty)
                _MetaItem(
                  icon: Icons.link,
                  label: link,
                  color: scheme.primary,
                  onTap: () => InAppWebScreen.open(context, link),
                ),
              if (joined != null)
                _MetaItem(
                    icon: Icons.calendar_month_outlined,
                    label: ProfileTrust.joinedLabel(joined)),
            ];
            if (items.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 11),
              child: Wrap(spacing: 14, runSpacing: 6, children: items),
            );
          }),
          ProfileTrust(user: known, isMe: isMe),
          const SizedBox(height: 17),
          // ONE row of counts. There were two — "1 post 0 following" above a
          // second row repeating Following beside Servers and Okay Score —
          // which is the sort of thing that makes somebody check whether the
          // two numbers disagree.
          ListenableBuilder(
            listenable: Listenable.merge(
                [FollowStore.instance, CommunityStore.instance]),
            builder: (context, _) => Wrap(
              // Spacing stays 20/10 (unwidened) on purpose: pushing it any
              // further is what tipped four stats from one line to two on a
              // 390-point phone, which cost the header a whole extra line —
              // the exact regression `type_metrics_test.dart` exists to
              // catch, and did.
              spacing: 20,
              runSpacing: 10,
              children: [
                // X's order: what you chose (Following) before what chose
                // you (Followers), and the post count last — it is also in
                // the app bar once the header scrolls away, which is where
                // X keeps it.
                // Your OWN following count comes from the SERVER graph (via
                // followingCountDisplay), falling back to the local list only
                // until the server answers — so the profile, the sidebar, and
                // every device you sign in on all show the same number. It used
                // to read the local set's size, which differs per device.
                // Other people's profiles use the server graph directly.
                ProfileStat(
                    value: isMe
                        ? '${FollowStore.instance.followingCountDisplay}'
                        : (followCounts != null ? '${followCounts!.$2}' : '—'),
                    label: 'Following',
                    // Both stats open the X-shaped tabbed list now — your own
                    // too (PeopleScreen still exists behind People elsewhere).
                    onTap: (isMe || followCounts != null)
                        ? () => _openFollowList(context, followers: false)
                        : null),
                // Real numbers for EVERYBODY, from the server graph (the
                // owner's call, 2026-08-05). Absent — not zero — until the
                // server answers; on your own profile the following count
                // falls back to the local list, which is never wrong about
                // your own follows.
                // The follower number is the fetched snapshot PLUS your own
                // live delta — tapping Follow/Unfollow used to leave it stale
                // until the profile was reopened, which read as "doesn't
                // update". The delta compares the store's live state against
                // what it was when the snapshot was fetched, so it can only
                // ever move the number by your own ±1.
                Builder(builder: (context) {
                  int? followers = followCounts?.$1;
                  if (followers != null && !isMe) {
                    final now = FollowStore.instance.isFollowing(username);
                    if (now && !followedAtFetch) followers += 1;
                    if (!now && followedAtFetch) {
                      followers = (followers - 1).clamp(0, 1 << 30);
                    }
                  }
                  return ProfileStat(
                      value: followers == null ? '—' : '$followers',
                      label: followers == 1 ? 'Follower' : 'Followers',
                      onTap: followCounts == null
                          ? null
                          : () => _openFollowList(context, followers: true));
                }),
                ProfileStat(
                    value: postCount == null ? '—' : '$postCount',
                    label: postCount == 1 ? 'Post' : 'Posts',
                    onTap: null),
                if (isMe)
                  ProfileStat(
                      value: '${CommunityStore.instance.communities.length}',
                      label: 'Servers',
                      onTap: null),
              ],
            ),
          ),
          // Okay Score used to be the fourth count. Four do not fit a 390pt
          // phone, so the row broke three-and-one, which reads as a mistake
          // rather than a layout. It is also the only one of the four that is
          // a whole screen of its own, so a row with somewhere to go suits it
          // better than a number in a huddle.
          if (isMe) ...[
            const SizedBox(height: 17),
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
      listenable: Listenable.merge(
          [FollowStore.instance, CreatorSubStore.instance]),
      builder: (context, _) {
        final following = FollowStore.instance.isFollowing(username);
        void toggle() {
          if (postNeedsPhone(context, what: 'Following')) return;
          FollowStore.instance.toggle(username);
        }
        // Two buttons share the space one had, so both stay VISUALLY dense
        // (no extra Material touch padding) — the default density overflowed
        // a 390-point phone beside the avatar. But dense used to also mean
        // SMALL: a 36pt-tall button with 14pt of side padding, which is what
        // made Message/Follow/Spark/Tip read as an afterthought row rather
        // than the primary actions on the screen. Taller (44, level with a
        // normal Material button) and wider (18) still fits two side by side
        // on a 390-point phone — widened 2026-08-13, "too small" report.
        final dense = OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          minimumSize: const Size(0, 44),
        );
        final text = Text(following ? 'Following' : 'Follow',
            maxLines: 1, overflow: TextOverflow.ellipsis);
        // A Subscribe button when this is a creator this device knows offers
        // subscriptions (a contact carries the flag on the sealed profile
        // share). A stranger's locked post still offers it on the card itself.
        final creator = knownUserFor(username);
        final subscribable = creator?.subscribable ?? false;
        final subscribed = CreatorSubStore.instance.active(username);
        // A WRAP, not three forced-separate rows. A plain contact only ever
        // shows Message+Follow and this changes nothing for them, but a
        // creator with a Lightning address, a phone number AND
        // subscriptions on used to be handed three stacked rows (5 buttons
        // tall) no matter how much width a 390pt phone actually had spare —
        // which is what "too many buttons" (2026-08-13, the SAME report
        // that asked for these bigger, now reads as "too many, too tall")
        // actually meant: buttons that could sit beside each other were
        // forced onto their own line regardless. A Wrap packs what fits and
        // only drops to a new line when it has to; `WrapAlignment.end`
        // keeps every line right-aligned under the avatar, matching how a
        // single row already sat.
        final buttons = <Widget>[
          // The pair every social profile has: talk to them, or keep up
          // with them. Message rides the same resolution the marketplace
          // uses — an existing chat first, then the directory.
          OutlinedButton(
            style: dense,
            onPressed: () => openSellerChat(context,
                username: username,
                name: knownUserFor(username)?.name ?? username,
                // This is an ordinary profile, not a listing or a seller —
                // marketplace: false keeps the resulting chat out of the
                // Marketplace section, which it used to land in by default.
                marketplace: false),
            child: const Text('Message',
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          following
              ? OutlinedButton(style: dense, onPressed: toggle, child: text)
              : FilledButton(style: dense, onPressed: toggle, child: text),
          if (subscribable)
            subscribed
                ? OutlinedButton.icon(
                    style: dense,
                    onPressed: null,
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Subscribed'),
                  )
                : FilledButton.icon(
                    // Same size as Message/Follow/Spark/Tip, not its own
                    // smaller copy — a Subscribe button sitting right below
                    // them at the old 36pt height read as a demotion.
                    style: dense,
                    onPressed: () => showSubscribeSheet(
                      context,
                      handle: username,
                      name: creator?.name ?? '@$username',
                      tiers: creator?.subscriptionTiers ?? const [],
                    ),
                    icon: const Icon(Icons.workspace_premium, size: 16),
                    label: Text(
                        '${(creator?.subscriptionTiers.length ?? 0) > 1 ? "Subscribe from" : "Subscribe ·"} '
                        '\$${((creator?.subscriptionCents ?? 0) / 100).toStringAsFixed(2)} · 30 days',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
          // Sparks and tips live on the PROFILE and in a chat — never on a
          // post. Money given to a PERSON is different from money pinned to
          // one piece of content, which is what Apple made Damus strip out.
          // Two SEPARATE buttons, not a rail-picker: a Spark is bitcoin
          // over Lightning, a Tip is real money over Stripe, and conflating
          // them under one "Spark" label was the confusion this split
          // fixed (2026-08-13) — the Wrap above does NOT undo that; it only
          // changes whether they sit beside or below Message/Follow. Each
          // offers only what this device can really do: Spark needs a
          // published Lightning address, Tip needs a contact we hold a
          // phone number for.
          if (canSpark(creator))
            OutlinedButton.icon(
              style: dense,
              onPressed: () => offerSpark(
                context,
                user: creator!,
                fallbackLabel: '@$username',
              ),
              icon: const Icon(Icons.bolt, size: 16),
              label: const Text('Spark'),
            ),
          if (canTip(creator))
            OutlinedButton.icon(
              style: dense,
              onPressed: () => offerTip(
                context,
                user: creator!,
                fallbackLabel: '@$username',
              ),
              icon: const Icon(Icons.attach_money, size: 16),
              label: const Text('Tip'),
            ),
        ];
        return Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: buttons,
        );
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

/// A bookmarked SERVER-feed post in the Bookmarks list. Server posts are a
/// different model (FeedPost) living in a community, so they render as a compact
/// row here — author, a snippet, a "Server" tag — rather than the full public
/// tile, and tap through to the post in its server feed.
class _ServerBookmarkTile extends StatelessWidget {
  final FeedPost post;
  const _ServerBookmarkTile({required this.post});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final who = post.authorName.trim().isEmpty
        ? '@${post.authorUsername}'
        : post.authorName;
    final snippet = post.text.trim();
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.secondaryContainer,
        child: Icon(Icons.forum_outlined,
            size: 18, color: scheme.onSecondaryContainer),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(who,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('Server',
                style: TextStyle(
                    fontSize: 10.5, color: AppColors.subtle(context))),
          ),
        ],
      ),
      subtitle: Text(snippet.isEmpty ? 'Server post' : snippet,
          maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'folder') {
            showBookmarkFolderPicker(context, post.id);
          } else if (v == 'remove') {
            BookmarkStore.instance.toggle(post.id);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'folder', child: Text('Add to folder')),
          PopupMenuItem(value: 'remove', child: Text('Remove bookmark')),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => FeedPostScreen(postId: post.id)),
      ),
    );
  }
}

/// The locked card under a subscribers-only post: a teaser (above, as the body)
/// then the price and a Subscribe button. If this device is the author, or
/// already holds an active pass, it quietly fetches the full text instead —
/// the server is the one that decides whether the body is served.
class _PaidLock extends StatefulWidget {
  final PublicPost post;
  const _PaidLock({required this.post});

  @override
  State<_PaidLock> createState() => _PaidLockState();
}

class _PaidLockState extends State<_PaidLock> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Entitled already? Reveal it without a tap. `mine` covers the author,
    // and the store's RPC re-checks entitlement server-side regardless of what
    // this local flag says.
    final p = widget.post;
    if (p.mine || CreatorSubStore.instance.active(p.authorUsername)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        PublicFeedStore.instance.unlock(p.id);
      });
    }
  }

  Future<void> _subscribe() async {
    final p = widget.post;
    setState(() => _busy = true);
    // The full tier list only reaches us for a creator this device knows
    // (their sealed profile share carries it). A stranger's locked card falls
    // back to the single price denormalised on the post.
    final creator = knownUserFor(p.authorUsername);
    final tiers = (creator != null && creator.subscriptionTiers.isNotEmpty)
        ? creator.subscriptionTiers
        : [SubscriptionTier(name: 'Subscriber', cents: p.subCents)];
    final ok = await showSubscribeSheet(
      context,
      handle: p.authorUsername,
      name: p.authorName.isEmpty ? '@${p.authorUsername}' : p.authorName,
      tiers: tiers,
    );
    if (ok && mounted) await PublicFeedStore.instance.unlock(p.id);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = widget.post;
    final price = p.subCents > 0
        // "30 days", not "/mo": a creator sub is a consumable pass, not an
        // auto-renewing subscription — see StorePurchases.creatorSubProductId.
        ? '\$${(p.subCents / 100).toStringAsFixed(2)} · 30 days'
        : '';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_outline, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Text('Subscribers-only post',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, color: scheme.primary)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            p.mine
                ? 'Only your subscribers can read this.'
                : 'Subscribe to ${p.authorName.isEmpty ? '@${p.authorUsername}' : p.authorName} to read it.',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
          if (!p.mine) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _busy ? null : _subscribe,
              icon: const Icon(Icons.workspace_premium, size: 18),
              label:
                  Text(price.isEmpty ? 'Subscribe' : 'Subscribe · $price'),
            ),
          ],
        ],
      ),
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
                    edited: post.edited,
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
                  // post below carries the content. For a paid post this is the
                  // teaser until unlocked, then the full text.
                  if (post.displayBody.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    FeedBodyText(
                      text: post.displayBody,
                      collapse: collapseLongBody,
                      focused: focused,
                      onTag: (t) =>
                          PublicFeedStore.instance.setTag(t.substring(1)),
                      onMention: (u) => openPublicProfile(context, u),
                    ),
                  ],
                  if (post.locked) ...[
                    const SizedBox(height: 8),
                    _PaidLock(post: post),
                  ],
                  // A community note that reached consensus shows inline on the
                  // opened post. Fetched lazily and only when focused, so the
                  // timeline never fans out a request per card.
                  if (focused && !post.locked)
                    CommunityNoteInline(post: post),
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
                    sparkCount: post.sparkCount,
                    sparkCents: post.sparkCents,
                    sparked: PublicFeedStore.instance.sparkedByMe(post.id),
                    // Sparks moved OFF posts (2026-08-09): tipping is
                    // person-to-person, offered on a profile and in a chat.
                    // Money pinned to one post is a payment for digital
                    // content — the shape Apple made Damus remove. The tally
                    // above still shows what a post was sparked before.
                    onSpark: null,
                    onReply: onReply,
                    // A repeat is two different intentions — pass it on as it
                    // is, or pass it on with something to say — so it asks
                    // which rather than picking one.
                    onRepost: () => _repostMenu(context),
                    onLike: () {
                      if (postNeedsPhone(context, what: 'Liking')) return;
                      PublicFeedStore.instance.toggleLike(post.id);
                    },
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
    if (postNeedsPhone(context, what: 'Reposting')) return;
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
              // Community notes: readers add context / fact-checks, and rate
              // each other's. A note enough readers find helpful shows on the
              // post.
              ListTile(
                leading: const Icon(Icons.fact_check_outlined),
                title: const Text('Community notes'),
                subtitle: const Text('Add context, or rate what readers wrote'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => CommunityNotesScreen(post: post),
                  ));
                },
              ),
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
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('Add to folder'),
                subtitle: const Text('Organize your bookmarks'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  showBookmarkFolderPicker(context, post.id);
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
              // Moderators and admins can remove ANY post — the server
              // re-checks the rank and that the author is outranked, so
              // this row is only ever a request. Drawn above Delete so an
              // admin's own post shows the plain delete, not this.
              if (!post.mine && PlatformModeration.instance.canModerate)
                ListTile(
                  leading:
                      const Icon(Icons.gavel_outlined, color: Colors.red),
                  title: const Text('Remove post (moderation)',
                      style: TextStyle(color: Colors.red)),
                  subtitle: const Text(
                      'Deletes it for everyone and logs the action'),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    final ok = await PlatformModeration.instance
                        .takedownPublicPost(post.id);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(ok
                            ? 'Post removed.'
                            : 'The server refused the takedown.')));
                    if (ok) {
                      await PublicFeedStore.instance.load();
                    }
                  },
                ),
              // Editing your own post, but only for a few minutes after
              // posting — the public feed is otherwise append-only so a post
              // people have acted on can't be quietly rewritten.
              if (PublicFeedStore.instance.canEdit(post))
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Edit post'),
                  subtitle: const Text(
                      'For a few minutes after posting; the edit is marked'),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await _editPost(context, post);
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

  /// Edit dialog for an own public post: prefilled with the current text, saved
  /// through PublicFeedStore.editPost (which re-screens it and stamps it).
  Future<void> _editPost(BuildContext context, PublicPost post) async {
    final controller = TextEditingController(text: post.body);
    final messenger = ScaffoldMessenger.of(context);
    final newText = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit post'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 6,
          minLines: 3,
          maxLength: PublicFeedStore.maxLength,
          decoration: const InputDecoration(hintText: 'Say something'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newText == null) return;
    try {
      await PublicFeedStore.instance.editPost(post.id, newText);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

/// One post and its replies.
///
/// Public because a profile links to it: your own posts are listed on the
/// profile the app already had, and tapping one has to land somewhere.
class PublicThreadScreen extends StatefulWidget {
  final String postId;
  const PublicThreadScreen({super.key, required this.postId});

  @override
  State<PublicThreadScreen> createState() => _PublicThreadScreenState();
}

class _PublicThreadScreenState extends State<PublicThreadScreen> {
  /// The thread fetched from the server when the loaded timeline doesn't
  /// hold this post — a profile reaches months back, the timeline holds
  /// pages. A local miss is "not loaded here", NOT "deleted"; this screen
  /// used to say "removed" on that miss, which called somebody's perfectly
  /// alive post deleted.
  ({
    PublicPost root,
    List<PublicPost> replies,
    List<PublicPost> ancestors
  })? _fetched;
  bool _resolving = false;

  /// True only when the SERVER said the post does not exist — the one
  /// case "This post was removed" is allowed to mean.
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    // Opening the post IS the view being counted — once per post per app
    // run, and nothing about the viewer travels with it.
    PublicFeedStore.instance.notePostViewed(widget.postId);
    if (PublicFeedStore.instance.byId(widget.postId) == null) _resolve();
  }

  Future<void> _resolve() async {
    setState(() => _resolving = true);
    try {
      final thread =
          await PublicFeedStore.instance.fetchThread(widget.postId);
      if (!mounted) return;
      setState(() {
        _fetched = thread;
        _gone = thread == null;
        _resolving = false;
      });
    } catch (_) {
      // Offline or a server error is not proof of deletion.
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final postId = widget.postId;
    return Scaffold(
      appBar: AppBar(title: const Text('Post')),
      body: ListenableBuilder(
        listenable: PublicFeedStore.instance,
        builder: (context, _) {
          final local = PublicFeedStore.instance.byId(postId);
          final post = local ?? _fetched?.root;
          if (post == null) {
            if (_resolving) {
              return const Center(child: CircularProgressIndicator());
            }
            if (_gone) {
              return const Center(child: Text('This post was removed.'));
            }
            // Neither loaded nor disproven — likely offline. Honest, with
            // a way to try again.
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Couldn\'t load this post.'),
                  const SizedBox(height: 10),
                  OutlinedButton(
                      onPressed: _resolve, child: const Text('Try again')),
                ],
              ),
            );
          }
          final replies = local != null
              ? PublicFeedStore.instance.repliesTo(postId)
              : _fetched!.replies;
          final ancestors = local != null
              ? PublicFeedStore.instance.ancestorsOf(postId)
              : _fetched!.ancestors;
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
              // Who's behind the numbers — only when there are numbers.
              // A roomy band of full figures, not a crammed line of
              // abbreviations: each count sits in its own block with its
              // word under it. Likes and reposts open the people behind
              // them; views stay plain, because a view count has no names
              // behind it, on purpose.
              if (post.viewCount > 0 ||
                  post.likeCount > 0 ||
                  post.repostCount > 0) ...[
                const Divider(height: 1),
                Builder(builder: (context) {
                  final mine = post.authorUsername ==
                      AppState.profile.value.username;
                  void openSheet() => showModalBottomSheet<void>(
                        context: context,
                        showDragHandle: true,
                        isScrollControlled: true,
                        builder: (_) =>
                            _EngagementSheet(post: post, isMine: mine),
                      );
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Row(
                      children: [
                        if (post.viewCount > 0)
                          FeedStatBlock(
                            value: thousands(post.viewCount),
                            label: post.viewCount == 1 ? 'View' : 'Views',
                            // Tappable on your OWN post: it opens the sheet to a
                            // "Viewed by" list. On someone else's it just shows
                            // the number — who viewed a post is the author's to
                            // see, not the crowd's.
                            onTap: post.authorUsername ==
                                    AppState.profile.value.username
                                ? openSheet
                                : null,
                          ),
                        if (post.likeCount > 0)
                          FeedStatBlock(
                            value: thousands(post.likeCount),
                            label: post.likeCount == 1 ? 'Like' : 'Likes',
                            onTap: openSheet,
                          ),
                        if (post.repostCount > 0)
                          FeedStatBlock(
                            value: thousands(post.repostCount),
                            label:
                                post.repostCount == 1 ? 'Repost' : 'Reposts',
                            onTap: openSheet,
                          ),
                      ],
                    ),
                  );
                }),
              ],
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
                // Same gate as the composer's GIF button: the column may
                // not exist on the server yet.
                gifEnabled: PublicFeedStore.instance.mediaSupported,
                onSend: (text, gifUrl) async {
                  try {
                    await PublicFeedStore.instance
                        .post(text, replyTo: post.id, gifUrl: gifUrl);
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

/// Who liked and who reposted one post, as tappable people.
///
/// Likes come through the server's one window into the likes table — a
/// directory join that answers usernames only (the table itself stores
/// phones and shows nobody else's rows). Reposts are ordinary public posts
/// and need no window. When the likes window isn't deployed yet the sheet
/// says so rather than showing an empty list that reads as "nobody".
class _EngagementSheet extends StatefulWidget {
  final PublicPost post;

  /// True when the viewer authored this post. Only then is the "Viewed by"
  /// list loaded and shown — who looked at a post is the author's to see.
  final bool isMine;
  const _EngagementSheet({required this.post, this.isMine = false});

  @override
  State<_EngagementSheet> createState() => _EngagementSheetState();
}

class _EngagementSheetState extends State<_EngagementSheet> {
  List<(String, String)>? _likers;
  List<PublicPost>? _reposters;
  List<(String, String)>? _viewers;
  bool _likersUnavailable = false;
  bool _viewersUnavailable = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = PublicFeedStore.instance;
    final likers = widget.post.likeCount > 0
        ? await store.likersOf(widget.post.id)
        : const <(String, String)>[];
    final reposters = widget.post.repostCount > 0
        ? await store.repostersOf(widget.post.id)
        : const <PublicPost>[];
    // Only the author sees who viewed, and only when there are views.
    final viewers = widget.isMine && widget.post.viewCount > 0
        ? await store.viewersOf(widget.post.id)
        : const <(String, String)>[];
    if (!mounted) return;
    setState(() {
      _likers = likers;
      _likersUnavailable = likers == null;
      _reposters = reposters;
      _viewers = viewers;
      _viewersUnavailable = viewers == null;
      _loading = false;
    });
  }

  void _openProfile(String username, String name) {
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            PublicProfileScreen(username: username, name: name)));
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: AppColors.subtle(context))),
      );

  Widget _person(String username, String name) => ListTile(
        dense: true,
        leading: CircleAvatar(
            radius: 17,
            child: Text(username.isEmpty ? '?' : username[0].toUpperCase())),
        title: Text(name.isEmpty ? '@$username' : name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: name.isEmpty
            ? null
            : Text('@$username', maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: username.isEmpty ? null : () => _openProfile(username, name),
      );

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
          height: 180, child: Center(child: CircularProgressIndicator()));
    }
    final likers = _likers ?? const <(String, String)>[];
    final reposters = _reposters ?? const <PublicPost>[];
    final viewers = _viewers ?? const <(String, String)>[];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: ListView(
          shrinkWrap: true,
          children: [
            if (widget.isMine && widget.post.viewCount > 0) ...[
              _header('VIEWED BY'),
              if (_viewersUnavailable)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(
                    'Who viewed isn\'t available yet — the server needs the '
                    'latest docs/public_feed.sql.',
                    style: TextStyle(
                        fontSize: 13, color: AppColors.subtle(context)),
                  ),
                )
              else ...[
                for (final (username, name) in viewers)
                  _person(username, name),
                // A signed-in viewer with no directory handle, or one who reads
                // the feed anonymously (no account), leaves a count but no name
                // — so fewer names than views is honest, not broken.
                if (widget.post.viewCount > viewers.length)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
                    child: Text(
                      'and ${widget.post.viewCount - viewers.length} more '
                      'without a public handle',
                      style: TextStyle(
                          fontSize: 12.5, color: AppColors.subtle(context)),
                    ),
                  ),
              ],
            ],
            if (widget.post.likeCount > 0) ...[
              _header('LIKED BY'),
              if (_likersUnavailable)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(
                    'Who liked isn\'t available yet — the server needs the '
                    'latest docs/public_feed.sql.',
                    style: TextStyle(
                        fontSize: 13, color: AppColors.subtle(context)),
                  ),
                )
              else ...[
                for (final (username, name) in likers)
                  _person(username, name),
                // Fewer names than the count is honest, not broken: a liker
                // with no directory handle (or a deactivated one) has no
                // name to show.
                if (widget.post.likeCount > likers.length)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
                    child: Text(
                      'and ${widget.post.likeCount - likers.length} more '
                      'without a public handle',
                      style: TextStyle(
                          fontSize: 12.5, color: AppColors.subtle(context)),
                    ),
                  ),
              ],
            ],
            if (widget.post.repostCount > 0) ...[
              _header('REPOSTED BY'),
              for (final r in reposters)
                _person(r.authorUsername, r.authorName),
              if (reposters.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text('Couldn\'t load reposts right now.',
                      style: TextStyle(
                          fontSize: 13, color: AppColors.subtle(context))),
                ),
            ],
            const SizedBox(height: 8),
          ],
        ),
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
    {String? replyTo, String? replyingToName, String? quoteOf}) async {
  // A name-only account reads the feed but can't add to it. The one funnel
  // every post/reply/quote passes through, so none is missed.
  if (postNeedsPhone(context)) return;
  await Navigator.of(context).push<void>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _Composer(
        replyTo: replyTo, replyingToName: replyingToName, quoteOf: quoteOf),
  ));
}

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
                    edited: post.edited,
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

  /// When on, this post is for the author's subscribers only. Available just to
  /// a creator who has turned subscriptions on, and only for a standalone text
  /// post (a reply, repost, poll or media post can't be paywalled).
  bool _subscribersOnly = false;

  /// The public preview under a paid post — what non-subscribers see to decide
  /// whether to subscribe. Optional: left blank, the store fills in a generic
  /// line, so the paid text is never leaked by default.
  final _teaser = TextEditingController();

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

  /// Usernames this device can offer as @mention suggestions: people you
  /// follow, contacts you've chatted with, and authors already on screen — no
  /// directory lookup, so it works offline and reveals nobody you don't know.
  List<String> _mentionCandidates(String prefix) => mentionMatches(prefix, [
        ...FollowStore.instance.following,
        for (final c in ChatStore.instance.allChats)
          if (c.contact.username.isNotEmpty) c.contact.username,
        for (final p in PublicFeedStore.instance.posts) p.authorUsername,
      ]);

  /// The tag-a-person chip row, shown only while an @mention is being typed.
  /// Tapping a chip completes the @handle in place — tagging from a list, not
  /// from memory. It rebuilds with the field because the TextField's onChanged
  /// already calls setState on every keystroke.
  Widget _mentionBar() {
    final prefix = activeMentionPrefix(_text.text);
    final matches =
        prefix == null ? const <String>[] : _mentionCandidates(prefix);
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
                avatar: const Icon(Icons.alternate_email, size: 14),
                label: Text(u),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  final text = _text.text
                      .replaceFirst(RegExp(r'@[A-Za-z0-9_]*$'), '@$u ');
                  _text.value = TextEditingValue(
                    text: text,
                    selection:
                        TextSelection.collapsed(offset: text.length),
                  );
                  setState(() {});
                },
              ),
            ),
        ],
      ),
    );
  }

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

  /// Picks a photo, unmixed with video — the fallback for a server whose
  /// schema hasn't been migrated for video yet ([PublicFeedStore.
  /// mediaSupported] false), so the one media button never offers a kind
  /// the insert would reject.
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

  /// Picks a photo OR a video from the library in one flow — the ONE media
  /// button. Falls back to the photo-only picker when the server can't
  /// take video yet ([PublicFeedStore.mediaSupported]).
  Future<void> _pickMedia() async {
    if (!PublicFeedStore.instance.mediaSupported) return _pickImage();
    try {
      final picked =
          await MediaPrep.pick(videoLimit: PublicFeedStore.maxVideoBytes);
      if (picked == null || !mounted) return;
      if (picked.isVideo) {
        setState(() {
          _video = picked.bytes;
          _videoName = picked.fileName;
          _image = null;
          _gifUrl = null;
        });
        return;
      }
      final dataUri =
          PhotoPrep.moderateAndPrepare(picked.bytes, maxBase64: 900 * 1024);
      if (dataUri == null || !mounted) return;
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

  @override
  void dispose() {
    _text.dispose();
    _teaser.dispose();
    _focus.dispose();
    for (final c in _pollFields ?? const <TextEditingController>[]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _send() async {
    // The spam brake: the button refuses to be hammered. Replies included —
    // twenty seconds is invisible to a person writing sentences.
    final wait = PublicFeedStore.instance.postCooldownLeft();
    if (wait > Duration.zero) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text('Slow down — you can post again in ${wait.inSeconds}s.')));
      return;
    }
    setState(() => _sending = true);
    try {
      await PublicFeedStore.instance.post(_text.text,
          replyTo: widget.replyTo,
          repostOf: widget.quoteOf,
          image: _image,
          gifUrl: _gifUrl,
          video: _video,
          pollOptions: [for (final c in _pollFields ?? const []) c.text],
          pollRunsFor: _isPoll ? _pollRunsFor : null,
          subscribersOnly: _subscribersOnly,
          teaser: _teaser.text);
      PublicFeedStore.instance.noteAuthored();
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
    // A subscribers-only post is long-form, so it gets the much larger cap.
    final cap = PublicFeedStore.maxLengthFor(_subscribersOnly);
    final left = cap - typed;
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
                                Icon(
                                    _subscribersOnly
                                        ? Icons.workspace_premium
                                        : Icons.public,
                                    size: 15,
                                    color: accent),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    _subscribersOnly
                                        ? 'Only your subscribers can read this'
                                        : me.username.isEmpty
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
                            // The paywall toggle — only for a creator, and only
                            // on a standalone text post (a reply, quote, poll or
                            // media post can't be paywalled). Turning it on
                            // clears any attachment, which the store also
                            // refuses.
                            if (widget.replyTo == null &&
                                widget.quoteOf == null &&
                                me.subscribable) ...[
                              const SizedBox(height: 10),
                              FilterChip(
                                avatar: Icon(
                                    _subscribersOnly
                                        ? Icons.lock
                                        : Icons.lock_open_outlined,
                                    size: 18),
                                label: Text(
                                    'Subscribers only · \$${(me.subscriptionCents / 100).toStringAsFixed(2)} · 30 days'),
                                selected: _subscribersOnly,
                                onSelected: (_isPoll || _hasMedia) && !_subscribersOnly
                                    ? null
                                    : (on) =>
                                        setState(() => _subscribersOnly = on),
                              ),
                              // The public preview: what everyone sees under
                              // the lock. Optional — left blank, a generic line
                              // fills it, so none of the paid text leaks.
                              if (_subscribersOnly) ...[
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _teaser,
                                  maxLines: 2,
                                  maxLength: PublicFeedStore.maxTeaserLength,
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                    labelText: 'Public preview (optional)',
                                    helperText:
                                        'Shown to everyone under the lock — a '
                                        'hook to subscribe. The post itself '
                                        'stays private.',
                                    helperMaxLines: 2,
                                  ),
                                ),
                              ],
                            ],
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
            // Tag-a-person chips while an @mention is being typed — the same
            // affordance the server feed's composer has, so a person is
            // tagged from a list instead of spelled out from memory.
            _mentionBar(),
            const Divider(height: 1),
            // Every other place somebody types in this app is sealed before
            // it leaves the device, so the reasonable assumption is that this
            // one is too. A paid post narrows WHO, not whether — the paywall
            // is access control, and the server still reads it to screen it.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: PublicContentNote(
                what: widget.replyTo == null ? 'post' : 'reply',
                who: _subscribersOnly ? 'Your subscribers' : 'Anyone',
              ),
            ),
            // The tools, on one row above the keyboard.
            Padding(
              // No viewInsets padding here: the Scaffold already shrinks the
              // body for the keyboard, and adding it again would push the row
              // a keyboard's height off the bottom of the screen.
              padding: const EdgeInsets.only(left: 6, right: 12),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.photo_library_outlined),
                    color: accent,
                    // Named for what the button actually opens: one native
                    // picker that offers photos and videos side by side, not
                    // two buttons for two different flows. The "add a video"
                    // half only applies once the server's schema has the
                    // columns for it — see PublicFeedStore.mediaSupported —
                    // so the tooltip says only what's really on offer.
                    tooltip: PublicFeedStore.instance.mediaSupported
                        ? 'Add a photo or video'
                        : 'Add a photo',
                    onPressed:
                        _sending || _isPoll || _subscribersOnly ? null : _pickMedia,
                  ),
                  // Hidden until the server's feed has the column for it.
                  // Offering a button whose post the insert would reject is
                  // worse than not offering it — see
                  // PublicFeedStore.mediaSupported.
                  if (PublicFeedStore.instance.mediaSupported)
                    IconButton(
                      icon: const Icon(Icons.gif_box_outlined),
                      color: accent,
                      tooltip: 'Add a GIF',
                      onPressed:
                          _sending || _isPoll || _subscribersOnly ? null : _pickGif,
                    ),
                  IconButton(
                    icon: Icon(_isPoll ? Icons.poll : Icons.poll_outlined),
                    color: accent,
                    tooltip: _isPoll ? 'Remove poll' : 'Add a poll',
                    // A poll is a post of its own — it cannot be a reply or a
                    // quote, and the table refuses those too.
                    onPressed: _sending ||
                            widget.replyTo != null ||
                            widget.quoteOf != null ||
                            _subscribersOnly ||
                            !PublicFeedStore.instance.pollsSupported
                        ? null
                        : _togglePoll,
                  ),
                  const Spacer(),
                  _CharacterRing(used: typed, limit: cap),
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

/// The trending hashtags and any active narrowing under the app bar. The
/// For you / Following switch itself now lives top-right in the app bar, so it
/// is no longer a tab row here.
class _FilterBar extends StatelessWidget {
  final PublicFeedStore store;
  const _FilterBar({required this.store});

  @override
  Widget build(BuildContext context) {
    final tags = PublicFeedStore.trendingTags(store.posts);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                    onPressed: () {
                      if (postNeedsPhone(context, what: 'Voting')) return;
                      PublicFeedStore.instance.vote(post.id, i);
                    },
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
