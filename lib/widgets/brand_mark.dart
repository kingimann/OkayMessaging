import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The app's speech-bubble mark, drawn as CHROME rather than as the icon tile.
///
/// `assets/icon/icon.png` is a home-screen icon: a white bubble on a
/// near-black rounded square. Dropped into an app bar it reads as a sticker,
/// because neither bar matches that square — light is `#FFFFFF` and dark is
/// `#23262B`, while the tile is `#101820`. Rounding the corners did not help;
/// the square was the problem.
///
/// So the tile is removed rather than disguised. The PNG is used as a
/// LUMINANCE MASK — the bright bubble becomes opaque, the dark tile and the
/// three dots inside it become fully transparent — and what is left is filled
/// with the bar's own foreground colour. The result is the real mark (not a
/// hand-redrawn approximation that would drift from the app icon) sitting in
/// the app bar like every other glyph beside it.
///
/// The matrix is the whole trick and is worth reading rather than trusting:
///
///  * the R, G and B rows are constants — every surviving pixel is [color];
///  * the A row is `gain × luminance − bias`, clamped by the filter itself.
///
/// Plain luminance alone would leave the tile at about 8% alpha — a faint
/// grey ghost of the square, which is exactly what this exists to remove. The
/// gain and bias push that below zero while leaving white comfortably over
/// 255, so the tile is gone rather than nearly gone.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 34, this.color, this.opacity = 1});

  /// Edge length of the (square) mark.
  final double size;

  /// What the bubble is filled with. Defaults to the app-bar ink, which is
  /// what makes it sit with the actions beside it instead of on top of them.
  final Color? color;

  /// Lets a caller hold it back from full strength. The mark names the app
  /// you are already inside, so it does not need to shout.
  final double opacity;

  // Rec. 709 luminance, the coefficients Flutter's own greyscale examples use.
  static const double lumR = 0.2126;
  static const double lumG = 0.7152;
  static const double lumB = 0.0722;

  /// Steepens the ramp so mid-greys resolve one way or the other instead of
  /// leaving a soft halo around the bubble's edge.
  static const double gain = 1.6;

  /// Subtracted after the gain: anything darker than roughly 15% grey lands
  /// below zero and is clipped to fully transparent. The tile (`#101820`,
  /// about 9% luminance) is well under it; the bubble is white and well over.
  static const double bias = 60;

  /// The alpha this mask gives a source pixel, before clamping — the pure
  /// arithmetic, so a test can check it against the real asset's own pixels
  /// rather than against a screenshot nobody can take from here.
  static double alphaFor(int r, int g, int b) =>
      gain * (lumR * r + lumG * g + lumB * b) - bias;

  /// The filter itself: constant colour, alpha from source luminance.
  static ColorFilter filterFor(Color color) => ColorFilter.matrix(<double>[
        0, 0, 0, 0, (color.r * 255).roundToDouble(), //
        0, 0, 0, 0, (color.g * 255).roundToDouble(), //
        0, 0, 0, 0, (color.b * 255).roundToDouble(), //
        gain * lumR, gain * lumG, gain * lumB, 0, -bias, //
      ]);

  @override
  Widget build(BuildContext context) {
    final ink = color ??
        Theme.of(context).appBarTheme.foregroundColor ??
        AppColors.accentOn(context);
    return Opacity(
      opacity: opacity,
      child: ColorFiltered(
        colorFilter: filterFor(ink),
        child: Image.asset('assets/icon/icon.png',
            width: size, height: size, filterQuality: FilterQuality.medium),
      ),
    );
  }
}
