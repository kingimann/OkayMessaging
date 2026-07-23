import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// How to travel a route. Each maps to a free public OSRM profile server.
enum TravelMode {
  car('Drive', 'routed-car'),
  foot('Walk', 'routed-foot'),
  bike('Cycle', 'routed-bike');

  const TravelMode(this.label, this.profile);
  final String label;
  final String profile;
}

/// A single turn-by-turn instruction. [location] is where the maneuver
/// happens (used by in-app navigation to advance to the next step).
class RouteStep {
  final String instruction;
  final double distanceMeters;
  final LatLng? location;
  const RouteStep(this.instruction, this.distanceMeters, {this.location});
}

/// A route: the path to draw, its length and time, and turn-by-turn steps.
class RouteResult {
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
  final List<RouteStep> steps;

  const RouteResult({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    this.steps = const [],
  });
}

/// Turns an OSRM maneuver into a human instruction like "Turn left onto Main
/// St". Pure, so it's easy to test.
String instructionFor(String type, String modifier, String name) {
  final onto = name.isNotEmpty ? ' onto $name' : '';
  final on = name.isNotEmpty ? ' on $name' : '';
  final mod = modifier.trim();
  switch (type) {
    case 'depart':
      return name.isNotEmpty ? 'Head out on $name' : 'Start';
    case 'arrive':
      return 'Arrive at your destination';
    case 'turn':
      return 'Turn ${mod.isEmpty ? 'ahead' : mod}$onto';
    case 'continue':
      return 'Continue ${mod.isEmpty ? 'straight' : mod}$on';
    case 'new name':
      return 'Continue$onto';
    case 'merge':
      return 'Merge${mod.isEmpty ? '' : ' $mod'}$onto';
    case 'on ramp':
      return 'Take the ramp$onto';
    case 'off ramp':
      return 'Take the exit$onto';
    case 'fork':
      return 'Keep ${mod.isEmpty ? 'straight' : mod}$onto';
    case 'end of road':
      return 'At the end of the road, turn ${mod.isEmpty ? 'ahead' : mod}$onto';
    case 'roundabout':
    case 'rotary':
      return 'Enter the roundabout$onto';
    default:
      return name.isNotEmpty ? 'Continue on $name' : 'Continue';
  }
}

/// Parses an OSRM `/route` GeoJSON response (with steps). Pure and testable;
/// returns null on anything malformed or a non-"Ok" result.
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

    final steps = <RouteStep>[];
    final legs = r['legs'];
    if (legs is List && legs.isNotEmpty && legs.first is Map) {
      final rawSteps = (legs.first as Map)['steps'];
      if (rawSteps is List) {
        for (final s in rawSteps) {
          if (s is! Map) continue;
          final man = s['maneuver'];
          final type = man is Map ? (man['type'] as String? ?? '') : '';
          final mod = man is Map ? (man['modifier'] as String? ?? '') : '';
          final name = s['name'] as String? ?? '';
          LatLng? loc;
          final rawLoc = man is Map ? man['location'] : null;
          if (rawLoc is List && rawLoc.length >= 2) {
            final lng = (rawLoc[0] as num?)?.toDouble();
            final lat = (rawLoc[1] as num?)?.toDouble();
            if (lat != null && lng != null) loc = LatLng(lat, lng);
          }
          steps.add(RouteStep(
            instructionFor(type, mod, name),
            (s['distance'] as num?)?.toDouble() ?? 0,
            location: loc,
          ));
        }
      }
    }

    return RouteResult(
      points: pts,
      distanceMeters: (r['distance'] as num?)?.toDouble() ?? 0,
      durationSeconds: (r['duration'] as num?)?.toDouble() ?? 0,
      steps: steps,
    );
  } catch (_) {
    return null;
  }
}

/// Fetches a route between two points for the given [mode] from the free OSRM
/// servers (OpenStreetMap data). Returns null on any error.
Future<RouteResult?> fetchRoute({
  required LatLng from,
  required LatLng to,
  TravelMode mode = TravelMode.car,
}) async {
  final path = '/${mode.profile}/route/v1/driving/'
      '${from.longitude},${from.latitude};${to.longitude},${to.latitude}';
  final uri = Uri.https('routing.openstreetmap.de', path, {
    'overview': 'full',
    'geometries': 'geojson',
    'steps': 'true',
  });
  try {
    final res = await http.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    return parseOsrmRoute(res.body);
  } catch (_) {
    return null;
  }
}

/// Advances the upcoming-maneuver index as the user reaches maneuver points:
/// every maneuver the user is within [thresholdMeters] of is considered
/// passed. Pure, so it's easy to test.
int advanceStep({
  required List<RouteStep> steps,
  required int current,
  required LatLng user,
  double thresholdMeters = 35,
}) {
  var i = current;
  while (i < steps.length - 1) {
    final loc = steps[i].location;
    if (loc == null) break;
    if (const Distance().distance(user, loc) <= thresholdMeters) {
      i++;
    } else {
      break;
    }
  }
  return i;
}

/// Metres left to travel: from the user to the upcoming maneuver, plus every
/// remaining step segment after it.
double remainingMeters({
  required RouteResult route,
  required int current,
  LatLng? user,
}) {
  if (route.steps.isEmpty || current >= route.steps.length) {
    return current >= route.steps.length ? 0 : route.distanceMeters;
  }
  var total = 0.0;
  for (var i = current; i < route.steps.length; i++) {
    total += route.steps[i].distanceMeters;
  }
  final loc = route.steps[current].location;
  if (user != null && loc != null) {
    total += const Distance().distance(user, loc);
  }
  return total;
}

/// Metres from [user] to the nearest point on the route polyline. Used to
/// detect when the user has strayed off-route during navigation. Pure.
///
/// Uses a local equirectangular projection around the user — accurate to
/// well under a metre at the tens-to-hundreds-of-metres scales that matter
/// for off-route checks.
double distanceToRouteMeters(LatLng user, List<LatLng> points) {
  if (points.isEmpty) return double.infinity;
  const mPerDegLat = 110540.0;
  final mPerDegLng = 111320.0 * math.cos(user.latitude * math.pi / 180);

  double px(LatLng p) => (p.longitude - user.longitude) * mPerDegLng;
  double py(LatLng p) => (p.latitude - user.latitude) * mPerDegLat;

  var best = double.infinity;
  for (var i = 0; i < points.length; i++) {
    // Distance to the vertex itself.
    final vx = px(points[i]);
    final vy = py(points[i]);
    best = math.min(best, math.sqrt(vx * vx + vy * vy));
    if (i == points.length - 1) break;
    // Distance to the segment [i, i+1] via projection.
    final wx = px(points[i + 1]);
    final wy = py(points[i + 1]);
    final dx = wx - vx;
    final dy = wy - vy;
    final lenSq = dx * dx + dy * dy;
    if (lenSq <= 0) continue;
    // The user sits at the local origin; project it onto the segment.
    final t = ((-vx * dx) + (-vy * dy)) / lenSq;
    if (t <= 0 || t >= 1) continue;
    final cx = vx + t * dx;
    final cy = vy + t * dy;
    best = math.min(best, math.sqrt(cx * cx + cy * cy));
  }
  return best;
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
