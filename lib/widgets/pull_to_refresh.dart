import 'package:flutter/material.dart';

import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../state/cloud_sync.dart';
import '../util/haptics.dart';

/// The app's standard pull-to-refresh, so the gesture does the same thing
/// everywhere: nudge the relay back into sync, pull down anything the server
/// keeps for us, then let the screen rebuild.
///
/// Wrap a screen's scrollable in this rather than hand-rolling a
/// [RefreshIndicator] — it also forces [AlwaysScrollableScrollPhysics] on the
/// child, without which a short list can't be pulled at all.
class PullToRefresh extends StatelessWidget {
  final Widget child;

  /// Screen-specific work to run alongside the shared refresh.
  final Future<void> Function()? onRefresh;

  const PullToRefresh({super.key, required this.child, this.onRefresh});

  /// An empty state that can still be pulled. A screen with nothing to show
  /// is exactly when someone reaches for refresh, so the placeholder goes
  /// inside a scrollable rather than replacing the list outright.
  static Widget emptyState({
    required Widget child,
    Future<void> Function()? onRefresh,
  }) {
    return PullToRefresh(
      onRefresh: onRefresh,
      child: LayoutBuilder(
        builder: (context, constraints) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(child: child),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () => refreshApp(extra: onRefresh),
      child: _alwaysScrollable(child),
    );
  }

  /// Re-applies scroll physics so even a list that doesn't fill the screen can
  /// be pulled down. A scrollable that set its own physics is left alone.
  static Widget _alwaysScrollable(Widget child) {
    const physics = AlwaysScrollableScrollPhysics();
    final unset = (child is ScrollView && child.physics == null) ||
        (child is SingleChildScrollView && child.physics == null);
    return unset ? _WithPhysics(physics: physics, child: child) : child;
  }

  /// Runs the shared refresh: a relay resync plus a pull of the server-kept
  /// state, with [extra] for whatever the screen itself needs. The spinner is
  /// held briefly so a fast refresh still reads as having happened.
  static Future<void> refreshApp({Future<void> Function()? extra}) async {
    // The pull crossed the trigger point — say so under the finger.
    Haptics.tap();
    final started = DateTime.now();
    if (RelayConfig.isEnabled) {
      try {
        await RelayService.instance.resync();
      } catch (_) {}
      // Communities and the Okay Score live on the server (encrypted); pull
      // down whatever another device has pushed since we last looked.
      await CloudSync.instance.refreshFromServer();
    }
    if (extra != null) {
      try {
        await extra();
      } catch (_) {}
    }
    final elapsed = DateTime.now().difference(started);
    const minimum = Duration(milliseconds: 650);
    if (elapsed < minimum) await Future<void>.delayed(minimum - elapsed);
  }
}

/// Applies [physics] to a descendant scrollable that didn't set its own.
class _WithPhysics extends StatelessWidget {
  final ScrollPhysics physics;
  final Widget child;
  const _WithPhysics({required this.physics, required this.child});

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: _AlwaysScrollableBehavior(physics),
      child: child,
    );
  }
}

class _AlwaysScrollableBehavior extends ScrollBehavior {
  final ScrollPhysics _physics;
  const _AlwaysScrollableBehavior(this._physics);

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      _physics.applyTo(super.getScrollPhysics(context));
}
