import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// A driving route: the path to draw plus its length and estimated time.
class RouteResult {
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;

  const RouteResult({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
  });
}

/// Parses an OSRM `/route` GeoJSON response. Pure and testable; returns null on
/// anything malformed or a non-"Ok" result.
RouteResult? parseOsrmRoute(String body) {
  try {
    final data = jsonDecode(body);
    if (data is! Map || data['code'] != 'Ok') return null;
    final routes = data['routes'];
    if (routes is! List || routes.isEmpty) return null;
    final r = routes.first;
    if (r is! Map) return null;
    final geom = r['geometry'];
    final coords = geom is Map ? geom['coordinates'] : null;
    if (coords is! List) return null;

    final pts = <LatLng>[];
    for (final c in coords) {
      if (c is List && c.length >= 2) {
        final lng = (c[0] as num?)?.toDouble();
        final lat = (c[1] as num?)?.toDouble();
        if (lat != null && lng != null) pts.add(LatLng(lat, lng));
      }
    }
    if (pts.isEmpty) return null;
    return RouteResult(
      points: pts,
      distanceMeters: (r['distance'] as num?)?.toDouble() ?? 0,
      durationSeconds: (r['duration'] as num?)?.toDouble() ?? 0,
    );
  } catch (_) {
    return null;
  }
}

/// Fetches a driving route between two points from the public OSRM server
/// (the routing companion to OpenStreetMap). Returns null on any error.
Future<RouteResult?> fetchRoute({
  required LatLng from,
  required LatLng to,
}) async {
  final path = '/route/v1/driving/'
      '${from.longitude},${from.latitude};${to.longitude},${to.latitude}';
  final uri = Uri.https('router.project-osrm.org', path, {
    'overview': 'full',
    'geometries': 'geojson',
  });
  try {
    final res = await http.get(uri).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return null;
    return parseOsrmRoute(res.body);
  } catch (_) {
    return null;
  }
}

/// A short travel-time label, e.g. "8 min" or "1 h 5 min", from seconds.
String formatDuration(double seconds) {
  final mins = (seconds / 60).round();
  if (mins < 1) return '1 min';
  if (mins < 60) return '$mins min';
  final h = mins ~/ 60;
  final m = mins % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}
