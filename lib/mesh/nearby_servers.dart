import 'package:flutter/foundation.dart';

/// A server somebody nearby is in, heard over Bluetooth.
///
/// Everything here travelled in the clear — a beacon has to, or nobody could
/// read it — so it is only ever sent for a server whose owner turned that on.
/// There is no membership list and no message in it: what a stranger learns is
/// that this server exists nearby and what it calls itself.
@immutable
class NearbyServer {
  const NearbyServer({
    required this.id,
    required this.name,
    required this.color,
    required this.icon,
    required this.members,
    required this.heardAt,
  });

  final String id;
  final String name;
  final String color;
  final String icon;

  /// How many people the beaconing phone says are in it. A number somebody
  /// else supplied, so it is shown as their claim and never trusted for
  /// anything that matters.
  final int members;

  final DateTime heardAt;

  NearbyServer at(DateTime when) => NearbyServer(
        id: id,
        name: name,
        color: color,
        icon: icon,
        members: members,
        heardAt: when,
      );

  /// Reads one off the air. Null for anything malformed or unnamed — a beacon
  /// with no name is a row nobody can act on.
  static NearbyServer? fromWire(Map<String, dynamic> json, DateTime now) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.trim().isEmpty) return null;
    final members = json['members'];
    return NearbyServer(
      id: id,
      // Bounded, because it is drawn in a list and it came from a stranger.
      name: name.trim().length > 60 ? name.trim().substring(0, 60) : name.trim(),
      color: json['color'] as String? ?? '#7A5CFF',
      icon: json['icon'] as String? ?? '',
      members: members is int && members >= 0 && members < 100000 ? members : 0,
      heardAt: now,
    );
  }

  Map<String, dynamic> toWire() => {
        'id': id,
        'name': name,
        'color': color,
        'icon': icon,
        'members': members,
      };
}

/// The servers currently within earshot.
///
/// A beacon is a claim that lasts about as long as being in the room does, so
/// entries expire. Without that, a list of "nearby" servers is a list of
/// servers that were nearby once — which is worse than an empty list, because
/// it looks like something you can join.
class NearbyServers extends ChangeNotifier {
  NearbyServers._();

  static final NearbyServers instance = NearbyServers._();

  /// How long a server stays listed after its last beacon. Beacons go out
  /// every [beaconInterval]; this is several of those, so one missed
  /// announcement does not make a server flicker out of the list.
  static const Duration linger = Duration(seconds: 90);

  /// How often a phone announces the servers it is in.
  static const Duration beaconInterval = Duration(seconds: 20);

  final Map<String, NearbyServer> _heard = {};

  /// What is in range right now, most recently heard first.
  List<NearbyServer> get servers {
    final list = [..._heard.values];
    list.sort((a, b) => b.heardAt.compareTo(a.heardAt));
    return List.unmodifiable(list);
  }

  bool get isEmpty => _heard.isEmpty;

  /// Records a beacon. Re-hearing a server refreshes it rather than adding it
  /// twice — several phones in the same server all beacon it.
  void heard(NearbyServer server) {
    final existing = _heard[server.id];
    _heard[server.id] = server;
    // A refresh of something already listed changes nothing anybody can see,
    // so it does not redraw the list.
    if (existing == null) notifyListeners();
  }

  /// Drops anything not heard from lately. Pure in [now] so the expiry can be
  /// tested without waiting a minute and a half.
  void expire(DateTime now) {
    final gone = [
      for (final entry in _heard.entries)
        if (now.difference(entry.value.heardAt) > linger) entry.key
    ];
    if (gone.isEmpty) return;
    for (final id in gone) {
      _heard.remove(id);
    }
    notifyListeners();
  }

  /// Forgets a server, for when it has just been joined and belongs in the
  /// real list instead.
  void forget(String id) {
    if (_heard.remove(id) != null) notifyListeners();
  }

  void clear() {
    if (_heard.isEmpty) return;
    _heard.clear();
    notifyListeners();
  }
}
