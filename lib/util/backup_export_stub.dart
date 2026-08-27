import 'dart:typed_data';

import 'backup_export.dart' show ExportOutcome;

/// Fallback when neither dart:html nor dart:io is available.
Future<ExportOutcome> exportFile(String fileName, Uint8List bytes,
        {String mimeType = 'application/octet-stream'}) async =>
    ExportOutcome.failed;

/// Fallback when neither dart:html nor dart:io is available.
Future<String?> shareImageBytes(String fileName, Uint8List bytes,
        {String subject = ''}) async =>
    null;

/// No platform to hand a URL to. The caller falls back to the clipboard,
/// which is the honest answer where there is no share sheet.
Future<bool> shareLink(String url, {String subject = ''}) async => false;
