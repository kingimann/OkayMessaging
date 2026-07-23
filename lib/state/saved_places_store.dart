import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A place the user has saved on the map.
class SavedPlace {
  final String name;
  final double lat;
  final double lng;
  const SavedPlace(this.name, this.lat, this.lng);

  /// A stable key from the rounded coordinates (used for de-duplication).
  String get key => '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';

  Map<String, dynamic> toJson() => {'name': name, 'lat': lat, 'lng': lng};

  factory SavedPlace.fromJson(Map<String, dynamic> j) => SavedPlace(
        j['name'] as String? ?? '',
        (j['lat'] as num).toDouble(),
        (j['lng'] as num).toDouble(),
      );
}

/// Persists the user's saved / favourite map places.
class SavedPlacesStore extends ChangeNotifier {
  SavedPlacesStore._();
  static final SavedPlacesStore instance = SavedPlacesStore._();

  static const _key = 'saved_places_v1';
  SharedPreferences? _prefs;
  List<SavedPlace> _places = [];

  List<SavedPlace> get places => List.unmodifiable(_places);

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        _places = (jsonDecode(raw) as List)
            .map((e) => SavedPlace.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      } catch (_) {
        _places = [];
      }
    }
    notifyListeners();
  }

  bool isSaved(double lat, double lng) {
    final k = SavedPlace('', lat, lng).key;
    return _places.any((p) => p.key == k);
  }

  /// Adds the place if new, or removes it if already saved. Returns the new
  /// saved state.
  bool toggle(SavedPlace place) {
    final existing = _places.indexWhere((p) => p.key == place.key);
    final saved = existing < 0;
    if (saved) {
      _places = [..._places, place];
    } else {
      _places = [..._places]..removeAt(existing);
    }
    _persist();
    notifyListeners();
    return saved;
  }

  void remove(SavedPlace place) {
    _places = _places.where((p) => p.key != place.key).toList();
    _persist();
    notifyListeners();
  }

  void _persist() {
    _prefs?.setString(
        _key, jsonEncode(_places.map((p) => p.toJson()).toList()));
  }

  @visibleForTesting
  void resetForTest() {
    _places = [];
    _prefs = null;
    notifyListeners();
  }
}
