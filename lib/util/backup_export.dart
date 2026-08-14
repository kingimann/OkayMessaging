import 'dart:typed_data';

import 'backup_export_stub.dart'
    if (dart.library.html) 'backup_export_web.dart'
    if (dart.library.io) 'backup_export_io.dart' as impl;

/// Exports an encrypted backup [bytes] as a file the user can send to a cloud
/// drive. On mobile this opens the share sheet (iCloud Drive / Dropbox / Google
/// Drive / Files); on web it downloads the file. Returns a short description of
/// what happened, or null on failure.
Future<String?> exportBackupFile(String fileName, Uint8List bytes) =>
    impl.exportBackupFile(fileName, bytes);

/// Shares a rendered PNG — the QR card, saved or sent as a picture rather
/// than as a link. On mobile this opens the share sheet; on web the browser
/// takes it. Returns a short description, or null on failure.
Future<String?> shareImageBytes(String fileName, Uint8List bytes,
        {String subject = ''}) =>
    impl.shareImageBytes(fileName, bytes, subject: subject);
