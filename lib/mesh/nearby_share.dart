import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../models/chat.dart';
import '../relay/relay_service.dart';
import '../state/chat_store.dart';
import '../state/session.dart';
import '../state/score_store.dart';
import '../util/file_saver.dart';
import 'mesh_packet.dart';
import 'mesh_service.dart';
import 'nearby_fast.dart';
import 'nearby_people.dart';
import 'nearby_transfer.dart';

/// Sending a photo straight to somebody standing next to you.
///
/// The shape AirDrop uses, because it is the right one: you are asked before
/// anything arrives. An offer says what is coming and how big; nothing moves
/// until the other person says yes; and what moves goes to them and stops
/// rather than through everybody in the room.
///
/// TWO TRANSPORTS, PICKED PER TRANSFER. Real AirDrop discovers over Bluetooth
/// and then moves the file over a direct Wi-Fi link. [NearbyFast] is the
/// supported half of that — Apple's MultipeerConnectivity — and when it has a
/// link to the person being sent to, a photo takes about a second. When it
/// does not, which is often, the same transfer goes over Bluetooth LE at a few
/// kilobytes a second and takes tens of seconds. Nothing above this file knows
/// which happened.
class NearbyShare extends ChangeNotifier {
  NearbyShare._();

  static final NearbyShare instance = NearbyShare._();

  /// What a transfer may say it is. Anything else is handled as a file.
  static const Set<String> kinds = {'image', 'video', 'file'};

  /// A file name off the air is a stranger's text, and it becomes a path.
  /// Bounded, stripped of anything that could climb out of a directory, and
  /// never empty.
  static String _safeName(String raw, String kind) {
    final cleaned = raw
        .trim()
        .replaceAll(RegExp(r'[/\\\x00-\x1f]'), '')
        // Runs of dots collapse to one. A single pass over ".." leaves "..."
        // as "..", which is still the parent directory — the traversal this
        // is here to stop.
        .replaceAll(RegExp(r'\.{2,}'), '.');
    // A name of nothing but dots is not a name; it is a directory entry that
    // File() would happily try to write to.
    if (cleaned.isEmpty || cleaned.replaceAll('.', '').isEmpty) {
      return switch (kind) {
        'image' => 'Photo',
        'video' => 'Video',
        _ => 'File',
      };
    }
    return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
  }

  /// Transfers in flight or just finished, newest first.
  final Map<String, NearbyTransfer> _transfers = {};

  /// What we are sending, by transfer id — held until the far end accepts,
  /// and then a while past "done", because done only means the last chunk
  /// LEFT: radio drops chunks, and the receiver may still ask for the ones
  /// that never landed.
  final Map<String, String> _outgoing = {};

  /// What is arriving, by transfer id.
  final Map<String, TransferAssembler> _incoming = {};

  /// Receiving-side stall watchdogs, by transfer id. Chunks stop coming
  /// when the radio hiccups; without this a transfer sat at 6% forever.
  /// Each tick with no progress asks the sender for what is missing, and
  /// after [_stalledTicksAllowed] silent ones the transfer fails honestly.
  final Map<String, Timer> _watchdogs = {};
  final Map<String, int> _lastReceived = {};
  final Map<String, int> _stalledTicks = {};

  /// Sender-side retention timers: how long the bytes stay around after the
  /// pump finishes, in case the far end asks again.
  final Map<String, Timer> _retention = {};

  /// Bytes of outgoing transfers that FAILED, kept so "Send again" is one
  /// tap instead of re-picking the file.
  final Map<String, String> _failedOutgoing = {};

  static const Duration watchdogTick = Duration(seconds: 8);
  static const int _stalledTicksAllowed = 4;
  static const Duration _retainAfterSend = Duration(minutes: 2);

  List<NearbyTransfer> get transfers {
    final list = [..._transfers.values];
    list.sort((a, b) => a.id.compareTo(b.id));
    return List.unmodifiable(list);
  }

  /// The one waiting to be accepted or refused, if any. Only ever one at a
  /// time on screen — a queue of pop-ups is how people say yes to something
  /// they meant to say no to.
  NearbyTransfer? get pendingIncoming {
    for (final t in _transfers.values) {
      if (t.state == TransferState.incoming) return t;
    }
    return null;
  }

  NearbyTransfer? byId(String id) => _transfers[id];

  /// Test hook: sends instead of touching a radio.
  @visibleForTesting
  static Future<bool> Function(String to, String kind, Map<String, dynamic> p)?
      debugSendOverride;

  /// One packet to one person, by whichever transport is up.
  ///
  /// The fast link first, because it is a hundred times quicker; Bluetooth
  /// when there is no link, or when the link refuses it. The far end cannot
  /// tell the difference — both arrive at [handle] as the same packet.
  Future<bool> _send(String to, String kind, Map<String, dynamic> payload) async {
    final override = debugSendOverride;
    if (override != null) return override(to, kind, payload);
    if (NearbyFast.instance.hasPeer(to) &&
        await NearbyFast.instance.send(to, kind, payload)) {
      return true;
    }
    return MeshService.instance.sendDirect(to, kind, payload);
  }

  // --- Sending -------------------------------------------------------------

  /// Offers [dataUri] to [person]. Nothing of the file moves yet — an offer
  /// carries a name, a kind and a size, so somebody can refuse a 12 MB video
  /// without having received it first.
  ///
  /// [kind] is 'image', 'video' or 'file' — what the far end should do with
  /// it once it is whole. [bytes] is the size of the original file, for
  /// saying so on the other person's screen.
  ///
  /// Returns the transfer, or null when it is too big for the way it would
  /// have to go. THAT DEPENDS ON THE TRANSPORT, which is why the check is
  /// here and not at the picker: a video is an ordinary thing to hand over a
  /// direct Wi-Fi link and an impossible thing to push through Bluetooth LE.
  Future<NearbyTransfer?> offer(NearbyPerson person, String dataUri,
      {required String fileName,
      String kind = 'file',
      int bytes = 0}) async {
    // Sized once, here, because the count goes in the offer and the far end
    // counts to it. If the fast link drops after this the transfer fails
    // rather than silently reshaping itself — a receiver waiting on forty
    // slices cannot be told mid-flight that it is now four hundred.
    final fast = NearbyFast.instance.hasPeer(person.digits);
    if (dataUri.isEmpty || dataUri.length > TransferChunks.limitFor(fast)) {
      return null;
    }
    final id = MeshPacket.randomId();
    final total = TransferChunks.chunkCount(dataUri, fast: fast);
    final transfer = NearbyTransfer(
      id: id,
      peerDigits: person.digits,
      peerName: person.name,
      fileName: fileName,
      totalChunks: total,
      state: TransferState.offered,
      fast: fast,
      kind: kind,
      bytes: bytes,
    );
    _transfers[id] = transfer;
    _outgoing[id] = dataUri;
    notifyListeners();

    // Who it is from has to be IN the offer. A packet carries who it is for,
    // not who sent it — without this the far end has an offer it cannot
    // answer, which looks like the sender walking away.
    final me = Session.instance.user.value;
    await _send(person.digits, MeshPacket.kindOffer, {
      'id': id,
      'n': fileName,
      'c': total,
      'b': bytes,
      'k': kind,
      'd': RelayService.digits(me?.phone ?? ''),
      'w': AppState.profile.value.name,
    });
    return transfer;
  }

  // --- Receiving -----------------------------------------------------------

  /// Says yes to what is on screen, and asks for it.
  Future<void> accept(String id) async {
    final t = _transfers[id];
    if (t == null || t.state != TransferState.incoming) return;
    _incoming[id] = TransferAssembler(t.totalChunks);
    _update(t.copyWith(state: TransferState.receiving));
    _watchReceiving(id);
    await _send(t.peerDigits, MeshPacket.kindAnswer, {'id': id, 'ok': true});
  }

  /// Watches an incoming transfer for stalls. Every quiet tick asks the
  /// sender for the slices that never arrived; too many quiet ticks in a
  /// row and it fails honestly instead of holding 6% on screen forever.
  void _watchReceiving(String id) {
    _lastReceived[id] = 0;
    _stalledTicks[id] = 0;
    _watchdogs[id]?.cancel();
    _watchdogs[id] = Timer.periodic(watchdogTick, (_) {
      final t = _transfers[id];
      final assembler = _incoming[id];
      if (t == null || assembler == null ||
          t.state != TransferState.receiving) {
        _stopWatching(id);
        return;
      }
      if (assembler.received > (_lastReceived[id] ?? 0)) {
        _lastReceived[id] = assembler.received;
        _stalledTicks[id] = 0;
        return;
      }
      final ticks = (_stalledTicks[id] ?? 0) + 1;
      _stalledTicks[id] = ticks;
      if (ticks >= _stalledTicksAllowed) {
        _incoming.remove(id);
        _stopWatching(id);
        _update(t.copyWith(state: TransferState.failed));
        return;
      }
      unawaited(_send(t.peerDigits, MeshPacket.kindResend, {
        'id': id,
        'need': assembler.missing(),
      }));
    });
  }

  void _stopWatching(String id) {
    _watchdogs.remove(id)?.cancel();
    _lastReceived.remove(id);
    _stalledTicks.remove(id);
  }

  /// Says no. The other end is told, so their screen stops waiting.
  Future<void> decline(String id) async {
    final t = _transfers[id];
    if (t == null) return;
    _incoming.remove(id);
    _update(t.copyWith(state: TransferState.declined));
    await _send(t.peerDigits, MeshPacket.kindAnswer, {'id': id, 'ok': false});
  }

  /// Whether [retry] has the bytes to re-offer this failed transfer.
  bool canRetry(String id) => _failedOutgoing.containsKey(id);

  /// Re-offers a failed outgoing transfer as a FRESH one — same file, same
  /// person, new id. Returns null when the bytes are gone (app restarted)
  /// or the person has left the room.
  Future<NearbyTransfer?> retry(String id) async {
    final t = _transfers[id];
    final data = _failedOutgoing.remove(id);
    if (t == null || data == null) return null;
    final person = NearbyPeople.instance.byDigits(t.peerDigits);
    if (person == null) {
      _failedOutgoing[id] = data; // still gone-able later
      return null;
    }
    return offer(person, data,
        fileName: t.fileName, kind: t.kind, bytes: t.bytes);
  }

  /// Stops a transfer that is already moving, from either end.
  ///
  /// A photo went in a second and there was nothing to stop. A video over
  /// Bluetooth is minutes, and a transfer nobody can call off is one that
  /// holds two radios hostage until it finishes.
  ///
  /// The far end is told either way: the sender stops pumping because
  /// [_pump] checks the state before every packet, and the receiver throws
  /// away what it has rather than keeping a third of a file.
  Future<void> cancel(String id) async {
    final t = _transfers[id];
    if (t == null || t.isFinished) return;
    _outgoing.remove(id);
    _incoming.remove(id);
    _stopWatching(id);
    _update(t.copyWith(state: TransferState.cancelled));
    await _send(t.peerDigits, MeshPacket.kindAnswer, {'id': id, 'ok': false});
  }

  // --- The wire ------------------------------------------------------------

  /// One direct packet, off the air. Every field is checked: this arrived
  /// from a device nobody vouched for.
  void handle(MeshPacket packet) {
    switch (packet.kind) {
      case MeshPacket.kindOffer:
        _onOffer(packet);
      case MeshPacket.kindAnswer:
        _onAnswer(packet);
      case MeshPacket.kindChunk:
        _onChunk(packet);
      case MeshPacket.kindResend:
        _onResend(packet);
    }
  }

  /// The far end lists the slices that never reached it; send those again.
  /// Only ever slices of a transfer this device is actually sending, and
  /// only while the bytes are still retained.
  Future<void> _onResend(MeshPacket packet) async {
    final id = packet.payload['id'];
    final need = packet.payload['need'];
    if (id is! String || need is! List) return;
    final t = _transfers[id];
    final data = _outgoing[id];
    if (t == null || data == null) return;
    if (t.state != TransferState.sending && t.state != TransferState.done) {
      return;
    }
    final wanted = [
      for (final n in need)
        if (n is int && n >= 0 && n < t.totalChunks) n
    ].take(64);
    for (final i in wanted) {
      await _send(t.peerDigits, MeshPacket.kindChunk, {
        'id': id,
        'i': i,
        'c': t.totalChunks,
        'p': TransferChunks.slice(data, i, fast: t.fast),
      });
    }
  }

  void _onOffer(MeshPacket packet) {
    final id = packet.payload['id'];
    final name = packet.payload['n'];
    final chunks = packet.payload['c'];
    if (id is! String || id.isEmpty || _transfers.containsKey(id)) return;
    if (name is! String) return;
    if (chunks is! int || chunks < 1) return;
    // A "file" claiming more chunks than the ceiling allows is refused before
    // any buffer is made for it.
    if (chunks > TransferChunks.maxChunks) return;
    final from = packet.payload['d'] as String? ?? '';
    final peer = NearbyPeople.instance.byDigits(from);
    // A kind off the air is a claim. Anything unrecognised is treated as a
    // plain file, which is the handling that assumes the least.
    final claimed = packet.payload['k'];
    final kind = (claimed is String && kinds.contains(claimed))
        ? claimed
        : 'file';
    final size = packet.payload['b'];
    _update(NearbyTransfer(
      id: id,
      peerDigits: from,
      peerName: peer?.name ?? (packet.payload['w'] as String? ?? 'Someone'),
      fileName: _safeName(name, kind),
      totalChunks: chunks,
      state: TransferState.incoming,
      kind: kind,
      bytes: size is int && size >= 0 ? size : 0,
    ));
  }

  void _onAnswer(MeshPacket packet) {
    final id = packet.payload['id'];
    if (id is! String) return;
    final t = _transfers[id];
    if (t == null || t.isFinished) return;
    if (packet.payload['ok'] != true) {
      // A "no" ARRIVING MID-TRANSFER is somebody cancelling, and it has to be
      // acted on: this used to be ignored unless the transfer was still
      // waiting to start, so a receiver who changed their mind about a video
      // watched it arrive anyway. [_pump] checks the state before every
      // packet, so setting it here is what stops the sending.
      final stopped = t.state == TransferState.offered
          ? TransferState.declined
          : TransferState.cancelled;
      _outgoing.remove(id);
      _incoming.remove(id);
      _stopWatching(id);
      _update(t.copyWith(state: stopped));
      return;
    }
    if (t.state != TransferState.offered) return;
    _update(t.copyWith(state: TransferState.sending));
    _pump(id);
  }

  /// Pushes the file out, a packet at a time.
  Future<void> _pump(String id) async {
    final data = _outgoing[id];
    final start = _transfers[id];
    if (data == null || start == null) return;
    final total = start.totalChunks;
    final to = start.peerDigits;
    for (var i = 0; i < total; i++) {
      final ok = await _send(to, MeshPacket.kindChunk, {
        'id': id,
        'i': i,
        'c': total,
        'p': TransferChunks.slice(data, i, fast: start.fast),
      });
      final current = _transfers[id];
      // Declined or cancelled mid-flight — stop rather than finish sending to
      // somebody who said no.
      if (current == null || current.state != TransferState.sending) return;
      if (!ok) {
        _update(current.copyWith(state: TransferState.failed));
        final kept = _outgoing.remove(id);
        if (kept != null) _failedOutgoing[id] = kept;
        return;
      }
      _update(current.copyWith(sent: i + 1));
    }
    // Keep the bytes a while: "done" only means the last chunk LEFT, and
    // the receiver may still ask for ones the radio dropped.
    _retention[id]?.cancel();
    _retention[id] = Timer(_retainAfterSend, () {
      _outgoing.remove(id);
      _retention.remove(id);
    });
    final finished = _transfers[id];
    if (finished == null) return;
    _update(finished.copyWith(state: TransferState.done));
    ScoreStore.instance.recordFlag('shared_nearby');
  }

  void _onChunk(MeshPacket packet) {
    final id = packet.payload['id'];
    final index = packet.payload['i'];
    final data = packet.payload['p'];
    if (id is! String || index is! int || data is! String) return;
    final t = _transfers[id];
    final assembler = _incoming[id];
    if (t == null || assembler == null) return;
    if (t.state != TransferState.receiving) return;
    if (!assembler.add(index, data)) return;
    _update(t.copyWith(received: assembler.received));

    if (!assembler.isComplete) return;
    final whole = assembler.assemble();
    _incoming.remove(id);
    _stopWatching(id);
    final current = _transfers[id];
    if (current == null) return;
    if (whole == null || whole.isEmpty) {
      _update(current.copyWith(state: TransferState.failed));
      return;
    }
    unawaited(_deliver(current, whole));
    _update(current.copyWith(state: TransferState.done));
    ScoreStore.instance.recordFlag('shared_nearby');
  }

  /// Puts what arrived into the chat with whoever sent it.
  ///
  /// Not a separate inbox: something somebody handed you came FROM them, and
  /// putting it in the conversation means the gallery, the search and the
  /// backup already know what to do with it.
  ///
  /// A picture goes in as a picture. A video or a file is written to disk —
  /// the same [saveIncomingFile] the WebRTC document path uses — and the chat
  /// gets a line saying what arrived and where it went, because a 12 MB video
  /// held as a base64 string inside a message is a chat store nobody can
  /// load twice.
  Future<void> _deliver(NearbyTransfer t, String dataUri) async {
    final store = ChatStore.instance;
    var chat = store.chatWithContact(t.peerDigits);
    if (chat == null) {
      final contact = AppUser(
        id: t.peerDigits,
        name: t.peerName,
        avatarColor: '#64B5F6',
        about: 'Available',
        phone: t.peerDigits,
      );
      chat = Chat(
          id: 'chat_${t.peerDigits}', contact: contact, messages: const []);
      store.upsert(chat);
    }
    final now = DateTime.now();
    if (t.kind == 'image') {
      store.addMessage(
        chat.id,
        Message(
          id: 'near_${t.id}',
          text: '',
          time: now,
          isMe: false,
          status: MessageStatus.delivered,
          isImage: true,
          imageUrl: dataUri,
          imageSeed: now.microsecondsSinceEpoch % 6,
        ),
      );
      return;
    }
    final bytes = bytesOfDataUri(dataUri);
    final where = bytes == null ? null : await saveIncomingFile(t.fileName, bytes);
    final icon = t.kind == 'video' ? '🎞' : '📎';
    store.addMessage(
      chat.id,
      Message(
        id: 'near_${t.id}',
        text: where == null
            ? '$icon ${t.fileName} — couldn\'t be saved'
            : '$icon ${t.fileName}\n$where',
        time: now,
        isMe: false,
        status: MessageStatus.delivered,
        // Flagged so the pinboard's Files tab can list it without guessing
        // from prose; only when it actually landed on disk.
        isFile: where != null,
        fileName: t.fileName,
      ),
    );
  }

  /// The bytes inside a `data:<type>;base64,…` URI, or null when it is not
  /// one or the payload will not decode. Pure.
  static Uint8List? bytesOfDataUri(String uri) {
    final comma = uri.indexOf(',');
    if (!uri.startsWith('data:') || comma < 0) return null;
    if (!uri.substring(0, comma).contains(';base64')) return null;
    try {
      return base64Decode(uri.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  void _update(NearbyTransfer t) {
    _transfers[t.id] = t;
    notifyListeners();
  }

  /// Forgets everything finished, so a list of transfers is a list of things
  /// happening rather than a history nobody asked to keep.
  void clearFinished() {
    final before = _transfers.length;
    _transfers.removeWhere((_, t) => t.isFinished);
    if (_transfers.length != before) notifyListeners();
  }

  /// How many part-finished files are being held in memory. Test-visible
  /// because "it stopped" and "it stopped AND let go of six megabytes of
  /// video" look identical from outside and are not the same thing.
  @visibleForTesting
  int get heldBuffers => _incoming.length;

  @visibleForTesting
  void resetForTest() {
    _transfers.clear();
    _outgoing.clear();
    _incoming.clear();
    for (final t in _watchdogs.values) {
      t.cancel();
    }
    _watchdogs.clear();
    _lastReceived.clear();
    _stalledTicks.clear();
    for (final t in _retention.values) {
      t.cancel();
    }
    _retention.clear();
    _failedOutgoing.clear();
    notifyListeners();
  }
}
