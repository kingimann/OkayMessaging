import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

/// What the page prefixes a client-secret request with, followed by an id the
/// answer is tagged with. Matches `notify('secret:' + id)` in web/connect.html.
const String _kSecretRequest = 'secret:';

/// The WebView that hosts Stripe's Connect embedded components.
///
/// Onboarding renders inside the app's own screen rather than in a browser or
/// a popup. Stripe's forms still run in Stripe's own code — which is what
/// keeps identity and banking details going straight to them and never
/// through this app — but the user never leaves.
class ConnectWebView {
  static bool get isSupported => true;

  /// Whether [url] is the return URL a Stripe-hosted flow ends on. Pure, and
  /// only ever true when a prefix was given — our own pages report completion
  /// by message, and one of them is served from the same origin as the return
  /// URL, so an empty prefix must never match anything.
  static bool isCompletion(String url, String prefix) =>
      prefix.isNotEmpty && url.startsWith(prefix);

  /// [needsCamera] is for the ID check, which captures a document photo and a
  /// selfie in the page. Without inline playback and a granted permission the
  /// capture silently fails to start.
  ///
  /// [onSecretRequest] answers the page's requests for a client secret. Stripe
  /// asks again whenever the session expires and wants a *new* one each time,
  /// so the page holds none and the app mints them.
  ///
  /// [completionUrlPrefix] is for flows hosted by Stripe rather than by one of
  /// our own pages: those end by *navigating* to a return URL instead of
  /// posting a message, so a navigation starting with this prefix is reported
  /// as 'submitted' and blocked — the app's screen is where the user lands,
  /// not whatever that URL happens to serve.
  static Widget build({
    required String url,
    required String clientSecret,
    required String publishableKey,
    required bool dark,
    required Color accent,
    required void Function(String event) onEvent,
    bool needsCamera = false,
    Future<String> Function()? onSecretRequest,
    String completionUrlPrefix = '',
  }) =>
      _ConnectWebView(
        url: url,
        clientSecret: clientSecret,
        publishableKey: publishableKey,
        dark: dark,
        accent: accent,
        onEvent: onEvent,
        needsCamera: needsCamera,
        onSecretRequest: onSecretRequest,
        completionUrlPrefix: completionUrlPrefix,
      );
}

class _ConnectWebView extends StatefulWidget {
  final String url;
  final String clientSecret;
  final String publishableKey;
  final bool dark;
  final Color accent;
  final void Function(String event) onEvent;
  final bool needsCamera;
  final Future<String> Function()? onSecretRequest;
  final String completionUrlPrefix;

  const _ConnectWebView({
    required this.url,
    required this.clientSecret,
    required this.publishableKey,
    required this.dark,
    required this.accent,
    required this.onEvent,
    required this.needsCamera,
    required this.onSecretRequest,
    required this.completionUrlPrefix,
  });

  @override
  State<_ConnectWebView> createState() => _ConnectWebViewState();
}

class _ConnectWebViewState extends State<_ConnectWebView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    // The ID check films a document and a face, which WKWebView will not do
    // unless inline playback is allowed up front.
    final params = widget.needsCamera && WebViewPlatform.instance is WebKitWebViewPlatform
        ? WebKitWebViewControllerCreationParams(
            allowsInlineMediaPlayback: true,
            mediaTypesRequiringUserAction: const {},
          )
        : const PlatformWebViewControllerCreationParams();
    _controller = WebViewController.fromPlatformCreationParams(
      params,
      // The user already agreed to the ID check on the previous screen; a
      // second prompt inside the page is friction, not consent.
      onPermissionRequest: widget.needsCamera ? (r) => r.grant() : null,
    )..setJavaScriptMode(JavaScriptMode.unrestricted)
      // The page paints its own background so it matches the app's theme
      // rather than flashing white on a dark screen.
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel('OkayConnect',
          onMessageReceived: (m) => _onMessage(m.message))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _keepBlankLinksInside();
            _start();
          },
          onNavigationRequest: _onNavigation,
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  /// The end of a Stripe-hosted flow is a navigation, not a message. Catch it,
  /// tell the screen, and refuse the navigation — the user belongs back in the
  /// app, not on whatever the return URL serves. (It serves the web build of
  /// this very app, so without this the WebView would show the app inside the
  /// app.)
  ///
  /// Only once the first page has loaded: our own identity page is served from
  /// the same origin as the return URL, so its own initial load looks exactly
  /// like a completion.
  NavigationDecision _onNavigation(NavigationRequest request) {
    if (_started &&
        ConnectWebView.isCompletion(
            request.url, widget.completionUrlPrefix)) {
      widget.onEvent('submitted');
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  /// Makes `target="_blank"` links navigate here instead of nowhere.
  ///
  /// Stripe's forms mark their terms, privacy and "learn more" links to open in
  /// a new window. WKWebView has no window to give them, so it drops the
  /// request and the link reads as broken — which is worse than either opening
  /// it or not having it. Re-pointing the click at this frame keeps them
  /// working without anything leaving the app.
  ///
  /// Runs on every page load, because the flow navigates between pages.
  ///
  /// Deliberately does NOT touch `window.open`: bank verification opens a real
  /// popup and talks back to its opener, and forcing that into this frame would
  /// break the handshake rather than fix it.
  void _keepBlankLinksInside() {
    _controller.runJavaScript('''
(function () {
  if (window.__okayBlankPatched) return;
  window.__okayBlankPatched = true;
  document.addEventListener('click', function (e) {
    var el = e.target;
    while (el && el.tagName !== 'A') el = el.parentElement;
    if (!el || el.target !== '_blank' || !el.href) return;
    e.preventDefault();
    window.location.href = el.href;
  }, true);
})();
''');
  }

  /// A message from the page: either a request for a client secret, or an
  /// event for the screen.
  Future<void> _onMessage(String message) async {
    if (!message.startsWith(_kSecretRequest)) {
      widget.onEvent(message);
      return;
    }
    final id = message.substring(_kSecretRequest.length);
    var secret = '';
    var reason = '';
    try {
      secret = await widget.onSecretRequest?.call() ?? '';
    } catch (e) {
      // Why it failed, handed to the page rather than reported separately.
      //
      // Reporting it here as well produced two error events for one failure —
      // this detailed one, then the page's generic "the app could not start a
      // Stripe session" — and the second overwrote the first, so the useful
      // half was always the one thrown away. The page owns the message; this
      // gives it something worth saying.
      reason = '$e';
    }
    if (!mounted) return;
    await _controller.runJavaScript(
      'window.okaySecret && window.okaySecret('
      '${_js(id)}, ${_js(secret)}, ${_js(reason)});',
    );
  }

  bool _started = false;

  /// Hands the client secret over *after* the page loads, so it never appears
  /// in a URL, in history, or in any log of one.
  ///
  /// Once only: onPageFinished can fire more than once for the same page, and
  /// a second init would authenticate a session Stripe has already consumed.
  void _start() {
    if (_started) return;
    _started = true;
    final hex =
        '#${(widget.accent.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    _controller.runJavaScript(
      'window.okayStart && window.okayStart('
      '${_js(widget.clientSecret)}, ${_js(widget.publishableKey)}, '
      '${widget.dark}, ${_js(hex)});',
    );
  }

  /// A JS string literal, quoted and escaped.
  static String _js(String value) => "'"
      "${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('\n', r'\n')}"
      "'";

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
