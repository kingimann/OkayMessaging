import 'dart:convert';

/// Cutting a packet into pieces a Bluetooth notification can actually carry,
/// and putting it back together at the other end.
///
/// A GATT notification on iOS carries around 180 bytes. A message envelope is
/// a couple of kilobytes once it has the ciphertext, the sender's name and the
/// key material in it, so nothing this app sends fits in one write and every
/// packet is a dozen frames.
///
/// PURE, AND IN DART RATHER THAN SWIFT, because reassembly is where this sort
/// of code goes wrong — a frame lost, a frame twice, two senders interleaved,
/// a last frame that never comes — and none of those are things anybody wants
/// to reproduce by walking two phones into a room.
class MeshChunks {
  MeshChunks._();

  /// Bytes of packet per frame, leaving room for the header. Deliberately
  /// under what iOS negotiates: a frame that exceeds the MTU is dropped by the
  /// stack rather than split for you.
  static const int payloadPerFrame = 140;

  /// How many frames one packet may be cut into. At 140 bytes a frame this is
  /// well past [MeshPacket.maxBytes], and it stops a malformed header
  /// promising a reassembly buffer nobody asked for.
  static const int maxFrames = 64;

  /// Splits [raw] into frames of the form `id:index:total:slice`.
  ///
  /// The id is repeated in every frame on purpose. Two neighbours can be
  /// halfway through sending different packets at the same moment, and
  /// without it the receiver has one buffer and two senders filling it.
  ///
  /// Returns an empty list for something too long to frame. A packet within
  /// [MeshPacket.maxBytes] always fits; refusing rather than clamping means a
  /// future change to either limit fails loudly instead of putting half a
  /// packet on the air.
  static List<String> split(String raw, {int size = payloadPerFrame}) {
    if (raw.isEmpty || size < 1) return const [];
    final total = (raw.length / size).ceil();
    if (total > maxFrames) return const [];
    final id = _frameId(raw);
    return [
      for (var i = 0; i < total; i++)
        '$id:$i:$total:'
            '${raw.substring(i * size, ((i + 1) * size).clamp(0, raw.length))}'
    ];
  }

  /// A short, stable id for a packet's frames. Not a checksum and not
  /// security — only enough to tell two senders apart in the moment.
  static String _frameId(String raw) {
    var hash = 0x811c9dc5;
    for (final unit in utf8.encode(raw)) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}

/// Collects frames until a packet is whole.
///
/// One of these per peer. It holds partial packets from several senders at
/// once and hands back a packet the moment its last frame lands.
class MeshReassembler {
  MeshReassembler({this.maxPending = 8});

  /// How many half-finished packets to hold. A peer that starts packets and
  /// never finishes them must not be able to grow this without limit; when it
  /// is full the least recently touched one is abandoned.
  final int maxPending;

  final Map<String, List<String?>> _pending = {};

  int get pendingCount => _pending.length;

  /// Feeds one frame in. Returns the complete packet when [frame] was the last
  /// one missing, and null otherwise — including for a frame that is
  /// malformed, out of range, or a duplicate.
  String? add(String frame) {
    final first = frame.indexOf(':');
    if (first <= 0) return null;
    final second = frame.indexOf(':', first + 1);
    if (second <= first) return null;
    final third = frame.indexOf(':', second + 1);
    if (third <= second) return null;

    final id = frame.substring(0, first);
    final index = int.tryParse(frame.substring(first + 1, second));
    final total = int.tryParse(frame.substring(second + 1, third));
    final slice = frame.substring(third + 1);
    if (index == null || total == null) return null;
    if (total < 1 || total > MeshChunks.maxFrames) return null;
    if (index < 0 || index >= total) return null;

    final slots = _pending.putIfAbsent(id, () => List<String?>.filled(total, null));
    // A second frame claiming a different length is a different packet with a
    // colliding id, or a corrupt one. Either way the buffer is no longer
    // trustworthy, so it goes rather than being partly overwritten.
    if (slots.length != total) {
      _pending.remove(id);
      return null;
    }
    slots[index] = slice;

    if (slots.any((s) => s == null)) {
      _evictIfCrowded(id);
      return null;
    }
    _pending.remove(id);
    return slots.join();
  }

  void reset() => _pending.clear();

  void _evictIfCrowded(String keep) {
    while (_pending.length > maxPending) {
      final oldest = _pending.keys.firstWhere((k) => k != keep,
          orElse: () => _pending.keys.first);
      if (oldest == keep) return;
      _pending.remove(oldest);
    }
  }
}
