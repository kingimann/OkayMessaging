import 'package:geolocator/geolocator.dart';

/// Native (iOS / Android / desktop) location via the platform's location
/// services. Handles the permission flow; returns null when services are off,
/// permission is denied, or anything else goes wrong (including when no
/// platform plugin is available, e.g. in unit tests).
Future<({double lat, double lng})?> getCurrentLatLng() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }

    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 12),
      ),
    );
    return (lat: pos.latitude, lng: pos.longitude);
  } catch (_) {
    return null;
  }
}
