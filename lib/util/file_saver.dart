import 'dart:typed_data';

import 'file_saver_stub.dart'
    if (dart.library.html) 'file_saver_web.dart'
    if (dart.library.io) 'file_saver_io.dart' as impl;

/// Saves received bytes as a file the user can open. On web this triggers a
/// browser download; on native it writes to a temporary file and returns its
/// path. Returns a short human description of where it went (or null on
/// failure).
Future<String?> saveIncomingFile(String fileName, Uint8List bytes) =>
    impl.saveFile(fileName, bytes);
