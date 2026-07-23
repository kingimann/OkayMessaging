import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// On web there is no OS share sheet in the Flutter sense, so we hand the
/// encrypted backup to the browser.
///
/// The naive `<a download>` approach is silently ignored by iOS Safari — the
/// tap looks like it worked but nothing is ever saved. So we prefer the Web
/// Share API (`navigator.share({files:[…]})`), which iOS Safari does support:
/// it opens the native share sheet, letting the user save to Files, iCloud
/// Drive, Dropbox, or Google Drive. Desktop browsers, which don't support
/// sharing files, fall back to a normal download.
Future<String?> exportBackupFile(String fileName, Uint8List bytes) async {
  final parts = <JSAny>[bytes.toJS].toJS;

  // 1) Preferred path: share the file via the native sheet (works on iOS).
  try {
    final nav = web.window.navigator;
    final file = web.File(
      parts,
      fileName,
      web.FilePropertyBag(type: 'application/octet-stream'),
    );
    final data = web.ShareData(
      files: <web.File>[file].toJS,
      title: fileName,
    );
    if (nav.canShare(data)) {
      try {
        await nav.share(data).toDart;
        return 'Choose iCloud Drive, Dropbox, Google Drive, or Files to save '
            'your backup.';
      } catch (_) {
        // The user dismissed the share sheet (or it failed). Don't silently
        // fall through to a download they didn't ask for.
        return 'Backup wasn\'t saved. Tap "Back up now" to try again.';
      }
    }
  } catch (_) {
    // Web Share unavailable — fall through to a plain download below.
  }

  // 2) Fallback: download the file (desktop browsers).
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
    return 'Backup downloaded — upload it to iCloud Drive, Dropbox, or Google '
        'Drive to keep it safe.';
  } catch (_) {
    return null;
  }
}
