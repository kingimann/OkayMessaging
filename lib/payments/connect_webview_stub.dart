import 'package:flutter/material.dart';

/// Web / default implementation. The embedded Connect components need a
/// WebView, which only exists on mobile, so this reports unsupported and the
/// caller falls back to telling the user to use the app.
class ConnectWebView {
  static bool get isSupported => false;

  /// Same pure rule as the native side, so the contract is one thing.
  static bool isCompletion(String url, String prefix) =>
      prefix.isNotEmpty && url.startsWith(prefix);

  static Widget build({
    required String url,
    required String clientSecret,
    required String publishableKey,
    required bool dark,
    required Color accent,
    required void Function(String event) onEvent,
    String platformAccount = '',
    bool needsCamera = false,
    Future<String> Function()? onSecretRequest,
    String completionUrlPrefix = '',
  }) =>
      const SizedBox.shrink();
}
