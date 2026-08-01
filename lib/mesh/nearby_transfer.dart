import 'package:flutter/foundation.dart';

/// Where a transfer has got to.
enum TransferState {
  /// Sent, waiting for them to say yes.
  offered,

  /// They have not answered yet, and it is on their screen.
  incoming,

  /// Moving.
  sending,
  receiving,

  done,
  declined,

  /// The other phone stopped answering, or the file arrived broken.
  failed,
}

/// One file on its way between two phones in a room.
///
/// Kept apart from the mesh's message path on purpose. A message is flooded —
/// nobody knows the way, so everybody carries it. A file is a hundred
/// kilobytes going to one person who agreed to receive it, so it goes to them
/// directly and stops. That difference is why [MeshPacket.directOnly] exists.
@immutable
class NearbyTransfer {
  const NearbyTransfer({
    required this.id,
    required this.peerDigits,
    required this.peerName,
    required this.fileName,
    required this.totalChunks,
    required this.state,
    this.received = 0,
    this.sent = 0,
  });

  final String id;
  final String peerDigits;
  final String peerName;

  /// What to call it on screen. Not a path — nothing here touches a
  /// filesystem, and a name off the air is a stranger's text.
  final String fileName;

  final int totalChunks;
  final TransferState state;

  /// Chunks in, for a transfer coming this way.
  final int received;

  /// Chunks out, for one going the other way.
  final int sent;

  /// How far along, 0..1. Zero rather than a division by zero for a transfer
  /// that has not been sized yet.
  double get progress {
    if (totalChunks <= 0) return 0;
    final done = state == TransferState.receiving ? received : sent;
    return (done / totalChunks).clamp(0.0, 1.0);
  }

  bool get isFinished =>
      state == TransferState.done ||
      state == TransferState.declined ||
      state == TransferState.failed;

  NearbyTransfer copyWith({
    TransferState? state,
    int? received,
    int? sent,
    int? totalChunks,
  }) =>
      NearbyTransfer(
        id: id,
        peerDigits: peerDigits,
        peerName: peerName,
        fileName: fileName,
        totalChunks: totalChunks ?? this.totalChunks,
        state: state ?? this.state,
        received: received ?? this.received,
        sent: sent ?? this.sent,
      );
}

/// Cutting a file into packet-sized pieces, and putting it back.
///
/// SEPARATE FROM MeshChunks, which cuts one packet into radio frames. This is
/// the layer above: a photo is far bigger than a packet, so it becomes forty
/// of them, each of which is then framed. Both layers are needed and they
/// count different things.
class TransferChunks {
  TransferChunks._();

  /// Characters of file per packet. Under [MeshPacket.maxBytes] with room for
  /// the envelope around it — a packet that overshoots is refused by the
  /// decoder, which would fail the whole transfer at the last step.
  static const int perPacket = 3000;

  /// The largest file this will carry, in characters of encoded data.
  ///
  /// A photo is capped at 140,000 by PhotoPrep, so this clears it with room.
  /// Bluetooth LE moves a few kilobytes a second: this is tens of seconds of
  /// two phones held near each other, which is the honest ceiling for a radio
  /// meant for heart-rate monitors.
  static const int maxLength = 200000;

  static int chunkCount(String data) => (data.length / perPacket).ceil();

  /// The [index]th slice, or empty when past the end.
  static String slice(String data, int index) {
    final start = index * perPacket;
    if (start >= data.length) return '';
    final end = start + perPacket;
    return data.substring(start, end > data.length ? data.length : end);
  }
}

/// Collects a file's chunks until it is whole.
class TransferAssembler {
  TransferAssembler(this.totalChunks);

  final int totalChunks;
  final Map<int, String> _parts = {};

  int get received => _parts.length;
  bool get isComplete => totalChunks > 0 && _parts.length == totalChunks;

  /// Files in one slice. Returns whether it was wanted — false for an index
  /// out of range or one already held, both of which happen when a sender
  /// retries.
  bool add(int index, String data) {
    if (index < 0 || index >= totalChunks) return false;
    if (_parts.containsKey(index)) return false;
    _parts[index] = data;
    return true;
  }

  /// The whole file, or null while anything is missing. Ordered by index
  /// rather than arrival — packets do not necessarily land in the order they
  /// were sent.
  String? assemble() {
    if (!isComplete) return null;
    final buffer = StringBuffer();
    for (var i = 0; i < totalChunks; i++) {
      buffer.write(_parts[i]);
    }
    return buffer.toString();
  }
}
