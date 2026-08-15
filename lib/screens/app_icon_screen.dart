import 'package:flutter/material.dart';

import '../models/app_icon_option.dart';
import '../state/app_icon_store.dart';
import '../theme/app_theme.dart';
import '../widgets/brand_mark.dart';

/// Pick the app's home-screen icon.
///
/// A grid of the real thing: each tile is drawn from the option's own two
/// colours through the same mask `tool/build_app_icons.dart` paints the PNGs
/// with, so the swatch is not an approximation of the icon — it is the same
/// arithmetic on the same artwork.
class AppIconScreen extends StatefulWidget {
  const AppIconScreen({super.key});

  @override
  State<AppIconScreen> createState() => _AppIconScreenState();
}

class _AppIconScreenState extends State<AppIconScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Cheap, and it is how the screen learns what is actually on the home
    // screen right now rather than what this session last set.
    AppIconStore.instance.load();
  }

  Future<void> _pick(AppIconOption option) async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await AppIconStore.instance.select(option);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Couldn't change the icon")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App icon')),
      body: ListenableBuilder(
        listenable: AppIconStore.instance,
        builder: (context, _) {
          final store = AppIconStore.instance;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              if (store.loaded && !store.available)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    // Said plainly rather than by greying the grid out: the
                    // web build has no home screen to put an icon on, and
                    // "unavailable" with no reason reads as broken.
                    'Changing the app icon works on iPhone. This build has no '
                    'home-screen icon to change.',
                    style:
                        TextStyle(fontSize: 13.5, color: AppColors.subtle(context)),
                  ),
                ),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 0.78,
                children: [
                  for (final option in appIconOptions)
                    _IconTile(
                      option: option,
                      selected: store.current.id == option.id,
                      enabled: store.available && !_busy,
                      onTap: () => _pick(option),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                // iOS pops its own "You have changed the icon for
                // OkayMessenger" alert and there is no public way to suppress
                // it. Saying so first turns a surprise into a confirmation.
                'iPhone shows its own alert when the icon changes. The app '
                'keeps whichever one you pick.',
                style: TextStyle(fontSize: 13, color: AppColors.subtle(context)),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile({
    required this.option,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final AppIconOption option;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentOn(context);
    return Semantics(
      selected: selected,
      button: true,
      label: option.name,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The ring sits OUTSIDE the tile, on the page, not on the icon —
            // a border painted inside a box lands on the artwork it is
            // supposed to be marking. The wallpaper picker learned that one
            // the hard way.
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? accent : Colors.transparent,
                  width: 2,
                ),
              ),
              child: ClipRRect(
                // iOS's own squircle is not reproducible here; a generous
                // rounded square is the closest honest stand-in.
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  width: 62,
                  height: 62,
                  child: AppIconArt(option: option),
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              option.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One icon, drawn from its own colours.
///
/// The mark comes from `assets/icon/icon.png` through the same luminance mask
/// `BrandMark` uses in the app bar and `tool/build_app_icons.dart` uses to
/// bake the PNGs — so a swatch here cannot show a shape the home screen does
/// not have.
class AppIconArt extends StatelessWidget {
  const AppIconArt({super.key, required this.option});

  final AppIconOption option;

  static Color _colour(int rgb) => Color(0xFF000000 | rgb);

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: _colour(option.tile),
        child: ColorFiltered(
          colorFilter: _bubbleFilter(_colour(option.bubble)),
          child: Image.asset('assets/icon/icon.png', fit: BoxFit.cover),
        ),
      );

  /// Constant colour, alpha from source luminance. `BrandMark.filterFor` is
  /// already public, so this is a reference to the app bar's own mask rather
  /// than a second copy of the arithmetic.
  static ColorFilter _bubbleFilter(Color colour) =>
      BrandMark.filterFor(colour);
}
