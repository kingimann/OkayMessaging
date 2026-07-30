import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;

import 'file_moderation.dart';

/// Turns a real photo from the device into something the relay can carry.
///
/// The relay is an ephemeral broadcast with a payload cap of roughly a
/// quarter-megabyte, and a photo rides *inside* the encrypted content blob —
/// so the image is resized and re-encoded as JPEG until its base64 form fits
/// [maxBase64Length], then shipped as a `data:` URI in the message's
/// `imageUrl`. No bucket, no upload: the photo goes device-to-device like the
/// text around it, and each side keeps its own copy.
class PhotoPrep {
  PhotoPrep._();

  /// Budget for the base64 payload. Encryption re-base64s the blob (~4/3
  /// growth), so this keeps the final wire payload safely under the relay's
  /// cap while still allowing a clearly readable photo.
  static const int maxBase64Length = 140000;

  /// Test hook: replaces the file-picker dialog.
  static Future<Uint8List?> Function()? debugPickOverride;

  /// Opens the platform's photo picker and returns the prepared `data:` URI,
  /// or null when the user cancelled or nothing usable was picked.
  /// [maxBase64] is the byte budget for the encoded result. It defaults to the
  /// relay's limit, which is what a chat photo has to fit; a picture bound for
  /// a storage bucket has no broadcast to squeeze into and can pass a bigger
  /// one.
  static Future<String?> pickPhoto({int maxBase64 = maxBase64Length}) async {
    Uint8List? bytes;
    if (debugPickOverride != null) {
      bytes = await debugPickOverride!();
    } else {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        withData: true,
      );
      bytes = result?.files.firstOrNull?.bytes;
    }
    if (bytes == null || bytes.isEmpty) return null;
    // Nothing leaves the device unmoderated: only real images pass, and a
    // rejection is surfaced (thrown) so the UI can say why.
    final verdict = FileModeration.inspectImage(bytes);
    if (!verdict.allowed) throw FileRejected(verdict.reason!);
    return prepare(bytes, maxBase64: maxBase64);
  }

  /// The picked image's own bytes, moderated but not shrunk.
  ///
  /// [pickPhoto] exists to fit a photo into a relay message, so it resizes and
  /// returns a data: URI. An identity document is the opposite problem: it goes
  /// to Stripe as a file, and squeezing it to a chat-sized payload is how a
  /// licence becomes too blurry to verify. Moderation still runs — nothing
  /// leaves this device unchecked.
  static Future<Uint8List?> pickBytes() async {
    Uint8List? bytes;
    if (debugPickOverride != null) {
      bytes = await debugPickOverride!();
    } else {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        withData: true,
      );
      bytes = result?.files.firstOrNull?.bytes;
    }
    if (bytes == null || bytes.isEmpty) return null;
    final verdict = FileModeration.inspectImage(bytes);
    if (!verdict.allowed) throw FileRejected(verdict.reason!);
    return bytes;
  }

  /// Resizes and re-encodes [original] until it fits the wire budget.
  /// Returns the `data:image/jpeg;base64,…` URI, or null for undecodable
  /// input. Pure, so the shrink loop is unit-testable with generated images.
  static String? prepare(Uint8List original,
      {int maxBase64 = maxBase64Length}) {
    img.Image? decoded;
    try {
      decoded = img.decodeImage(original);
    } catch (_) {
      return null;
    }
    if (decoded == null) return null;
    // The photo's EXIF rotation must be applied before the metadata is
    // dropped by re-encoding, or portraits arrive lying on their side.
    decoded = img.bakeOrientation(decoded);

    var maxSide = 1280;
    var quality = 75;
    while (true) {
      var frame = decoded;
      if (frame.width > maxSide || frame.height > maxSide) {
        frame = img.copyResize(
          frame,
          width: frame.width >= frame.height ? maxSide : null,
          height: frame.height > frame.width ? maxSide : null,
          interpolation: img.Interpolation.average,
        );
      }
      final jpeg = img.encodeJpg(frame, quality: quality);
      final b64 = base64Encode(jpeg);
      if (b64.length <= maxBase64) return 'data:image/jpeg;base64,$b64';
      // Still too big: shrink harder, then trade quality.
      if (maxSide > 480) {
        maxSide = (maxSide * 0.75).round();
      } else if (quality > 30) {
        quality -= 15;
      } else {
        // A pathological image that won't compress — refuse rather than jam
        // the relay with a payload that would be dropped anyway.
        return null;
      }
    }
  }

  /// Whether [url] is an inline photo produced by [prepare].
  static bool isDataUri(String url) => url.startsWith('data:image/');

  /// The raw bytes of a `data:` URI photo, or null when [url] isn't one (or
  /// is malformed).
  static Uint8List? bytesFromDataUri(String url) {
    if (!isDataUri(url)) return null;
    final comma = url.indexOf(',');
    if (comma == -1) return null;
    try {
      return base64Decode(url.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }
}
