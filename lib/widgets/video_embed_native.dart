import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Plays an embeddable video inside the app.
///
/// A WebView on YouTube's own embed page, which is the only way a
/// third-party app is permitted to play a YouTube video: their terms
/// require the official player, and scraping a stream URL would break both
/// the terms and, regularly, the app. So this is the player, hosted in the
/// app's own screen — the user never leaves, and YouTube still counts the
/// view and serves whatever it serves.
///
/// Deliberately NOT rendered inside a chat bubble. A WebView per bubble in a
/// scrolling list is several native views the list has to keep alive, and it
/// is how a chat starts stuttering; the bubble draws a thumbnail with a play
/// button, and the tap opens this.
class VideoEmbed {
  static bool get isSupported => true;

  /// [parentHost] is only for Twitch, whose embed refuses to play unless the
  /// origin embedding it matches the `parent` it was given — a clickjacking
  /// guard written for websites. A WebView told to load a URL has no origin
  /// at all, so for Twitch the player is loaded as a one-line HTML page whose
  /// BASE URL is the app's own web host, which is then the origin Twitch
  /// sees. YouTube needs none of this and keeps the plain, proven load.
  static Widget build({required String embedUrl, String parentHost = ''}) =>
      _EmbedView(embedUrl: embedUrl, parentHost: parentHost);
}

class _EmbedView extends StatefulWidget {
  const _EmbedView({required this.embedUrl, this.parentHost = ''});

  final String embedUrl;
  final String parentHost;

  @override
  State<_EmbedView> createState() => _EmbedViewState();
}

class _EmbedViewState extends State<_EmbedView> {
  late final WebViewController _controller = _build();

  WebViewController _build() {
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black);
    if (widget.parentHost.isEmpty) {
      c.loadRequest(Uri.parse(widget.embedUrl));
      return c;
    }
    // The iframe carries no controls of its own to add; the player inside it
    // is Twitch's, whole. The page is only here to give it an origin.
    c.loadHtmlString(
      '<!doctype html><meta name="viewport" '
      'content="width=device-width,initial-scale=1">'
      '<style>html,body{margin:0;height:100%;background:#000}'
      'iframe{border:0;width:100%;height:100%}</style>'
      '<iframe src="${widget.embedUrl}" allowfullscreen '
      'allow="autoplay; fullscreen; picture-in-picture"></iframe>',
      baseUrl: 'https://${widget.parentHost}',
    );
    return c;
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
