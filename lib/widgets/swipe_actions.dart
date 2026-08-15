import 'package:flutter/material.dart';

import '../util/haptics.dart';

/// One side of a row's swipe.
///
/// [dismisses] is the whole distinction, and it is about what the action DOES
/// rather than how far the finger went. An action that takes the row out of
/// the list it is in — archiving from the inbox, unarchiving from the
/// archive — lets the row fly away, because the row really is leaving. An
/// action that changes something ABOUT the row — read, unread, pin, mute —
/// snaps back, because the row is still there and animating it off screen
/// would say otherwise.
class SwipeAction {
  final IconData icon;

  /// Shown beside the glyph once the swipe is far enough along to mean
  /// something. Modern swipe rows label the action rather than leaving
  /// somebody to recognise a glyph mid-gesture.
  final String label;
  final Color colour;
  final VoidCallback onAct;
  final bool dismisses;

  const SwipeAction({
    required this.icon,
    required this.label,
    required this.colour,
    required this.onAct,
    this.dismisses = false,
  });
}

/// A list row you can swipe either way, the shape every messaging app has.
///
/// Built on `Dismissible` rather than a package: the two behaviours needed —
/// fly away, or act and snap back — are `confirmDismiss` returning true or
/// false, which this codebase already leans on for swipe-to-reply in
/// `chat_screen.dart` ("snap back; we only use the swipe to trigger reply").
/// A second gesture library beside the one already in use is how two swipes
/// in one app end up feeling different.
///
/// Either side may be null, and with both null the row is returned untouched
/// rather than wrapped in a Dismissible that can only refuse — a gesture that
/// starts and goes nowhere is worse than no gesture.
class SwipeActions extends StatelessWidget {
  const SwipeActions({
    super.key,
    required this.itemKey,
    required this.child,
    this.onSwipeRight,
    this.onSwipeLeft,
  });

  /// Stable per row. A Dismissible in a list needs one, and it must be the
  /// ROW's identity rather than its index — otherwise the row that slides up
  /// into a dismissed slot inherits its half-finished animation.
  final Key itemKey;
  final Widget child;

  /// Revealed by dragging the row to the RIGHT (`startToEnd`), so its
  /// background sits on the left.
  final SwipeAction? onSwipeRight;

  /// Revealed by dragging the row to the LEFT (`endToStart`).
  final SwipeAction? onSwipeLeft;

  /// How far a NON-dismissing action has to be dragged before it fires.
  ///
  /// Lower than a dismissing one on purpose: snapping back costs a mistaken
  /// swipe one tap to undo, while letting a row fly out of the list on a
  /// half-gesture is the thing people complain about. So a reversible action
  /// is easy to reach and a destructive one has to be meant.
  static const double actThreshold = 0.28;
  static const double dismissThreshold = 0.45;

  Widget _background(BuildContext context, SwipeAction action, bool left) {
    return Container(
      color: action.colour,
      alignment: left ? Alignment.centerLeft : Alignment.centerRight,
      padding: EdgeInsets.only(left: left ? 22 : 0, right: left ? 0 : 22),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Always icon-then-label reading order, on both sides: the glyph is
          // the thing recognised first, and it belongs nearest the edge the
          // finger came from.
          if (left) ...[
            Icon(action.icon, color: Colors.white, size: 21),
            const SizedBox(width: 10),
            Text(action.label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600)),
          ] else ...[
            Text(action.label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 10),
            Icon(action.icon, color: Colors.white, size: 21),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final right = onSwipeRight;
    final left = onSwipeLeft;
    if (right == null && left == null) return child;

    final DismissDirection direction;
    if (right != null && left != null) {
      direction = DismissDirection.horizontal;
    } else if (right != null) {
      direction = DismissDirection.startToEnd;
    } else {
      direction = DismissDirection.endToStart;
    }

    double thresholdFor(SwipeAction? a) =>
        a == null ? 1.0 : (a.dismisses ? dismissThreshold : actThreshold);

    return Dismissible(
      key: itemKey,
      direction: direction,
      dismissThresholds: {
        DismissDirection.startToEnd: thresholdFor(right),
        DismissDirection.endToStart: thresholdFor(left),
      },
      background: right == null
          ? const SizedBox.shrink()
          : _background(context, right, true),
      secondaryBackground: left == null
          ? const SizedBox.shrink()
          : _background(context, left, false),
      confirmDismiss: (d) async {
        final action = d == DismissDirection.startToEnd ? right : left;
        if (action == null) return false;
        // The action lands under the thumb as well as on screen — the same
        // rule a like already follows. It fires here rather than in
        // onDismissed so a snap-back action is felt too.
        Haptics.tap();
        action.onAct();
        return action.dismisses;
      },
      // Everything already happened in confirmDismiss; this exists only
      // because Dismissible requires a handler once a dismiss can succeed.
      onDismissed: (_) {},
      child: child,
    );
  }
}
