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

  static Widget build({required String embedUrl}) =>
      _EmbedView(embedUrl: embedUrl);
}

class _EmbedView extends StatefulWidget {
  const _EmbedView({required this.embedUrl});

  final String embedUrl;

  @override
  State<_EmbedView> createState() => _EmbedViewState();
}

class _EmbedViewState extends State<_EmbedView> {
  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setBackgroundColor(Colors.black)
    ..loadRequest(Uri.parse(widget.embedUrl));

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
