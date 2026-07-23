import 'dart:typed_data';

/// Fallback when neither dart:html nor dart:io is available.
Future<String?> exportBackupFile(String fileName, Uint8List bytes) async => null;
