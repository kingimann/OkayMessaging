import 'package:flutter/material.dart';

/// Web / default implementation. In-app playback needs a WebView, which the
/// web build has no plugin for — and on the web the browser can simply open
/// the link itself, so the caller falls back to launching it.
class VideoEmbed {
  static bool get isSupported => false;

  static Widget build({required String embedUrl, String parentHost = ''}) =>
      const SizedBox.shrink();
}
