import 'package:flutter/material.dart';

import '../models/link_preview.dart';
import '../screens/in_app_web_screen.dart';
import '../theme/app_theme.dart';
import 'chat_photo.dart';

/// A shared link, drawn as a card under the message text.
///
/// Under, never instead of: somebody typed those words around the link and
/// they are the message. The card is the extra.
class LinkPreviewCard extends StatelessWidget {
  const LinkPreviewCard({
    super.key,
    required this.preview,
    required this.textColor,
    required this.metaColor,
    this.onPlay,
  });

  final LinkPreview preview;
  final Color textColor;
  final Color metaColor;

  /// Opens the in-app player. Null leaves the card opening the link the
  /// ordinary way — which is also what every non-YouTube card does.
  final VoidCallback? onPlay;

  /// Opens the link on one of the app's OWN screens. Never a browser and
  /// never a handoff — the rule a test pins across every file in `lib`, and
  /// the reason the reel card says "Open in instagram.com" rather than
  /// promising to play it: opening it here is still opening it here.
  Future<void> _open(BuildContext context) =>
      InAppWebScreen.open(context, preview.url, title: preview.host);

  /// What the second line says the tap will do. A reel names the PAGE
  /// rather than showing a play button, because it does not play here —
  /// Instagram and Facebook serve reels behind a login — and a play button
  /// that only opens a page is a small lie told a hundred times a day.
  String get _action => switch (preview.kind) {
        LinkKind.youtube => 'Play',
        LinkKind.reel => 'Open on ${preview.host}',
        LinkKind.page => preview.host,
      };

  @override
  Widget build(BuildContext context) {
    final playable = preview.playable && onPlay != null;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: playable ? onPlay : () => _open(context),
        child: Container(
          width: 250,
          decoration: BoxDecoration(
            color: metaColor.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: metaColor.withValues(alpha: 0.25)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (preview.thumbnail.isNotEmpty)
                Stack(
                  alignment: Alignment.center,
                  children: [
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: ChatPhoto(
                          url: preview.thumbnail, fit: BoxFit.cover),
                    ),
                    if (playable)
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.play_arrow,
                            color: Colors.white, size: 30),
                      ),
                  ],
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (preview.title.isNotEmpty)
                      Text(preview.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: textColor,
                              fontSize: 14,
                              height: 1.25,
                              fontWeight: FontWeight.w700)),
                    if (preview.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(preview.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: metaColor, fontSize: 12.5, height: 1.25)),
                    ],
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(
                            preview.kind == LinkKind.youtube
                                ? Icons.play_circle_outline
                                : Icons.link,
                            size: 13,
                            color: metaColor),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(_action,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  TextStyle(color: metaColor, fontSize: 11.5)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
