import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import 'file_moderation.dart';

/// One item picked from the device's Photos library — a photo OR a video,
/// from the SAME picker screen. Every real photo picker (iOS's
/// PHPickerViewController, Android's Photo Picker) already offers both in
/// one place; a separate "Video" button that opens something else (this
/// app's old one opened the generic file browser) is the odd one out, not
/// the unified picker.
@immutable
class PickedMedia {
  const PickedMedia(
      {required this.bytes, required this.isVideo, required this.fileName});

  /// The file's own bytes, moderated but — for a photo — not yet resized:
  /// that budget differs per caller (a relay message vs. a bucket upload),
  /// so the shrink step ([PhotoPrep.prepare]) stays the caller's own.
  final Uint8List bytes;

  final bool isVideo;

  final String fileName;
}

/// Picks a photo or video from the library in one flow, replacing the old
/// pattern of two separate buttons — one for [PhotoPrep.pickPhoto], one for
/// a video picked through [NearbyPick] (built for handing a file to someone
/// standing next to you, which is why its picker opened the Files app: it
/// has no reason to assume Photos is where the file lives).
class MediaPrep {
  MediaPrep._();

  /// Test hook: replaces the platform picker with (bytes, filename).
  @visibleForTesting
  static Future<(Uint8List, String)?> Function()? debugPickOverride;

  /// Opens the platform's unified photo/video picker. Returns null when
  /// nothing was picked; throws [FileRejected] with a reason the UI can
  /// show when what was picked can't be used.
  ///
  /// [videoLimit] is the caller's own ceiling for a video upload (a bucket
  /// quota, not a broadcast budget — video never rides the relay).
  static Future<PickedMedia?> pick({required int videoLimit}) async {
    Uint8List? bytes;
    String name = '';
    final override = debugPickOverride;
    if (override != null) {
      final picked = await override();
      if (picked == null) return null;
      bytes = picked.$1;
      name = picked.$2;
    } else {
      // pickMedia (not pickImage) is what makes this ONE picker rather than
      // two: PHPickerViewController on iOS offers photos and videos side by
      // side, and this is the image_picker call that reaches it.
      final media = await ImagePicker().pickMedia();
      if (media == null) return null;
      bytes = await media.readAsBytes();
      name = media.name;
    }
    if (bytes.isEmpty) return null;

    final kind = FileModeration.sniff(bytes);
    if (kind == 'video') {
      // Nothing else in FileModeration allows video through an UPLOAD path
      // on purpose (inspectImage/inspectFile both refuse it) — inspectNearby
      // is reused here for its size/hash checks only, the same way the
      // video button already did before this picker was unified.
      final verdict = FileModeration.inspectNearby(bytes, limit: videoLimit);
      if (!verdict.allowed) throw FileRejected(verdict.reason!);
      return PickedMedia(bytes: bytes, isVideo: true, fileName: name);
    }
    // Not sniffed as video — treated as a photo attempt regardless of what
    // it turns out to be; the caller's own PhotoPrep.moderateAndPrepare call
    // is what actually validates it as a real, allowed image and refuses
    // anything else, so this file doesn't duplicate that check.
    return PickedMedia(bytes: bytes, isVideo: false, fileName: name);
  }
}
