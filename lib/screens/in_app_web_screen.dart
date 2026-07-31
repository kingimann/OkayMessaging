import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../payments/connect_webview.dart';
import '../theme/app_theme.dart';

/// Any web page, on one of the app's own screens.
///
/// Nothing in this app hands a link to a browser. A page opened here keeps the
/// app's app bar and the back gesture, and shows the host it is actually on —
/// which a browser handoff never did, because by then the user had left.
///
/// The web build has no WebView (webview_flutter is mobile-only), and there
/// "opening a tab" means a tab in the browser the app is already running in,
/// so [open] falls back to that rather than refusing.
class InAppWebScreen extends StatefulWidget {
  final String url;
  final String title;

  const InAppWebScreen({super.key, required this.url, this.title = ''});

  /// Shows [url] on an app screen. Ignores anything that isn't http(s): a link
  /// in a post is untrusted text, and `javascript:` or a custom scheme is not
  /// something to hand anywhere.
  static Future<void> open(BuildContext context, String url,
      {String title = ''}) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return;
    if (ConnectWebView.isSupported) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => InAppWebScreen(url: uri.toString(), title: title),
      ));
      return;
    }
    // Web build only: a tab in the browser this already is.
    try {
      await launchUrl(uri);
    } catch (_) {}
  }

  @override
  State<InAppWebScreen> createState() => _InAppWebScreenState();
}

class _InAppWebScreenState extends State<InAppWebScreen> {
  String? _error;

  void _onEvent(String event) {
    const prefix = 'error:';
    if (mounted && event.startsWith(prefix)) {
      setState(() => _error = event.substring(prefix.length));
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(widget.url)?.host ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title.isEmpty ? host : widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16)),
            // Whose page this is. A browser at least showed an address bar;
            // an in-app WebView that hides it is worse, not better.
            if (widget.title.isNotEmpty && host.isNotEmpty)
              Text(host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5, color: Colors.grey.shade400)),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: !ConnectWebView.isSupported
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text('Opening pages needs the mobile app.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.subtle(context))),
              ),
            )
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline,
                            size: 42, color: Colors.grey.shade400),
                        const SizedBox(height: 14),
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.subtle(context))),
                        const SizedBox(height: 18),
                        OutlinedButton(
                          onPressed: () => setState(() => _error = null),
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                )
              : ConnectWebView.build(
                  url: widget.url,
                  // Not a Stripe page; nothing of ours to hand it.
                  clientSecret: '',
                  publishableKey: '',
                  dark: Theme.of(context).brightness == Brightness.dark,
                  accent: AppColors.accentOn(context),
                  onEvent: _onEvent,
                ),
    );
  }
}
