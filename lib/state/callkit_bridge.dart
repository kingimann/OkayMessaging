import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'call_media.dart';
import 'call_service.dart';

/// Mirrors OkayMessenger calls into iOS CallKit so they get the system's
/// call treatment — lock-screen answer and end, the green in-call pill,
/// mute from the system UI, and an entry the OS treats like a real call —
/// and applies the system's actions back onto [CallService].
///
/// Everything is fire-and-forget over one channel; platforms without the
/// native side (web, Android, tests) just never hear back and nothing
/// breaks.
class CallKitBridge {
  CallKitBridge._();
  static final CallKitBridge instance = CallKitBridge._();

  static const _channel = MethodChannel('okay/callkit');

  final Map<String, String> _uuidByCall = {};
  bool _started = false;
  String? _reportedCallId;
  CallStatus? _reportedStatus;

  /// A stable CallKit UUID for a relay call id (CallKit insists on UUIDs;
  /// the relay uses strings). Random v4, minted once per call.
  @visibleForTesting
  String uuidFor(String callId) =>
      _uuidByCall.putIfAbsent(callId, _mintUuid);

  static String _mintUuid() {
    final rng = Random.secure();
    final b = List<int>.generate(16, (_) => rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant
    String hex(int start, int end) => b
        .sublist(start, end)
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }

  void init() {
    if (_started || kIsWeb) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      final service = CallService.instance;
      switch (call.method) {
        case 'answer':
          service.accept();
        case 'end':
          final c = service.current.value;
          if (c == null) return;
          if (c.direction == CallDirection.incoming &&
              c.status == CallStatus.ringing) {
            service.decline();
          } else {
            service.end();
          }
        case 'mute':
          CallMedia.instance.setMuted(call.arguments as bool? ?? false);
      }
    });
    CallService.instance.current.addListener(_onSession);
  }

  Future<void> _invoke(String method, Map<String, dynamic> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (_) {
      // No native CallKit here — the in-app call UI stands alone.
    }
  }

  /// Follows the session through its lifecycle and reports each transition
  /// exactly once.
  void _onSession() {
    final c = CallService.instance.current.value;
    if (c == null || c.status == CallStatus.ended ||
        c.status == CallStatus.declined) {
      final endedId = c?.callId ?? _reportedCallId;
      if (endedId != null && _reportedCallId != null) {
        _invoke('ended', {
          'uuid': uuidFor(endedId),
          // The Flutter UI's own hang-up already told the relay; CallKit
          // just needs the system UI to retire. Anything else ended remotely.
          'remote': true,
        });
        _uuidByCall.remove(endedId);
      }
      _reportedCallId = null;
      _reportedStatus = null;
      return;
    }
    if (c.callId != _reportedCallId) {
      _reportedCallId = c.callId;
      _reportedStatus = c.status;
      _invoke(
        c.direction == CallDirection.outgoing ? 'outgoing' : 'incoming',
        {
          'uuid': uuidFor(c.callId),
          'name': c.peer.name.isEmpty ? c.peer.phone : c.peer.name,
          'video': c.video,
        },
      );
      if (c.status != CallStatus.connected) return;
    }
    if (c.status == CallStatus.connected &&
        _reportedStatus != CallStatus.connected) {
      _reportedStatus = CallStatus.connected;
      // An incoming call answered in the app's own UI must also be answered
      // in CallKit ('accepted' requests a CXAnswerCallAction): the system
      // stops ringing, AND — since CallKit owns the audio session once a
      // call is reported — iOS activates audio for WebRTC. Without it the
      // system call stays "ringing" and the voice path stays silent. When
      // the answer already came FROM CallKit the duplicate action errors
      // harmlessly. Outgoing calls just report the connect time.
      _invoke(
        c.direction == CallDirection.incoming ? 'accepted' : 'connected',
        {'uuid': uuidFor(c.callId)},
      );
    }
  }

  @visibleForTesting
  void resetForTest() {
    _uuidByCall.clear();
    _reportedCallId = null;
    _reportedStatus = null;
  }
}
