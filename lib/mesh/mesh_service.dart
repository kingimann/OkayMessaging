import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../crypto/e2e.dart';
import '../crypto/key_exchange.dart';
import '../app_state.dart';
import '../relay/relay_service.dart';
import '../state/chat_store.dart';
import '../state/community_store.dart';
import '../state/score_store.dart';
import '../state/session.dart';
import 'nearby_fast.dart';
import 'nearby_people.dart';
import 'nearby_servers.dart';
import 'nearby_share.dart';
import 'mesh_chunks.dart';
import 'mesh_packet.dart';
import 'mesh_router.dart';

/// Messages over Bluetooth, when there is no internet to send them over.
///
/// Every phone running this is both a beacon and a listener, and passes on
/// what it hears. Two people in a room can talk with no signal at all; three
/// people spread across a building can talk through the one in the middle,
/// whose phone carries the message without being able to read it — the
/// envelope is sealed by [RelayService.encode] before it ever reaches this
/// file, exactly as it is for the internet path.
///
/// WHAT THIS DELIBERATELY IS NOT, yet:
///
///  * **Text only.** Bluetooth LE moves a few kilobytes a second on iOS. A
///    photo is about 105 KB here, so it is a minute per hop with the radio at
///    full tilt; [MeshPacket.maxBytes] refuses it rather than trying.
///  * **Foreground only.** Advertising and scanning stop when iOS suspends the
///    app, because `Info.plist` does not ask for the Bluetooth background
///    modes. Adding `bluetooth-central` and `bluetooth-peripheral` to
///    `UIBackgroundModes` turns background operation on with no change to this
///    code — but background advertising drops the local name and hides the
///    service UUID in the overflow area, so discovery gets slow and uneven,
///    and App Review asks about those modes. That is a decision to take
///    deliberately, not a line to add quietly.
///  * **iOS only.** The web build has no peripheral role to offer — Safari
///    does not implement Web Bluetooth at all — so [available] is false there
///    and every caller treats "no" as ordinary.
class MeshService extends ChangeNotifier {
  MeshService._();

  static final MeshService instance = MeshService._();

  static const MethodChannel _channel = MethodChannel('okay/mesh');

  static const _enabledKey = 'mesh_enabled_v1';
  static const _relayKey = 'mesh_relay_v1';
  static const _findableKey = 'mesh_findable_v1';
  static const _discoverKey = 'mesh_discover_v1';

  final MeshRouter router = MeshRouter();
  final Map<String, MeshReassembler> _reassemblers = {};

  bool _enabled = false;
  bool _relayForOthers = true;
  bool _findServers = true;
  Findable _findable = Findable.off;
  bool _running = false;
  bool? _available;
  int _peers = 0;
  Timer? _beacon;

  /// Whether the user has turned this on. Off until asked: it runs a radio,
  /// and a messenger that quietly starts broadcasting is not one this app
  /// wants to be.
  bool get enabled => _enabled;

  /// Whether this phone passes on messages that are not its own.
  ///
  /// On by default, because a mesh where nobody relays is a mesh of one hop —
  /// but it is somebody's battery and somebody's radio, so it is theirs to
  /// turn off. Turning it off does not stop this phone sending or receiving.
  bool get relayForOthers => _relayForOthers;

  /// Whether this phone listens for servers being announced nearby.
  ///
  /// Separate from announcing your own: hearing about a stranger's server is
  /// a different thing from telling strangers about yours, and somebody may
  /// want one without the other.
  bool get findServers => _findServers;

  /// Who can see this phone when they look for somebody to send a file to.
  ///
  /// Off by default. Being findable means putting your name in the air for
  /// everyone in range, which is fine in a friend's kitchen and not fine on a
  /// train — the same question AirDrop asks, for the same reason.
  Findable get findable => _findable;

  /// Whether the radio is actually up right now.
  bool get running => _running;

  /// How many phones are in range and speaking this protocol.
  int get peers => _peers;

  /// Test hook: stands in for the platform's answer about this device.
  @visibleForTesting
  static bool? debugAvailableOverride;

  /// Test hook: receives what would have gone on the air.
  @visibleForTesting
  static void Function(String frame)? debugSendOverride;

  /// Whether this device can do any of this.
  ///
  /// False on web and on anything that is not iOS, so callers handle "no" as
  /// the normal case. Asked once — a phone does not grow a radio at runtime.
  Future<bool> get available async {
    if (debugAvailableOverride != null) return debugAvailableOverride!;
    if (_available != null) return _available!;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return _available = false;
    }
    try {
      return _available = await _channel.invokeMethod<bool>('available') ?? false;
    } on PlatformException {
      return _available = false;
    } on MissingPluginException {
      return _available = false;
    }
  }

  /// Reads the saved settings and starts the radio if it was on.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? false;
    _relayForOthers = prefs.getBool(_relayKey) ?? true;
    _findable = Findable.values.firstWhere(
        (f) => f.name == prefs.getString(_findableKey),
        orElse: () => Findable.off);
    _findServers = prefs.getBool(_discoverKey) ?? true;
    notifyListeners();
    if (_enabled) await start();
  }

  Future<void> setRelayForOthers(bool on) async {
    if (_relayForOthers == on) return;
    _relayForOthers = on;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_relayKey, on);
  }

  Future<void> setFindable(Findable how) async {
    if (_findable == how) return;
    _findable = how;
    if (how == Findable.off) NearbyPeople.instance.clear();
    notifyListeners();
    (await SharedPreferences.getInstance())
        .setString(_findableKey, how.name);
    // Hiding has to stop the fast link advertising too, or a name is still
    // answerable on the other transport.
    await NearbyFast.instance.syncWith(running: _running, findable: how);
    if (how != Findable.off) _helloOnce();
  }

  /// Test seam: sets who may reach this device without touching prefs, the
  /// fast link or the air. [setFindable] does all three, which a test with no
  /// radio cannot let it do.
  @visibleForTesting
  void debugSetFindable(Findable how) {
    _findable = how;
    notifyListeners();
  }

  Future<void> setFindServers(bool on) async {
    if (_findServers == on) return;
    _findServers = on;
    if (!on) NearbyServers.instance.clear();
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_discoverKey, on);
  }

  /// Turns the mesh on or off and remembers the choice.
  Future<void> setEnabled(bool on) async {
    if (_enabled == on) return;
    _enabled = on;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, on);
    if (on) {
      await start();
    } else {
      await stop();
    }
  }

  Future<void> start() async {
    if (_running || !await available) return;
    router.myDigits = RelayService.digits(Session.instance.user.value?.phone ?? '');
    _channel.setMethodCallHandler(_onPlatformCall);
    try {
      await _channel.invokeMethod<void>('start');
      _running = true;
      _startBeacon();
      notifyListeners();
      // The fast link rides alongside, not instead: it is the same feature,
      // and a transfer picks whichever of the two is up when it starts.
      unawaited(NearbyFast.instance
          .syncWith(running: true, findable: _findable));
    } on PlatformException {
      _running = false;
      notifyListeners();
    } on MissingPluginException {
      // A build without the native side — the web, or an iOS binary older
      // than the plugin. Not an error to report, just a radio there isn't.
      _running = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _peers = 0;
    _beacon?.cancel();
    _beacon = null;
    _reassemblers.clear();
    NearbyServers.instance.clear();
    NearbyPeople.instance.clear();
    notifyListeners();
    await NearbyFast.instance
        .syncWith(running: false, findable: _findable);
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Already down, which is where we wanted to be.
    }
  }

  /// Puts a sealed envelope on the air for [toDigits].
  ///
  /// Returns whether it went. False means this device cannot mesh, the mesh is
  /// off, or the envelope is too big for a radio this slow — all ordinary
  /// answers, and all of them mean the caller should use the internet instead.
  Future<bool> send(String toDigits, Map<String, dynamic> payload,
      {required String messageId}) async {
    if (!_running && debugSendOverride == null) return false;
    if (!MeshPacket.fits(payload)) return false;
    final packet = MeshPacket(
        id: messageId, to: toDigits, ttl: MeshPacket.maxTtl, payload: payload);
    router.noteSent(messageId);
    ScoreStore.instance.recordFlag('sent_mesh');
    return _transmit(packet);
  }

  // --- Servers over the air -----------------------------------------------

  /// Announces the servers this phone is in that were marked discoverable.
  ///
  /// Repeated rather than sent once: somebody who walks into the room a minute
  /// from now has to be able to find you, and there is no way to know they
  /// arrived.
  void _startBeacon() {
    _beacon?.cancel();
    // The hello goes out more often than the server beacon: picking somebody
    // to send a file to is done while standing there waiting for their name
    // to appear, and ten seconds of nothing reads as broken.
    _beacon = Timer.periodic(NearbyPeople.helloInterval, (_) {
      final now = DateTime.now();
      NearbyServers.instance.expire(now);
      NearbyPeople.instance.expire(now);
      _helloOnce();
      if (_sinceServerBeacon++ * NearbyPeople.helloInterval.inSeconds >=
          NearbyServers.beaconInterval.inSeconds) {
        _sinceServerBeacon = 0;
        _beaconOnce();
      }
    });
    _helloOnce();
    _beaconOnce();
  }

  int _sinceServerBeacon = 0;

  /// Says who this phone is, if its owner has said that is alright.
  void _helloOnce() {
    if (!_running && debugSendOverride == null) return;
    if (_findable == Findable.off) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final digits = RelayService.digits(me.phone);
    if (digits.isEmpty) return;
    final profile = AppState.profile.value;
    _transmit(MeshPacket(
      id: MeshPacket.randomId(),
      to: '',
      ttl: MeshPacket.maxTtl,
      kind: MeshPacket.kindHello,
      payload: {
        'd': digits,
        'n': profile.name.isEmpty ? 'Someone' : profile.name,
        'c': profile.avatarColor,
      },
    ));
  }

  void _beaconOnce() {
    if (!_running && debugSendOverride == null) return;
    for (final community in CommunityStore.instance.communities) {
      if (!community.discoverableNearby) continue;
      _transmit(MeshPacket(
        id: MeshPacket.randomId(),
        to: '',
        ttl: MeshPacket.maxTtl,
        kind: MeshPacket.kindServer,
        payload: {
          'id': community.id,
          'name': community.name,
          'color': community.color,
          'icon': community.icon,
          'members': community.members.length,
        },
      ));
    }
  }

  /// Asks whoever is near for the way into [communityId].
  ///
  /// Carries this device's public key, so the answer can be sealed to it. The
  /// request itself is public — it says somebody here wants into this server,
  /// which is the same thing the beacon already said exists.
  Future<bool> requestInvite(String communityId) async {
    final myKey = SecureKeyExchange.instance.myPublicKey;
    if (myKey == null) return false;
    return _transmit(MeshPacket(
      id: MeshPacket.randomId(),
      to: '',
      ttl: MeshPacket.maxTtl,
      kind: MeshPacket.kindAskInvite,
      payload: {'cid': communityId, 'pk': myKey},
    ));
  }

  /// Answers a request for a way in, if this phone is entitled to give one.
  ///
  /// THREE GATES, and all of them matter. The server has to have been marked
  /// discoverable, this member has to be allowed to invite under the server's
  /// own policy, and the answer is encrypted to the key that asked — so the
  /// secret goes to the asker rather than to everyone within range, which is
  /// what a plaintext reply would mean.
  void _answerInvite(Map<String, dynamic> body) {
    final cid = body['cid'];
    final theirKey = body['pk'];
    if (cid is! String || theirKey is! String || theirKey.isEmpty) return;
    final community = CommunityStore.instance.byId(cid);
    if (community == null || !community.discoverableNearby) return;
    if (!CommunityStore.instance.canInvite(cid)) return;

    final me = Session.instance.user.value;
    final myKey = SecureKeyExchange.instance.myPublicKey;
    if (me == null || myKey == null) return;
    final shared = SecureKeyExchange.instance.sharedSecretWith(theirKey);
    if (shared == null) return;

    final invite = CommunityStore.instance.exportInvite(cid,
        myDigits: RelayService.digits(me.phone),
        myName: AppState.profile.value.name);
    if (invite == null) return;

    _transmit(MeshPacket(
      id: MeshPacket.randomId(),
      to: '',
      ttl: MeshPacket.maxTtl,
      kind: MeshPacket.kindInvite,
      payload: {
        'cid': cid,
        'pk': myKey,
        'blob': E2eCrypto.encrypt(shared, jsonEncode(invite)),
      },
    ));
  }

  /// Opens an answer, if it was meant for this phone.
  ///
  /// Every phone in range hears every reply and tries this; only the one
  /// holding the other half of the handshake gets anything out of it. That is
  /// also why a reply is not addressed — the air carries no record of who
  /// joined what.
  void _takeInvite(Map<String, dynamic> body) {
    final cid = body['cid'];
    final theirKey = body['pk'];
    final blob = body['blob'];
    if (cid is! String || theirKey is! String || blob is! String) return;
    if (CommunityStore.instance.byId(cid) != null) return; // already in it
    final shared = SecureKeyExchange.instance.sharedSecretWith(theirKey);
    if (shared == null) return;
    final plain = E2eCrypto.decrypt(shared, blob);
    if (plain == null) return; // not for us, which is the usual case
    try {
      final snapshot = jsonDecode(plain);
      if (snapshot is! Map) return;
      _pendingInvites[cid] = Map<String, dynamic>.from(snapshot);
      notifyListeners();
    } catch (_) {}
  }

  /// Invites that arrived and are waiting for the user to say yes.
  final Map<String, Map<String, dynamic>> _pendingInvites = {};

  /// Whether the way into [communityId] has arrived.
  bool hasInviteFor(String communityId) =>
      _pendingInvites.containsKey(communityId);

  /// Joins a server whose invite arrived over the air. Returns whether it
  /// worked — false when nothing has answered yet.
  bool joinNearby(String communityId) {
    final snapshot = _pendingInvites.remove(communityId);
    if (snapshot == null) return false;
    final me = Session.instance.user.value;
    final joined = CommunityStore.instance.joinFromInvite(
      snapshot,
      myDigits: RelayService.digits(me?.phone ?? ''),
      myName: AppState.profile.value.name,
    );
    if (joined == null) return false;
    NearbyServers.instance.forget(communityId);
    notifyListeners();
    return true;
  }

  /// Puts a sealed server event — a channel message, a structure sync — on the
  /// air. Broadcast, because no phone knows which of its neighbours are
  /// members, and a non-member cannot decrypt it anyway.
  Future<bool> sendCommunity(Map<String, dynamic> payload,
      {required String eventId}) async {
    if (!_running && debugSendOverride == null) return false;
    if (!MeshPacket.fits(payload)) return false;
    router.noteSent(eventId);
    return _transmit(MeshPacket(
      id: eventId,
      to: '',
      ttl: MeshPacket.maxTtl,
      kind: MeshPacket.kindCommunity,
      payload: payload,
    ));
  }

  Future<bool> _transmit(MeshPacket packet) async {
    final frames = MeshChunks.split(packet.encode());
    if (frames.isEmpty) return false;
    final sink = debugSendOverride;
    if (sink != null) {
      for (final f in frames) {
        sink(f);
      }
      return true;
    }
    try {
      await _channel.invokeMethod<void>('send', {'frames': frames});
      return true;
    } on PlatformException {
      return false;
    }
  }

  Future<void> _onPlatformCall(MethodCall call) async {
    switch (call.method) {
      case 'frame':
        final args = call.arguments;
        if (args is! Map) return;
        final peer = args['peer'] as String? ?? '';
        final frame = args['frame'] as String?;
        if (frame != null) onFrame(peer, frame);
      case 'peers':
        final count = call.arguments;
        if (count is int && count != _peers) {
          _peers = count;
          notifyListeners();
        }
    }
  }

  /// One frame heard from [peer]. Public so a test can drive the whole path
  /// without a radio.
  @visibleForTesting
  void onFrame(String peer, String frame) {
    final whole = _reassemblers
        .putIfAbsent(peer, MeshReassembler.new)
        .add(frame);
    if (whole == null) return;
    final packet = MeshPacket.decode(whole);
    if (packet == null) return;
    _handle(packet);
  }

  void _handle(MeshPacket packet) {
    switch (router.accept(packet)) {
      case MeshAction.drop:
        return;
      case MeshAction.deliver:
        _deliver(packet);
      case MeshAction.deliverAndRelay:
        _deliver(packet);
        _relay(packet);
      case MeshAction.relay:
        _relay(packet);
    }
  }

  void _deliver(MeshPacket packet) {
    switch (packet.kind) {
      case MeshPacket.kindMessage:
        // Straight into the path an internet-delivered message takes — same
        // decrypt, same dedup by message id, same store. A message that
        // arrived over Bluetooth is not a different kind of message.
        RelayService.applyIncoming(packet.payload,
            myPhone: Session.instance.user.value?.phone ?? '');
      case MeshPacket.kindServer:
        if (!_findServers) return;
        final server =
            NearbyServer.fromWire(packet.payload, DateTime.now());
        // Not one we are already in — that is a server, not a nearby one.
        if (server == null) return;
        if (CommunityStore.instance.byId(server.id) != null) return;
        NearbyServers.instance.heard(server);
      case MeshPacket.kindAskInvite:
        _answerInvite(packet.payload);
      case MeshPacket.kindInvite:
        _takeInvite(packet.payload);
      case MeshPacket.kindHello:
        // Only from somebody this phone would answer. "People I chat with"
        // is enforced HERE as well as at the sender: a modified app that
        // announces itself to everyone still cannot make you list it.
        final person =
            NearbyPerson.fromWire(packet.payload, DateTime.now());
        if (person == null) return;
        if (person.digits ==
            RelayService.digits(Session.instance.user.value?.phone ?? '')) {
          return; // your own hello, off a neighbour
        }
        if (_findable == Findable.off) return;
        if (_findable == Findable.contacts &&
            ChatStore.instance.chatWithContact(person.digits) == null) {
          return;
        }
        NearbyPeople.instance.heard(person);
      case MeshPacket.kindOffer:
      case MeshPacket.kindAnswer:
      case MeshPacket.kindChunk:
        NearbyShare.instance.handle(packet);
      case MeshPacket.kindCommunity:
        // Same routing the community bus uses, which fails quietly for a
        // server this phone is not in: it cannot decrypt what it is not a
        // member of, and that is the membership check.
        RelayService.instance.applyCommunityFromMesh(
            packet.payload, Session.instance.user.value?.phone ?? '');
    }
  }

  void _relay(MeshPacket packet) {
    // Somebody else's traffic, and they said no. Their own messages still go
    // out and still arrive — this only stops the carrying.
    if (!_relayForOthers) return;
    final onward = router.forwarded(packet);
    if (onward == null) return;
    // Carrying somebody else's message is the thing that makes a mesh a mesh,
    // and the one contribution nobody would otherwise notice making.
    if (!packet.isBroadcast) ScoreStore.instance.recordFlag('relayed_mesh');
    _transmit(onward);
  }

  @visibleForTesting
  void resetForTest() {
    router.reset();
    _reassemblers.clear();
    _enabled = false;
    _relayForOthers = true;
    _findServers = true;
    _running = false;
    _available = null;
    _peers = 0;
    _beacon?.cancel();
    _beacon = null;
    _pendingInvites.clear();
    _findable = Findable.off;
    _sinceServerBeacon = 0;
    NearbyServers.instance.clear();
    NearbyPeople.instance.clear();
  }

  /// Puts a direct packet on the air for one person. Never relayed by
  /// anybody: [MeshPacket.directOnly] sees to that at the far end, and a hop
  /// count of zero sees to it here.
  Future<bool> sendDirect(
      String toDigits, String kind, Map<String, dynamic> payload) {
    if (!_running && debugSendOverride == null) return Future.value(false);
    return _transmit(MeshPacket(
      id: MeshPacket.randomId(),
      to: toDigits,
      ttl: 0,
      kind: kind,
      payload: payload,
    ));
  }

  /// Test hook: say hello without waiting for the timer.
  @visibleForTesting
  void debugHelloNow() => _helloOnce();

  /// Test hook: one round of beacons, without waiting for the timer.
  @visibleForTesting
  void debugBeaconNow() => _beaconOnce();

  /// Test hook: answer a request for a way in, as a member's phone would.
  @visibleForTesting
  void debugAnswerInvite(Map<String, dynamic> body) => _answerInvite(body);

  /// Test hook: hand a packet straight to the delivery path, skipping the
  /// router — for checking what a packet DOES once it has been accepted.
  @visibleForTesting
  void debugDeliver(MeshPacket packet) => _deliver(packet);

  /// Test hook: the whole path a heard packet takes — router first, then
  /// deliver and/or relay. This is what actually happens off the air, and the
  /// only way to see whether something was passed on.
  @visibleForTesting
  void debugReceive(MeshPacket packet) => _handle(packet);
}
