import 'package:flutter/foundation.dart';

/// Who can see you when they look for someone to send something to.
///
/// AirDrop's own question, and it is the right one: being findable means
/// putting your name in the air for every stranger in range, which is fine in
/// a friend's kitchen and not fine on a train. Off is the default.
enum Findable {
  /// Nobody. You can still send; nobody can see you to send to you.
  off,

  /// Only people already in your chats. Their phones announce themselves and
  /// yours answers only to numbers it recognises.
  contacts,

  /// Anyone in range, for the ten minutes you need it.
  everyone;

  String get label => switch (this) {
        Findable.off => 'No one',
        Findable.contacts => 'People I chat with',
        Findable.everyone => 'Everyone nearby',
      };

  String get detail => switch (this) {
        Findable.off =>
          'Nobody nearby can see you. You can still send to people who can.',
        Findable.contacts =>
          'Only people you already have a chat with can see you here',
        Findable.everyone =>
          'Anyone nearby can see your name and send you things',
      };
}

/// Somebody in range with the app open, heard over Bluetooth.
@immutable
class NearbyPerson {
  const NearbyPerson({
    required this.digits,
    required this.name,
    required this.avatarColor,
    required this.heardAt,
  });

  /// Digits of their number or account code — what a packet is addressed to.
  final String digits;

  final String name;
  final String avatarColor;
  final DateTime heardAt;

  /// Reads one off the air. Null for anything unnamed or unaddressable — a
  /// row nobody can act on is worse than no row.
  static NearbyPerson? fromWire(Map<String, dynamic> json, DateTime now) {
    final digits = json['d'];
    final name = json['n'];
    if (digits is! String || digits.isEmpty) return null;
    if (name is! String || name.trim().isEmpty) return null;
    final trimmed = name.trim();
    return NearbyPerson(
      digits: digits,
      // Bounded, because it is drawn in a list and a stranger chose it.
      name: trimmed.length > 40 ? trimmed.substring(0, 40) : trimmed,
      avatarColor: json['c'] as String? ?? '#7A5CFF',
      heardAt: now,
    );
  }

  Map<String, dynamic> toWire() => {'d': digits, 'n': name, 'c': avatarColor};
}

/// The people currently within earshot.
///
/// Entries expire, like the nearby-servers list: a list of people who *were*
/// nearby looks like a list you can send to, and is not.
class NearbyPeople extends ChangeNotifier {
  NearbyPeople._();

  static final NearbyPeople instance = NearbyPeople._();

  /// How long somebody stays listed after their last hello.
  static const Duration linger = Duration(seconds: 60);

  /// How often a findable phone says it is here. More often than the server
  /// beacon: picking a person to send to is something somebody does while
  /// standing there waiting, so a ten-second wait to see a name is too long.
  static const Duration helloInterval = Duration(seconds: 8);

  final Map<String, NearbyPerson> _heard = {};

  List<NearbyPerson> get people {
    final list = [..._heard.values];
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return List.unmodifiable(list);
  }

  bool get isEmpty => _heard.isEmpty;

  NearbyPerson? byDigits(String digits) => _heard[digits];

  void heard(NearbyPerson person) {
    final existing = _heard[person.digits];
    _heard[person.digits] = person;
    // A refresh of somebody already listed changes nothing anyone can see.
    if (existing == null || existing.name != person.name) notifyListeners();
  }

  /// Drops anyone not heard from lately. Pure in [now], so the expiry is
  /// testable without waiting a minute.
  void expire(DateTime now) {
    final gone = [
      for (final e in _heard.entries)
        if (now.difference(e.value.heardAt) > linger) e.key
    ];
    if (gone.isEmpty) return;
    for (final d in gone) {
      _heard.remove(d);
    }
    notifyListeners();
  }

  void clear() {
    if (_heard.isEmpty) return;
    _heard.clear();
    notifyListeners();
  }
}
