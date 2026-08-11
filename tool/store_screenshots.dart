// Converts phone screenshots to the exact pixel sizes App Store Connect
// accepts. Pure Dart, so it runs the same on Windows, macOS and Linux —
// unlike `sips`, which is macOS only.
//
//   dart run tool/store_screenshots.dart screenshots
//   dart run tool/store_screenshots.dart screenshots --all
//   dart run tool/store_screenshots.dart screenshots --size=1320x2868
//   dart run tool/store_screenshots.dart art --size=1024x1024 --cover
//
// Reads every .png/.jpg in the input folder and writes one file per size into
// build/store_screenshots/<WxH>/. Originals are never touched.
//
// WHY IT DOES NOT SIMPLY STRETCH EVERYTHING: a phone screenshot and the store
// slot are usually the same shape to within a fraction of a percent (a
// 1179x2556 iPhone into the 1290x2796 slot is 0.02% out), and forcing those
// to size is invisible. A genuinely different shape — an iPad shot dropped
// into an iPhone slot, or a landscape one — is not, and stretching it would
// hand Apple a distorted image that looks like a mistake, because it is one.
// So past a tolerance it scales to FIT and pads the gap with the picture's
// own edge colour: nothing is cropped, nothing is squashed, and the file says
// which of the two happened.

import 'dart:io';

import 'package:image/image.dart' as img;

/// The sizes App Store Connect accepts for the iPhone 6.5"/6.7"/6.9" slot,
/// plus the 13" iPad one. Keyed by pixels rather than by inches on purpose —
/// Apple moves which device an inch label means, and the pixel count is the
/// thing the upload actually checks.
const Map<String, (int, int)> kSizes = {
  '1290x2796': (1290, 2796), // the default: accepted for 6.5"/6.7"/6.9"
  '1320x2868': (1320, 2868),
  '1260x2736': (1260, 2736),
  '2064x2752': (2064, 2752), // iPad 13"
  // The In-App Purchase promotional image. Square, and the one place Apple
  // states the pixel format outright: RGB, flattened, no rounded corners.
  // Every output here is flattened anyway (see _canvas), so this size needs
  // no special case beyond its shape.
  '1024x1024': (1024, 1024),
};

const String kDefault = '1290x2796';

/// How far out of shape an image may be before it is padded instead of
/// stretched. 1% is comfortably past the ~0.3% that separates real iPhone
/// screenshot shapes, and far short of anything a person would notice.
const double kAspectTolerance = 0.01;

/// Below this fraction of the target width, an upscale starts to look soft.
/// Worth saying out loud rather than quietly shipping a blurry screenshot.
const double kSoftBelow = 0.6;

/// An OPAQUE canvas — three channels, no alpha.
///
/// Apple wants store images "flattened", and the IAP promotional image says
/// so explicitly. Compositing onto a 3-channel canvas is what guarantees it:
/// a PNG saved from an image that still carries an alpha channel is not
/// flattened even when every pixel in it happens to be opaque.
img.Image _canvas(int w, int h, img.Color fill) {
  final c = img.Image(width: w, height: h, numChannels: 3);
  img.fill(c, color: fill);
  return c;
}

/// The colour to pad with: the average of the four corners, which on a
/// screenshot is the status-bar/background colour at each end.
img.Color _edgeColour(img.Image src) {
  final corners = [
    src.getPixel(0, 0),
    src.getPixel(src.width - 1, 0),
    src.getPixel(0, src.height - 1),
    src.getPixel(src.width - 1, src.height - 1),
  ];
  int r = 0, g = 0, b = 0;
  for (final p in corners) {
    r += p.r.toInt();
    g += p.g.toInt();
    b += p.b.toInt();
  }
  return img.ColorRgb8(r ~/ 4, g ~/ 4, b ~/ 4);
}

/// Converts [src] to exactly [w]x[h], flattened, and says in one word how.
///
/// Public so a test can hold the three behaviours that matter: the output is
/// the exact size asked for, it never carries an alpha channel, and a shape
/// that differs by more than [kAspectTolerance] is padded or cropped rather
/// than stretched.
(img.Image, String) fitForStore(img.Image src, int w, int h, {required bool cover}) {
  final srcAspect = src.width / src.height;
  final dstAspect = w / h;
  final off = (srcAspect - dstAspect).abs() / dstAspect;
  final bg = _edgeColour(src);

  if (off <= kAspectTolerance) {
    final out = _canvas(w, h, bg);
    img.compositeImage(
        out,
        img.copyResize(src,
            width: w, height: h, interpolation: img.Interpolation.cubic),
        dstX: 0,
        dstY: 0);
    return (out, 'resized');
  }

  // Scale to FILL and centre-crop, or to FIT and pad. Padding is the default
  // because it loses nothing; --cover is for the square promotional image,
  // where two thick bars either side of a phone screenshot look like a
  // mistake and a crop of the app in use does not.
  final scale = cover
      ? ((w / src.width) > (h / src.height) ? w / src.width : h / src.height)
      : ((w / src.width) < (h / src.height) ? w / src.width : h / src.height);
  final inner = img.copyResize(src,
      width: (src.width * scale).round(),
      height: (src.height * scale).round(),
      interpolation: img.Interpolation.cubic);
  final out = _canvas(w, h, bg);
  img.compositeImage(out, inner,
      dstX: (w - inner.width) ~/ 2, dstY: (h - inner.height) ~/ 2);
  return (out, cover ? 'cropped' : 'padded');
}

void main(List<String> args) {
  final flags = args.where((a) => a.startsWith('--')).toList();
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final inputDir = positional.isEmpty ? 'screenshots' : positional.first;
  final cover = flags.contains('--cover');

  final wanted = <String>[];
  if (flags.contains('--all')) {
    wanted.addAll(kSizes.keys);
  } else {
    final picked = flags.firstWhere((f) => f.startsWith('--size='),
        orElse: () => '--size=$kDefault');
    final key = picked.substring('--size='.length);
    if (!kSizes.containsKey(key)) {
      stderr.writeln('Unknown --size=$key. Choose one of: '
          '${kSizes.keys.join(', ')} — or pass --all.');
      exitCode = 2;
      return;
    }
    wanted.add(key);
  }

  final dir = Directory(inputDir);
  if (!dir.existsSync()) {
    stderr.writeln('No such folder: $inputDir\n'
        'Put your screenshots in it, or pass the path as the first argument.');
    exitCode = 2;
    return;
  }
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => RegExp(r'\.(png|jpg|jpeg)$', caseSensitive: false)
          .hasMatch(f.path))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    stderr.writeln('No .png or .jpg files in $inputDir');
    exitCode = 2;
    return;
  }

  var written = 0;
  for (final key in wanted) {
    final (w, h) = kSizes[key]!;
    final out = Directory('build/store_screenshots/$key')
      ..createSync(recursive: true);
    for (final f in files) {
      final src = img.decodeImage(f.readAsBytesSync());
      if (src == null) {
        stderr.writeln('  !! could not read ${f.path} — skipped');
        continue;
      }
      final (result, how) = fitForStore(src, w, h, cover: cover);
      // Always PNG: App Store Connect takes PNG or JPEG, and PNG avoids
      // re-compressing an image that was already compressed once.
      final name = '${f.uri.pathSegments.last.split('.').first}.png';
      File('${out.path}/$name').writeAsBytesSync(img.encodePng(result));
      final soft = src.width < w * kSoftBelow ? '  (source is small — '
          'this will look soft; retake at a higher resolution if you can)' : '';
      stdout.writeln('$key  $name  ${src.width}x${src.height} -> ${w}x$h  '
          '[$how]$soft');
      written++;
    }
  }
  stdout.writeln('\n$written file(s) in build/store_screenshots/');
}
