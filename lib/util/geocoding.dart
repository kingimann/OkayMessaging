import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// A place returned by the geocoder.
class GeoResult {
  /// A short, human-friendly label (e.g. "Eiffel Tower, Paris").
  final String name;
  final double lat;
  final double lng;

  /// A human category label (e.g. "Restaurant", "Cafe"), or '' when unknown.
  final String category;

  const GeoResult({
    required this.name,
    required this.lat,
    required this.lng,
    this.category = '',
  });
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
    out.add(GeoResult(
      name: name,
      lat: lat,
      lng: lng,
      category: props is Map ? _category(props) : '',
    ));
  }
  return out;
}

/// A human category label from Photon's osm_value (e.g. "fast_food" →
/// "Fast food"), or '' for generic places.
String _category(Map<dynamic, dynamic> props) {
  final raw = props['osm_value']?.toString() ?? '';
  if (raw.isEmpty || raw == 'yes') return '';
  final words = raw.replaceAll('_', ' ').trim();
  if (words.isEmpty) return '';
  return words[0].toUpperCase() + words.substring(1);
}

/// Builds a readable one-line label from Photon feature properties, e.g.
/// "Eiffel Tower, Paris, France" or "1226 Valencia Street, San Francisco".
String _label(Map<dynamic, dynamic> props) {
  final parts = <String>[];
  void add(Object? v) {
    final s = v?.toString().trim() ?? '';
    if (s.isNotEmpty && !parts.contains(s)) parts.add(s);
  }

  // A street address keeps its house number ("1226 Valencia Street") —
  // otherwise address results are ambiguous to the point of useless.
  final street = props['street']?.toString().trim() ?? '';
  final houseNo = props['housenumber']?.toString().trim() ?? '';
  final address = houseNo.isNotEmpty && street.isNotEmpty
      ? '$houseNo $street'
      : street;

  add(props['name']);
  add(address);
  add(props['city']);
  add(props['state']);
  add(props['country']);
  return parts.take(3).join(', ');
}

/// Removes near-duplicate results (same label at effectively the same spot —
/// Photon frequently returns them for businesses).
List<GeoResult> dedupePlaces(List<GeoResult> results) {
  final seen = <String>{};
  final out = <GeoResult>[];
  for (final r in results) {
    final key = '${r.name.toLowerCase()}|'
        '${r.lat.toStringAsFixed(3)},${r.lng.toStringAsFixed(3)}';
    if (seen.add(key)) out.add(r);
  }
  return out;
}

/// Orders [results] nearest-first from ([lat], [lng]) using an
/// equirectangular approximation (plenty for ranking). Pure.
List<GeoResult> sortPlacesByDistance(
    List<GeoResult> results, double lat, double lng) {
  final cosLat = math.cos(lat * math.pi / 180);
  double d2(GeoResult r) {
    final dx = (r.lng - lng) * cosLat;
    final dy = r.lat - lat;
    return dx * dx + dy * dy;
  }

  final sorted = [...results]..sort((a, b) => d2(a).compareTo(d2(b)));
  return sorted;
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
/// (unlike Nominatim) sends CORS headers so it works from the browser.
///
/// Returns an empty list when nothing matched, and **null** when the request
/// itself failed (offline, rate-limited, server error) — callers can then
/// keep showing previous results instead of blanking the list.
Future<List<GeoResult>?> searchPlaces(
  String query, {
  double? lat,
  double? lng,
  int limit = 6,
}) async {
  final q = query.trim();
  if (q.isEmpty) return const [];
  final biased = lat != null && lng != null;
  final uri = Uri.https('photon.komoot.io', '/api', {
    'q': q,
    // Over-fetch so de-duplication still leaves a full page of results.
    'limit': '${limit * 2}',
    'lang': 'en',
    if (biased) ...{
      // Bias results toward the map centre so "coffee" finds *nearby*
      // coffee: zoom sets the bias radius and location_bias_scale how
      // strongly proximity outweighs global relevance.
      'lat': '$lat',
      'lon': '$lng',
      'zoom': '13',
      'location_bias_scale': '0.5',
    },
  });
  try {
    final res = await http
        .get(uri, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return null;
    var results = dedupePlaces(parsePhoton(res.body));
    if (biased) results = sortPlacesByDistance(results, lat, lng);
    return results.take(limit).toList();
  } catch (_) {
    return null;
  }
}
