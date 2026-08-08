import 'package:flutter/material.dart';

/// A key on the home `Scaffold`, so a screen opened FROM the sidebar can reach
/// the sidebar again — the drawer lives only on home, and a pushed destination
/// has its own Scaffold with no drawer of its own.
final GlobalKey<ScaffoldState> homeScaffoldKey = GlobalKey<ScaffoldState>();

/// The ☰ button shown in place of the back arrow on screens opened from the
/// sidebar. Every drawer destination is pushed straight on top of home, so
/// tapping this returns to home and slides the sidebar open — you reach the
/// menu directly instead of backing out first. Only ever used on
/// sidebar-launched instances (a `fromSidebar` flag), so a screen pushed from
/// somewhere else — Wallet from a chat, say — keeps its normal back button.
class SidebarMenuButton extends StatelessWidget {
  const SidebarMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.menu),
      tooltip: 'Menu',
      onPressed: () {
        final nav = Navigator.of(context);
        if (nav.canPop()) nav.pop();
        // Open once home is the current route again. A post-frame hop keeps the
        // drawer from fighting the pop transition for the gesture arena.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          homeScaffoldKey.currentState?.openDrawer();
        });
      },
    );
  }
}
