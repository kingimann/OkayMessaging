import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../relay/relay_service.dart';
import '../state/session.dart';
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

  final MeshRouter router = MeshRouter();
  final Map<String, MeshReassembler> _reassemblers = {};

  bool _enabled = false;
  bool _running = false;
  bool? _available;
  int _peers = 0;

  /// Whether the user has turned this on. Off until asked: it runs a radio,
  /// and a messenger that quietly starts broadcasting is not one this app
  /// wants to be.
  bool get enabled => _enabled;

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

  /// Reads the saved setting and starts the radio if it was on.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? false;
    notifyListeners();
    if (_enabled) await start();
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
      notifyListeners();
    } on PlatformException {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _peers = 0;
    _reassemblers.clear();
    notifyListeners();
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
    return _transmit(packet);
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
    // Straight into the path an internet-delivered message takes — same
    // decrypt, same dedup by message id, same store. A message that arrived
    // over Bluetooth is not a different kind of message.
    RelayService.applyIncoming(packet.payload,
        myPhone: Session.instance.user.value?.phone ?? '');
  }

  void _relay(MeshPacket packet) {
    final onward = router.forwarded(packet);
    if (onward != null) _transmit(onward);
  }

  @visibleForTesting
  void resetForTest() {
    router.reset();
    _reassemblers.clear();
    _enabled = false;
    _running = false;
    _available = null;
    _peers = 0;
  }
}
