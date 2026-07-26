import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user.dart';

/// The user's favourite people for quick calling on the Calls tab. Persisted
/// on-device (like everything else, nothing is stored on a server). Order is
/// the order they were added.
class FavouritesStore extends ChangeNotifier {
  FavouritesStore._();
  static final FavouritesStore instance = FavouritesStore._();
  static const _key = 'call_favourites_v1';

  List<AppUser> _favourites = [];
  SharedPreferences? _prefs;

  List<AppUser> get favourites => List.unmodifiable(_favourites);

  bool isFavourite(String id) => _favourites.any((u) => u.id == id);

  Future<void> load() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final raw = _prefs!.getString(_key);
      if (raw != null) {
        _favourites = (jsonDecode(raw) as List)
            .map((e) => AppUser.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setString(
          _key, jsonEncode(_favourites.map((u) => u.toJson()).toList()));
    } catch (_) {}
  }

  void add(AppUser user) {
    if (user.isGroup || isFavourite(user.id)) return;
    _favourites = [..._favourites, user];
    _save();
    notifyListeners();
  }

  void remove(String id) {
    _favourites = _favourites.where((u) => u.id != id).toList();
    _save();
    notifyListeners();
  }

  void toggle(AppUser user) =>
      isFavourite(user.id) ? remove(user.id) : add(user);

  @visibleForTesting
  void resetForTest() {
    _favourites = [];
    _prefs = null;
    notifyListeners();
  }
}
