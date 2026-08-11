import 'package:flutter/material.dart';

import '../app_state.dart';
import 'user_avatar.dart';

/// A key on the home `Scaffold`, so screens hosted INSIDE it (the bottom
/// tabs) can reach its drawer. The old `SidebarMenuButton` (a ☰ on pushed
/// sidebar destinations) is gone — the owner's call: a pushed screen goes
/// back with the normal back arrow. This is different: [HomeDrawerButton]
/// lives on TABS, where the drawer is already present on the enclosing home
/// Scaffold and opening it navigates nowhere.
final GlobalKey<ScaffoldState> homeScaffoldKey = GlobalKey<ScaffoldState>();

/// What opens the sidebar, on every tab: **your own profile picture**, not a
/// ☰ (the owner's call — X's shape).
///
/// It draws the same [UserAvatar] the drawer's profile card does, off the one
/// [AppState.profile] notifier, so changing your photo changes this in the
/// same frame rather than on the next launch. Whatever the avatar is — a
/// photo, an emoji, a gradient of initials — is what shows, because that is
/// what the rest of the app already draws for you.
///
/// It is the same button it was: a tap opens home's drawer IN PLACE over the
/// current tab. Only the glyph changed, so the tooltip still names the action
/// rather than the picture — a screen reader announcing "your photo" would
/// not tell anybody what tapping does.
class HomeDrawerButton extends StatelessWidget {
  const HomeDrawerButton({super.key});

  /// The avatar's radius. Small enough to sit in an app bar's 40pt leading
  /// slot with the standard touch target still around it.
  static const double radius = 15;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: AppState.profile,
      builder: (context, me, _) => IconButton(
        tooltip: 'Open navigation menu',
        // The picture is the whole button, so the default icon padding would
        // leave it floating in the middle of a large tap target.
        padding: EdgeInsets.zero,
        icon: UserAvatar(user: me, radius: radius),
        onPressed: () => homeScaffoldKey.currentState?.openDrawer(),
      ),
    );
  }
}
