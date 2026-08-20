import 'dart:typed_data';

import 'backup_export_stub.dart'
    if (dart.library.io) 'backup_export_io.dart'
    if (dart.library.js_interop) 'backup_export_web.dart' as impl;

export 'backup_export_stub.dart'
    if (dart.library.io) 'backup_export_io.dart'
    if (dart.library.js_interop) 'backup_export_web.dart' show shareImageBytes;

/// What became of a file handed to the platform.
///
/// The helper below knows the MECHANISM; only the caller knows the noun, so
/// the sentence shown to somebody is theirs to write. It used to be the
/// helper's, and it said "backup" — which was fine for the one caller it was
/// written for and wrong for every other: exporting an inspection report
/// answered "Choose … to save your backup", and a dismissed share pointed at
/// a "Back up now" button that does not exist on that screen.
enum ExportOutcome {
  /// The OS share sheet took it. Where it goes is the user's next choice.
  shared,

  /// The browser downloaded it.
  downloaded,

  /// The share sheet was closed without picking anything.
  dismissed,

  /// It could not be handed over at all.
  failed,
}

/// Hands [bytes] to the platform as a file called [fileName], to share or
/// save.
///
/// **[mimeType] is what makes the file usable at the other end**, and
/// hardcoding it was the bug: this was written for an encrypted backup blob,
/// which genuinely is `application/octet-stream`, and then reused for PDFs
/// and web pages. iOS decides from the type which apps the share sheet
/// offers and whether Quick Look will preview it, and a browser decides from
/// the Blob's type whether to render or to download an unknown binary — so a
/// report exported as octet-stream arrives as something nothing will open.
Future<ExportOutcome> exportFile(String fileName, Uint8List bytes,
        {String mimeType = 'application/octet-stream'}) =>
    impl.exportFile(fileName, bytes, mimeType: mimeType);
