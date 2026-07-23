/// Fallback used on platforms without a browser Geolocation API (and in tests):
/// device location isn't available, so callers fall back to manual picking.
Future<({double lat, double lng})?> getCurrentLatLng() async => null;
