import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// The app's Liquid Glass surface — Apple's iOS 26 material, as closely as
/// Flutter can draw it.
///
/// One widget, because the bottom bar and the chat composer are the two
/// pieces of chrome that FLOAT over content, and two hand-tuned imitations
/// of the same material is exactly how they drift apart.
///
/// What makes it read as glass rather than as a translucent rectangle, in
/// the order the layers are painted:
///
///  1. **A real backdrop blur.** Frosting without a blur is just a tint.
///  2. **A low-alpha tint** over it, so what is behind still shows through.
///  3. **A specular sheen** — a top-to-bottom highlight gradient. This is
///     the layer people actually read as "glass": a flat translucent panel
///     looks like paper, and light catching a curved edge does not.
///  4. **A bright hairline rim**, brighter at the top than the bottom, the
///     way a lit edge is.
///  5. **A soft drop shadow** underneath, so it sits ABOVE the content
///     rather than being a hole cut in it.
///
/// **The blur is dropped on web.** A live backdrop blur makes CanvasKit
/// re-read and blur the whole scene every frame, which turns scrolling into
/// a slideshow; there the tint goes nearly opaque instead. Same look, none
/// of the per-frame cost — the trade the bottom bar already made.
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.radius = 30,
    this.blur = 30,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final double radius;

  /// Sigma of the backdrop blur. Higher reads as thicker glass.
  final double blur;
  final EdgeInsetsGeometry padding;

  /// How much of the backdrop shows through. Deliberately low — the point of
  /// the material is that you can see what is under it.
  static double tintAlpha(bool isDark) => isDark ? 0.44 : 0.52;

  /// The nearly-opaque stand-in used where a live blur is too expensive.
  static double flatAlpha(bool isDark) => isDark ? 0.94 : 0.96;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? const Color(0xFF1C1F24) : Colors.white;
    final tint = base.withValues(
        alpha: kIsWeb ? flatAlpha(isDark) : tintAlpha(isDark));
    // The lit edge: brighter along the top, fading round the bottom. A rim
    // of one flat colour reads as a border; this reads as an edge.
    final rimTop = (isDark ? Colors.white : Colors.white)
        .withValues(alpha: isDark ? 0.22 : 0.75);
    final rimBottom = (isDark ? Colors.white : Colors.black)
        .withValues(alpha: isDark ? 0.06 : 0.06);

    final pane = DecoratedBox(
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(radius),
        // Layer 3: the sheen. Light collects at the top of a curved pane and
        // falls away underneath, so the stops are not symmetric.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: isDark ? 0.10 : 0.28),
            Colors.white.withValues(alpha: isDark ? 0.02 : 0.06),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
      ),
      child: Padding(padding: padding, child: child),
    );

    return DecoratedBox(
      // Layer 5, painted first so it sits under everything else.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.40 : 0.14),
            blurRadius: 26,
            spreadRadius: -2,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: kIsWeb
                ? pane
                : BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                    child: pane,
                  ),
          ),
          // Layer 4, painted last so the rim is never blurred by its own
          // backdrop filter — a blurred edge is the thing that makes a glass
          // panel look like a smudge.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  border: GradientBoxBorder(
                    top: rimTop,
                    bottom: rimBottom,
                    radius: radius,
                  ).asBorder,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A top-lit rim. Flutter's [Border] takes one colour per side, so the
/// gradient is faked the only way that keeps the corners round: a single
/// hairline whose colour is the average of the two, over a top-edge
/// highlight drawn as part of the sheen above.
///
/// Kept as a named thing rather than an inline expression because getting
/// this wrong (a hard 1px white box) is what makes glass look like plastic.
class GradientBoxBorder {
  const GradientBoxBorder({
    required this.top,
    required this.bottom,
    required this.radius,
  });

  final Color top;
  final Color bottom;
  final double radius;

  /// The hairline actually drawn. 0.8 rather than 1: a full logical pixel
  /// reads as a drawn outline on a 3x screen, and a rim should be light
  /// catching an edge.
  Border get asBorder => Border.all(
        color: Color.lerp(top, bottom, 0.45) ?? top,
        width: 0.8,
      );
}
