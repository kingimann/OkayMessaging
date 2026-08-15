import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import 'file_saver.dart';

/// What happened when somebody asked to keep a photo or a video.
///
/// An enum rather than a bool because the three failures need three different
/// sentences: "the app was told no" is a Settings trip, "this build cannot"
/// is nothing the person can act on, and "it broke" is worth retrying. One
/// "Couldn't save" for all of them sends somebody to the wrong place.
enum MediaSaveResult {
  saved,

  /// The photo library said no. Recoverable, in Settings.
  denied,

  /// No photo library to save to (the web build, and any desktop target).
  /// Falls back to a download and says so rather than pretending.
  downloaded,

  /// Nothing to save — the bytes never arrived.
  empty,

  failed,
}

/// Keeps media in the device's own photo library.
///
/// **`photo_manager` was already a dependency** — the attachment sheet's
/// recent-photos strip reads through it — so saving needs no new package and
/// no new permission prompt beyond the one the app already asks for.
///
/// Nothing here decides WHETHER a thing may be saved. That is the caller's
/// business, and it is not a small one: a chat with "forward and copy off"
/// and a view-once photo must both refuse, so the Save control is not drawn
/// in the first place rather than being drawn and then apologising. Keeping
/// that rule at the call sites means this file cannot quietly become the
/// place a new surface forgets to check.
class MediaSaver {
  const MediaSaver._();

  /// Test seam: stands in for the whole platform round trip, so the surfaces
  /// that offer Save can be exercised without a photo library.
  @visibleForTesting
  static Future<MediaSaveResult> Function(Uint8List bytes, String name)?
      debugSaveOverride;

  /// Whether this build has a photo library at all. False on web, where the
  /// honest answer is a download.
  static bool get hasGallery => !kIsWeb;

  static String _stamped(String ext) =>
      'okay_${DateTime.now().millisecondsSinceEpoch}.$ext';

  /// Saves an image. [name] is used only for the file, never shown.
  static Future<MediaSaveResult> saveImage(Uint8List bytes,
          {String? name}) async =>
      _save(bytes, name ?? _stamped('jpg'), video: false);

  /// Saves a video.
  static Future<MediaSaveResult> saveVideo(Uint8List bytes,
          {String? name}) async =>
      _save(bytes, name ?? _stamped('mp4'), video: true);

  static Future<MediaSaveResult> _save(Uint8List bytes, String name,
      {required bool video}) async {
    final override = debugSaveOverride;
    if (override != null) return override(bytes, name);
    if (bytes.isEmpty) return MediaSaveResult.empty;

    // No photo library here. A browser download is the real equivalent and
    // the caller says so in those words, rather than reporting "Saved to
    // Photos" about a thing that went to the downloads folder.
    if (!hasGallery) {
      final where = await saveIncomingFile(name, bytes);
      return where == null ? MediaSaveResult.failed : MediaSaveResult.downloaded;
    }

    try {
      // The library's own prompt, and only when saving — the app does not ask
      // for photo access on launch to make a Save button look enabled.
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.hasAccess) return MediaSaveResult.denied;
      if (video) {
        // saveVideo wants a File, so the bytes land in the temporary
        // directory first — through the same conditional shim the file saver
        // uses, which is what keeps `dart:io` out of this file and this file
        // importable on web.
        final file = await tempFileFor(name, bytes);
        if (file == null) return MediaSaveResult.failed;
        await PhotoManager.editor.saveVideo(file as dynamic, title: name);
        return MediaSaveResult.saved;
      }
      // A non-null AssetEntity is the only success `photo_manager` reports —
      // it throws on refusal, which the catch below turns into `failed`.
      await PhotoManager.editor.saveImage(bytes, filename: name);
      return MediaSaveResult.saved;
    } catch (_) {
      // A platform channel that throws is a failure, not a crash: somebody
      // asked to keep a photo, and the worst honest outcome is being told it
      // did not work.
      return MediaSaveResult.failed;
    }
  }

  /// The sentence to show for each outcome. Here rather than at each call
  /// site so three surfaces cannot invent three different wordings for the
  /// same failure.
  static String message(MediaSaveResult r, {required bool video}) {
    final what = video ? 'Video' : 'Photo';
    return switch (r) {
      MediaSaveResult.saved => '$what saved to your library',
      MediaSaveResult.downloaded => '$what downloaded',
      MediaSaveResult.denied =>
        'Allow photo access in Settings to save this $what'
            .replaceFirst('this $what', video ? 'videos' : 'photos'),
      MediaSaveResult.empty => 'Nothing to save yet — it is still loading',
      MediaSaveResult.failed => "Couldn't save that $what",
    };
  }
}
