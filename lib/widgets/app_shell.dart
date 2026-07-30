import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models/user.dart';
import '../state/session.dart';

/// Lets non-widget code (incoming default-messenger links) navigate — and the
/// shell's own sidebar, which sits *above* the navigator and so has none of it
/// in scope: `Navigator.of` from a drawer tile finds nothing and asserts.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Which bottom tab the app is on.
///
/// Lifted out of the home screen because the bottom bar lives above every
/// route now, not only above the tabs — so the bar and the tabs are two widgets
/// in different places that have to agree on one number.
class ShellTabs {
  ShellTabs._();

  static final ValueNotifier<int> index = ValueNotifier<int>(0);

  /// Set when a tab is chosen, so the home screen can react to a change it did
  /// not make itself (clearing a badge, fading the incoming tab).
  static void Function(int index)? onSelected;

  static void select(int i) {
    index.value = i;
    onSelected?.call(i);
  }
}

/// Counts the dialogs and modal sheets currently on the navigator.
///
/// A sheet or a dialog is a layer over the page, not another page — it owns
/// the screen for as long as it is up, and its barrier already blocks the rest
/// of the app. The shell steps aside for one: the bar would otherwise paint
/// across the sheet's own buttons and take their taps, and the bottom padding
/// the shell hands the pages would push the sheet's content out of its box.
///
/// Per-instance rather than static on purpose. A static counter survives a
/// navigator being thrown away without its routes being popped — which is
/// exactly how a widget test ends — and the leftover would leave the next one
/// with no bar at all.
class ShellModals extends NavigatorObserver {
  final ValueNotifier<int> depth = ValueNotifier<int>(0);

  /// The popups being counted. A set rather than a bare tally so a route can
  /// never be counted twice or released twice, whichever way it leaves.
  final Set<Route<dynamic>> _open = <Route<dynamic>>{};

  void _add(Route<dynamic>? route) {
    if (route is! PopupRoute) return;
    if (_open.add(route)) depth.value++;
  }

  void _release(Route<dynamic>? route) {
    if (route == null) return;
    if (_open.remove(route)) depth.value--;
  }

  /// A popped sheet is still on screen — it animates out over ~200ms, and it
  /// is still laying itself out the whole way. Releasing it at `didPop` gave
  /// the padding back while the sheet was mid-flight, and a sheet built for
  /// the full height suddenly had 72 fewer pixels: the chat actions sheet
  /// overflowed by exactly that on the way out. So the count holds until the
  /// route's own animation says it is gone.
  void _releaseWhenGone(PopupRoute<dynamic> route) {
    final animation = route.animation;
    if (animation == null || animation.status == AnimationStatus.dismissed) {
      _release(route);
      return;
    }
    void listener(AnimationStatus status) {
      if (status != AnimationStatus.dismissed) return;
      animation.removeStatusListener(listener);
      _release(route);
    }

    animation.addStatusListener(listener);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) _releaseWhenGone(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _release(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _release(oldRoute);
    _add(newRoute);
  }
}

/// The frame every screen sits in: the sidebar and the bottom bar.
///
/// WHY THIS EXISTS. The sidebar and the bottom bar used to belong to the home
/// screen's Scaffold, so anything pushed on top of it covered them — and the
/// only way back was the arrow in the corner. A pushed screen was a dead end
/// with one exit. Wrapping the navigator instead means the bar and the sidebar
/// are always there, on every screen, and the arrow is not the way out any
/// more: the destinations are.
///
/// The bar and the drawer are supplied by the caller (the home screen owns what
/// they contain), so this holds the arrangement and nothing about the contents.
class AppShell extends StatefulWidget {
  /// The app's navigator — every route in the app renders in here.
  final Widget child;

  final Widget drawer;
  final Widget Function(BuildContext context) bottomBar;

  /// How many dialogs or sheets are up; the shell hides while any are.
  final ValueListenable<int> modalDepth;

  const AppShell({
    super.key,
    required this.child,
    required this.drawer,
    required this.bottomBar,
    required this.modalDepth,
  });

  /// The shell's own scaffold, so a screen's app bar can open the sidebar. A
  /// route has its own Scaffold with no drawer in it, so Scaffold.of would find
  /// the wrong one and assert.
  static final GlobalKey<ScaffoldState> scaffoldKey =
      GlobalKey<ScaffoldState>();

  static void openSidebar() => scaffoldKey.currentState?.openDrawer();

  static void closeSidebar() => scaffoldKey.currentState?.closeDrawer();

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// Measured, not assumed. The bar's height depends on the device's home
  /// indicator and on the pill labels, so a constant here would drift the
  /// first time either changed — and the drift is invisible until something
  /// at the bottom of a screen stops taking taps.
  double _barHeight = 0;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppUser?>(
        // Signed in is exactly the span where these destinations exist, and it
        // is a fact the app already keeps. A hand-toggled flag was tried first
        // and was worse than wrong: the home screen turned it off from dispose
        // via a post-frame callback, and after a screen closed that callback
        // landed on whatever was on screen next, taking the bar with it.
        valueListenable: Session.instance.user,
        builder: (context, user, _) => ValueListenableBuilder<int>(
          valueListenable: widget.modalDepth,
          builder: (context, modals, _) =>
              _frame(context, on: user != null && modals == 0),
        ),
      );

  Widget _frame(BuildContext context, {required bool on}) {
    final media = MediaQuery.of(context);
    return Scaffold(
      key: AppShell.scaffoldKey,
      drawer: on ? widget.drawer : null,
      // OVERLAID, not reserved. As `bottomNavigationBar` the Scaffold would lay
      // every route out above the bar and the bar would stop being glass — the
      // whole point of it is the content sliding under.
      //
      // But overlaying alone hides whatever is at the bottom of a screen *and
      // eats its taps*: the send button in the forward picker sat under the bar
      // and the tap landed on the bar. So the routes below are told about the
      // bar the way Scaffold tells a body about `extendBody: true` — as bottom
      // padding — and every screen that already respects the safe area clears
      // it for free.
      body: Stack(
        children: [
          MediaQuery(
            data: on
                ? media.copyWith(
                    // The bar's own layout already swallows the home indicator,
                    // so this replaces that inset rather than stacking on it.
                    padding: media.padding.copyWith(bottom: _barHeight),
                    // viewPadding as well as padding: SafeArea reads `padding`,
                    // but Scaffold places a floating action button off
                    // `viewPadding`, and the send button in the forward picker
                    // is one. With only the first set it stayed under the bar
                    // and the bar took its taps.
                    viewPadding:
                        media.viewPadding.copyWith(bottom: _barHeight),
                  )
                : media,
            child: widget.child,
          ),
          if (on)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _MeasureHeight(
                onHeight: (h) {
                  if (h == _barHeight) return;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _barHeight = h);
                  });
                },
                child: widget.bottomBar(context),
              ),
            ),
        ],
      ),
    );
  }
}

/// Reports its child's laid-out height. Used so the shell can pad the routes
/// underneath by exactly what the floating bar covers.
class _MeasureHeight extends SingleChildRenderObjectWidget {
  final ValueChanged<double> onHeight;

  const _MeasureHeight({required this.onHeight, required Widget child})
      : super(child: child);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureHeight(onHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasureHeight r) =>
      r.onHeight = onHeight;
}

class _RenderMeasureHeight extends RenderProxyBox {
  ValueChanged<double> onHeight;

  _RenderMeasureHeight(this.onHeight);

  @override
  void performLayout() {
    super.performLayout();
    onHeight(size.height);
  }
}

/// The button in the top-left of every screen: the sidebar, not a back arrow.
///
/// One widget so "the leading slot is always the sidebar" is a rule with one
/// implementation rather than a habit repeated 75 times.
class SidebarButton extends StatelessWidget {
  const SidebarButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        icon: const Icon(Icons.menu),
        // The same tooltip Scaffold gives its own drawer button, because this
        // is the same button — it just lives in a different Scaffold.
        tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
        onPressed: AppShell.openSidebar,
      );
}
