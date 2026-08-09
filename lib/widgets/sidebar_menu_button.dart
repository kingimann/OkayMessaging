import 'package:flutter/material.dart';

import '../screens/home_screen.dart';

/// A key on the home `Scaffold`, so home's own drawer can be reached by key
/// where needed. (Pushed sidebar destinations no longer open home's drawer —
/// they show their own overlay sidebar; see [SidebarMenuButton].)
final GlobalKey<ScaffoldState> homeScaffoldKey = GlobalKey<ScaffoldState>();

/// The ☰ button shown in place of the back arrow on screens opened from the
/// sidebar. Tapping it slides the sidebar in OVER the current screen — it does
/// NOT pop back to Chats first (which read as "it just took me back to chat").
/// Picking a destination navigates; dismissing keeps you where you were. Only
/// ever used on sidebar-launched instances (a `fromSidebar` flag), so a screen
/// pushed from somewhere else — Wallet from a chat, say — keeps its normal back
/// button.
class SidebarMenuButton extends StatelessWidget {
  const SidebarMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.menu),
      tooltip: 'Menu',
      onPressed: () => showSidebarOverlay(context),
    );
  }
}
