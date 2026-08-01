import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../util/file_moderation.dart';

/// Something chosen from the device, ready to hand to somebody in the room.
@immutable
class PickedItem {
  const PickedItem({
    required this.dataUri,
    required this.fileName,
    required this.kind,
    required this.bytes,
  });

  /// The whole file as a `data:<type>;base64,…` URI. The transfer pipeline
  /// moves text, so this is the form it travels in.
  final String dataUri;

  final String fileName;

  /// 'image', 'video' or 'file' — what the far end should do with it.
  final String kind;

  /// Size of the original file in bytes, for saying so before it is sent.
  final int bytes;
}

/// Picking anything at all to hand to somebody standing next to you.
///
/// SEPARATE FROM PhotoPrep, which exists to squeeze a photo into a relay
/// message: that path resizes until the base64 fits a quarter-megabyte,
/// because the picture has to ride inside an encrypted broadcast. Nothing
/// here is broadcast and nothing is stored, so a file goes as it is — the
/// only ceiling is what the radio between the two phones can carry, and the
/// caller passes that in because Bluetooth LE and a direct Wi-Fi link are not
/// remotely the same offer.
class NearbyPick {
  NearbyPick._();

  /// Test hook: returns (bytes, name) instead of opening a picker.
  @visibleForTesting
  static Future<(Uint8List, String)?> Function()? debugPickOverride;

  /// The content type a kind travels as.
  ///
  /// It matters for images specifically: the chat draws a received picture
  /// from its data: URI, and the widgets that decode one check for an
  /// `image/` prefix. Everything else is bytes to be written to disk, and
  /// octet-stream is the honest label for that.
  static String mimeFor(String kind) => switch (kind) {
        'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'bmp' => 'image/bmp',
        'heic' => 'image/heic',
        'video' => 'video/mp4',
        'pdf' => 'application/pdf',
        'text' => 'text/plain',
        _ => 'application/octet-stream',
      };

  /// Wraps [bytes] as a data: URI of the type [kind] travels as. Pure.
  static String dataUriFor(Uint8List bytes, String kind) =>
      'data:${mimeFor(kind)};base64,${base64Encode(bytes)}';

  /// Opens the picker and moderates what comes back.
  ///
  /// [limit] is the ceiling in bytes of original file — the caller works it
  /// out from the transport that would carry it. Throws [FileRejected] with a
  /// reason the UI can show; returns null when the picker was dismissed.
  static Future<PickedItem?> pick({required int limit}) async {
    Uint8List? bytes;
    String name = '';
    final override = debugPickOverride;
    if (override != null) {
      final picked = await override();
      if (picked == null) return null;
      bytes = picked.$1;
      name = picked.$2;
    } else {
      final result = await FilePicker.pickFiles(withData: true);
      final file = result?.files.firstOrNull;
      if (file?.bytes == null) return null;
      bytes = file!.bytes;
      name = file.name;
    }
    if (bytes == null || bytes.isEmpty) return null;

    // Nothing leaves this device unmoderated, on any path. Executables and
    // scripts are refused here as everywhere; video is not, because there is
    // no server on the other side of this one.
    final verdict = FileModeration.inspectNearby(bytes, limit: limit);
    if (!verdict.allowed) throw FileRejected(verdict.reason!);

    return PickedItem(
      dataUri: dataUriFor(bytes, verdict.kind),
      fileName: name.trim().isEmpty ? 'File' : name.trim(),
      kind: FileModeration.handlingFor(verdict.kind),
      bytes: bytes.length,
    );
  }
}
