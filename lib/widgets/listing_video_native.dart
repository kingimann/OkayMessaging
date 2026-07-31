import 'dart:io';
import '../theme/app_theme.dart';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../state/market_media.dart';

/// Downloads a sealed listing video, unseals it, and plays it from a local
/// temp file. The bytes only ever exist in the clear on this device — the
/// bucket serves ciphertext, and the temp file is deleted with the player.
class ListingVideoPlayer {
  static bool get isSupported => true;

  static Widget build({
    required String communityId,
    required String path,
  }) =>
      _ListingVideo(communityId: communityId, path: path);
}

class _ListingVideo extends StatefulWidget {
  final String communityId;
  final String path;
  const _ListingVideo({required this.communityId, required this.path});

  @override
  State<_ListingVideo> createState() => _ListingVideoState();
}

class _ListingVideoState extends State<_ListingVideo> {
  VideoPlayerController? _controller;
  File? _tempFile;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await MarketMedia.instance
        .downloadVideo(widget.communityId, widget.path);
    if (!mounted) return;
    if (bytes == null) {
      setState(() {
        _loading = false;
        _error = 'Couldn\'t load the video. Check your connection.';
      });
      return;
    }
    try {
      final dir = await Directory.systemTemp.createTemp('okay_video');
      final file = File('${dir.path}/listing.mp4');
      await file.writeAsBytes(bytes, flush: true);
      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
        return;
      }
      setState(() {
        _tempFile = file;
        _controller = controller;
        _loading = false;
      });
      controller.play();
      controller.setLooping(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'This video can\'t be played on this device.';
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    // The decrypted copy does not outlive the player.
    try {
      _tempFile?.parent.deleteSync(recursive: true);
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final error = _error;
    if (error != null) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Center(
          child: Text(error,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.subtle(context), fontSize: 13.5)),
        ),
      );
    }
    final controller = _controller!;
    return AspectRatio(
      aspectRatio: controller.value.aspectRatio == 0
          ? 16 / 9
          : controller.value.aspectRatio,
      child: GestureDetector(
        onTap: () => setState(() {
          controller.value.isPlaying ? controller.pause() : controller.play();
        }),
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(controller),
            if (!controller.value.isPlaying)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow,
                    color: Colors.white, size: 36),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoProgressIndicator(controller, allowScrubbing: true),
            ),
          ],
        ),
      ),
    );
  }
}
