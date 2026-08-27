import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'backup_export.dart' show ExportOutcome;

/// Writes the file to a temp path and opens the system share sheet, from
/// which the user can pick iCloud Drive, Dropbox, Google Drive, Files —
/// or, for a type iOS understands, Quick Look, Print, Mail and the rest.
///
/// [mimeType] is what decides which of those are offered at all. It used to
/// be pinned to `application/octet-stream` because this only ever carried an
/// encrypted backup, and a PDF or a web page handed over under that type
/// arrives as an opaque blob nothing volunteers to open.
Future<ExportOutcome> exportFile(String fileName, Uint8List bytes,
    {String mimeType = 'application/octet-stream'}) async {
  try {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/$fileName';
    await File(path).writeAsBytes(bytes);
    await Share.shareXFiles(
      [XFile(path, mimeType: mimeType)],
      subject: fileName,
    );
    return ExportOutcome.shared;
  } catch (_) {
    return ExportOutcome.failed;
  }
}

/// Writes a PNG to a temp file and opens the system share sheet — the same
/// shape as [exportFile], with the mime type an image needs so the
/// sheet offers Photos and Messages rather than only Files.
Future<String?> shareImageBytes(String fileName, Uint8List bytes,
    {String subject = ''}) async {
  try {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/$fileName';
    await File(path).writeAsBytes(bytes);
    await Share.shareXFiles(
      [XFile(path, mimeType: 'image/png')],
      subject: subject.isEmpty ? fileName : subject,
    );
    return 'Shared.';
  } catch (_) {
    return null;
  }
}

/// Hands a URL to the OS share sheet — the way a post leaves the app.
///
/// A LINK, not the post's text. Share used to copy the body to the
/// clipboard, which pastes words into a conversation and points nobody back
/// here; a URL unfurls into a card and is the whole growth mechanism.
Future<bool> shareLink(String url, {String subject = ''}) async {
  if (url.isEmpty) return false;
  try {
    await Share.share(url, subject: subject);
    return true;
  } catch (_) {
    return false;
  }
}
