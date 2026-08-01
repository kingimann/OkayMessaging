import 'mesh_packet.dart';

/// What a phone should do with a packet it just heard.
enum MeshAction {
  /// It is addressed here. Open it, and pass it on as well — somebody else in
  /// range may be a hop closer to a device that has not had it yet.
  deliverAndRelay,

  /// It is addressed here and has no hops left. Open it, say nothing.
  deliver,

  /// Not for this phone, but it can carry it one hop further.
  relay,

  /// Seen before, out of hops, malformed, or from this phone to begin with.
  drop,
}

/// The decision half of the mesh: what to open, what to pass on, what to
/// throw away.
///
/// PURE ON PURPOSE. Everything hard about a flood network — a message going
/// round a ring of phones forever, a packet that never dies, the same message
/// delivered nine times because nine neighbours all relayed it — is decided
/// here, where it can be tested without a radio, two phones, or a room.
class MeshRouter {
  MeshRouter({this.myDigits = '', this.memory = _defaultMemory});

  /// How many message ids to remember. A flood only terminates because
  /// everyone recognises what they have already carried, so this is the whole
  /// safety mechanism — big enough to cover a busy room for a long while, and
  /// bounded so it cannot grow without limit on a device left running.
  static const int _defaultMemory = 2000;

  /// Digits of this device's own number. A packet addressed here is delivered;
  /// one this device sent is dropped when it comes back.
  String myDigits;

  final int memory;

  /// Ids already handled, oldest first. A LinkedHashSet keeps insertion order,
  /// which is what makes "forget the oldest" a one-liner.
  final Set<String> _seen = <String>{};

  /// Ids this device originated, so its own message coming back off a
  /// neighbour is not delivered to the sender as an incoming one.
  final Set<String> _mine = <String>{};

  int get rememberedCount => _seen.length;

  /// Notes that this device is the origin of [id]. Called when sending, so the
  /// echo that arrives a moment later is recognised.
  void noteSent(String id) {
    _mine.add(id);
    _remember(id);
    while (_mine.length > memory) {
      _mine.remove(_mine.first);
    }
  }

  /// Whether [id] has already been through here.
  bool hasSeen(String id) => _seen.contains(id);

  /// What to do with [packet], and remembers it either way.
  ///
  /// Calling this twice with the same packet gives [MeshAction.drop] the
  /// second time — which is the point, and the reason it is not a pure
  /// function despite everything else here being one.
  MeshAction accept(MeshPacket packet) {
    if (_seen.contains(packet.id)) return MeshAction.drop;
    _remember(packet.id);
    // This phone's own message, heard back from a neighbour that relayed it.
    if (_mine.contains(packet.id)) return MeshAction.drop;

    // A broadcast is for everyone: a server beacon, a request for a way in,
    // a server event nobody can address because no phone knows which of its
    // neighbours are members. Open it and pass it on — whether it turns out to
    // mean anything here is for the handler to decide, not the router, which
    // holds no keys and should not.
    final forMe = packet.isBroadcast ||
        (myDigits.isNotEmpty && packet.to == myDigits);
    if (forMe) {
      // Still worth passing on: a group message is addressed to each member
      // separately, and the neighbour behind this one may not have heard it.
      return packet.ttl > 0 ? MeshAction.deliverAndRelay : MeshAction.deliver;
    }
    return packet.ttl > 0 ? MeshAction.relay : MeshAction.drop;
  }

  /// The packet to put back on the air after [accept] said to relay, or null
  /// when it has no hops left. Never mutates the original.
  MeshPacket? forwarded(MeshPacket packet) {
    if (packet.ttl <= 0) return null;
    return packet.withTtl(packet.ttl - 1);
  }

  void reset() {
    _seen.clear();
    _mine.clear();
  }

  void _remember(String id) {
    _seen.add(id);
    // Bounded, oldest out first. Forgetting an id means a packet could be
    // carried a second time — harmless, since delivery is deduped by message
    // id further up — where growing without limit would not be.
    while (_seen.length > memory) {
      _seen.remove(_seen.first);
    }
  }
}
