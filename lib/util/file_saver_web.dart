import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Saves [bytes] as a file the user can keep. Prefers the Web Share API (which
/// iOS Safari supports, unlike the `<a download>` attribute), so the file goes
/// through the native share sheet (Files / iCloud / Dropbox / …). Desktop
/// browsers fall back to a normal download.
Future<String?> saveFile(String fileName, Uint8List bytes) async {
  final parts = <JSAny>[bytes.toJS].toJS;

  // 1) Native share sheet (works on iOS).
  try {
    final nav = web.window.navigator;
    final file = web.File(
      parts,
      fileName,
      web.FilePropertyBag(type: 'application/octet-stream'),
    );
    final data = web.ShareData(files: <web.File>[file].toJS, title: fileName);
    if (nav.canShare(data)) {
      try {
        await nav.share(data).toDart;
        return 'Choose where to save "$fileName".';
      } catch (_) {
        return 'Not saved. Try again.';
      }
    }
  } catch (_) {
    // Fall through to a download.
  }

  // 2) Download (desktop browsers).
  try {
    final blob = web.Blob(
      parts,
      web.BlobPropertyBag(type: 'application/octet-stream'),
    );
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..setAttribute('download', fileName);
    anchor.click();
    web.URL.revokeObjectURL(url);
    return 'Downloaded $fileName';
  } catch (_) {
    return null;
  }
}
