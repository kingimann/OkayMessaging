import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../models/chat.dart';
import '../relay/relay_service.dart';
import '../state/chat_store.dart';
import '../state/session.dart';
import '../state/score_store.dart';
import 'mesh_packet.dart';
import 'mesh_service.dart';
import 'nearby_people.dart';
import 'nearby_transfer.dart';

/// Sending a photo straight to somebody standing next to you.
///
/// The shape AirDrop uses, because it is the right one: you are asked before
/// anything arrives. An offer says what is coming and how big; nothing moves
/// until the other person says yes; and what moves goes to them and stops
/// rather than through everybody in the room.
///
/// WHAT THIS IS NOT: fast. Real AirDrop discovers over Bluetooth and then
/// transfers over peer-to-peer Wi-Fi at tens of megabytes a second. Only
/// Bluetooth LE is wired up here, which moves a few kilobytes a second, so a
/// photo is tens of seconds of two phones held near each other. That is the
/// honest ceiling of a radio designed for heart-rate monitors; getting past
/// it means MultipeerConnectivity, which is a different native transport
/// rather than a setting.
class NearbyShare extends ChangeNotifier {
  NearbyShare._();

  static final NearbyShare instance = NearbyShare._();

  /// Transfers in flight or just finished, newest first.
  final Map<String, NearbyTransfer> _transfers = {};

  /// What we are sending, by transfer id — held until the far end accepts.
  final Map<String, String> _outgoing = {};

  /// What is arriving, by transfer id.
  final Map<String, TransferAssembler> _incoming = {};

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

  Future<bool> _send(String to, String kind, Map<String, dynamic> payload) {
    final override = debugSendOverride;
    if (override != null) return override(to, kind, payload);
    return MeshService.instance.sendDirect(to, kind, payload);
  }

  // --- Sending -------------------------------------------------------------

  /// Offers [dataUri] to [person]. Nothing of the file moves yet — an offer
  /// carries a name and a size, so somebody can refuse it without having
  /// received it first.
  ///
  /// Returns the transfer, or null when the file is too big for this radio.
  Future<NearbyTransfer?> offer(NearbyPerson person, String dataUri,
      {required String fileName}) async {
    if (dataUri.isEmpty || dataUri.length > TransferChunks.maxLength) {
      return null;
    }
    final id = MeshPacket.randomId();
    final total = TransferChunks.chunkCount(dataUri);
    final transfer = NearbyTransfer(
      id: id,
      peerDigits: person.digits,
      peerName: person.name,
      fileName: fileName,
      totalChunks: total,
      state: TransferState.offered,
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
      'b': dataUri.length,
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
    await _send(t.peerDigits, MeshPacket.kindAnswer, {'id': id, 'ok': true});
  }

  /// Says no. The other end is told, so their screen stops waiting.
  Future<void> decline(String id) async {
    final t = _transfers[id];
    if (t == null) return;
    _incoming.remove(id);
    _update(t.copyWith(state: TransferState.declined));
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
    if (chunks > (TransferChunks.maxLength / TransferChunks.perPacket).ceil()) {
      return;
    }
    final from = packet.payload['d'] as String? ?? '';
    final peer = NearbyPeople.instance.byDigits(from);
    _update(NearbyTransfer(
      id: id,
      peerDigits: from,
      peerName: peer?.name ?? (packet.payload['w'] as String? ?? 'Someone'),
      fileName: name.trim().isEmpty
          ? 'Photo'
          : (name.length > 60 ? name.substring(0, 60) : name.trim()),
      totalChunks: chunks,
      state: TransferState.incoming,
    ));
  }

  void _onAnswer(MeshPacket packet) {
    final id = packet.payload['id'];
    if (id is! String) return;
    final t = _transfers[id];
    if (t == null || t.state != TransferState.offered) return;
    if (packet.payload['ok'] != true) {
      _outgoing.remove(id);
      _update(t.copyWith(state: TransferState.declined));
      return;
    }
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
        'p': TransferChunks.slice(data, i),
      });
      final current = _transfers[id];
      // Declined or cancelled mid-flight — stop rather than finish sending to
      // somebody who said no.
      if (current == null || current.state != TransferState.sending) return;
      if (!ok) {
        _update(current.copyWith(state: TransferState.failed));
        _outgoing.remove(id);
        return;
      }
      _update(current.copyWith(sent: i + 1));
    }
    _outgoing.remove(id);
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
    final current = _transfers[id];
    if (current == null) return;
    if (whole == null || whole.isEmpty) {
      _update(current.copyWith(state: TransferState.failed));
      return;
    }
    _deliver(current, whole);
    _update(current.copyWith(state: TransferState.done));
    ScoreStore.instance.recordFlag('shared_nearby');
  }

  /// Puts what arrived into the chat with whoever sent it.
  ///
  /// Not a separate inbox: a photo somebody handed you is a photo from them,
  /// and putting it in the conversation means the gallery, the search and the
  /// backup already know what to do with it.
  void _deliver(NearbyTransfer t, String dataUri) {
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

  @visibleForTesting
  void resetForTest() {
    _transfers.clear();
    _outgoing.clear();
    _incoming.clear();
    notifyListeners();
  }
}
