import 'dart:convert';

import 'package:http/http.dart' as http;

/// A place returned by the geocoder.
class GeoResult {
  /// A short, human-friendly label (e.g. "Eiffel Tower, Paris").
  final String name;
  final double lat;
  final double lng;

  const GeoResult({required this.name, required this.lat, required this.lng});
}

/// Parses a Photon (`/api`) GeoJSON response into results. Pure and testable;
/// returns an empty list on malformed input rather than throwing.
List<GeoResult> parsePhoton(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return const [];
  }
  if (decoded is! Map) return const [];
  final features = decoded['features'];
  if (features is! List) return const [];

  final out = <GeoResult>[];
  for (final f in features) {
    if (f is! Map) continue;
    final geom = f['geometry'];
    final coords = geom is Map ? geom['coordinates'] : null;
    if (coords is! List || coords.length < 2) continue;
    final lng = (coords[0] as num?)?.toDouble();
    final lat = (coords[1] as num?)?.toDouble();
    if (lat == null || lng == null) continue;

    final props = f['properties'];
    final name = props is Map ? _label(props) : null;
    if (name == null || name.isEmpty) continue;
    out.add(GeoResult(name: name, lat: lat, lng: lng));
  }
  return out;
}

/// Builds a readable one-line label from Photon feature properties, e.g.
/// "Eiffel Tower, Paris, France".
String _label(Map<dynamic, dynamic> props) {
  final parts = <String>[];
  void add(Object? v) {
    final s = v?.toString().trim() ?? '';
    if (s.isNotEmpty && !parts.contains(s)) parts.add(s);
  }

  add(props['name']);
  add(props['street']);
  add(props['city']);
  add(props['state']);
  add(props['country']);
  return parts.take(3).join(', ');
}

/// Looks up a readable place name for a coordinate via Photon's reverse
/// geocoder. Returns null on any error.
Future<GeoResult?> reverseGeocode(double lat, double lng) async {
  final uri = Uri.https('photon.komoot.io', '/reverse', {
    'lat': '$lat',
    'lon': '$lng',
  });
  try {
    final res = await http
        .get(uri, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final results = parsePhoton(res.body);
    return results.isEmpty ? null : results.first;
  } catch (_) {
    return null;
  }
}

/// Searches OpenStreetMap data for [query] via Komoot's Photon geocoder, which
/// (unlike Nominatim) sends CORS headers so it works from the browser. Returns
/// an empty list on any error.
Future<List<GeoResult>> searchPlaces(String query) async {
  final q = query.trim();
  if (q.isEmpty) return const [];
  final uri = Uri.https('photon.komoot.io', '/api', {
    'q': q,
    'limit': '6',
  });
  try {
    final res = await http
        .get(uri, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return const [];
    return parsePhoton(res.body);
  } catch (_) {
    return const [];
  }
}
