import 'dart:ui' show ImageFilter;
import '../state/session.dart';
import '../widgets/phone_gate.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../models/user.dart';

import '../state/call_log.dart';
import '../state/chat_store.dart';
import '../state/feed_store.dart';
import '../state/follow_store.dart';
import '../tabs/activity_tab.dart';
import '../tabs/calls_tab.dart';
import '../tabs/chats_tab.dart';
import '../theme/app_theme.dart';
import 'archived_chats_screen.dart';
import 'chat_search_delegate.dart';
import 'communities.dart';
import 'explore_map_screen.dart';
import 'new_chat_screen.dart';
import '../widgets/nearby_offer_host.dart';
import 'nearby_share_screen.dart';
import 'notes_screen.dart';
import 'marketplace_screen.dart';
import 'public_feed_screen.dart';
import 'settings_screen.dart';
import 'wallet_screen.dart';
import 'edit_profile_screen.dart';
import 'starred_messages_screen.dart';
import '../app_state.dart';
import '../util/build_info.dart';
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
      List.generate(5, (_) => ScrollController());

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
  void dispose() {
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
        appBar: AppBar(
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
            ] else if (_index == 1)
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'New server',
                onPressed: () => createCommunityFlow(context),
              )
            else if (_index == 2)
              const CallsTabActions()
            else if (_index == 3)
              // It used to sit beside the filter chips, on the same row, and
              // clipped them mid-word — "Servers" read "Ser". An action belongs
              // in the bar the screen already has.
              ListenableBuilder(
                listenable: ChatStore.instance,
                builder: (context, _) {
                  final unread = ChatStore.instance.chats
                      .where((c) => c.unreadCount > 0)
                      .toList();
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
        drawer: _AppSideBar(onSelectTab: _onSelectTab, currentTab: _index),
        // Tabs keep their state in an IndexedStack; switching softly fades the
        // incoming tab in rather than hard-cutting.
        body: FadeTransition(
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
              ])
                PrimaryScrollController(
                  controller: _tabScrollControllers[i],
                  child: tab,
                ),
            ],
          ),
        ),
        bottomNavigationBar: ListenableBuilder(
          listenable: Listenable.merge(
              [CallLog.instance, ChatStore.instance, FeedStore.instance]),
          builder: (context, _) => _ModernNavBar(
            index: _index,
            missedCalls: CallLog.instance.newMissedCount,
            activityCount: CallLog.instance.newMissedCount +
                FeedStore.instance.unseenNotificationCount +
                ChatStore.instance.chats
                    .fold(0, (n, c) => n + (c.unreadCount > 0 ? 1 : 0)),
            onSelect: _onSelectTab,
          ),
        ),
      ),
      ),
    );
  }

  void _onSelectTab(int i) {
    // Tapping the tab you are already on takes you back to the top of it —
    // the gesture every app with a bottom bar has, and the only way back up a
    // long list without dragging.
    if (i == _index) {
      _scrollTabToTop(i);
    } else {
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

class _ModernNavBar extends StatelessWidget {
  final int index;
  final int missedCalls;
  final int activityCount;
  final ValueChanged<int> onSelect;

  const _ModernNavBar({
    required this.index,
    required this.onSelect,
    this.missedCalls = 0,
    this.activityCount = 0,
  });

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
              _NavPill(
                icon: Icons.chat_bubble_outline,
                activeIcon: Icons.chat_bubble,
                label: 'Chats',
                selected: index == 0,
                onTap: () => onSelect(0),
              ),
              const SizedBox(width: 6),
              _NavPill(
                icon: Icons.groups_outlined,
                activeIcon: Icons.groups,
                label: 'Servers',
                selected: index == 1,
                onTap: () => onSelect(1),
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
                icon: Icons.notifications_none,
                activeIcon: Icons.notifications,
                label: 'Alerts',
                selected: index == 3,
                badgeCount: activityCount,
                onTap: () => onSelect(3),
              ),
              const SizedBox(width: 6),
              _NavPill(
                icon: Icons.person_outline,
                activeIcon: Icons.person,
                label: 'You',
                selected: index == 4,
                onTap: () => onSelect(4),
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
/// that otherwise live several taps deep.
class _AppSideBar extends StatelessWidget {
  /// Switches the home screen's bottom tab — for destinations that ARE a tab,
  /// where pushing a second copy on top would stack two of the same screen.
  final ValueChanged<int> onSelectTab;

  /// Which bottom tab is showing behind the drawer, so its row can say so.
  final int currentTab;

  const _AppSideBar({required this.onSelectTab, required this.currentTab});

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
                onTap: () => _go(context, const EditProfileScreen()),
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
                                  '${FollowStore.instance.followingCount} '
                                  'following',
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: AppColors.subtle(context))),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.edit_outlined,
                          size: 18, color: Colors.grey),
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
              _drawerHeader(context, 'Apps'),
              ListTile(
                leading: const Icon(Icons.public),
                title: const Text('Newsfeed'),
                trailing: const PhoneOnlyHint(),
                subtitle: const Text('One public timeline, everyone on it'),
                onTap: () => _go(context, const PublicFeedScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.map_outlined),
                title: const Text('Maps'),
                subtitle: const Text('Search, navigate, share places'),
                onTap: () => _go(context, const ExploreMapScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.storefront_outlined),
                title: const Text('Marketplace'),
                trailing:
                    const _GateHint(ownerMayPass: true, numberlessMayPass: true),
                subtitle: const Text('Buy and sell with your servers'),
                onTap: () => _go(context, const MarketplaceScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: const Text('Servers'),
                // Servers IS a bottom tab, so this switches the bar rather
                // than pushing a second copy of a screen that is already open
                // behind the drawer — and says when it is the one showing,
                // which nothing here used to do for any row.
                selected: currentTab == 1,
                selectedTileColor:
                    Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
                onTap: () {
                  Navigator.of(context).pop();
                  onSelectTab(1);
                },
              ),
              ListTile(
                leading: const Icon(Icons.sticky_note_2_outlined),
                title: const Text('Notes'),
                subtitle: const Text('Write things down, kept on this device'),
                onTap: () => _go(context, const NotesScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.wifi_tethering),
                title: const Text('Okay Drop'),
                trailing:
                    const _GateHint(ownerMayPass: true, numberlessMayPass: true),
                // One line on the narrowest phone still sold — the drawer
                // test taps every destination, and a second line here pushes
                // the last one off the bottom.
                subtitle:
                    const Text('Photos, videos and files, phone to phone'),
                onTap: () => _go(context, const NearbyShareScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: const Text('Wallet'),
                trailing: const _GateHint(),
                subtitle: const Text('Send and receive money'),
                onTap: () => _go(context, const WalletScreen()),
              ),
              const Divider(height: 17),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Settings'),
                onTap: () => _go(context, const SettingsScreen()),
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
        padding: EdgeInsets.symmetric(
          // Narrower side padding on the selected pill than it looks: the
          // label already sets it apart, and 16 a side across five pills is
          // what pushed a 390-point phone over the edge.
          horizontal: selected ? 12 : 11,
          vertical: 11,
        ),
        decoration: BoxDecoration(
          color: selected
              ? ink.withValues(alpha: isDark ? 0.16 : 0.07)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _IconWithBadge(
              icon: selected ? activeIcon : icon,
              color: selected ? ink : idle,
              badgeCount: badgeCount,
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
              child: selected
                  ? Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: TextStyle(
                          color: ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
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
                    (ownerMayPass && PlatformModeration.instance.isOwner)
                ? const SizedBox.shrink()
                : Tooltip(
                    message: 'Needs a verified account',
                    child: Icon(Icons.lock_outline,
                        size: 17, color: AppColors.subtle(context)),
                  ),
      );
}
