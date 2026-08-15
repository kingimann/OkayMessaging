import 'dart:typed_data';

/// Fallback used on platforms without a concrete implementation (e.g. the test
/// VM). Saving is a no-op there.
Future<String?> saveFile(String fileName, Uint8List bytes) async => null;

/// No filesystem here, so no file to hand back.
Future<Object?> tempFileFor(String fileName, Uint8List bytes) async => null;
