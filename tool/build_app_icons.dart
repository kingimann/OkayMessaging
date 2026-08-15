// Generates the alternate iOS app icons from the one the app already ships.
//
//   dart run tool/build_app_icons.dart
//
// Writes ios/Runner/Assets.xcassets/AppIcon-<Name>.appiconset/ for every entry
// in `appIconOptions` that is not the default, each carrying the same size
// list as AppIcon.appiconset minus the App Store marketing slot (an alternate
// icon has no listing to appear in).
//
// WHY IT RECOLOURS RATHER THAN DRAWING: `assets/icon/icon.png` is the real
// mark, and a hand-redrawn copy would drift from it the first time either
// changed. The source is a white bubble on a near-black tile, so the SAME
// luminance mask `BrandMark` uses in the app bar separates the two here — the
// bubble clamps to fully opaque, the tile and the three dots inside the
// bubble clip to nothing — and each variant paints its own two colours
// through it. Antialiased edges survive, because the mask is a ramp rather
// than a threshold.
//
// The output is FLATTENED, three channels, no alpha. Apple states that
// outright for app icons, and a PNG saved from an image that still carries an
// alpha channel is not flattened even when every pixel in it is opaque — the
// same trap `tool/store_screenshots.dart` documents.
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

import 'package:okay_messaging/models/app_icon_option.dart';

/// Steepens the ramp so mid-greys resolve one way or the other rather than
/// leaving a halo round the bubble.
///
/// These two are `BrandMark.gain` and `BrandMark.bias`, and a test pins that
/// they still are: the app bar's mark and the home-screen icon are the same
/// artwork through the same mask, so a change to one that missed the other
/// would show up as an app bar and an icon that no longer match.
const double maskGain = 1.6;
const double maskBias = 60;

/// Rec. 709, the coefficients `BrandMark` uses.
const double lumR = 0.2126;
const double lumG = 0.7152;
const double lumB = 0.0722;

/// How opaque the bubble is at this source pixel, 0..1.
double bubbleAt(int r, int g, int b) {
  final a = maskGain * (lumR * r + lumG * g + lumB * b) - maskBias;
  return a <= 0 ? 0 : (a >= 255 ? 1 : a / 255);
}

/// The source mark repainted in one option's two colours.
///
/// Pure, and takes the decoded image rather than a path, so a test can hand
/// it a two-pixel picture and check the arithmetic instead of eyeballing a
/// PNG nobody here can look at.
img.Image recolour(img.Image src, AppIconOption option) {
  final out = img.Image(width: src.width, height: src.height, numChannels: 3);
  final tr = (option.tile >> 16) & 0xFF;
  final tg = (option.tile >> 8) & 0xFF;
  final tb = option.tile & 0xFF;
  final br = (option.bubble >> 16) & 0xFF;
  final bg = (option.bubble >> 8) & 0xFF;
  final bb = option.bubble & 0xFF;
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      final p = src.getPixel(x, y);
      final t = bubbleAt(p.r.toInt(), p.g.toInt(), p.b.toInt());
      out.setPixelRgb(
        x,
        y,
        (tr + (br - tr) * t).round(),
        (tg + (bg - tg) * t).round(),
        (tb + (bb - tb) * t).round(),
      );
    }
  }
  return out;
}

/// One entry in an `.appiconset`'s Contents.json.
class IconSlot {
  const IconSlot(this.size, this.idiom, this.scale);
  final String size; // "20x20", "83.5x83.5"
  final String idiom; // "iphone" / "ipad"
  final int scale;

  /// Edge length in real pixels.
  int get pixels {
    final edge = double.parse(size.split('x').first);
    return (edge * scale).round();
  }

  String fileName(String id) => 'Icon-$id-$size@${scale}x.png';
}

/// Exactly what AppIcon.appiconset carries, minus `ios-marketing`: the App
/// Store listing shows the PRIMARY icon, and an alternate set that claims a
/// marketing slot is a set Xcode refuses.
const List<IconSlot> slots = <IconSlot>[
  IconSlot('20x20', 'iphone', 2),
  IconSlot('20x20', 'iphone', 3),
  IconSlot('29x29', 'iphone', 1),
  IconSlot('29x29', 'iphone', 2),
  IconSlot('29x29', 'iphone', 3),
  IconSlot('40x40', 'iphone', 2),
  IconSlot('40x40', 'iphone', 3),
  IconSlot('57x57', 'iphone', 1),
  IconSlot('57x57', 'iphone', 2),
  IconSlot('60x60', 'iphone', 2),
  IconSlot('60x60', 'iphone', 3),
  IconSlot('20x20', 'ipad', 1),
  IconSlot('20x20', 'ipad', 2),
  IconSlot('29x29', 'ipad', 1),
  IconSlot('29x29', 'ipad', 2),
  IconSlot('40x40', 'ipad', 1),
  IconSlot('40x40', 'ipad', 2),
  IconSlot('50x50', 'ipad', 1),
  IconSlot('50x50', 'ipad', 2),
  IconSlot('72x72', 'ipad', 1),
  IconSlot('72x72', 'ipad', 2),
  IconSlot('76x76', 'ipad', 1),
  IconSlot('76x76', 'ipad', 2),
  IconSlot('83.5x83.5', 'ipad', 2),
];

/// The Contents.json an alternate set needs.
String contentsJson(String id) => const JsonEncoder.withIndent('  ').convert({
      'images': [
        for (final s in slots)
          {
            'size': s.size,
            'idiom': s.idiom,
            'filename': s.fileName(id),
            'scale': '${s.scale}x',
          },
      ],
      'info': {'version': 1, 'author': 'xcode'},
    });

const String sourcePath = 'assets/icon/icon.png';
const String catalogPath = 'ios/Runner/Assets.xcassets';

void main(List<String> args) {
  final source = img.decodePng(File(sourcePath).readAsBytesSync());
  if (source == null) {
    stderr.writeln('could not decode $sourcePath');
    exitCode = 1;
    return;
  }
  for (final option in appIconOptions) {
    if (option.id.isEmpty) continue; // the shipped icon; nothing to generate
    final dir = Directory('$catalogPath/${option.bundleName}.appiconset');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    final art = recolour(source, option);
    // One resize per distinct pixel size — several slots share one (a 60x60@2x
    // and a 40x40@3x are both 120), and resizing the same square twice would
    // only be slower.
    final cache = <int, List<int>>{};
    for (final slot in slots) {
      final bytes = cache.putIfAbsent(
          slot.pixels,
          () => img.encodePng(img.copyResize(art,
              width: slot.pixels,
              height: slot.pixels,
              interpolation: img.Interpolation.cubic)));
      File('${dir.path}/${slot.fileName(option.id)}')
          .writeAsBytesSync(bytes);
    }
    File('${dir.path}/Contents.json').writeAsStringSync(contentsJson(option.id));
    stdout.writeln('${option.name}: ${slots.length} files in ${dir.path}');
  }
}
