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

/// Writes [bytes] to a real file in the temporary directory and hands it
/// back, for the platform APIs that take a File rather than bytes —
/// `photo_manager`'s `saveVideo` is the one that needed it.
///
/// Returned as `Object?` so the shim's signature is the same on every
/// platform: `dart:io` does not exist on web, and a `File` in the type would
/// make this file impossible to reference from one that does.
Future<Object?> tempFileFor(String fileName, Uint8List bytes) async {
  try {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes);
    return file;
  } catch (_) {
    return null;
  }
}
