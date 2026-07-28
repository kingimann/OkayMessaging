// Selects the native WebView on mobile (dart:io) and a safe stub on web, so
// the web build never compiles webview_flutter.
export 'connect_webview_stub.dart'
    if (dart.library.io) 'connect_webview_native.dart';
