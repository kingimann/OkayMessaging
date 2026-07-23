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
