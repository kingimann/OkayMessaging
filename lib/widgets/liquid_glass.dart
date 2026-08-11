import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// The app's Liquid Glass surface — Apple's iOS 26 material.
///
/// One widget, because the bottom bar and the chat composer are the two
/// pieces of chrome that FLOAT over content, and two hand-tuned imitations
/// of one material is exactly how they drift apart.
///
/// **The first attempt was frosted plastic and this is the correction.** It
/// blurred the backdrop and laid a 45%-opaque tint over it, which is a slab
/// you cannot see through; a white gradient on top of a slab is a slab with
/// a gradient on it. Real glass is defined by four things, and the tint is
/// the least important of them:
///
///  1. **You can see through it.** The tint is now ~16% (dark) / ~22%
///     (light) — it colours the backdrop rather than replacing it.
///  2. **It makes what is behind it more vivid, not greyer.** Apple's
///     materials boost saturation and lift the blacks. That is done here in
///     the backdrop filter itself ([_vibrance]), composed with the blur, so
///     content under the panel reads as *seen through* something rather than
///     as *hidden behind* something.
///  3. **The edge BENDS what is behind it** — the signature. A pane that
///     only blurs has no thickness; a lens squeezes straight lines as they
///     pass under the rim. That needs a fragment shader
///     (`assets/shaders/liquid_glass.frag`) and Impeller, so it is used when
///     available and skipped cleanly when not.
///  4. **The rim catches light unevenly** — bright where it faces the light,
///     a weaker bead opposite, dark in between. A rim that glows evenly all
///     the way round is a drawn outline, which is what the first attempt
///     had.
///
/// **Off Impeller (web, and any platform where the shader will not load) it
/// degrades to blur + vibrance + tint**, which is the honest fallback: less
/// glassy, never broken.
class LiquidGlass extends StatefulWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.radius = 30,
    this.blur = 24,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final double radius;

  /// Sigma of the backdrop blur. Lower than you would expect on purpose:
  /// the vibrance and the lensing carry the material now, and a heavy blur
  /// erases the very content the transparency exists to show.
  final double blur;
  final EdgeInsetsGeometry padding;

  /// How much of the backdrop the tint replaces. It COLOURS what is behind;
  /// it does not stand in for it.
  static double tintAlpha(bool isDark) => isDark ? 0.16 : 0.22;

  /// The stand-in where a live backdrop filter is too expensive (web:
  /// CanvasKit re-reads and blurs the whole scene every frame).
  static double flatAlpha(bool isDark) => isDark ? 0.92 : 0.94;

  /// How far in from the rim the lens bends, in logical pixels.
  static const double edgeBand = 14;

  /// How hard it bends, in pixels of sample displacement at the rim.
  static const double refraction = 9;

  /// Saturation multiplier applied to the backdrop. >1 is the whole point:
  /// a blur alone desaturates, and desaturated-behind-a-panel is what makes
  /// frosted plastic look like frosted plastic.
  static const double saturation = 1.7;

  /// A saturation matrix, plus a small lift so blacks under the pane do not
  /// crush to a flat void.
  static ColorFilter vibrance({required bool isDark}) {
    const s = saturation;
    // Rec. 709 luminance, the standard weights.
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final lift = isDark ? 14.0 : 6.0;
    return ColorFilter.matrix(<double>[
      (1 - s) * lr + s, (1 - s) * lg, (1 - s) * lb, 0, lift, //
      (1 - s) * lr, (1 - s) * lg + s, (1 - s) * lb, 0, lift, //
      (1 - s) * lr, (1 - s) * lg, (1 - s) * lb + s, 0, lift, //
      0, 0, 0, 1, 0, //
    ]);
  }

  /// Whether the refraction shader has been loaded. False on web, and false
  /// until the first load finishes.
  static bool get shaderReady => _LiquidGlassState._program != null;

  @visibleForTesting
  static void resetShaderForTest() {
    _LiquidGlassState._program = null;
    _LiquidGlassState._tried = false;
  }

  @override
  State<LiquidGlass> createState() => _LiquidGlassState();
}

class _LiquidGlassState extends State<LiquidGlass> {
  static ui.FragmentProgram? _program;
  static bool _tried = false;

  @override
  void initState() {
    super.initState();
    _loadShader();
  }

  /// Loads once for the whole app. Failure is not an error path anybody
  /// needs to hear about — the widget simply keeps the blur-only look.
  Future<void> _loadShader() async {
    if (_tried || kIsWeb) return;
    _tried = true;
    try {
      final p = await ui.FragmentProgram.fromAsset(
          'assets/shaders/liquid_glass.frag');
      if (!mounted) {
        _program = p;
        return;
      }
      setState(() => _program = p);
    } on Object catch (e) {
      // Impeller off, an older engine, a shader that did not compile — all
      // the same answer here.
      FlutterError.reportError(FlutterErrorDetails(
        exception: e,
        library: 'liquid_glass',
        context: ErrorDescription('loading the Liquid Glass shader; the '
            'panel falls back to blur without refraction'),
        silent: true,
      ));
    }
  }

  /// The backdrop filter: blur, then vibrance, then — when the shader is
  /// there — the lens on top of both, so it refracts an already-treated
  /// image rather than the raw scene.
  ui.ImageFilter? _backdrop(bool isDark) {
    if (kIsWeb) return null;
    final treated = ui.ImageFilter.compose(
      outer: LiquidGlass.vibrance(isDark: isDark),
      inner: ui.ImageFilter.blur(sigmaX: widget.blur, sigmaY: widget.blur),
    );
    final program = _program;
    if (program == null) return treated;
    try {
      final shader = program.fragmentShader();
      // The shader works in the bound texture's own pixels, which are
      // PHYSICAL, so every length crossing this boundary is scaled.
      final dpr = MediaQuery.devicePixelRatioOf(context);
      // Indices 0 and 1 are uSize and are DELIBERATELY not set here: the
      // engine writes the bound texture's size into the first vec2 itself.
      // Setting them would be writing over the one thing the shader can
      // trust — and asking the widget for its size does not work anyway,
      // because a bottomNavigationBar is laid out with an unbounded height.
      shader
        ..setFloat(2, widget.radius * dpr)
        ..setFloat(3, LiquidGlass.edgeBand * dpr)
        ..setFloat(4, LiquidGlass.refraction * dpr)
        ..setFloat(5, isDark ? 0.55 : 0.85)
        ..setFloat(6, isDark ? 0.0 : 1.0);
      return ui.ImageFilter.compose(
        outer: ui.ImageFilter.shader(shader),
        inner: treated,
      );
    } on Object {
      // ImageFilter.shader throws outright without Impeller.
      _program = null;
      return treated;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? const Color(0xFF0E1116) : Colors.white;
    final tint = base.withValues(
        alpha: kIsWeb
            ? LiquidGlass.flatAlpha(isDark)
            : LiquidGlass.tintAlpha(isDark));

    final filter = _backdrop(isDark);
    final pane = DecoratedBox(
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(widget.radius),
        // A whisper of a sheen, and only across the top third. The first
        // attempt ran a white wash over the whole pane, which is what
        // made it read as paper.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: isDark ? 0.07 : 0.16),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.35],
        ),
      ),
      child: Padding(padding: widget.padding, child: widget.child),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.34 : 0.12),
            blurRadius: 24,
            spreadRadius: -4,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(widget.radius),
            child: filter == null
                ? pane
                : BackdropFilter(filter: filter, child: pane),
          ),
          // The rim, painted OUTSIDE the backdrop filter — a blurred edge
          // is what makes a glass panel look like a smudge.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _SpecularRim(radius: widget.radius, isDark: isDark),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The lit rim: bright where the edge faces the light, a weaker bead
/// opposite it, and nearly nothing in between.
///
/// A [SweepGradient] rather than a flat [Border] because that difference IS
/// the effect. One colour all the way round is an outline; light falling on
/// a curved bead is not, and the eye knows which it is looking at even when
/// it cannot say why.
class _SpecularRim extends CustomPainter {
  const _SpecularRim({required this.radius, required this.isDark});

  final double radius;
  final bool isDark;

  /// Where the light is, as a fraction of the way round from 3 o'clock.
  /// 0.625 puts it at the upper left, matching the shader's light vector —
  /// if these two disagree the highlight and the refraction fight.
  static const double lightTurn = 0.625;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect =
        RRect.fromRectAndRadius(rect.deflate(0.5), Radius.circular(radius));
    final hi = isDark ? 0.42 : 0.95;
    final lo = isDark ? 0.04 : 0.10;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..shader = SweepGradient(
        // Turned so the bright stop lands on the upper-left curve.
        transform: const GradientRotation(lightTurn * 2 * math.pi),
        colors: [
          Colors.white.withValues(alpha: hi),
          Colors.white.withValues(alpha: lo),
          // The second, weaker bead opposite the light.
          Colors.white.withValues(alpha: hi * 0.45),
          Colors.white.withValues(alpha: lo),
          Colors.white.withValues(alpha: hi),
        ],
        stops: const [0.0, 0.25, 0.5, 0.75, 1.0],
      ).createShader(rect);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_SpecularRim old) =>
      old.radius != radius || old.isDark != isDark;
}
