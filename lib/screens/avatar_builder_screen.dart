import 'dart:math';

import 'package:avatar_maker/avatar_maker.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../util/avatar_face.dart';

/// Build your own cartoon face — the Snapchat-shaped avatar.
///
/// Pops the SELECTION string (which nose, which hair, which colours) so the
/// caller can store it on the profile, or null if they backed out. It never
/// writes the profile itself: this screen is reached from Edit profile, and
/// the one place that decides what a saved profile contains should stay the
/// one place.
///
/// **The controller is deliberately the NON-persistent one.** The package's
/// persistent controller keeps the selection in SharedPreferences under its
/// own key, which would be a second, invisible copy of the avatar living
/// outside the profile — and outside `account_wipe`, so the next account on
/// this phone would inherit the last one's face. The profile is the only
/// store; this screen just edits a value and hands it back.
///
/// **The preview is the screen's whole point, and the package does not ship
/// one** — its own docs say "it is advised that an avatar also be present in
/// the same page to show the user a preview of the changes being made". The
/// first cut of this screen took the customizer as-is, which meant building a
/// face you could not see: you tapped a nose and nothing on screen changed.
class AvatarBuilderScreen extends StatefulWidget {
  const AvatarBuilderScreen({super.key, this.initial = ''});

  /// The face being edited, if there is one. Empty starts from the defaults.
  final String initial;

  @override
  State<AvatarBuilderScreen> createState() => _AvatarBuilderScreenState();
}

class _AvatarBuilderScreenState extends State<AvatarBuilderScreen> {
  late final AvatarMakerController _controller =
      NonPersistentAvatarMakerController(
          locale: const Locale('en'),
          // Three of the package's fourteen tabs have no options at all —
          // its cosmetic system expects an app to supply the art and none
          // ships with it. An empty tab is worse than no tab.
          customizedPropertyCategories: AvatarFace.hiddenCategories);

  /// The colour behind the face — ours, not the package's. Kept in state
  /// rather than on the controller, which knows nothing about it.
  AvatarBackdrop _backdrop = AvatarFace.backdrops.first;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    // The constructor starts an init it does not wait for, and that init
    // ends by reassigning the selection — so anything applied before it
    // lands is thrown away and the customizer opens on the defaults.
    await _controller.initController();
    _backdrop = AvatarFace.backdropOf(widget.initial);
    if (AvatarFace.looksValid(widget.initial)) {
      // Reopening lands on the face they already have rather than on the
      // defaults — otherwise "change my hair" means rebuilding the whole
      // person.
      try {
        await _controller.saveAvatarSVG(jsonAvatarOptions: widget.initial);
      } catch (_) {
        // A selection this build cannot read: start from the defaults rather
        // than refusing to open the screen.
      }
    }
    if (mounted) setState(() => _ready = true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Rolls a random face.
  ///
  /// **Written here rather than using the package's own randomiser, which
  /// throws.** `randomizedSelectedOptions()` walks EVERY displayed category
  /// and calls `nextInt(properties.length)` — and the three cosmetic
  /// categories carry no properties, so it dies on
  /// `RangeError (max): Not in inclusive range 1..4294967296: 0` the moment
  /// the button is tapped. Found by tapping it in a test.
  ///
  /// Ours rolls only the categories that survive a round trip — the same
  /// list the stored selection is trimmed to — so a shuffled face is always
  /// one that can be saved and redrawn on somebody else's phone.
  void _shuffle() {
    final rnd = Random();
    for (final category in _controller.propertyCategories) {
      if (!AvatarFace.faceKeys.contains(category.id.name)) continue;
      final items = category.properties;
      if (items == null || items.isEmpty) continue;
      // The same field the customizer's own tap handler writes.
      _controller.selectedOptions[category.id] =
          items.elementAt(rnd.nextInt(items.length));
    }
    // The backdrop is ours, so it is rolled here rather than by the loop
    // above — and it is included, because a shuffle that left the colour
    // behind would only ever half-change the avatar.
    setState(() =>
        _backdrop = AvatarFace.backdrops[rnd.nextInt(AvatarFace.backdrops.length)]);
    // Redraws and notifies, so the preview above moves with it.
    _controller.updatePreview();
  }

  void _save() {
    // Sanitised on the way out, so what is stored is exactly what another
    // device can draw — the package emits three effect keys its own decoder
    // chokes on. See [AvatarFace.faceKeys].
    final built = AvatarFace.sanitize(
        AvatarFace.withBackdrop(_controller.getJsonOptionsSync(), _backdrop));
    Navigator.of(context).pop(built.isEmpty ? null : built);
  }

  /// The customizer, dressed in the app's own tokens rather than the
  /// package's defaults — one radius scale, the app's ink accent, and tiles
  /// that read as chosen or not chosen in both themes.
  AvatarMakerThemeData _theme(BuildContext context) {
    final accent = AppColors.accentOn(context);
    final surface = Theme.of(context).colorScheme.surfaceContainerHighest;
    return AvatarMakerThemeData(
      primaryBgColor: Theme.of(context).scaffoldBackgroundColor,
      secondaryBgColor: Theme.of(context).scaffoldBackgroundColor,
      // The chosen tile is the accent it is chosen WITH, so the tick and the
      // ring never disagree about which one is on.
      selectedTileDecoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: accent, width: 1.6),
      ),
      unselectedTileDecoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      boxDecoration: const BoxDecoration(),
      selectedIconColor: accent,
      unselectedIconColor: AppColors.subtle(context),
      iconColor: accent,
      labelTextStyle: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: AppColors.subtle(context)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Build your avatar')),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              top: false,
              child: Column(
                children: [
                  _Preview(
                    controller: _controller,
                    onShuffle: _shuffle,
                    backdrop: _backdrop,
                    onBackdrop: (b) => setState(() => _backdrop = b),
                  ),
                  Expanded(
                    child: AvatarMakerCustomizer(
                      controller: _controller,
                      // Nothing is written anywhere until Save is tapped —
                      // the profile is saved by Edit profile, and autosaving
                      // here would change the avatar of somebody who backed
                      // out.
                      autosave: false,
                      // Which tabs it draws comes from the CONTROLLER's own
                      // category list, not from a copy passed here — that one
                      // is only read when the customizer has to build a
                      // controller of its own, which it never does here.
                      theme: _theme(context),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
                    child: Column(
                      children: [
                        FilledButton(
                          onPressed: _save,
                          style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(48)),
                          child: const Text('Use this avatar'),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          // Said once, because it is the reason this is built
                          // in rather than borrowed from Bitmoji.
                          'Drawn on your phone. Nobody else is involved.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: AppColors.subtle(context)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// The face as it stands, big, with the two controls that are not categories:
/// shuffle, and the colour behind it.
///
/// It listens to the controller rather than reading it once, so it carries
/// the transient preview of whatever is under the finger inside the
/// customizer — that is what makes tapping a nose feel like anything, and it
/// is the one avatar in the app that should reflect a preview.
///
/// It draws through [AvatarFacePainting], the same widget every other avatar
/// in the app draws through, rather than the package's own avatar widget —
/// which frames the face smaller, with a margin. With a backdrop behind it
/// that difference would be plain: a face floating in the middle of a
/// coloured circle here, filling it everywhere else.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.controller,
    required this.onShuffle,
    required this.backdrop,
    required this.onBackdrop,
  });

  final AvatarMakerController controller;
  final VoidCallback onShuffle;
  final AvatarBackdrop backdrop;
  final ValueChanged<AvatarBackdrop> onBackdrop;

  static const double _size = 112;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 12),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        children: [
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) => AvatarFacePainting(
              key: const Key('avatarPreview'),
              svg: controller.displayedAvatarSVG,
              backdrop: backdrop,
              size: _size,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 40,
            child: Row(
              children: [
                const SizedBox(width: 16),
                // Shuffle is how most people start — the alternative is
                // picking thirteen categories from the defaults one at a
                // time. Beside the colours rather than above them, because a
                // row of its own is a row the customizer below loses.
                OutlinedButton.icon(
                  onPressed: onShuffle,
                  icon: const Icon(Icons.shuffle, size: 17),
                  label: const Text('Shuffle'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.lg)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(right: 16),
                    itemCount: AvatarFace.backdrops.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, i) {
                      final b = AvatarFace.backdrops[i];
                      return _BackdropSwatch(
                        backdrop: b,
                        selected: b.id == backdrop.id,
                        onTap: () => onBackdrop(b),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One colour to sit behind the face.
///
/// The ring is drawn OUTSIDE the swatch, on the panel, so it never covers the
/// colour it is marking — the same mistake the wallpaper picker made, where a
/// border painted inside a pale tile was invisible against it.
class _BackdropSwatch extends StatelessWidget {
  const _BackdropSwatch({
    required this.backdrop,
    required this.selected,
    required this.onTap,
  });

  final AvatarBackdrop backdrop;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentOn(context);
    return Tooltip(
      message: backdrop.label,
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // Transparent rather than absent when unselected, so choosing one
            // does not shift the row along by two points.
            border: Border.all(
                color: selected ? accent : Colors.transparent, width: 2),
          ),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: backdrop.gradient,
                border: backdrop.isNone
                    ? Border.all(color: AppColors.subtle(context), width: 1)
                    : null,
              ),
              // "None" is not a colour, so it says so rather than showing a
              // circle of the panel it is sitting on.
              child: backdrop.isNone
                  ? Icon(Icons.block,
                      size: 14, color: AppColors.subtle(context))
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
