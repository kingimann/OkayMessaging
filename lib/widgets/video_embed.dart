// Selects the native WebView on mobile (dart:io) and a stub on web, exactly
// as the Stripe Connect view does — the web build must never compile
// webview_flutter.
export 'video_embed_stub.dart'
    if (dart.library.io) 'video_embed_native.dart';
