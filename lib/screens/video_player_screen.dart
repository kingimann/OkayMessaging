import 'package:flutter/material.dart';

import '../models/link_preview.dart';
import '../theme/app_theme.dart';
import '../widgets/video_embed.dart';
import 'in_app_web_screen.dart';

/// Plays a shared video without leaving the app.
///
/// Only reached for a link the app can actually play — YouTube, via its own
/// embed player (see [VideoEmbed]). Everything else opens where it lives,
/// and the card that leads here says so rather than showing a play button
/// that hands you to another app.
class VideoPlayerScreen extends StatelessWidget {
  const VideoPlayerScreen({super.key, required this.preview});

  final LinkPreview preview;

  /// The video's own page, on one of the app's own screens — the same rule
  /// every other link follows.
  Future<void> _openPage(BuildContext context) =>
      InAppWebScreen.open(context, preview.url, title: preview.host);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(preview.title.isEmpty ? preview.host : preview.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Open the page',
            icon: const Icon(Icons.open_in_new),
            onPressed: () => _openPage(context),
          ),
        ],
      ),
      body: Center(
        child: VideoEmbed.isSupported
            ? AspectRatio(
                aspectRatio: 16 / 9,
                child: VideoEmbed.build(embedUrl: preview.embedUrl),
              )
            : Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.smart_display_outlined,
                        size: 46, color: Colors.white70),
                    const SizedBox(height: 14),
                    Text(
                      'Videos play in the app on your phone. Here, this '
                      'opens the page instead.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: AppColors.subtle(context), height: 1.4),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => _openPage(context),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Open the page'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
