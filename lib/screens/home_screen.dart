import 'dart:ui' show ImageFilter;
import '../state/session.dart';
import '../widgets/phone_gate.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../models/user.dart';
import '../widgets/sidebar_menu_button.dart';

import '../state/call_log.dart';
import '../state/chat_store.dart';
import '../state/feed_store.dart';
import '../state/follow_store.dart';
import '../state/sidebar_prefs.dart';
import 'sidebar_customize_screen.dart';
import '../tabs/activity_tab.dart';
import '../tabs/calls_tab.dart';
import '../tabs/chats_tab.dart';
import '../theme/app_theme.dart';
import '../widgets/numberless_grace_banner.dart';
import 'archived_chats_screen.dart';
import 'chat_search_delegate.dart';
import 'communities.dart';
import 'server_discover_screen.dart';
import 'servers_screen.dart';
import 'store_screen.dart';
import 'map_screen.dart';
import 'new_chat_screen.dart';
import '../widgets/nearby_offer_host.dart';
import 'nearby_share_screen.dart';
import 'ai_chat_screen.dart';
import '../widgets/app_dialogs.dart';
import 'marketplace_screen.dart';
import 'public_feed_screen.dart';
import 'public_forum_screen.dart';
import 'settings_screen.dart';
import 'wallet_screen.dart';
import 'starred_messages_screen.dart';
import '../app_state.dart';
import '../util/build_info.dart';
import '../util/haptics.dart';
import '../widgets/user_avatar.dart';
import '../state/identity_verification.dart';
import '../state/platform_moderation.dart';

/// The top-level screen: a modern pill bottom bar switching between Chats and
/// Calls, with a compose FAB.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// Names a destination in the floating bar for a test. Finding one by its
  /// icon is ambiguous — the Servers empty state draws the same glyph, and so
  /// does the sidebar's row for the same tab.
  @visibleForTesting
  static Key debugNavPillKey(String label) => _NavPill.keyFor(label);

  /// Lets a PUSHED screen (e.g. the Newsfeed, which carries the app's bottom
  /// bar) send the app to a bottom tab: it pops back to the home route, then
  /// the home screen — listening below — switches. Null between requests.
  static final ValueNotifier<int?> tabRequest = ValueNotifier<int?>(null);

  /// Pops back to home and switches to bottom tab [index].
  static void goToTab(BuildContext context, int index) {
    Navigator.of(context).popUntil((r) => r.isFirst);
    tabRequest.value = index;
  }

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  int _index = 0;

  /// One scroll controller per tab, handed down as the tab's
  /// [PrimaryScrollController]. A tab's own ListView attaches to it without
  /// being told to, which is what makes tapping the current tab again scroll
  /// it back to the top — the gesture every app with a bottom bar has.
  ///
  /// One controller per tab rather than one shared: they all live at once
  /// inside the IndexedStack, and a controller with five positions attached
  /// cannot be asked to animate any of them.
  late final List<ScrollController> _tabScrollControllers =
      List.generate(7, (_) => ScrollController());

  /// Runs a quick fade-in whenever the visible tab changes.
  late final AnimationController _tabFadeController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 1,
  );
  late final Animation<double> _tabFade = _tabFadeController
      .drive(CurveTween(curve: Curves.easeOut))
      .drive(Tween(begin: 0.35, end: 1.0));

  @override
  void initState() {
    super.initState();
    HomeScreen.tabRequest.addListener(_onTabRequest);
  }

  /// A pushed screen asked to switch tabs (via [HomeScreen.goToTab]).
  void _onTabRequest() {
    final i = HomeScreen.tabRequest.value;
    if (i == null || !mounted) return;
    HomeScreen.tabRequest.value = null;
    _onSelectTab(i);
  }

  @override
  void dispose() {
    HomeScreen.tabRequest.removeListener(_onTabRequest);
    _tabFadeController.dispose();
    for (final c in _tabScrollControllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _onMenuSelected(String value) {
    switch (value) {
      case 'filter':
        ChatsTab.filtersVisible.value = !ChatsTab.filtersVisible.value;
        break;
      case 'settings':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SettingsScreen()),
        );
        break;
      case 'starred':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const StarredMessagesScreen()),
        );
        break;
      case 'archived':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ArchivedChatsScreen()),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final onChats = _index == 0;
    // Nothing arrives on this phone without being asked about first — the
    // whole reason to model this on AirDrop rather than simply accepting what
    // is sent. Hosted here so the question is asked wherever you happen to
    // be, not only on the screen you would have sent from.
    return NearbyOfferHost(
      child: PopScope(
      // Back from any other tab returns to Chats before it leaves the app.
      // Without this, Android's back gesture and the browser's back button
      // both closed the app from a tab nobody had navigated *to* — the tab
      // bar is navigation, so back should undo it.
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onSelectTab(0);
      },
      child: Scaffold(
        key: homeScaffoldKey,
        // The Newsfeed and Okay AI tabs are full screens with their own app
        // bars — showing home's on top of theirs would stack two.
        appBar: (_index == 5 || _index == 6)
            ? null
            : AppBar(
          // 20pt of title inset plus three actions truncated the brand name to
          // "OkayMessen…" on a 390pt iPhone. The name is the one word on this
          // screen that must not be cut.
          titleSpacing: 14,
          title: _index == 0
              // Scaled down rather than ellipsised. Three actions leave the
              // title about 190pt on a 390pt iPhone and 120pt on a 320pt one,
              // where 20pt type read "OkayMe…" — a truncated brand name is
              // worse than a slightly smaller one, and this does nothing at
              // all on a screen wide enough to hold it.
              ? FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'OkayMessenger',
                    style: TextStyle(
                      color: isDark ? Colors.white : AppColors.tealGreen,
                      fontWeight: FontWeight.bold,
                      fontSize: 20,
                    ),
                  ),
                )
              : Text(_titleForIndex),
          actions: [
            // Search is on every tab, not just this one. It looks through
            // people, messages, servers, channels, calls and links — none of
            // which is a Chats-tab-only idea — and it was reachable from one
            // of five destinations.
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Search',
              onPressed: () =>
                  showSearch(context: context, delegate: ChatSearchDelegate()),
            ),
            if (onChats) ...[
              IconButton(
                icon: const Icon(Icons.add_comment_outlined),
                tooltip: 'New chat',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const NewChatScreen()),
                ),
              ),
              PopupMenuButton<String>(
                onSelected: _onMenuSelected,
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'filter',
                    child: Text(ChatsTab.filtersVisible.value
                        ? 'Hide filters'
                        : 'Filter chats'),
                  ),
                  const PopupMenuItem(
                      value: 'archived', child: Text('Archived chats')),
                  const PopupMenuItem(
                      value: 'starred', child: Text('Starred messages')),
                ],
              ),
            ] else if (_index == 1) ...[
              IconButton(
                icon: const Icon(Icons.explore_outlined),
                tooltip: 'Discover servers',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ServerDiscoverScreen())),
              ),
              IconButton(
                icon: const Icon(Icons.vpn_key_outlined),
                tooltip: 'Join with a code',
                onPressed: () => joinByCodeFlow(context),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'New server',
                onPressed: () => createCommunityFlow(context),
              ),
            ]
            else if (_index == 2)
              const CallsTabActions()
            else if (_index == 3)
              // It used to sit beside the filter chips, on the same row, and
              // clipped them mid-word — "Servers" read "Ser". An action belongs
              // in the bar the screen already has.
              ListenableBuilder(
                listenable: ChatStore.instance,
                builder: (context, _) {
                  // "All" means all: the Marketplace folder's unreads too,
                  // or the button clears the list and leaves the badge lit.
                  final unread = [
                    ...ChatStore.instance.chats,
                    ...ChatStore.instance.marketplaceChats,
                  ].where((c) => c.unreadCount > 0).toList();
                  if (unread.isEmpty) return const SizedBox.shrink();
                  return IconButton(
                    icon: const Icon(Icons.done_all),
                    tooltip: 'Mark all read',
                    onPressed: () {
                      for (final c in unread) {
                        ChatStore.instance.markRead(c.id);
                      }
                    },
                  );
                },
              )
            else if (_index == 4)
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
          ],
        ),
        // Let the content flow behind the floating glass bar so it blurs through.
        extendBody: true,
        drawer: AppSideBar(onSelectTab: _onSelectTab, currentTab: _index),
        // Tabs keep their state in an IndexedStack; switching softly fades the
        // incoming tab in rather than hard-cutting.
        // The 14-day reminder sits ABOVE every tab, not inside one: the
        // account is being deleted whichever screen somebody happens to be
        // looking at, and it must not be a thing you only see on Chats.
        body: Column(
          children: [
            const NumberlessGraceBanner(),
            Expanded(
              child: FadeTransition(
          opacity: _tabFade,
          child: IndexedStack(
            index: _index,
            children: [
              for (final (i, tab) in const <(int, Widget)>[
                (0, ChatsTab()),
                (1, CommunitiesTab()),
                (2, CallsTab()),
                (3, ActivityTab()),
                // The same profile screen everybody else gets, with the parts
                // only you can act on. There used to be a second one here.
                (4, _YouTab()),
                // The Newsfeed and Okay AI are BOTTOM TABS now (the owner's
                // call): full screens with their own app bars, so home's bar
                // hides while either is showing. Their old sidebar rows are
                // gone — the bar is how you reach them.
                (5, PublicFeedScreen(asTab: true)),
                (6, AiChatScreen()),
              ])
                PrimaryScrollController(
                  controller: _tabScrollControllers[i],
                  child: tab,
                ),
            ],
          ),
        ),
            ),
          ],
        ),
        bottomNavigationBar: ListenableBuilder(
          listenable: AppBottomNavBar.badgeListenable,
          builder: (context, _) => AppBottomNavBar(
            index: _index,
            missedCalls: AppBottomNavBar.missedCallsNow,
            activityCount: AppBottomNavBar.activityCountNow,
            onSelect: _onSelectTab,
          ),
        ),
      ),
      ),
    );
  }

  void _onSelectTab(int i) {
    // Search is not a tab: it pushes the feed with the field already up, so
    // there is nothing in the IndexedStack to switch to and no pill to light.
    if (i == AppBottomNavBar.searchTab) {
      Haptics.select();
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => const PublicFeedScreen(startSearching: true)));
      return;
    }
    // Tapping the tab you are already on takes you back to the top of it —
    // the gesture every app with a bottom bar has, and the only way back up a
    // long list without dragging.
    if (i == _index) {
      _scrollTabToTop(i);
    } else {
      Haptics.select();
      _tabFadeController.forward(from: 0);
      setState(() => _index = i);
    }
    // Opening the Calls tab clears the missed-call badge. Also on a re-tap:
    // something can have arrived while the tab was already open.
    if (i == 2) CallLog.instance.markSeen();
    // Opening Notifications clears the feed mention/reply badge.
    if (i == 3) FeedStore.instance.markNotificationsSeen();
  }

  void _scrollTabToTop(int i) {
    final c = _tabScrollControllers[i];
    // A tab with nested scrollables (the profile's own tab bar) attaches more
    // than one position to its controller, and animating an ambiguous
    // controller throws. Nothing to scroll is not an error either.
    if (c.positions.length != 1 || c.offset <= 0) return;
    c.animateTo(0,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic);
  }

  String get _titleForIndex => switch (_index) {
        1 => 'Servers',
        2 => 'Calls',
        3 => 'Notifications',
        4 => 'You',
        // 5 and 6 (Newsfeed, Okay AI) never reach this — those tabs render
        // their own app bars and home's is hidden.
        _ => 'OkayMessenger',
      };
}

/// A floating "liquid glass" bottom bar: a translucent, blurred pill that
/// hovers over the content (which shows through it), with an animated
/// highlight behind the selected destination.
/// The "You" tab: the one profile screen, told whose it is.
class _YouTab extends StatelessWidget {
  const _YouTab();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppUser>(
        valueListenable: AppState.profile,
        builder: (context, me, _) => PublicProfileScreen(
          key: ValueKey('you-${me.username}'),
          username: me.username,
          name: me.name,
          embedded: true,
        ),
      );
}

/// The app's floating "liquid glass" bottom navigation bar. Public so a pushed
/// screen that wants the same bar (the Newsfeed) can mount it and route taps
/// back to the home tabs via [HomeScreen.goToTab]. [index] is -1 when the
/// hosting screen is not itself one of the tabs, so no pill reads as selected.
class AppBottomNavBar extends StatelessWidget {
  /// Not a tab index — the value [onSelect] receives when Search is tapped.
  /// Search opens a pushed screen rather than swapping the IndexedStack, and
  /// deliberately does not collide with a real index (removing or renumbering
  /// a tab shifts every other one, which this app has been careful about).
  static const int searchTab = -2;

  final int index;
  final int missedCalls;
  final int activityCount;
  final ValueChanged<int> onSelect;

  const AppBottomNavBar({
    super.key,
    required this.index,
    required this.onSelect,
    this.missedCalls = 0,
    this.activityCount = 0,
  });

  /// Missed calls awaiting attention — the Calls pill's badge.
  static int get missedCallsNow => CallLog.instance.newMissedCount;

  /// New missed calls, feed notifications and unread conversations combined —
  /// the Alerts pill's badge. Both chat shelves count (a Marketplace buyer is
  /// still unread news). Computed here so the home bar and the Newsfeed's copy
  /// show the identical number.
  static int get activityCountNow => CallLog.instance.newMissedCount +
      FeedStore.instance.unseenNotificationCount +
      [
        ...ChatStore.instance.chats,
        ...ChatStore.instance.marketplaceChats,
      ].fold(0, (n, c) => n + (c.unreadCount > 0 ? 1 : 0));

  /// The stores whose changes move the two badges — wrap the bar in a
  /// ListenableBuilder on this so a pushed copy stays in sync too.
  static Listenable get badgeListenable => Listenable.merge(
      [CallLog.instance, ChatStore.instance, FeedStore.instance]);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // A frosted tint over the blur — light and airy in light mode, deep in
    // dark mode — with a soft highlight border to catch the "glass" edge.
    final glass = (isDark ? const Color(0xFF1C1F24) : Colors.white)
        .withValues(alpha: isDark ? 0.62 : 0.68);
    final border = (isDark ? Colors.white : Colors.black)
        .withValues(alpha: isDark ? 0.14 : 0.06);
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    // A live backdrop blur is gorgeous on native but very expensive on Flutter
    // web (CanvasKit re-reads and blurs the whole screen every frame, which
    // makes scrolling stutter). On web, drop the blur and use a near-opaque
    // bar instead — same look, none of the per-frame cost.
    final barColor = kIsWeb
        ? (isDark ? const Color(0xFF1C1F24) : Colors.white)
            .withValues(alpha: isDark ? 0.97 : 0.98)
        : glass;
    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: barColor,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: border, width: 0.8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        // FIVE PILLS DO NOT FIT EVERY PHONE. At 390 — an iPhone 15 — the row
        // ran nine points over; at 320 it is worse. Handing each pill an equal
        // fifth was tried and was worse than the overflow: only the selected
        // pill carries a label, so an equal share squeezed "Chats" down to
        // "C". Scaling the whole row down keeps every pill in proportion and
        // the label readable, and does nothing at all on a screen wide enough.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Servers and You (the profile) are deliberately NOT on the bar
              // — both live in the drawer (the Servers row, and the profile
              // card at its top). Newsfeed · Chats · Search · Calls · AI, in
              // that order: Notifications moved to the newsfeed's top-right
              // and Search took the middle slot it vacated (the owner's call).
              _NavPill(
                icon: Icons.public,
                activeIcon: Icons.public,
                label: 'Newsfeed',
                selected: index == 5,
                onTap: () => onSelect(5),
              ),
              const SizedBox(width: 6),
              _NavPill(
                icon: Icons.chat_bubble_outline,
                activeIcon: Icons.chat_bubble,
                label: 'Chats',
                selected: index == 0,
                onTap: () => onSelect(0),
              ),
              const SizedBox(width: 6),
              // Search sits in the MIDDLE (the owner's call), where
              // Notifications used to be — that moved to the newsfeed's
              // top-right, taking its badge with it. Search is the one pill
              // that is not a tab: it PUSHES the feed with the field already
              // up, so it never reads as selected.
              _NavPill(
                icon: Icons.search,
                activeIcon: Icons.search,
                label: 'Search',
                selected: false,
                onTap: () => onSelect(searchTab),
              ),
              const SizedBox(width: 6),
              _NavPill(
                icon: Icons.call_outlined,
                activeIcon: Icons.call,
                label: 'Calls',
                selected: index == 2,
                badgeCount: missedCalls,
                onTap: () => onSelect(2),
              ),
              const SizedBox(width: 6),
              _NavPill(
                icon: Icons.auto_awesome_outlined,
                activeIcon: Icons.auto_awesome,
                label: 'AI',
                selected: index == 6,
                onTap: () => onSelect(6),
              ),
            ],
          ),
        ),
      ),
    );

    return Padding(
      padding:
          EdgeInsets.fromLTRB(14, 0, 14, bottomInset > 0 ? bottomInset : 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: kIsWeb
            ? decorated
            : BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: decorated,
              ),
      ),
    );
  }
}

/// The left sidebar: profile up top, then one-tap shortcuts to the places
/// that otherwise live several taps deep. Home's drawer, and only home's —
/// a pushed destination goes back with the normal back arrow (the owner's
/// call; the ☰-on-destination overlay experiment is gone).
class AppSideBar extends StatelessWidget {
  /// Switches the home screen's bottom tab — for destinations that ARE a tab,
  /// where pushing a second copy on top would stack two of the same screen.
  final ValueChanged<int> onSelectTab;

  /// Which bottom tab is showing behind the drawer, so its row can say so.
  final int currentTab;

  const AppSideBar({
    super.key,
    required this.onSelectTab,
    required this.currentTab,
  });

  Widget _drawerHeader(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );

  void _go(BuildContext context, Widget screen) {
    Navigator.of(context).pop(); // close the drawer first
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  /// Switches to a bottom tab from the sidebar: closes the drawer and switches.
  void _goToTab(BuildContext context, int tab) {
    Navigator.of(context).pop();
    onSelectTab(tab);
  }

  /// Sign out from the drawer — the same action Settings offers, one tap closer.
  /// Confirmed first, because the drawer is easy to brush. Signing out keeps
  /// this account's data on the device (switching accounts, not wiping); the
  /// dialog says so. Back to the root so the login gate isn't left under a
  /// stack of pushed routes.
  Future<void> _signOut(BuildContext context) async {
    final navigator = Navigator.of(context);
    final ok = await showAppConfirmDialog(
      context,
      icon: Icons.logout,
      title: 'Sign out?',
      message: 'You can sign back in anytime. This account\'s chats and data '
          'stay on this device.',
      confirmLabel: 'Sign out',
      destructive: true,
    );
    if (!ok) return;
    await Session.instance.signOut();
    navigator.popUntil((route) => route.isFirst);
  }

  /// One app row by its [SidebarPrefs] id. The drawer draws these in the
  /// user's order; the customize screen only needs names and icons, so this
  /// stays the single place a row's destination and gates live.
  Widget _appRow(BuildContext context, String id) {
    switch (id) {
      // 'okayai' and 'newsfeed' are BOTTOM TABS now, not sidebar rows, and
      // 'contacts' lives in the Calls tab's app bar — an id still in
      // somebody's saved order just renders nothing. The one-line
      // descriptions the rows used to carry are gone too (the owner's call):
      // the names say enough, and the list reads faster without them.
      case 'forum':
        return ListTile(
          leading: const Icon(Icons.forum_outlined),
          // No padlock, like Newsfeed: a name-only account can READ the forum;
          // posting/voting is gated per-action inside.
          title: const Text('Forum'),
          onTap: () => _go(context, const PublicForumScreen(fromSidebar: true)),
        );
      case 'maps':
        return ListTile(
          leading: const Icon(Icons.map_outlined),
          title: const Text('Maps'),
          onTap: () => _go(context, const MapScreen(fromSidebar: true)),
        );
      case 'marketplace':
        return ListTile(
          leading: const Icon(Icons.storefront_outlined),
          title: const Text('Marketplace'),
          trailing:
              const _GateHint(ownerMayPass: true, numberlessMayPass: true),
          onTap: () => _go(context, const MarketplaceScreen(fromSidebar: true)),
        );
      case 'servers':
        return ListTile(
          leading: const Icon(Icons.groups_outlined),
          title: const Text('Servers'),
          // Pushed like every other row now (the owner's call), so it leaves
          // with a normal back arrow instead of surfacing the hidden tab.
          onTap: () => _go(context, const ServersScreen()),
        );
      case 'drop':
        return ListTile(
          leading: const Icon(Icons.wifi_tethering),
          title: const Text('Okay Drop'),
          trailing:
              const _GateHint(ownerMayPass: true, numberlessMayPass: true),
          onTap: () => _go(context, const NearbyShareScreen(fromSidebar: true)),
        );
      case 'wallet':
        return ListTile(
          leading: const Icon(Icons.account_balance_wallet_outlined),
          title: const Text('Wallet'),
          trailing: const _GateHint(),
          onTap: () => _go(context, const WalletScreen(fromSidebar: true)),
        );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: ValueListenableBuilder(
          valueListenable: AppState.profile,
          builder: (context, me, _) => ListView(
            padding: EdgeInsets.zero,
            children: [
              InkWell(
                // The profile left the bottom bar, so tapping your card here is
                // the way to it now — it switches to the profile tab (like the
                // Servers row switches to that one) rather than pushing a second
                // copy. Editing lives inside the profile and in Settings.
                onTap: () => _goToTab(context, 4),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                  child: Row(
                    children: [
                      UserAvatar(user: me, radius: 28),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(me.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 17, fontWeight: FontWeight.w700)),
                            if (me.handle.isNotEmpty)
                              Text(me.handle,
                                  style: TextStyle(
                                      fontSize: 13.5,
                                      color: AppColors.subtle(context))),
                            if (me.pronouns.trim().isNotEmpty)
                              Text(me.pronouns.trim(),
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: AppColors.subtle(context))),
                            ListenableBuilder(
                              listenable: FollowStore.instance,
                              builder: (context, _) => Text(
                                  '${FollowStore.instance.followingCountDisplay} '
                                  'following',
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: AppColors.subtle(context))),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right,
                          size: 20, color: Colors.grey),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              // The full apps that live outside the five tabs, under a header
              // that says what they are — the list used to run them straight
              // into Settings with nothing to separate the two.
              //
              // The bottom bar is not repeated here. It is on screen already,
              // and a drawer that lists the tab bar is a second copy of the
              // navigation rather than more of it. Servers is the exception,
              // because it is where the other apps' content lives.
              //
              // Which rows show, and in what order, is the user's call
              // (SidebarPrefs) — the tune button beside the header is where
              // they say so.
              Row(
                children: [
                  Expanded(child: _drawerHeader(context, 'Apps')),
                  IconButton(
                    icon: const Icon(Icons.tune, size: 18),
                    tooltip: 'Customize sidebar',
                    onPressed: () =>
                        _go(context, const SidebarCustomizeScreen(fromSidebar: true)),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
              ListenableBuilder(
                listenable: SidebarPrefs.instance,
                builder: (context, _) => Column(
                  children: [
                    for (final id in SidebarPrefs.instance.visible)
                      _appRow(context, id),
                  ],
                ),
              ),
              const Divider(height: 17),
              // With Settings rather than in the Apps list above: both are
              // fixed, so neither can be hidden or reordered away. Somebody
              // who has hidden every app row must still be able to reach the
              // way to pay and the way to change things.
              ListTile(
                leading: const Icon(Icons.shopping_bag_outlined),
                title: const Text('Store'),
                onTap: () => _go(context, const StoreScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Settings'),
                onTap: () => _go(context, const SettingsScreen(fromSidebar: true)),
              ),
              ListTile(
                leading: const Icon(Icons.logout, color: Colors.red),
                title: const Text('Sign out',
                    style: TextStyle(color: Colors.red)),
                onTap: () => _signOut(context),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'OkayMessenger · $kBuildStamp',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavPill extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final int badgeCount;
  final VoidCallback onTap;

  _NavPill({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  }) : super(key: keyFor(label));

  /// How a test names a destination in the bar. The icon is not enough:
  /// `Icons.groups_outlined` is also the Servers empty state, so finding a
  /// pill by icon can land on the illustration instead of the button.
  static Key keyFor(String label) => ValueKey('nav-pill-$label');

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? Colors.white : const Color(0xFF0F1419);
    final idle = isDark ? AppColors.subtle(context) : AppColors.subtle(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? ink.withValues(alpha: isDark ? 0.16 : 0.07)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        // Icon on top, label beneath — the classic bottom-bar stack rather
        // than a label that only appears beside the selected icon.
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _IconWithBadge(
              icon: selected ? activeIcon : icon,
              color: selected ? ink : idle,
              badgeCount: badgeCount,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(
                color: selected ? ink : idle,
                fontSize: 11,
                height: 1.0,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A nav icon with an optional red count badge (used for missed calls).
class _IconWithBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final int badgeCount;

  const _IconWithBadge({
    required this.icon,
    required this.color,
    required this.badgeCount,
  });

  @override
  Widget build(BuildContext context) {
    final canvas = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF16181C)
        : Colors.white;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon, size: 24, color: color),
        if (badgeCount > 0)
          Positioned(
            right: -6,
            top: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
              decoration: BoxDecoration(
                color: const Color(0xFFE53935),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: canvas, width: 1.5),
              ),
              child: Text(
                badgeCount > 9 ? '9+' : '$badgeCount',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A quiet padlock on the drawer rows that lead somewhere verified-only, so
/// the gate is not a surprise at the end of a tap. Nothing at all once the
/// account is verified, or on a build where verification is impossible.
///
/// [ownerMayPass] mirrors the same flag on the [VerifiedGate] each row opens,
/// and has to keep mirroring it: a padlock on a row that opens is a worse lie
/// than no padlock at all.
/// One padlock for two gates. A row behind both would otherwise carry two,
/// which reads as a worse problem than it is — and the phone gate is the
/// outer one, so it is the one that decides.
class _GateHint extends StatelessWidget {
  const _GateHint({this.ownerMayPass = false, this.numberlessMayPass = false});

  final bool ownerMayPass;

  /// True where a numberless account is let in (browse-only marketplace), so
  /// the row shows no phone padlock — a padlock on a row that opens is a
  /// worse lie than no padlock. A numbered-but-unverified account still sees
  /// the verified hint.
  final bool numberlessMayPass;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Session.instance.user,
        builder: (context, _) => Session.instance.isNumberless
            ? (numberlessMayPass
                ? const SizedBox.shrink()
                : const PhoneOnlyHint())
            : _VerifiedOnlyHint(ownerMayPass: ownerMayPass),
      );
}

class _VerifiedOnlyHint extends StatelessWidget {
  const _VerifiedOnlyHint({this.ownerMayPass = false});

  final bool ownerMayPass;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge(
            [IdentityVerification.instance, PlatformModeration.instance]),
        builder: (context, _) =>
            IdentityVerification.instance.allowsTrusted ||
                    (ownerMayPass &&
                        PlatformModeration.instance.canAdminister)
                ? const SizedBox.shrink()
                : Tooltip(
                    message: 'Needs a verified account',
                    child: Icon(Icons.lock_outline,
                        size: 17, color: AppColors.subtle(context)),
                  ),
      );
}
