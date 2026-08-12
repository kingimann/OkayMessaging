import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A city the user picked to keep an eye on, beside their own location.
///
/// **Not coarsened, on purpose — unlike [WeatherScreen]'s device fix.**
/// [WeatherService.coarsen] exists to keep a live GPS reading from pinning
/// down where THIS PHONE is; a city somebody searched for and added by name
/// is not that. Rounding "Paris, France" to the nearest 11km buys nothing —
/// the name already said which city — so this stores exactly what the
/// geocoder returned.
class WeatherCity {
  final String label;
  final double lat;
  final double lng;

  const WeatherCity({required this.label, required this.lat, required this.lng});

  /// A stable key for de-duplication, coarse enough that two searches for
  /// the same city land on the same entry even if the geocoder's answer
  /// wobbles by a few metres between calls.
  String get key => '${lat.toStringAsFixed(2)},${lng.toStringAsFixed(2)}';

  Map<String, dynamic> toJson() => {'label': label, 'lat': lat, 'lng': lng};

  factory WeatherCity.fromJson(Map<String, dynamic> j) => WeatherCity(
        label: j['label'] as String? ?? '',
        lat: (j['lat'] as num?)?.toDouble() ?? 0,
        lng: (j['lng'] as num?)?.toDouble() ?? 0,
      );
}

/// Persists the cities added to the Weather screen — device-local, like
/// [SavedPlacesStore]; a list of places somebody checks the weather for is
/// not a fact about anywhere they've been.
class WeatherCitiesStore extends ChangeNotifier {
  WeatherCitiesStore._();
  static final WeatherCitiesStore instance = WeatherCitiesStore._();

  static const _key = 'weather_cities_v1';

  /// A screen-width row of tabs stops being usable well before this — the
  /// cap exists so "add a city" can never turn into an unscrollable list.
  static const int maxCities = 10;

  SharedPreferences? _prefs;
  List<WeatherCity> _cities = [];

  List<WeatherCity> get cities => List.unmodifiable(_cities);

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        _cities = (jsonDecode(raw) as List)
            .map((e) => WeatherCity.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      } catch (_) {
        _cities = [];
      }
    }
    notifyListeners();
  }

  bool contains(WeatherCity city) => _cities.any((c) => c.key == city.key);

  /// Adds [city] unless it is already saved or the list is already at
  /// [maxCities]. Returns whether it was actually added, so the screen can
  /// say why nothing happened rather than silently doing nothing.
  bool add(WeatherCity city) {
    if (contains(city) || _cities.length >= maxCities) return false;
    _cities = [..._cities, city];
    _persist();
    notifyListeners();
    return true;
  }

  void remove(WeatherCity city) {
    _cities = _cities.where((c) => c.key != city.key).toList();
    _persist();
    notifyListeners();
  }

  void _persist() {
    _prefs?.setString(
        _key, jsonEncode([for (final c in _cities) c.toJson()]));
  }

  @visibleForTesting
  void resetForTest() {
    _cities = [];
    _prefs = null;
    notifyListeners();
  }
}
