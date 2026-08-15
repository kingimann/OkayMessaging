import 'dart:math' as math;

/// One home-screen icon somebody can pick.
///
/// **Authored as PAIRS — a tile colour and a bubble colour together — for the
/// same reason the QR presets are.** The mark has to survive at 40 points on
/// a home screen among a hundred other icons; a free colour picker is exactly
/// how somebody ends up with a beautiful icon nobody can find. So there is no
/// picker, only this list, and [contrast] is measured by a test rather than
/// trusted to the eye that chose it.
///
/// Deliberately free of any Flutter import: `tool/build_app_icons.dart` runs
/// on the plain Dart VM and generates the real PNGs from this same list, so
/// the swatch in the picker and the icon on the home screen cannot describe
/// different colours.
class AppIconOption {
  const AppIconOption({
    required this.id,
    required this.name,
    required this.tile,
    required this.bubble,
  });

  /// Empty for the icon the app ships with. Everything else is the suffix of
  /// its asset-catalog set, which is also the name iOS knows it by.
  final String id;

  /// What the picker calls it.
  final String name;

  /// 0xRRGGBB. The square behind the mark.
  final int tile;

  /// 0xRRGGBB. The speech bubble on it.
  final int bubble;

  /// What `setAlternateIconName` is handed. Empty means null — the primary
  /// icon, which is not an "alternate" at all and must never be named as one.
  String get bundleName => id.isEmpty ? '' : 'AppIcon-$id';

  /// WCAG contrast between the two colours, so a pair that cannot be read at
  /// icon size fails a test instead of shipping.
  double get contrast {
    final a = _relativeLuminance(tile);
    final b = _relativeLuminance(bubble);
    final hi = math.max(a, b);
    final lo = math.min(a, b);
    return (hi + 0.05) / (lo + 0.05);
  }

  static double _relativeLuminance(int rgb) {
    double channel(int v) {
      final c = v / 255.0;
      return c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4) as double;
    }

    return 0.2126 * channel((rgb >> 16) & 0xFF) +
        0.7152 * channel((rgb >> 8) & 0xFF) +
        0.0722 * (channel(rgb & 0xFF));
  }
}

/// Every icon on offer, the shipped one first.
///
/// Six is a deliberate ceiling rather than a start: each alternate is twenty
/// PNGs in the app bundle, and a grid of thirty icons is a settings screen
/// nobody finishes reading. The palette stays inside the app's own register —
/// one light, four deep — rather than reaching for the saturated colours the
/// 2026-08-09 pass took out of the chrome.
const List<AppIconOption> appIconOptions = <AppIconOption>[
  // The shipped icon: the mark as `assets/icon/icon.png` already draws it.
  AppIconOption(id: '', name: 'Ink', tile: 0x101820, bubble: 0xFFFFFF),
  AppIconOption(id: 'Paper', name: 'Paper', tile: 0xF7F9F9, bubble: 0x0F1419),
  AppIconOption(id: 'Ocean', name: 'Ocean', tile: 0x0B3D5C, bubble: 0xFFFFFF),
  AppIconOption(id: 'Forest', name: 'Forest', tile: 0x14452F, bubble: 0xFFFFFF),
  AppIconOption(id: 'Ember', name: 'Ember', tile: 0x7A2718, bubble: 0xFFFFFF),
  AppIconOption(id: 'Slate', name: 'Slate', tile: 0x4A5568, bubble: 0xFFFFFF),
];

/// The option [bundleName] names, or the default when nothing matches — an
/// icon this build does not know about is not a reason to show no selection.
AppIconOption appIconFor(String bundleName) => appIconOptions.firstWhere(
      (o) => o.bundleName == bundleName,
      orElse: () => appIconOptions.first,
    );
