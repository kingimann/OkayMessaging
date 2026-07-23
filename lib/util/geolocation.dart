import 'package:flutter/foundation.dart';

import 'geolocation_stub.dart'
    if (dart.library.js_interop) 'geolocation_web.dart'
    if (dart.library.io) 'geolocation_io.dart' as impl;

/// Test hook: when set, replaces the platform implementation. Widget tests
/// set this to `() async => null` because plugin platform channels never
/// complete inside the fake-async test zone.
@visibleForTesting
Future<({double lat, double lng})?> Function()? debugGeolocationOverride;

/// The device's current coordinates, or null when unavailable (permission
/// denied, services off, timed out, or no location support).
///
/// Web uses the browser Geolocation API; iOS / Android use the platform's
/// location services via geolocator (which also handles the permission
/// prompt).
Future<({double lat, double lng})?> getCurrentLatLng() =>
    (debugGeolocationOverride ?? impl.getCurrentLatLng)();
