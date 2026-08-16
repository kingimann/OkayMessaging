import 'dart:convert';

import 'package:avatar_maker/avatar_maker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// A face somebody BUILT — the thing people mean when they ask for Snapchat
/// avatars: pick a nose, a hairstyle, a jacket, and that cartoon is you
/// everywhere in the app.
///
/// **The SELECTION travels, never the drawing.** What is stored on the
/// profile and shared with contacts is a small JSON string naming which nose,
/// which hair, which colours — a couple of hundred bytes. The SVG it draws is
/// kilobytes, and the profile bundle rides along with messages, so sending
/// the picture would put a drawing on the wire over and over for something
/// the other device can redraw exactly from the recipe. It also means a
/// changed avatar is a changed string, which the existing profile share
/// already knows how to carry.
///
/// **Nothing here is fetched.** The parts are SVG vectors compiled into the
/// app (`avatar_maker`, MIT), so a face draws with no network at all — the
/// same rule the generated Multiavatar it sits beside already follows, and
/// the reason a hosted avatar service was refused: one would mean a third
/// party learning who has which face and being asked for a picture every time
/// a chat list scrolled past it.
class AvatarFace {
  AvatarFace._();

  /// The parts of a selection that survive a round trip, and the whole
  /// reason this list exists.
  ///
  /// **The package's own encode and decode disagree.** `getJsonOptionsSync`
  /// writes `AvatarBackground`, `AvatarEffect` and `AvatarEffectColor` —
  /// its decorative effect layer — with labels its own decoder then cannot
  /// find, so feeding its output straight back throws `Bad state: No
  /// element` and the face fails to draw at all. Proven by round-tripping
  /// each key on its own. Dropping those three costs the effect layer and
  /// keeps the person: hair, eyes, brows, nose, mouth, skin, outfit,
  /// accessory and background all survive.
  ///
  /// It doubles as the guard on what arrives from another device: a
  /// selection is a string somebody else's app wrote, and only these keys
  /// are ever read out of it.
  static const Set<String> faceKeys = {
    'HairStyle',
    'HairColor',
    'FacialHairType',
    'FacialHairColor',
    'EyeType',
    'EyebrowType',
    'Nose',
    'MouthType',
    'SkinColor',
    'OutfitType',
    'OutfitColor',
    'Accessory',
    'Background',
  };

  /// A ceiling on what may be stored or accepted from the wire. The real
  /// selection is ~300 bytes; this is the guard that stops a malformed or
  /// hostile profile from carrying something enormous, since this string is
  /// broadcast to every contact.
  static const int maxLength = 1500;

  /// Rendered SVG per selection string. A chat list draws the same handful of
  /// faces over and over, and redrawing from the recipe each time is wasted
  /// work — the answer is deterministic, so it can be kept.
  static final Map<String, String> _svg = {};

  /// One controller, reused. Building one merges the whole property-category
  /// table, which is not something to do per avatar per frame; it holds no
  /// state between calls that matters here, because every call sets the
  /// selection it is about to draw.
  ///
  /// Held as the FUTURE of a ready one, because the constructor kicks off an
  /// async `initController()` it does not wait for, and that init ends by
  /// reassigning `selectedOptions` — so a selection applied before it lands
  /// is silently thrown away and every face draws as the default. That is
  /// not a hypothetical: it drew Bald and Eyepatch as byte-identical SVGs
  /// until this was awaited.
  static Future<AvatarMakerController>? _ready;

  static Future<AvatarMakerController> _controller() async {
    return _ready ??= () async {
      final c = NonPersistentAvatarMakerController(
          // Named rather than left to chance: the controller looks its own
          // strings up at construction, and this decides which it gets.
          locale: const Locale('en'));
      await c.initController();
      return c;
    }();
  }

  /// Keeps only the parts that survive a round trip ([faceKeys]), so what is
  /// stored and broadcast is exactly what the far end can draw. Returns ''
  /// when there is nothing usable left.
  static String sanitize(String selection) {
    if (!looksValid(selection)) return '';
    try {
      final decoded = jsonDecode(selection);
      if (decoded is! Map) return '';
      final kept = <String, String>{
        for (final e in decoded.entries)
          if (faceKeys.contains(e.key) && e.value is String)
            '${e.key}': e.value as String,
      };
      // A selection missing a category cannot be drawn at all — the package
      // asserts every one is present — so a partial one is no face.
      if (kept.length != faceKeys.length) return '';
      return jsonEncode(kept);
    } catch (_) {
      return '';
    }
  }

  /// Whether [selection] is worth trying to draw at all — the cheap check
  /// every call site makes before reaching for the cache.
  static bool looksValid(String selection) {
    final s = selection.trim();
    return s.length > 1 && s.length <= maxLength && s.startsWith('{');
  }

  /// The drawing for [selection] if it is already in hand, else null.
  ///
  /// Separate from [render] on purpose: a widget's `build` cannot await, and
  /// a face that is already known should appear in the first frame rather
  /// than flashing initials and then swapping.
  static String? svgIfReady(String selection) => _svg[selection];

  /// Draws [selection] and remembers it. Null when the string is not a face —
  /// a profile arrives from another device, so it is never assumed good.
  static Future<String?> render(String selection) async {
    if (!looksValid(selection)) return null;
    final cached = _svg[selection];
    if (cached != null) return cached;
    try {
      final c = await _controller();
      await c.saveAvatarSVG(jsonAvatarOptions: selection);
      final svg = c.getAvatarSVGSync();
      if (svg.isEmpty) return null;
      _svg[selection] = svg;
      return svg;
    } catch (_) {
      // A selection this build cannot read — an older or newer set of parts,
      // or something that was never a face. The caller falls back to the
      // initials avatar, which is always drawable.
      return null;
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _svg.clear();
    _ready = null;
  }
}

/// Draws a built face, falling back to [fallback] until it can.
///
/// The fallback is not a placeholder for a moment — it is what a contact who
/// has never built one shows forever, and what an unreadable selection shows
/// too. So it is a real avatar (colour + initials, or the generated one),
/// never a spinner: a chat list of spinning circles would be worse than a
/// list of coloured initials.
class AvatarFaceView extends StatefulWidget {
  const AvatarFaceView({
    super.key,
    required this.selection,
    required this.size,
    required this.fallback,
  });

  final String selection;
  final double size;
  final Widget fallback;

  @override
  State<AvatarFaceView> createState() => _AvatarFaceViewState();
}

class _AvatarFaceViewState extends State<AvatarFaceView> {
  String? _svg;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AvatarFaceView old) {
    super.didUpdateWidget(old);
    if (old.selection != widget.selection) _load();
  }

  void _load() {
    // Captured, because the answer arrives later and the widget may have been
    // recycled onto a different person by then — a chat list reuses these.
    final want = widget.selection;
    // Already known: take it now, in this frame, with no rebuild at all.
    final ready = AvatarFace.svgIfReady(want);
    if (ready != null) {
      _svg = ready;
      return;
    }
    _svg = null;
    AvatarFace.render(want).then((svg) {
      if (mounted && svg != null && widget.selection == want) {
        setState(() => _svg = svg);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final svg = _svg;
    if (svg == null) return widget.fallback;
    return ClipOval(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: SvgPicture.string(svg, fit: BoxFit.cover),
      ),
    );
  }
}
