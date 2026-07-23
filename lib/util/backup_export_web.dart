// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

/// On web there is no OS share sheet, so download the encrypted backup; the
/// user then uploads it to their cloud drive of choice.
Future<String?> exportBackupFile(String fileName, Uint8List bytes) async {
  final blob = html.Blob([bytes]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', fileName)
    ..click();
  html.Url.revokeObjectUrl(url);
  return 'Backup downloaded — upload it to iCloud Drive, Dropbox, or Google '
      'Drive to keep it safe.';
}
