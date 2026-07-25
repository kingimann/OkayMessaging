import 'package:latlong2/latlong.dart';

import '../models/user.dart';

/// A friend placed on the Snap-style map at a location.
class FriendPlace {
  final AppUser user;
  final LatLng position;
  const FriendPlace(this.user, this.position);
}

