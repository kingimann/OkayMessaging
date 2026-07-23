import 'geolocation_stub.dart'
    if (dart.library.js_interop) 'geolocation_web.dart' as impl;

/// The device's current coordinates, or null when unavailable (permission
/// denied, timed out, or no geolocation support — e.g. on native/tests).
Future<({double lat, double lng})?> getCurrentLatLng() =>
    impl.getCurrentLatLng();
