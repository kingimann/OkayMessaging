// Selects the native StoreKit / Play Billing implementation on mobile
// (dart:io) and a safe stub on web, so the web build never compiles the
// in_app_purchase plugin.
export 'apple_iap_stub.dart' if (dart.library.io) 'apple_iap_native.dart';
