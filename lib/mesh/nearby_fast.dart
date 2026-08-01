import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../relay/relay_service.dart';
import '../state/session.dart';
import 'mesh_packet.dart';
import 'nearby_people.dart';
import 'nearby_share.dart';

/// The fast link between two phones in a room.
///
/// The Bluetooth mesh finds people, carries messages and carries files, and it
/// is slow: LE moves a few kilobytes a second, so a photo is tens of seconds
/// of two phones held near each other. MultipeerConnectivity — Apple's own
/// framework, and the supported half of what AirDrop does — discovers over
/// Bluetooth and then brings up a direct Wi-Fi link between the two devices.
/// The same photo goes in about a second.
///
/// THIS IS A SECOND TRANSPORT, NOT A REPLACEMENT. It exists only between two
/// devices that found each other and connected, which takes a moment and often
/// never happens. Every caller asks [hasPeer] first and falls back to the mesh,
/// and nothing anywhere depends on this being up.
///
/// WHAT GOES IN THE AIR BEFORE A LINK EXISTS: a random token, minted fresh
/// each time this starts, and nothing else. Somebody browsing the service
/// learns that a phone nearby runs this app — which the mesh's Bluetooth
/// service UUID already tells them — and not who. Who is exchanged over the
/// link, which is encrypted, and only when the user has made themselves
/// findable at all. That is the same condition the Bluetooth hello goes out
/// under, and this one is not in the clear.
class NearbyFast extends ChangeNotifier {
  NearbyFast._();

  static final NearbyFast instance = NearbyFast._();

  static const MethodChannel _channel = MethodChannel('okay/nearbyfast');

  /// The two things that cross a link. Everything else is refused.
  static const String _kindHello = 'hi';
  static const String _kindPacket = 'pkt';

  /// What this device is advertised as. Meaningless, and different every run.
  String? _token;

  /// Peers with a live link, by their token.
  final Set<String> _peerTokens = {};

  /// Who those peers turned out to be, once they said so.
  final Map<String, String> _digitsByToken = {};
  final Map<String, String> _tokenByDigits = {};

  bool _running = false;
  bool _advertising = false;
  bool? _available;

  /// Whether the link layer is up. Not whether anybody is on the other end.
  bool get running => _running;

  /// Digits of everyone reachable over a fast link right now.
  Iterable<String> get peerDigits => _tokenByDigits.keys;

  /// Whether [digits] can be reached fast. The one question callers ask.
  bool hasPeer(String digits) => _tokenByDigits.containsKey(digits);

  /// Test hook: stands in for the platform's answer about this device.
  @visibleForTesting
  static bool? debugAvailableOverride;

  /// Test hook: receives what would have gone over a link, as (token, body).
  @visibleForTesting
  static void Function(String to, String body)? debugSendOverride;

  Future<bool> get available async {
    final override = debugAvailableOverride;
    if (override != null) return override;
    if (_available != null) return _available!;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return _available = false;
    }
    try {
      return _available =
          await _channel.invokeMethod<bool>('available') ?? false;
    } on PlatformException {
      return _available = false;
    } on MissingPluginException {
      return _available = false;
    }
  }

  /// Brings the link layer up or down to match the mesh's own state.
  ///
  /// Driven from [MeshService] rather than from a setting of its own: this is
  /// the fast half of "message people nearby", not a second feature to find
  /// and turn on. Advertising follows findability — browsing does not, because
  /// somebody who has hidden themselves can still send.
  Future<void> syncWith({required bool running, required Findable findable}) async {
    final wantAdvertise = findable != Findable.off;
    if (!running) {
      await stop();
      return;
    }
    if (_running) {
      if (wantAdvertise != _advertising) await _setAdvertising(wantAdvertise);
      return;
    }
    await start(advertise: wantAdvertise);
  }

  Future<void> start({required bool advertise}) async {
    if (_running || !await available) return;
    // Fresh every run. A token that persisted would be a name that follows
    // somebody between rooms, which is the thing this avoids.
    final token = MeshPacket.randomId();
    _channel.setMethodCallHandler(_onPlatformCall);
    try {
      await _channel.invokeMethod<void>(
          'start', {'token': token, 'advertise': advertise});
      _token = token;
      _running = true;
      _advertising = advertise;
      notifyListeners();
    } on PlatformException {
      _running = false;
    } on MissingPluginException {
      // A build without the native side — the web, or an older binary. Not an
      // error, just a link layer there isn't.
      _running = false;
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _advertising = false;
    _token = null;
    _peerTokens.clear();
    _digitsByToken.clear();
    _tokenByDigits.clear();
    notifyListeners();
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Already down, which is where we wanted to be.
    } on MissingPluginException {
      // Never was up.
    }
  }

  Future<void> _setAdvertising(bool on) async {
    _advertising = on;
    try {
      await _channel.invokeMethod<void>('advertise', on);
    } on PlatformException {
      // Nothing to advertise from. Sending still works.
    } on MissingPluginException {
      // Nothing to advertise from. Sending still works.
    }
  }

  // --- The wire ------------------------------------------------------------

  /// Sends one direct packet to [toDigits] over the fast link.
  ///
  /// Returns false when there is no link to that person, which is the ordinary
  /// case and means the caller should use the mesh instead. The envelope here
  /// is deliberately NOT [MeshPacket.encode]: that format is capped at 4 KB
  /// because a radio for heart-rate monitors cannot carry more, and the whole
  /// point of this path is that it can.
  Future<bool> send(
      String toDigits, String kind, Map<String, dynamic> payload) async {
    final token = _tokenByDigits[toDigits];
    if (token == null) return false;
    return _sendRaw(token, {
      'k': _kindPacket,
      'kind': kind,
      'to': toDigits,
      'p': payload,
    });
  }

  Future<bool> _sendRaw(String token, Map<String, dynamic> body) async {
    final override = debugSendOverride;
    if (override != null) {
      override(token, jsonEncode(body));
      return true;
    }
    if (!_running) return false;
    try {
      return await _channel.invokeMethod<bool>(
              'send', {'to': token, 'body': jsonEncode(body)}) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Tells a peer who this device belongs to.
  ///
  /// Sent under exactly the condition the Bluetooth hello is sent under — the
  /// user has made themselves findable — and over an encrypted link rather
  /// than in the clear. Somebody who is not findable never sends this, so
  /// their token stays a token and nobody can address them.
  Future<void> _helloTo(String token) async {
    if (!_advertising) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final digits = RelayService.digits(me.phone);
    if (digits.isEmpty) return;
    final name = AppState.profile.value.name;
    await _sendRaw(token, {
      'k': _kindHello,
      'd': digits,
      'n': name.isEmpty ? 'Someone' : name,
    });
  }

  Future<void> _onPlatformCall(MethodCall call) async {
    switch (call.method) {
      case 'peers':
        final args = call.arguments;
        if (args is! List) return;
        await notePeers([
          for (final t in args)
            if (t is String) t
        ]);
      case 'body':
        final args = call.arguments;
        if (args is! Map) return;
        final from = args['from'];
        final body = args['body'];
        if (from is String && body is String) noteBody(from, body);
    }
  }

  /// The current set of linked peers, off the platform. Public so a test can
  /// drive the whole path without two phones.
  @visibleForTesting
  Future<void> notePeers(List<String> tokens) async {
    final incoming = tokens.toSet();
    final arrived = incoming.difference(_peerTokens);
    final gone = _peerTokens.difference(incoming);
    if (arrived.isEmpty && gone.isEmpty) return;
    for (final token in gone) {
      final digits = _digitsByToken.remove(token);
      if (digits != null) _tokenByDigits.remove(digits);
    }
    _peerTokens
      ..removeAll(gone)
      ..addAll(arrived);
    notifyListeners();
    for (final token in arrived) {
      await _helloTo(token);
    }
  }

  /// One body off a link. Every field is checked: a link is encrypted, which
  /// says nothing about whether the phone at the other end is honest.
  ///
  /// Returns whether it was acted on. Callers ignore that; a test does not,
  /// because "it was dropped" and "it was accepted and happened to do nothing"
  /// look identical from outside and are not the same thing.
  @visibleForTesting
  bool noteBody(String from, String body) {
    if (!_peerTokens.contains(from)) return false;
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return false;
    }
    if (decoded is! Map) return false;
    switch (decoded['k']) {
      case _kindHello:
        final digits = decoded['d'];
        if (digits is! String || digits.isEmpty || digits.length > 40) {
          return false;
        }
        if (!RegExp(r'^\d+$').hasMatch(digits)) return false;
        // One token per person and one person per token, or a peer that
        // reconnects under a new token leaves a stale route behind it.
        final previous = _tokenByDigits[digits];
        if (previous != null && previous != from) {
          _digitsByToken.remove(previous);
        }
        _digitsByToken[from] = digits;
        _tokenByDigits[digits] = from;
        notifyListeners();
        return true;
      case _kindPacket:
        final kind = decoded['kind'];
        final to = decoded['to'];
        final payload = decoded['p'];
        // A file, and only a file. This link is not a second way into the
        // message bus or the server bus — those arrive sealed, over the mesh,
        // and are checked there.
        if (kind is! String || !MeshPacket.directOnly.contains(kind)) {
          return false;
        }
        if (payload is! Map) return false;
        final me = RelayService.digits(Session.instance.user.value?.phone ?? '');
        if (me.isEmpty || to != me) return false;
        NearbyShare.instance.handle(MeshPacket(
          id: MeshPacket.randomId(),
          to: me,
          ttl: 0,
          kind: kind,
          payload: Map<String, dynamic>.from(payload),
        ));
        return true;
      default:
        return false;
    }
  }

  @visibleForTesting
  void resetForTest() {
    _running = false;
    _advertising = false;
    _available = null;
    _token = null;
    _peerTokens.clear();
    _digitsByToken.clear();
    _tokenByDigits.clear();
  }

  /// Test hook: pretend the link layer is up, without a platform to bring up.
  @visibleForTesting
  void debugMarkRunning({bool advertising = true}) {
    _running = true;
    _advertising = advertising;
    _token ??= 'testtoken';
  }
}
