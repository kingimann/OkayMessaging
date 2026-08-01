import 'dart:convert';

/// One hop's worth of a message travelling over Bluetooth instead of the
/// internet.
///
/// The [payload] is the SAME sealed envelope `RelayService.encode` builds for
/// the Supabase bus and the mailbox — already encrypted, already addressed.
/// That is what makes relaying through a stranger's phone acceptable: the
/// device carrying it cannot read it, any more than the server can. Nothing in
/// this file may ever look inside [payload].
///
/// What travels in the clear is only what a router needs: who it is for, so a
/// phone knows whether to open it or pass it on, and an id and a hop count, so
/// it stops.
class MeshPacket {
  const MeshPacket({
    required this.id,
    required this.to,
    required this.ttl,
    required this.payload,
  });

  /// Wire format version. A phone that meets a packet it cannot parse should
  /// drop it rather than guess, so this is checked before anything else.
  static const int version = 1;

  /// The furthest a packet may travel. Five hops is well past the range any
  /// crowd of phones actually forms, and a mesh with no ceiling is a mesh that
  /// carries the same message forever.
  static const int maxTtl = 5;

  /// The biggest packet this carries, in bytes of encoded JSON.
  ///
  /// TEXT ONLY, and this is the line that enforces it. Bluetooth LE on iOS
  /// moves a few kilobytes a second, so a photo — which this app caps at about
  /// 105 KB — is a minute per hop with the radio pinned the whole time. A
  /// message that will not fit goes by the internet or not at all; it does not
  /// go slowly.
  static const int maxBytes = 4096;

  /// The message id, which is already unique per message. Doubles as the
  /// dedup key: a mesh floods, so the same packet arrives repeatedly and the
  /// only thing stopping an infinite loop is having seen this before.
  final String id;

  /// Digits of the recipient's number. In the clear on purpose — a phone has
  /// to know whether a packet is its own without being able to decrypt it.
  /// It reveals that somebody near you is talking to this number, which is
  /// the price of routing without a server.
  final String to;

  /// Hops remaining. Decremented by each relay; a packet at zero is dropped.
  final int ttl;

  /// The sealed envelope. Opaque here, always.
  final Map<String, dynamic> payload;

  MeshPacket withTtl(int next) =>
      MeshPacket(id: id, to: to, ttl: next, payload: payload);

  Map<String, dynamic> toJson() => {
        'v': version,
        'id': id,
        'to': to,
        'ttl': ttl,
        'p': payload,
      };

  String encode() => jsonEncode(toJson());

  /// Parses one packet, or null if it is malformed, from another version, or
  /// outside the bounds this router will act on.
  ///
  /// Everything arriving here came off the air from a device nobody vouched
  /// for, so every field is checked rather than assumed. A TTL above [maxTtl]
  /// is not clamped, it is refused: clamping would let one sender hand every
  /// phone in range a packet with a hop count of its choosing.
  static MeshPacket? decode(String raw) {
    if (raw.length > maxBytes) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      if (json['v'] != version) return null;
      final id = json['id'];
      final to = json['to'];
      final ttl = json['ttl'];
      final payload = json['p'];
      if (id is! String || id.isEmpty) return null;
      if (to is! String) return null;
      if (ttl is! int || ttl < 0 || ttl > maxTtl) return null;
      if (payload is! Map) return null;
      return MeshPacket(
        id: id,
        to: to,
        ttl: ttl,
        payload: Map<String, dynamic>.from(payload),
      );
    } catch (_) {
      return null;
    }
  }

  /// Whether [payload] is small enough to be worth sending over a radio this
  /// slow. Checked before transmitting, so an oversized message fails at the
  /// sender rather than half-arriving.
  static bool fits(Map<String, dynamic> payload) =>
      MeshPacket(id: 'x', to: 'x', ttl: maxTtl, payload: payload)
          .encode()
          .length <=
      maxBytes;
}
