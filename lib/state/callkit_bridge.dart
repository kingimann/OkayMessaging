import 'dart:convert';

import 'package:crypto/crypto.dart';
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
  /// the relay uses strings). DERIVED from the call id, not minted: a VoIP
  /// push reports the call to CallKit from Swift before Dart is even
  /// running, and both sides computing SHA-256(callId) is what makes them
  /// name the same system call instead of ringing it twice. The Swift twin
  /// is CallKitBridge.uuidFor in AppDelegate.swift — the two must agree
  /// byte for byte.
  @visibleForTesting
  String uuidFor(String callId) =>
      _uuidByCall.putIfAbsent(callId, () => _derivedUuid(callId));

  static String _derivedUuid(String callId) {
    final b = List<int>.of(sha256.convert(utf8.encode(callId)).bytes.take(16));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4 shape
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
      // Swift passes {uuid, callId} once it knows the call id (a VoIP wake
      // knows it before Dart does); older shapes were a bare uuid string.
      final args = call.arguments;
      final callId =
          args is Map ? (args['callId'] as String? ?? '') : '';
      switch (call.method) {
        case 'answer':
          if (service.current.value != null) {
            service.accept();
          } else if (callId.isNotEmpty) {
            // Answered from the lock screen before the app finished waking:
            // the offer is still on its way in from the mailbox. Remember
            // the intent; the offer's arrival completes it.
            service.noteVoipAnswer(callId);
          }
        case 'end':
          final c = service.current.value;
          if (c == null) {
            if (callId.isNotEmpty) service.noteVoipDecline(callId);
            return;
          }
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
          // So Swift can name the relay call in lock-screen actions — a
          // VoIP wake acts before this side has any session to consult.
          'callId': c.callId,
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
