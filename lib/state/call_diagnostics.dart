import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_media.dart';
import 'self_test.dart';

/// What the ICE probe found: how many candidates of each kind this device
/// could gather, and whether the microphone opened at all.
class CallProbe {
  final bool micOk;
  final String micError;
  final int host;
  final int srflx;
  final int relay;

  const CallProbe({
    required this.micOk,
    this.micError = '',
    required this.host,
    required this.srflx,
    required this.relay,
  });
}

/// "Check call setup": says why calls do or don't connect from THIS network.
///
/// WHY THIS EXISTS. Every way a call can fail to connect looks identical —
/// endless "Connecting…" — and which of them it is depends on the network
/// the phone happens to be on that minute. The three candidate kinds ICE
/// gathers are the whole diagnosis: no HOST candidates means WebRTC itself
/// is broken here; no SRFLX means STUN is blocked (rare, hostile network);
/// no RELAY means the TURN server is unreachable — and two phones on
/// carrier NAT need the relay, so "calls only work on Wi-Fi" is exactly
/// this row being red. The probe gathers real candidates against the real
/// ICE servers a call would use; nothing is called and nobody is disturbed.
class CallSelfTest {
  /// Injected so tests drive the whole thing without a network or devices.
  @visibleForTesting
  static Future<CallProbe> Function()? debugProbe;

  /// How long to wait for candidate gathering. TURN allocation over TCP on
  /// a slow network can take several seconds; cutting this short reads as
  /// "TURN unreachable" on networks where it merely crawls.
  static const Duration gatherWindow = Duration(seconds: 8);

  static Future<SelfTestReport> run() async {
    CallProbe? probe;
    String? error;
    if (CallMedia.instance.isSupported || debugProbe != null) {
      try {
        probe = await (debugProbe ?? _probe)();
      } catch (e) {
        error = '$e';
      }
    }
    final verdict = verdictFor(
      supported: CallMedia.instance.isSupported || debugProbe != null,
      probe: probe,
      error: error,
    );
    return SelfTestReport(
      title: 'Call self-test',
      steps: stepsFor(
        supported: CallMedia.instance.isSupported || debugProbe != null,
        probe: probe,
        error: error,
      ),
      verdict: verdict.$1,
      faulty: verdict.$2,
    );
  }

  /// The candidate's ICE type ('host' / 'srflx' / 'relay' / 'prflx'), or
  /// null when the line doesn't carry one. Pure, so it's easy to test.
  static String? candidateType(String? candidate) {
    if (candidate == null) return null;
    final m = RegExp(r'\btyp (\w+)').firstMatch(candidate);
    return m?.group(1);
  }

  static Future<CallProbe> _probe() async {
    // The microphone half: can a call open one at all.
    var micOk = false;
    var micError = '';
    try {
      final stream =
          await navigator.mediaDevices.getUserMedia({'audio': true});
      micOk = stream.getAudioTracks().isNotEmpty;
      for (final t in stream.getTracks()) {
        t.stop();
      }
      await stream.dispose();
    } catch (e) {
      micError = '$e';
    }

    // The network half: gather real candidates against the real servers.
    var host = 0, srflx = 0, relay = 0;
    RTCPeerConnection? pc;
    try {
      pc = await createPeerConnection(CallMedia.rtcConfig);
      final done = Completer<void>();
      pc.onIceCandidate = (c) {
        switch (candidateType(c.candidate)) {
          case 'host':
            host++;
          case 'srflx':
            srflx++;
          case 'relay':
            relay++;
        }
      };
      pc.onIceGatheringState = (state) {
        if (state ==
                RTCIceGatheringState.RTCIceGatheringStateComplete &&
            !done.isCompleted) {
          done.complete();
        }
      };
      await pc.createDataChannel('probe', RTCDataChannelInit());
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      // Whichever comes first: gathering finishes, or the window closes on
      // a TURN server that will never answer.
      await done.future.timeout(gatherWindow, onTimeout: () {});
    } catch (_) {
      // Counts stay at whatever was gathered before the failure.
    } finally {
      try {
        await pc?.close();
      } catch (_) {}
    }
    return CallProbe(
        micOk: micOk, micError: micError, host: host, srflx: srflx, relay: relay);
  }

  /// Every line of the report. Pure, so the combinations are reachable from
  /// a test without a network.
  @visibleForTesting
  static List<DiagnosticStep> stepsFor({
    required bool supported,
    required CallProbe? probe,
    required String? error,
  }) {
    if (!supported) {
      return const [
        DiagnosticStep(
            'This device',
            'This build has no WebRTC, so there is nothing to check.',
            CheckState.unknown),
      ];
    }
    if (probe == null) {
      return [
        DiagnosticStep(
            'Probe',
            error == null
                ? 'The check could not run.'
                : 'The check could not run: $error',
            CheckState.fail),
      ];
    }
    return [
      probe.micOk
          ? const DiagnosticStep(
              'Microphone', 'Opens and captures.', CheckState.pass)
          : DiagnosticStep(
              'Microphone',
              'Could not be opened'
                  '${probe.micError.isEmpty ? '' : ' — ${probe.micError}'}. '
                  'Allow microphone access in Settings.',
              CheckState.fail),
      probe.host > 0
          ? DiagnosticStep('This network',
              '${probe.host} local route${probe.host == 1 ? '' : 's'}.',
              CheckState.pass)
          : const DiagnosticStep(
              'This network',
              'No local candidates at all — WebRTC could not open a '
                  'socket here.',
              CheckState.fail),
      probe.srflx > 0
          ? const DiagnosticStep('Direct path (STUN)',
              'This device can learn its public address.', CheckState.pass)
          : const DiagnosticStep(
              'Direct path (STUN)',
              'Blocked. Direct calls depend on the relay below.',
              CheckState.fail),
      probe.relay > 0
          ? const DiagnosticStep('Relay path (TURN)',
              'Reachable — calls connect even behind carrier NAT.',
              CheckState.pass)
          : const DiagnosticStep(
              'Relay path (TURN)',
              'Unreachable. Calls between two phones on cellular need '
                  'this, so they will fail on this network.',
              CheckState.fail),
    ];
  }

  /// The one sentence worth acting on.
  @visibleForTesting
  static (String, bool) verdictFor({
    required bool supported,
    required CallProbe? probe,
    required String? error,
  }) {
    if (!supported) {
      return ('This build cannot make calls, so there is nothing to check.',
          false);
    }
    if (probe == null) {
      return ('The check could not run${error == null ? '' : ': $error'}.',
          true);
    }
    if (!probe.micOk) {
      return (
        'The microphone could not be opened, and a call without one is '
            'text. Allow microphone access for the app in iOS Settings.',
        true
      );
    }
    if (probe.host == 0) {
      return (
        'WebRTC could not open a socket on this network at all — calls '
            'cannot work here.',
        true
      );
    }
    if (probe.relay == 0 && probe.srflx == 0) {
      return (
        'Both the direct path and the relay are blocked on this network. '
            'Calls will not connect here; try another network.',
        true
      );
    }
    if (probe.relay == 0) {
      return (
        'The TURN relay is unreachable from here. Calls will work when a '
            'direct path exists (same Wi-Fi, open networks) and fail '
            'between two phones on cellular — which is why calls '
            '"sometimes" fail. If a private TURN server is configured, '
            'check its credentials.',
        true
      );
    }
    return (
      'Calls can connect from this network: the microphone opens, and '
          'both the direct path and the relay are reachable.',
      false
    );
  }
}
