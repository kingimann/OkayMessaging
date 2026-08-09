import 'package:flutter/material.dart';

/// A key on the home `Scaffold`, so screens hosted INSIDE it (the bottom
/// tabs) can reach its drawer. The old `SidebarMenuButton` (a ☰ on pushed
/// sidebar destinations) is gone — the owner's call: a pushed screen goes
/// back with the normal back arrow. This is different: [HomeDrawerButton]
/// lives on TABS, where the drawer is already present on the enclosing home
/// Scaffold and opening it navigates nowhere.
final GlobalKey<ScaffoldState> homeScaffoldKey = GlobalKey<ScaffoldState>();

/// The ☰ on the Newsfeed and Okay AI TABS. Those two bring their own app bars
/// (home's is hidden while they show), which would otherwise lose the drawer
/// hamburger — this one opens home's drawer in place, over the current tab.
class HomeDrawerButton extends StatelessWidget {
  const HomeDrawerButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.menu),
      tooltip: 'Open navigation menu',
      onPressed: () => homeScaffoldKey.currentState?.openDrawer(),
    );
  }
}
