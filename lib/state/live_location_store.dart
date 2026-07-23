import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

/// A peer's most recently received live position.
class LiveLocation {
  final double lat;
  final double lng;
  final DateTime at;
  const LiveLocation(this.lat, this.lng, this.at);

  LatLng get position => LatLng(lat, lng);
}

/// Holds the live locations peers have broadcast to us, keyed by phone digits.
///
/// Nothing is persisted — locations live only in memory and expire after
/// [ttl], mirroring the app's store-nothing relay model. When a friend stops
/// sharing (or goes offline), their pin simply goes stale and disappears.
class LiveLocationStore extends ChangeNotifier {
  LiveLocationStore._();
  static final LiveLocationStore instance = LiveLocationStore._();

  /// A location older than this is considered stale and ignored.
  static const Duration ttl = Duration(minutes: 10);

  final Map<String, LiveLocation> _byDigits = {};

  /// Records a peer's position. [digits] is their phone number's digits.
  void update(String digits, double lat, double lng, {DateTime? at}) {
    if (digits.isEmpty) return;
    _byDigits[digits] = LiveLocation(lat, lng, at ?? DateTime.now());
    notifyListeners();
  }

  /// The peer's live location if it's still fresh (within [ttl]), else null.
  LiveLocation? locationFor(String digits, {DateTime? now}) {
    final loc = _byDigits[digits];
    if (loc == null) return null;
    final t = now ?? DateTime.now();
    return t.difference(loc.at) > ttl ? null : loc;
  }

  /// Whether any peer location has been received (fresh or not).
  bool get isEmpty => _byDigits.isEmpty;

  @visibleForTesting
  void resetForTest() {
    _byDigits.clear();
    notifyListeners();
  }
}
