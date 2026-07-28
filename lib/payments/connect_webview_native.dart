import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

/// The WebView that hosts Stripe's Connect embedded components.
///
/// Onboarding renders inside the app's own screen rather than in a browser or
/// a popup. Stripe's forms still run in Stripe's own code — which is what
/// keeps identity and banking details going straight to them and never
/// through this app — but the user never leaves.
class ConnectWebView {
  static bool get isSupported => true;

  /// [needsCamera] is for the ID check, which captures a document photo and a
  /// selfie in the page. Without inline playback and a granted permission the
  /// capture silently fails to start.
  static Widget build({
    required String url,
    required String clientSecret,
    required String publishableKey,
    required bool dark,
    required Color accent,
    required void Function(String event) onEvent,
    bool needsCamera = false,
  }) =>
      _ConnectWebView(
        url: url,
        clientSecret: clientSecret,
        publishableKey: publishableKey,
        dark: dark,
        accent: accent,
        onEvent: onEvent,
        needsCamera: needsCamera,
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

  const _ConnectWebView({
    required this.url,
    required this.clientSecret,
    required this.publishableKey,
    required this.dark,
    required this.accent,
    required this.onEvent,
    required this.needsCamera,
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
          onMessageReceived: (m) => widget.onEvent(m.message))
      ..setNavigationDelegate(
        NavigationDelegate(onPageFinished: (_) => _start()),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  /// Hands the client secret over *after* the page loads, so it never appears
  /// in a URL, in history, or in any log of one.
  void _start() {
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
