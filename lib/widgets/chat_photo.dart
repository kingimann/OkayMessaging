import 'package:flutter/material.dart';

import '../util/photo_prep.dart';

/// Renders a chat photo from its [url] — an inline `data:` URI (a real photo
/// sent over the relay) or a network URL (a GIF from the provider's CDN) — with one
/// [errorBuilder] contract for both.
class ChatPhoto extends StatelessWidget {
  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget Function(BuildContext)? errorBuilder;

  const ChatPhoto({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.errorBuilder,
  });

  @override
  Widget build(BuildContext context) {
    Widget error(BuildContext context, Object _, StackTrace? __) =>
        errorBuilder?.call(context) ?? const SizedBox.shrink();
    final bytes = PhotoPrep.bytesFromDataUri(url);
    if (bytes != null) {
      return Image.memory(bytes,
          fit: fit, width: width, height: height, errorBuilder: error);
    }
    if (PhotoPrep.isDataUri(url)) {
      // A data URI that wouldn't decode — treat like a broken link.
      return error(context, url, null);
    }
    return Image.network(url,
        fit: fit, width: width, height: height, errorBuilder: error);
  }
}
