import 'dart:convert';

import 'package:avatar_maker/avatar_maker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// A colour behind the face. [AvatarFace.backdrops] is the palette.
class AvatarBackdrop {
  const AvatarBackdrop(this.id, this.label, this.colors);

  /// Stored in the selection, so it must stay stable: a saved avatar names
  /// this string, and renaming one would blank it on every device.
  final String id;
  final String label;

  /// Empty means no backdrop — the face keeps whatever is behind it.
  final List<Color> colors;

  bool get isNone => colors.isEmpty;

  /// The fill, or null when there is none to paint.
  Gradient? get gradient => colors.isEmpty
      ? null
      : LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight);
}

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

  /// A colour behind the face — the one axis of customization the package
  /// does not provide at all.
  ///
  /// Its own cosmetic system ships NO art (the three "cosmetic" categories
  /// come with zero options, because an app is expected to supply them), and
  /// what it does support is drawn as a WIDGET LAYER rather than baked into
  /// the SVG — so a background chosen there would appear in the builder and
  /// nowhere else in the app. This is ours instead: a colour pair carried in
  /// the selection under [backdropKey] and painted by [AvatarFaceView] behind
  /// the face, so it shows in every chat list, header and profile.
  ///
  /// The face itself is drawn on transparency (the package's own Background
  /// category defaults to `Transparent`), which is what leaves room for it.
  static const List<AvatarBackdrop> backdrops = [
    AvatarBackdrop('none', 'None', []),
    AvatarBackdrop('slate', 'Slate', [Color(0xFF2F343A), Color(0xFF4A5158)]),
    AvatarBackdrop('sky', 'Sky', [Color(0xFF4FC3F7), Color(0xFF1976D2)]),
    AvatarBackdrop('mint', 'Mint', [Color(0xFF6EE7B7), Color(0xFF059669)]),
    AvatarBackdrop('sun', 'Sun', [Color(0xFFFFD166), Color(0xFFF77F00)]),
    AvatarBackdrop('rose', 'Rose', [Color(0xFFFF8FA3), Color(0xFFD00000)]),
    AvatarBackdrop('grape', 'Grape', [Color(0xFFB39DDB), Color(0xFF5E35B1)]),
    AvatarBackdrop('sand', 'Sand', [Color(0xFFF2E8CF), Color(0xFFD4A373)]),
    AvatarBackdrop('ink', 'Ink', [Color(0xFF1B1F23), Color(0xFF000000)]),
  ];

  /// Where the backdrop rides in the stored selection. Ours, not the
  /// package's — [render] strips it before the package ever sees it, because
  /// its decoder throws on a key it does not know.
  static const String backdropKey = 'Backdrop';

  /// The backdrop a selection names, or the first ("None") when it names
  /// nothing this build knows.
  static AvatarBackdrop backdropOf(String selection) {
    try {
      final decoded = jsonDecode(selection);
      if (decoded is Map) {
        final id = decoded[backdropKey];
        for (final b in backdrops) {
          if (b.id == id) return b;
        }
      }
    } catch (_) {}
    return backdrops.first;
  }

  /// The same selection with a different backdrop.
  static String withBackdrop(String selection, AvatarBackdrop backdrop) {
    try {
      final decoded = jsonDecode(selection);
      if (decoded is! Map) return selection;
      final out = <String, dynamic>{
        for (final e in decoded.entries) '${e.key}': e.value,
      };
      if (backdrop.colors.isEmpty) {
        out.remove(backdropKey);
      } else {
        out[backdropKey] = backdrop.id;
      }
      return jsonEncode(out);
    } catch (_) {
      return selection;
    }
  }

  /// Categories the builder hides.
  ///
  /// The package DISPLAYS its three cosmetic categories and gives them no
  /// options at all — an app is expected to supply the art and none ships
  /// with it — so the customizer opened on sixteen tabs, three of which drew
  /// nothing whatsoever. An empty tab is worse than no tab.
  ///
  /// **Each one has to name a property list as well as being hidden**, and
  /// that is not decoration: customizing a category runs a check that its
  /// default value is one of its properties, and these three ship a default
  /// with an EMPTY property list — so merely asking for `toDisplay: false`
  /// throws `ArgumentError: The default value of a category must be in its
  /// property list` before the screen can draw. Naming the placeholder the
  /// category already defaults to satisfies it and changes nothing else.
  static List<CustomizedPropertyCategory> get hiddenCategories => [
        CustomizedPropertyCategory(
            id: PropertyCategoryIds.AvatarBackground,
            toDisplay: false,
            properties: [NoBackgroundItem()],
            defaultValue: NoBackgroundItem()),
        CustomizedPropertyCategory(
            id: PropertyCategoryIds.AvatarEffect,
            toDisplay: false,
            properties: [NoEffectItem()],
            defaultValue: NoEffectItem()),
        CustomizedPropertyCategory(
            id: PropertyCategoryIds.AvatarEffectColor,
            toDisplay: false,
            properties: [NoEffectColorItem()],
            defaultValue: NoEffectColorItem()),
      ];

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
      // Ours rides alongside, and only when it names a backdrop this build
      // knows — an unknown one is dropped rather than carried to somebody
      // else's phone to be ignored there.
      final backdrop = decoded[backdropKey];
      if (backdrop is String &&
          backdrops.any((b) => b.id == backdrop && b.colors.isNotEmpty)) {
        kept[backdropKey] = backdrop;
      }
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
      // The package's decoder walks every key it is given and throws on one
      // it does not know, so ours never reaches it.
      await c.saveAvatarSVG(jsonAvatarOptions: withoutBackdrop(selection));
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

  /// [selection] with our own key taken out — what the package is allowed to
  /// see. Its decoder walks every key it is given and throws `Bad state: No
  /// element` on one it does not know, so every hand-off to it goes through
  /// here: drawing a face, and reopening one in the builder. Missing the
  /// second is what made a saved face reopen as the defaults.
  static String withoutBackdrop(String selection) {
    try {
      final decoded = jsonDecode(selection);
      if (decoded is! Map || !decoded.containsKey(backdropKey)) {
        return selection;
      }
      return jsonEncode({
        for (final e in decoded.entries)
          if (e.key != backdropKey) '${e.key}': e.value,
      });
    } catch (_) {
      return selection;
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
    return AvatarFacePainting(
      svg: svg,
      backdrop: AvatarFace.backdropOf(widget.selection),
      size: widget.size,
    );
  }
}

/// The ONE place a face is actually painted: the backdrop behind, the drawing
/// over it, clipped to a circle.
///
/// Shared by [AvatarFaceView] — which is every chat list, header and profile
/// in the app — and by the builder's own preview, deliberately: a preview
/// drawn a second way is a preview that lies about framing, and the package's
/// own avatar widget draws the face at 80% of the circle with a margin around
/// it, which is not how the app draws it.
class AvatarFacePainting extends StatelessWidget {
  const AvatarFacePainting({
    super.key,
    required this.svg,
    required this.backdrop,
    required this.size,
  });

  final String svg;
  final AvatarBackdrop backdrop;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(
          // Behind the face, which is drawn on transparency. Painted here
          // rather than baked into the SVG so the same recipe can change its
          // backdrop without every cached drawing being redrawn.
          decoration: BoxDecoration(gradient: backdrop.gradient),
          child: svg.isEmpty
              ? const SizedBox.shrink()
              : SvgPicture.string(svg, fit: BoxFit.cover),
        ),
      ),
    );
  }
}
