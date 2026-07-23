import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Reads the device's current position via the browser Geolocation API.
/// Returns null if the user denies permission, the request times out, or the
/// browser has no geolocation support.
Future<({double lat, double lng})?> getCurrentLatLng() async {
  final completer = Completer<({double lat, double lng})?>();

  void done(({double lat, double lng})? value) {
    if (!completer.isCompleted) completer.complete(value);
  }

  try {
    web.window.navigator.geolocation.getCurrentPosition(
      (web.GeolocationPosition pos) {
        done((lat: pos.coords.latitude, lng: pos.coords.longitude));
      }.toJS,
      (web.GeolocationPositionError _) {
        done(null);
      }.toJS,
      web.PositionOptions(timeout: 10000, enableHighAccuracy: false),
    );
  } catch (_) {
    done(null);
  }

  // Belt-and-braces timeout in case neither callback ever fires.
  return completer.future
      .timeout(const Duration(seconds: 12), onTimeout: () => null);
}
