import 'package:flutter/material.dart';

/// Web build: no dart:io, no temp file, no player. The tile says where the
/// video CAN be watched instead of pretending nothing exists.
class ListingVideoPlayer {
  static bool get isSupported => false;

  static Widget build({
    required String communityId,
    required String path,
  }) =>
      const SizedBox.shrink();
}
