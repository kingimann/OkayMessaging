import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Writes the encrypted backup to a temp file and opens the system share sheet,
/// from which the user can pick iCloud Drive, Dropbox, Google Drive, or Files.
Future<String?> exportBackupFile(String fileName, Uint8List bytes) async {
  try {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/$fileName';
    await File(path).writeAsBytes(bytes);
    await Share.shareXFiles(
      [XFile(path, mimeType: 'application/octet-stream')],
      subject: fileName,
    );
    return 'Choose iCloud Drive, Dropbox, Google Drive, or Files to save your '
        'backup.';
  } catch (_) {
    return null;
  }
}
