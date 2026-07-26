import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// Completes with the first future that succeeds, ignoring failures. Errors
/// only if every future fails. Used to race several servers and take whichever
/// answers first, instead of waiting on a slow one before trying the next.
Future<T> _firstSuccess<T>(List<Future<T>> futures) {
  final completer = Completer<T>();
  var pending = futures.length;
  if (pending == 0) {
    return Future.error(StateError('no futures'));
  }
  for (final f in futures) {
    f.then((v) {
      if (!completer.isCompleted) completer.complete(v);
    }).catchError((Object e) {
      pending--;
      if (pending == 0 && !completer.isCompleted) completer.completeError(e);
    });
  }
  return completer.future;
}

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

/// Turns a raw OSM tag value ('fast_food') into a human label ('Fast food'),
/// or '' for generic values.
String _humanize(String raw) {
  if (raw.isEmpty || raw == 'yes') return '';
  final words = raw.replaceAll('_', ' ').trim();
  if (words.isEmpty) return '';
  return words[0].toUpperCase() + words.substring(1);
}

/// A human category label from Photon's osm_value, or '' for generic places.
String _category(Map<dynamic, dynamic> props) =>
    _humanize(props['osm_value']?.toString() ?? '');

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

/// Parses an Overpass API response into places. Ways/relations use their
/// computed `center`; unnamed POIs fall back to their category label (so a
/// nameless car park still shows as "Parking"). Pure and testable.
List<GeoResult> parseOverpass(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return const [];
  }
  if (decoded is! Map) return const [];
  final elements = decoded['elements'];
  if (elements is! List) return const [];

  final out = <GeoResult>[];
  for (final e in elements) {
    if (e is! Map) continue;
    final center = e['center'];
    final lat = (e['lat'] as num?)?.toDouble() ??
        (center is Map ? (center['lat'] as num?)?.toDouble() : null);
    final lng = (e['lon'] as num?)?.toDouble() ??
        (center is Map ? (center['lon'] as num?)?.toDouble() : null);
    if (lat == null || lng == null) continue;
    final tags = e['tags'];
    if (tags is! Map) continue;
    final category = _humanize((tags['amenity'] ??
            tags['shop'] ??
            tags['tourism'] ??
            tags['leisure'] ??
            '')
        .toString());
    final name = (tags['name'] ?? '').toString().trim();
    if (name.isEmpty && category.isEmpty) continue;
    out.add(GeoResult(
      name: name.isEmpty ? category : name,
      lat: lat,
      lng: lng,
      category: category,
    ));
  }
  return out;
}

/// True category search — every matching POI around a point, like Apple
/// Maps' nearby categories — via the Overpass API. The Photon text geocoder
/// can't do this: it matches *names*, so "restaurant" finds places called
/// Restaurant instead of restaurants.
///
/// Each entry in [filters] is a full Overpass bracket group such as
/// '[amenity=cafe]' or '[amenity][name~"tims",i]'; the groups are OR-ed.
/// Same contract as [searchPlaces]: null = failed, empty = nothing matched.
Future<List<GeoResult>?> searchNearby({
  required List<String> filters,
  required double lat,
  required double lng,
  int radiusMeters = 4000,
  int limit = 25,
}) async {
  final around = '(around:$radiusMeters,$lat,$lng)';
  final union = filters.map((f) => 'nwr$f$around;').join();
  final query = '[out:json][timeout:8];($union);out center ${limit * 3};';
  // Query several independent public servers (all share the /api/interpreter
  // path) IN PARALLEL and take whichever answers first, so one overloaded
  // server no longer makes the whole search wait. Each host's request throws
  // on failure so the race skips it. Returns null only if every host fails.
  const hosts = [
    'overpass-api.de',
    'overpass.private.coffee',
    'overpass.kumi.systems',
    'overpass.osm.ch',
  ];
  try {
    return await _firstSuccess(
      hosts.map((h) => _overpassHost(h, query, lat, lng, limit)).toList(),
    );
  } catch (_) {
    return null;
  }
}

/// Queries one Overpass host; returns the parsed results or throws on any
/// failure (non-200, HTML error page, runtime-error "remark", or network
/// error) so [_firstSuccess] treats it as a loser in the race.
Future<List<GeoResult>> _overpassHost(
    String host, String query, double lat, double lng, int limit) async {
  final res = await http.get(
    Uri.https(host, '/api/interpreter', {'data': query}),
    headers: {'Accept': 'application/json'},
  ).timeout(const Duration(seconds: 10));
  if (res.statusCode != 200) throw StateError('overpass ${res.statusCode}');
  final body = res.body;
  // Overload/timeout comes back as HTTP 200 with an HTML error page or JSON
  // carrying a runtime-error "remark" — both are failures, not "no matches".
  if (!body.trimLeft().startsWith('{')) throw StateError('overpass html');
  final decoded = jsonDecode(body);
  final remark = decoded is Map ? decoded['remark']?.toString() ?? '' : '';
  if (remark.contains('error') || remark.contains('timed out')) {
    throw StateError('overpass remark');
  }
  final results = dedupePlaces(parseOverpass(body));
  return sortPlacesByDistance(results, lat, lng).take(limit).toList();
}

const String _fFood = r'[amenity~"^(restaurant|fast_food|food_court)$"]';
const String _fCafe = r'[amenity~"^(cafe|ice_cream)$"]';
const String _fBar = r'[amenity~"^(bar|pub|biergarten)$"]';
const String _fFuel = r'[amenity~"^(fuel|charging_station)$"]';
const String _fHotel = r'[tourism~"^(hotel|hostel|motel|guest_house)$"]';
const String _fShop =
    r'[shop~"^(supermarket|convenience|mall|department_store)$"]';
const String _fAtm = r'[amenity~"^(atm|bank)$"]';
const String _fHealth = r'[amenity~"^(hospital|clinic|doctors)$"]';

/// Typed queries that are really *category intents*: "coffee" means "cafes
/// near me", not places named Coffee. Maps a query to an Overpass filter.
const Map<String, String> _categoryAliases = {
  'food': _fFood, 'restaurant': _fFood, 'restaurants': _fFood,
  'fast food': '[amenity=fast_food]', 'takeout': '[amenity=fast_food]',
  'coffee': _fCafe, 'coffee shop': _fCafe, 'cafe': _fCafe, 'cafes': _fCafe,
  'bar': _fBar, 'bars': _fBar, 'pub': _fBar, 'pubs': _fBar,
  'gas': _fFuel, 'gas station': _fFuel, 'fuel': _fFuel,
  'petrol': _fFuel, 'petrol station': _fFuel,
  'charging': '[amenity=charging_station]',
  'ev charging': '[amenity=charging_station]',
  'hotel': _fHotel, 'hotels': _fHotel, 'motel': _fHotel, 'hostel': _fHotel,
  'grocery': _fShop, 'groceries': _fShop, 'grocery store': _fShop,
  'supermarket': _fShop, 'supermarkets': _fShop,
  'atm': _fAtm, 'atms': _fAtm, 'bank': _fAtm, 'banks': _fAtm,
  'parking': '[amenity=parking]',
  'pharmacy': '[amenity=pharmacy]', 'drugstore': '[amenity=pharmacy]',
  'hospital': _fHealth, 'clinic': _fHealth, 'doctor': _fHealth,
  'park': '[leisure=park]', 'parks': '[leisure=park]',
  'playground': '[leisure=playground]',
  'school': '[amenity=school]', 'schools': '[amenity=school]',
  'gym': '[leisure=fitness_centre]',
  'police': '[amenity=police]',
  'library': '[amenity=library]',
};

/// The Overpass filter for a typed query that's really a category intent
/// ("coffee", "gas station"), or null for genuine name/address queries.
String? categoryFilterFor(String query) =>
    _categoryAliases[query.trim().toLowerCase()];

/// Fallback name search when the geocoder is unreachable: case-insensitive
/// match over OSM place names around a point, via Overpass. Nearby-only
/// (no worldwide addresses), but far better than search simply dying.
Future<List<GeoResult>?> searchNamesNearby(
  String query, {
  required double lat,
  required double lng,
  int limit = 12,
}) {
  final q = query.replaceAll('"', '').replaceAll(r'\', '').trim();
  if (q.isEmpty) return Future.value(const []);
  // Constrained to POI-tagged objects: an unconstrained name regex scans
  // every building and road in radius and times the server out.
  final name = '[name~"${RegExp.escape(q)}",i]';
  return searchNearby(
    filters: [
      '[amenity]$name',
      '[shop]$name',
      '[tourism]$name',
      '[leisure]$name',
    ],
    lat: lat,
    lng: lng,
    radiusMeters: 15000,
    limit: limit,
  );
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
        .timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return null;
    var results = dedupePlaces(parsePhoton(res.body));
    if (biased) results = sortPlacesByDistance(results, lat, lng);
    return results.take(limit).toList();
  } catch (_) {
    return null;
  }
}
