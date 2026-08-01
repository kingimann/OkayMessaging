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

  /// Stopped by one of the two people, at either end, after it had started.
  /// Not the same fact as [declined] — nobody refused it, somebody changed
  /// their mind — and a 12 MB video is long enough that they need to be able
  /// to.
  cancelled,

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
    this.fast = false,
    this.kind = 'file',
    this.bytes = 0,
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

  /// What the far end should do with it once it is whole: 'image' to show,
  /// 'video' to play, 'file' to save. Off the air and therefore a claim, not
  /// a fact — [FileModeration] sniffs the bytes at the sender and the
  /// receiver decides what to do from this, so the worst a lie achieves is a
  /// file that lands in the wrong place.
  final String kind;

  /// Size of the original file, for saying so before it is accepted. A person
  /// deciding whether to take a 40 MB video needs to be told it is 40 MB.
  final int bytes;

  /// Whether this was sized for the fast link rather than for Bluetooth.
  ///
  /// Decided once, when the offer goes out, because the number of chunks is
  /// in the offer and the far end counts them. Only the sender ever looks at
  /// it — a receiver reassembles slices in index order and never needs to
  /// know how big they were.
  final bool fast;

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
      state == TransferState.cancelled ||
      state == TransferState.failed;

  /// Moving right now, in either direction.
  bool get isMoving =>
      state == TransferState.sending || state == TransferState.receiving;

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
        fast: fast,
        kind: kind,
        bytes: bytes,
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

  /// Characters of file per message on the fast link.
  ///
  /// MultipeerConnectivity has no four-kilobyte ceiling — it is a Wi-Fi link,
  /// not an LE characteristic — so this is sized for a progress bar that moves
  /// rather than for a radio. A capped photo becomes a handful of messages
  /// that land in about a second.
  static const int perPacketFast = 32000;

  static int sizeFor(bool fast) => fast ? perPacketFast : perPacket;

  /// The largest file Bluetooth will carry, in characters of encoded data.
  ///
  /// A photo is capped at 140,000 by PhotoPrep, so this clears it with room.
  /// LE moves a few kilobytes a second: this is already tens of seconds of two
  /// phones held near each other, which is the honest ceiling for a radio
  /// meant for heart-rate monitors. A video does not go this way.
  static const int maxLength = 200000;

  /// The largest file the fast link will carry, in characters of encoded data
  /// — about 12 MB of file, which is a short video or any ordinary document.
  ///
  /// NOT the link's limit. MultipeerConnectivity over Wi-Fi would carry far
  /// more; this pipeline is the constraint, because it moves base64 TEXT. A
  /// string of n characters is 2n bytes of memory in Dart, the receiver holds
  /// every slice and then builds the whole thing again to assemble it, so the
  /// peak is several times the file. Raising this means moving bytes instead
  /// of text through the channel, on both sides, in Swift as well as Dart —
  /// not changing this number.
  static const int maxLengthFast = 16000000;

  /// The ceiling for a transfer going by [fast] or not, in characters.
  static int limitFor(bool fast) => fast ? maxLengthFast : maxLength;

  /// The same ceiling in bytes of original file, which is what a person picks
  /// and what a size cap should be stated in. Base64 is four characters per
  /// three bytes, and a data: URI adds a short prefix.
  static int fileLimitFor(bool fast) => limitFor(fast) ~/ 4 * 3;

  static int chunkCount(String data, {bool fast = false}) =>
      (data.length / sizeFor(fast)).ceil();

  /// The most chunks any honest transfer can claim.
  ///
  /// Worked out from the LARGER ceiling at the LARGER packet size, which is
  /// the only pair that can actually occur together — a fast transfer is cut
  /// into fast-sized pieces. Using the small ceiling here would have refused
  /// every honest video as a liar.
  static int get maxChunks => (maxLengthFast / perPacketFast).ceil();

  /// The [index]th slice, or empty when past the end.
  static String slice(String data, int index, {bool fast = false}) {
    final size = sizeFor(fast);
    final start = index * size;
    if (start >= data.length) return '';
    final end = start + size;
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
