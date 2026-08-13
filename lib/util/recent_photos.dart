import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

/// One recent photo from the device's own library, for the chat composer's
/// inline strip. Holds byte-provider closures rather than photo_manager's
/// own [AssetEntity] directly, for two reasons: nothing outside this file
/// needs that type (the same shape [PhotoPrep] keeps around its own picker
/// calls), and an [AssetEntity] cannot be constructed by hand — there is no
/// device photo library in a test, so [RecentPhoto.forTest] is the only way
/// a test can ever produce one of these.
class RecentPhoto {
  final String id;
  final Future<Uint8List?> Function() _thumbnail;
  final Future<Uint8List?> Function() _sendBytes;

  const RecentPhoto._(this.id, this._thumbnail, this._sendBytes);

  factory RecentPhoto._fromAsset(AssetEntity asset) => RecentPhoto._(
        asset.id,
        () => asset.thumbnailDataWithSize(const ThumbnailSize.square(240)),
        // Send-quality bytes. Deliberately NOT the asset's origin bytes — an
        // original can be many megabytes and, with iCloud Photos storage
        // optimization on, may not even be downloaded to the phone yet, so
        // asking for it can stall on a slow fetch for a photo
        // `PhotoPrep.prepare` is about to shrink to well under its wire
        // budget anyway. 1280px already matches `prepare`'s own
        // first-attempt ceiling, so nothing above that is ever kept
        // regardless of source.
        () => asset.thumbnailDataWithSize(const ThumbnailSize.square(1280)),
      );

  @visibleForTesting
  factory RecentPhoto.forTest({
    required String id,
    required Future<Uint8List?> Function() thumbnail,
    required Future<Uint8List?> Function() sendBytes,
  }) =>
      RecentPhoto._(id, thumbnail, sendBytes);

  /// A small preview for the strip.
  Future<Uint8List?> thumbnail() => _thumbnail();

  /// Send-quality bytes. The caller still owns moderating and shrinking
  /// them — this file only lists what's on the device and reads it, never
  /// decides what may be sent.
  Future<Uint8List?> sendBytes() => _sendBytes();
}

/// Enumerates the device's own recent photos for the chat composer's inline
/// strip — tap a thumbnail and it sends, no separate full-screen picker.
/// [PhotoPrep] still governs what happens to whatever is picked here:
/// moderation, resizing, the relay's wire budget — this file only lists what
/// is on the device, never touches the network, and never decides what may
/// be sent.
class RecentPhotos {
  RecentPhotos._();

  /// Whether this platform can even ask. photo_manager has no web
  /// implementation — there is no browser API for "list my camera roll" —
  /// so the strip is unavailable there and the composer falls back to the
  /// existing full picker rather than showing a tray that can only ever be
  /// empty.
  static bool get supported => !kIsWeb;

  /// Test hook: replaces the real permission + library calls, since there is
  /// no device photo library to enumerate in a test.
  @visibleForTesting
  static Future<List<RecentPhoto>?> Function()? debugOverride;

  /// The most recent [count] photos, or null when permission was refused or
  /// this platform can't ask at all — distinct from an empty list (a real,
  /// empty library), so the UI can tell "nothing to show" from "ask again".
  static Future<List<RecentPhoto>?> recent({int count = 30}) async {
    if (debugOverride != null) return debugOverride!();
    if (!supported) return null;
    final state = await PhotoManager.requestPermissionExtend();
    if (!state.hasAccess) return null;
    final paths = await PhotoManager.getAssetPathList(
        onlyAll: true, type: RequestType.image);
    if (paths.isEmpty) return const [];
    final assets = await paths.first.getAssetListRange(start: 0, end: count);
    return [for (final a in assets) RecentPhoto._fromAsset(a)];
  }

  @visibleForTesting
  static void resetForTest() => debugOverride = null;
}
