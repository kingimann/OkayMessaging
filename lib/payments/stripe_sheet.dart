// Selects the native Stripe Payment Sheet on mobile/desktop (dart:io) and a
// safe stub on web, so the web build never compiles the flutter_stripe SDK.
export 'stripe_sheet_stub.dart' if (dart.library.io) 'stripe_sheet_native.dart';
