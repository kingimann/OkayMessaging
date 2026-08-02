import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../theme/app_theme.dart';

/// A video on the public feed, played straight from its bucket URL.
///
/// Different from [ListingVideoPlayer] on purpose. A listing's video is
/// sealed with its server's secret, so it has to be downloaded whole,
/// decrypted, written to a temp file and played from disk — which is why it
/// does not work on the web at all. A public post is world-readable by
/// definition: there is nobody to keep the bytes from, so they sit in the
/// bucket in the clear and `VideoPlayerController.networkUrl` streams them.
/// That works everywhere the app does, and it starts playing before the whole
/// file has arrived.
///
/// **Muted, and it does not start on its own.** Video that plays itself is
/// the single most complained-about thing on a feed, it burns somebody's data
/// on a post they were scrolling past, and on a public timeline it is how a
/// room full of phones all start shouting at once.
class FeedVideo extends StatefulWidget {
  final String url;

  /// Shape of the box before the first frame is known, so the timeline does
  /// not jump when the video loads.
  final double aspectRatio;

  const FeedVideo({super.key, required this.url, this.aspectRatio = 16 / 9});

  @override
  State<FeedVideo> createState() => _FeedVideoState();
}

class _FeedVideoState extends State<FeedVideo> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null) {
      setState(() => _failed = true);
      return;
    }
    final controller = VideoPlayerController.networkUrl(uri);
    try {
      await controller.initialize();
      await controller.setLooping(true);
      // Sound is a decision, not a default.
      await controller.setVolume(0);
    } catch (_) {
      await controller.dispose();
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() => _controller = controller);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _toggle() {
    final c = _controller;
    if (c == null) return;
    setState(() => c.value.isPlaying ? c.pause() : c.play());
  }

  void _toggleSound() {
    final c = _controller;
    if (c == null) return;
    setState(() => c.setVolume(c.value.volume > 0 ? 0 : 1));
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (_failed) {
      return AspectRatio(
        aspectRatio: widget.aspectRatio,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Center(
            child: Icon(Icons.videocam_off_outlined,
                color: AppColors.subtle(context)),
          ),
        ),
      );
    }
    if (c == null) {
      return AspectRatio(
        aspectRatio: widget.aspectRatio,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(
              child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2))),
        ),
      );
    }
    final playing = c.value.isPlaying;
    return AspectRatio(
      aspectRatio: c.value.aspectRatio > 0
          ? c.value.aspectRatio
          : widget.aspectRatio,
      child: GestureDetector(
        onTap: _toggle,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(c),
            // Only while paused: a play glyph sitting on top of moving video
            // is the badge every autoplaying feed wears, and this one is not
            // autoplaying.
            if (!playing)
              const DecoratedBox(
                decoration: BoxDecoration(
                    color: Colors.black45, shape: BoxShape.circle),
                child: Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.play_arrow,
                      size: 34, color: Colors.white),
                ),
              ),
            Positioned(
              right: 8,
              bottom: 8,
              child: GestureDetector(
                onTap: _toggleSound,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                      color: Colors.black45, shape: BoxShape.circle),
                  child: Padding(
                    padding: const EdgeInsets.all(7),
                    child: Icon(
                        c.value.volume > 0
                            ? Icons.volume_up
                            : Icons.volume_off,
                        size: 17,
                        color: Colors.white),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoProgressIndicator(c, allowScrubbing: true),
            ),
          ],
        ),
      ),
    );
  }
}
