/// Builds a maps deep-link for a shared location. iPhone and Mac users get an
/// Apple Maps link (which opens the Apple Maps app); everyone else gets a
/// Google Maps link. An optional [label] titles the dropped pin.
Uri mapsUrl({
  required double lat,
  required double lng,
  String label = '',
  required bool apple,
}) {
  final trimmed = label.trim();
  if (apple) {
    final q = trimmed.isEmpty ? '' : '&q=${Uri.encodeComponent(trimmed)}';
    return Uri.parse('https://maps.apple.com/?ll=$lat,$lng$q');
  }
  return Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
}

/// Builds a driving-directions deep-link to ([lat], [lng]). Apple Maps on
/// iPhone/Mac, Google Maps elsewhere.
Uri directionsUrl({
  required double lat,
  required double lng,
  required bool apple,
}) {
  if (apple) {
    return Uri.parse('https://maps.apple.com/?daddr=$lat,$lng&dirflg=d');
  }
  return Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
}

/// A short human distance label, e.g. "850 m" or "2.3 km", from a distance in
/// metres.
String formatDistance(double meters) {
  if (meters < 1000) return '${meters.round()} m';
  final km = meters / 1000;
  return km >= 10 ? '${km.round()} km' : '${km.toStringAsFixed(1)} km';
}
