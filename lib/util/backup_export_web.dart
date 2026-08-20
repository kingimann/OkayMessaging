import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'backup_export.dart' show ExportOutcome;

/// On web there is no OS share sheet in the Flutter sense, so we hand the
/// file to the browser.
///
/// The naive `<a download>` approach is silently ignored by iOS Safari — the
/// tap looks like it worked but nothing is ever saved. So we prefer the Web
/// Share API (`navigator.share({files:[…]})`), which iOS Safari does support:
/// it opens the native share sheet, letting the user save to Files, iCloud
/// Drive, Dropbox, or Google Drive. Desktop browsers, which don't support
/// sharing files, fall back to a normal download.
///
/// [mimeType] rides on BOTH paths, and it is what the browser reads to decide
/// whether it can open the thing at all — a PDF or a web page handed over as
/// `application/octet-stream` is an unknown binary, which is what this used
/// to send for every caller.
Future<ExportOutcome> exportFile(String fileName, Uint8List bytes,
    {String mimeType = 'application/octet-stream'}) async {
  final parts = <JSAny>[bytes.toJS].toJS;

  // 1) Preferred path: share the file via the native sheet (works on iOS).
  try {
    final nav = web.window.navigator;
    final file = web.File(
      parts,
      fileName,
      web.FilePropertyBag(type: mimeType),
    );
    final data = web.ShareData(
      files: <web.File>[file].toJS,
      title: fileName,
    );
    if (nav.canShare(data)) {
      try {
        await nav.share(data).toDart;
        return ExportOutcome.shared;
      } catch (_) {
        // The user dismissed the share sheet (or it failed). Don't silently
        // fall through to a download they didn't ask for.
        return ExportOutcome.dismissed;
      }
    }
  } catch (_) {
    // Web Share unavailable — fall through to a plain download below.
  }

  // 2) Fallback: download the file (desktop browsers).
  try {
    final blob = web.Blob(parts, web.BlobPropertyBag(type: mimeType));
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..setAttribute('download', fileName);
    anchor.click();
    web.URL.revokeObjectURL(url);
    return ExportOutcome.downloaded;
  } catch (_) {
    return ExportOutcome.failed;
  }
}

/// The image half of [exportFile], and it makes the same call for the
/// same reason: `<a download>` is silently ignored by iOS Safari, so the Web
/// Share API is tried first and a plain download is the desktop fallback.
Future<String?> shareImageBytes(String fileName, Uint8List bytes,
    {String subject = ''}) async {
  final parts = <JSAny>[bytes.toJS].toJS;
  try {
    final nav = web.window.navigator;
    final file = web.File(
        parts, fileName, web.FilePropertyBag(type: 'image/png'));
    final data = web.ShareData(
        files: <web.File>[file].toJS,
        title: subject.isEmpty ? fileName : subject);
    if (nav.canShare(data)) {
      try {
        await nav.share(data).toDart;
        return 'Shared.';
      } catch (_) {
        return null;
      }
    }
  } catch (_) {
    // Web Share unavailable — fall through to a plain download below.
  }
  try {
    final blob = web.Blob(parts, web.BlobPropertyBag(type: 'image/png'));
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..setAttribute('download', fileName);
    anchor.click();
    web.URL.revokeObjectURL(url);
    return 'Downloaded.';
  } catch (_) {
    return null;
  }
}
