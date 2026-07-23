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
