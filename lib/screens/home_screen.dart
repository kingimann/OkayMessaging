import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../models/user.dart';

import '../state/call_log.dart';
import '../state/feed_store.dart';
import '../state/follow_store.dart';
import '../tabs/activity_tab.dart';
import '../tabs/calls_tab.dart';
import '../tabs/chats_tab.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import 'archived_chats_screen.dart';
import 'chat_search_delegate.dart';
import 'communities.dart';
import 'explore_map_screen.dart';
import 'new_chat_screen.dart';
import 'marketplace_screen.dart';
import 'public_feed_screen.dart';
import 'settings_screen.dart';
import 'wallet_screen.dart';
import 'edit_profile_screen.dart';
import 'starred_messages_screen.dart';
import '../app_state.dart';
import '../util/build_info.dart';
import '../widgets/user_avatar.dart';

/// The top-level screen: a modern pill bottom bar switching between Chats and
/// Calls, with a compose FAB.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  int _index = 0;

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
    // The bottom bar lives in the shell above every route, so the tab it
    // chooses arrives from there rather than from a callback here.
    ShellTabs.index.addListener(_followShell);
    ShellTabs.onSelected = _onSelectTab;
    // The shell's bar outlives any one home screen, so a fresh one starts on
    // the tab this screen is actually showing rather than whichever was last
    // chosen before signing out. After the frame, because the bar is an
    // ancestor and notifying it mid-build is not allowed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ShellTabs.index.value = _index;
    });
  }

  void _followShell() {
    if (ShellTabs.index.value != _index) _onSelectTab(ShellTabs.index.value);
  }

  @override
  void dispose() {
    ShellTabs.index.removeListener(_followShell);
    if (ShellTabs.onSelected == _onSelectTab) ShellTabs.onSelected = null;
    _tabFadeController.dispose();
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
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: const SidebarButton(),
        titleSpacing: 20,
        title: _index == 0
            ? Text(
                'OkayMessenger',
                style: TextStyle(
                  color: isDark ? Colors.white : AppColors.tealGreen,
                  fontWeight: FontWeight.bold,
                  fontSize: 22,
                ),
              )
            : Text(_titleForIndex),
        actions: [
          if (onChats) ...[
            IconButton(
              icon: const Icon(Icons.add_comment_outlined),
              tooltip: 'New chat',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NewChatScreen()),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Search',
              onPressed: () =>
                  showSearch(context: context, delegate: ChatSearchDelegate()),
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
              tooltip: 'New community',
              onPressed: () => createCommunityFlow(context),
            )
          else if (_index == 2)
            const CallsTabActions()
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
      // The sidebar and the bottom bar are the shell's now — they sit above
      // every route rather than only above these tabs, so a pushed screen
      // keeps them instead of covering them.
      //
      // Tabs keep their state in an IndexedStack; switching softly fades the
      // incoming tab in rather than hard-cutting.
      body: FadeTransition(
        opacity: _tabFade,
        child: IndexedStack(
          index: _index,
          children: const [
            ChatsTab(),
            CommunitiesTab(),
            CallsTab(),
            ActivityTab(),
            // The same profile screen everybody else gets, with the parts only
            // you can act on. There used to be a second implementation here.
            _YouTab(),
          ],
        ),
      ),
    );
  }

  void _onSelectTab(int i) {
    if (!mounted) return;
    if (i != _index) _tabFadeController.forward(from: 0);
    setState(() => _index = i);
    // Opening the Calls tab clears the missed-call badge.
    if (i == 2) CallLog.instance.markSeen();
    // Opening Notifications clears the feed mention/reply badge.
    if (i == 3) FeedStore.instance.markNotificationsSeen();
  }

  String get _titleForIndex => switch (_index) {
        1 => 'Communities',
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

/// The bottom bar. Public for the same reason as the sidebar.
class ModernNavBar extends StatelessWidget {
  final int index;
  final int missedCalls;
  final int activityCount;
  final ValueChanged<int> onSelect;

  const ModernNavBar({
    super.key,
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
/// The app's sidebar. Public because the shell above every route owns it now
/// rather than the home screen.
class AppSideBar extends StatelessWidget {
  /// Switches the home screen's bottom tab — for destinations that ARE a tab,
  /// where pushing a second copy on top would stack two of the same screen.
  final ValueChanged<int> onSelectTab;

  const AppSideBar({super.key, required this.onSelectTab});

  /// The sidebar hangs off the shell's Scaffold, which is a *parent* of the
  /// app's navigator — so `Navigator.of(context)` from a tile finds nothing.
  /// The drawer closes through its own scaffold and pushes through the key.
  void _go(BuildContext context, Widget screen) {
    AppShell.closeSidebar();
    rootNavigatorKey.currentState
        ?.push(MaterialPageRoute(builder: (_) => screen));
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
                                      color: Colors.grey.shade600)),
                            if (me.pronouns.trim().isNotEmpty)
                              Text(me.pronouns.trim(),
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: Colors.grey.shade500)),
                            ListenableBuilder(
                              listenable: FollowStore.instance,
                              builder: (context, _) => Text(
                                  '${FollowStore.instance.followingCount} '
                                  'following',
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: Colors.grey.shade500)),
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
              // The full apps that live outside the five tabs, plus the
              // destinations people kept asking where to find.
              ListTile(
                leading: const Icon(Icons.public),
                title: const Text('Newsfeed'),
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
                subtitle: const Text('Buy and sell with your servers'),
                onTap: () => _go(context, const MarketplaceScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: const Text('Servers'),
                onTap: () {
                  AppShell.closeSidebar();
                  onSelectTab(1); // the Servers tab, without stacking a copy
                },
              ),
              ListTile(
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: const Text('Wallet'),
                subtitle: const Text('Send and receive money'),
                onTap: () => _go(context, const WalletScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Settings'),
                onTap: () => _go(context, const SettingsScreen()),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
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

  const _NavPill({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? Colors.white : const Color(0xFF0F1419);
    final idle = isDark ? Colors.grey.shade500 : Colors.grey.shade600;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
        padding: EdgeInsets.symmetric(
          horizontal: selected ? 16 : 13,
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
