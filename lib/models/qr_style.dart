import 'package:flutter/material.dart';

/// A look for the QR card — the thing Telegram lets you pick when it offers
/// "customize" on a QR code.
///
/// **Every preset is authored as a PAIR**, background and modules together,
/// and that is the whole safety of the feature. A QR is not decoration: a
/// scanner needs real contrast between the dark and light squares, and a
/// free colour picker is how somebody ends up with a beautiful code no
/// camera can read. So there is no picker — there are presets, each one a
/// combination that stays scannable, and a test measures the contrast of
/// every one of them rather than trusting the eye that chose it.
@immutable
class QrStyle {
  const QrStyle({
    required this.id,
    required this.name,
    required this.start,
    required this.end,
    required this.module,
  });

  /// Stored on the device; the name is what the chip says.
  final String id;
  final String name;

  /// The card's gradient, top-left to bottom-right. A flat preset simply
  /// names the same colour twice.
  final Color start;
  final Color end;

  /// The colour of the code's own squares — the "dark" modules, whether or
  /// not it is literally dark.
  final Color module;

  /// The quiet zone behind the code itself. Always the gradient's own start
  /// colour rather than white: a white box floating on a coloured card is
  /// what the preset is trying not to look like, and the contrast that
  /// matters is module-against-this.
  Color get field => start;

  /// WCAG relative luminance, the same arithmetic [contrastWith] needs.
  static double _luminance(Color c) => c.computeLuminance();

  /// The contrast ratio between the modules and the card behind them, on the
  /// usual 1–21 scale. What a scanner actually needs is nearer 3:1 than the
  /// 4.5:1 text asks for, but presets are held to the higher bar — a code
  /// read in bad light, at an angle, through a scratched lens, is the case
  /// worth designing for.
  double get contrast {
    final a = _luminance(module);
    final b = _luminance(field);
    final lighter = a > b ? a : b;
    final darker = a > b ? b : a;
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Whether the card wants light text on it (the name and handle drawn over
  /// the gradient), decided from the gradient rather than the app theme: this
  /// card keeps its own colours in dark mode and light mode alike, so the
  /// theme has no say in what is readable on top of it.
  bool get wantsLightInk => _luminance(start) < 0.5;
}

/// The presets, in the order the chips appear. The first is the default and
/// is deliberately the plain one — somebody who never opens this still gets
/// the most scannable code there is, black on white.
const List<QrStyle> qrStyles = [
  QrStyle(
    id: 'classic',
    name: 'Classic',
    start: Color(0xFFFFFFFF),
    end: Color(0xFFFFFFFF),
    module: Color(0xFF0F1419),
  ),
  QrStyle(
    id: 'ink',
    name: 'Ink',
    start: Color(0xFF101820),
    end: Color(0xFF23262B),
    module: Color(0xFFFFFFFF),
  ),
  QrStyle(
    id: 'ocean',
    name: 'Ocean',
    start: Color(0xFF06344F),
    end: Color(0xFF0B6E8F),
    module: Color(0xFFFFFFFF),
  ),
  QrStyle(
    id: 'forest',
    name: 'Forest',
    start: Color(0xFF06301F),
    end: Color(0xFF0E5C39),
    module: Color(0xFFFFFFFF),
  ),
  QrStyle(
    id: 'plum',
    name: 'Plum',
    start: Color(0xFF2B0B3A),
    end: Color(0xFF5B1D6B),
    module: Color(0xFFFFFFFF),
  ),
  QrStyle(
    id: 'ember',
    name: 'Ember',
    start: Color(0xFF4A1206),
    end: Color(0xFF8A2B10),
    module: Color(0xFFFFFFFF),
  ),
  QrStyle(
    id: 'sand',
    name: 'Sand',
    start: Color(0xFFF7EFE2),
    end: Color(0xFFE8D9BE),
    module: Color(0xFF3A2A12),
  ),
  QrStyle(
    id: 'mint',
    name: 'Mint',
    start: Color(0xFFE9F7F1),
    end: Color(0xFFCDEDE0),
    module: Color(0xFF0B3D2C),
  ),
];

/// The preset [id] names, or the default when it names nothing this build
/// knows — a style saved by a newer build must not leave somebody with no
/// QR code at all.
QrStyle qrStyleById(String id) =>
    qrStyles.firstWhere((s) => s.id == id, orElse: () => qrStyles.first);

/// The shape of the code's squares. Rounded is what most apps draw now and
/// it costs nothing: a scanner reads the grid, not the corners.
enum QrModuleShape {
  square('Squares'),
  round('Dots');

  const QrModuleShape(this.label);
  final String label;

  static QrModuleShape fromId(String id) => QrModuleShape.values.firstWhere(
      (s) => s.name == id,
      orElse: () => QrModuleShape.square);
}
