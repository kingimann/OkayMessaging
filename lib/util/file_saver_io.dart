import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Writes the received bytes to a file in the app's documents directory and
/// returns a description of where it was saved.
Future<String?> saveFile(String fileName, Uint8List bytes) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/$fileName';
    await File(path).writeAsBytes(bytes);
    return 'Saved to $path';
  } catch (_) {
    return null;
  }
}
