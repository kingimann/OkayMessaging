import 'package:latlong2/latlong.dart';

import '../models/user.dart';

/// A friend placed on the Snap-style map at a location.
class FriendPlace {
  final AppUser user;
  final LatLng position;
  const FriendPlace(this.user, this.position);
}

/// Deterministically scatters [friends] around [base] so the map looks alive
/// and each friend keeps a stable spot between opens. Positions are derived
/// from each user's id (no randomness), within roughly a few kilometres.
List<FriendPlace> friendPlaces(LatLng base, List<AppUser> friends) {
  final places = <FriendPlace>[];
  for (final f in friends) {
    // Two independent hashes → a stable lat/lng offset in ~[-0.03, 0.03] deg.
    final h = f.id.hashCode;
    final dLat = ((h & 0xFFFF) / 0xFFFF - 0.5) * 0.06;
    final dLng = (((h >> 16) & 0xFFFF) / 0xFFFF - 0.5) * 0.06;
    places.add(FriendPlace(f, LatLng(base.latitude + dLat, base.longitude + dLng)));
  }
  return places;
}
