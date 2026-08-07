import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/geolocation.dart';

/// A place the account trusts to send money from without a second check — a
/// home or an office, held with a radius because GPS never lands on the exact
/// same point twice.
class TrustedPlace {
  final String name;
  final double lat;
  final double lng;

  /// How close counts as "here", in metres. A house is tens of metres; the
  /// default is generous so standing in the garden still counts.
  final double radiusMeters;

  const TrustedPlace({
    required this.name,
    required this.lat,
    required this.lng,
    this.radiusMeters = 150,
  });

  /// Identity is the rounded coordinate, so the same spot added twice is one
  /// place — the name and radius can differ without splitting it.
  String get key => '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';

  Map<String, dynamic> toJson() =>
      {'name': name, 'lat': lat, 'lng': lng, 'r': radiusMeters};

  factory TrustedPlace.fromJson(Map<String, dynamic> j) => TrustedPlace(
        name: (j['name'] as String?)?.trim().isNotEmpty == true
            ? j['name'] as String
            : 'Trusted place',
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        radiusMeters: (j['r'] as num?)?.toDouble() ?? 150,
      );
}

/// Why (or why not) a send needs the extra check — kept so the UI can say the
/// true reason instead of a bare yes/no.
enum StepUpDecision {
  /// The protection is off, so nothing extra is asked.
  off,

  /// The recipient is a trusted contact — sends to them skip the check.
  trustedContact,

  /// The device is inside one of the trusted places.
  inTrustedPlace,

  /// Not in a trusted place — the second factor is required.
  outsideTrustedPlace,

  /// Location couldn't be read (off, denied, timed out). Fails CLOSED — an
  /// unknown location is treated like an untrusted one, so turning location
  /// off is not a way around the check.
  locationUnknown;

  /// Whether the send has to pass the second factor first.
  bool get needsStepUp =>
      this == outsideTrustedPlace || this == locationUnknown;
}

/// The trust rules behind sending money: the places and people that let a P2P
/// send go straight through, and the toggle that turns the whole thing on.
///
/// **Account-scoped and on-device only.** Which places and people you trust is
/// as revealing as a home address and a friends list, so it never leaves the
/// device and is wiped/parked with the account like everything else. The
/// second factor itself is a code texted to the account's phone — the same SMS
/// check as signing in.
class PaymentSecurityStore extends ChangeNotifier {
  PaymentSecurityStore._();
  static final PaymentSecurityStore instance = PaymentSecurityStore._();

  static const _kEnabled = 'pay_sec_enabled_v1';
  static const _kPlaces = 'pay_sec_places_v1';
  static const _kContacts = 'pay_sec_trusted_contacts_v1';

  SharedPreferences? _prefs;

  /// Whether a send from outside a trusted place has to pass the second
  /// factor. Off by default — turning it on is an explicit choice, and it is
  /// only worth turning on once a two-step PIN exists to be the factor.
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  List<TrustedPlace> _places = [];
  Set<String> _trustedContacts = {};

  List<TrustedPlace> get places => List.unmodifiable(_places);
  Set<String> get trustedContacts => Set.unmodifiable(_trustedContacts);

  static String _digits(String key) => key.replaceAll(RegExp(r'\D'), '');

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_kEnabled) ?? false;
    final rawPlaces = prefs.getString(_kPlaces);
    if (rawPlaces != null) {
      try {
        _places = (jsonDecode(rawPlaces) as List)
            .map((e) => TrustedPlace.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      } catch (_) {
        _places = [];
      }
    }
    _trustedContacts =
        (prefs.getStringList(_kContacts) ?? const []).map(_digits).toSet()
          ..removeWhere((d) => d.isEmpty);
    notifyListeners();
  }

  void _persistPlaces() => _prefs?.setString(
      _kPlaces, jsonEncode([for (final p in _places) p.toJson()]));

  void _persistContacts() =>
      _prefs?.setStringList(_kContacts, _trustedContacts.toList());

  Future<void> setEnabled(bool value) async {
    if (enabled.value == value) return;
    enabled.value = value;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setBool(_kEnabled, value);
    notifyListeners();
  }

  void addPlace(TrustedPlace place) {
    _places = [
      ..._places.where((p) => p.key != place.key),
      place,
    ];
    _persistPlaces();
    notifyListeners();
  }

  void removePlace(String key) {
    _places = _places.where((p) => p.key != key).toList();
    _persistPlaces();
    notifyListeners();
  }

  bool isTrustedContact(String recipientKey) =>
      _trustedContacts.contains(_digits(recipientKey));

  void setTrustedContact(String recipientKey, bool trusted) {
    final d = _digits(recipientKey);
    if (d.isEmpty) return;
    final changed =
        trusted ? _trustedContacts.add(d) : _trustedContacts.remove(d);
    if (!changed) return;
    _persistContacts();
    notifyListeners();
  }

  /// Metres between two coordinates (haversine), the WGS-84 mean radius.
  static double distanceMeters(
      double lat1, double lng1, double lat2, double lng2) {
    const earth = 6371000.0;
    double rad(double d) => d * pi / 180;
    final dLat = rad(lat2 - lat1);
    final dLng = rad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(rad(lat1)) * cos(rad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    return earth * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  /// Whether [lat],[lng] is inside any trusted place's radius.
  bool within(double lat, double lng) => _places.any(
      (p) => distanceMeters(lat, lng, p.lat, p.lng) <= p.radiusMeters);

  /// Decides whether a P2P send to [recipientKey] needs the second factor
  /// right now — off, a trusted contact, inside a trusted place, or neither
  /// (which needs the check). Reads the device location only when it might
  /// change the answer, so a trusted contact never triggers a GPS prompt.
  Future<StepUpDecision> assess(String recipientKey) async {
    if (!enabled.value) return StepUpDecision.off;
    if (isTrustedContact(recipientKey)) return StepUpDecision.trustedContact;
    final loc = await getCurrentLatLng();
    if (loc == null) return StepUpDecision.locationUnknown;
    return within(loc.lat, loc.lng)
        ? StepUpDecision.inTrustedPlace
        : StepUpDecision.outsideTrustedPlace;
  }

  @visibleForTesting
  void resetForTest() {
    enabled.value = false;
    _places = [];
    _trustedContacts = {};
    _prefs = null;
    notifyListeners();
  }
}
