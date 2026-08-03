import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import 'self_test.dart';
import 'session.dart';

/// Proves LIVE delivery on this device, end to end and against the real
/// project: subscribe to a scratch channel the way the inbox subscribes,
/// broadcast to it the way every send goes out, and wait for the ping to
/// come back over the socket.
///
/// It exists because every way live delivery can die looks identical from a
/// chat — messages still arrive, late, through the offline mailbox — so
/// "slow messages" cannot be told apart from "dead socket", "blocked
/// network" or "old build on the other phone" without asking the transport
/// itself. The envelope-unwrap step is checked explicitly: an app build
/// from before the unwrap fix receives pings and drops every one of them.
class RelaySelfTest {
  /// Injected so tests drive the whole thing without a network.
  @visibleForTesting
  static Future<bool> Function()? debugProbe;

  static Future<SelfTestReport> run() async {
    final relayEnabled = RelayConfig.isEnabled;
    final signedIn = Session.instance.user.value != null;
    bool? arrived;
    String? error;
    if (relayEnabled && signedIn) {
      try {
        arrived = await (debugProbe ?? _probe)();
      } catch (e) {
        error = '$e';
      }
    }
    final steps = <DiagnosticStep>[
      DiagnosticStep(
          'Relay configured',
          relayEnabled
              ? 'This build knows the relay server.'
              : 'This build has no relay configured — nothing can be '
                  'delivered at all.',
          relayEnabled ? CheckState.pass : CheckState.fail),
      DiagnosticStep(
          'Signed in',
          signedIn
              ? 'There is an account to deliver to.'
              : 'Not signed in — no inbox to test.',
          signedIn ? CheckState.pass : CheckState.fail),
      if (arrived != null || error != null)
        DiagnosticStep(
            'Live round trip',
            arrived == true
                ? 'A broadcast sent from this phone arrived back over the '
                    'live socket, correctly unwrapped.'
                : error != null
                    ? 'The probe failed: $error'
                    : 'The broadcast was sent but never arrived over the '
                        'socket within 8 seconds.',
            arrived == true ? CheckState.pass : CheckState.fail),
    ];
    final String verdict;
    final bool faulty;
    if (!relayEnabled || !signedIn) {
      verdict = 'Nothing to test until the relay is configured and an '
          'account is signed in.';
      faulty = true;
    } else if (arrived == true) {
      verdict = 'Live delivery works on THIS phone: messages, typing, '
          'read ticks, reactions and incoming calls sent to it should all '
          'appear instantly while the app is open. If a conversation still '
          'lags, run this same check on the other phone — and make sure '
          'both phones run a build from after the envelope fix, because an '
          'older build receives these pings and drops every one.';
      faulty = false;
    } else {
      verdict = 'Live delivery is NOT working from here — the socket never '
          'delivered the probe. Messages will still arrive through the '
          'offline mailbox when a chat is opened or refreshed, which is '
          'exactly the "slow messages" symptom. Check the network (some '
          'Wi-Fi blocks websockets; try cellular), then run this again.';
      faulty = true;
    }
    return SelfTestReport(
        title: 'Live delivery self-test',
        steps: steps,
        verdict: verdict,
        faulty: faulty);
  }

  static Future<bool> _probe() async {
    final client = Supabase.instance.client;
    final me = Session.instance.user.value?.phone ?? '';
    // A scratch topic, not the real inbox: subscribing the same topic twice
    // in one client can collide with the app's own subscription, and the
    // point is to test the transport, not to fight over the channel.
    final topic =
        'selftest_${RelayService.digits(me)}_${DateTime.now().millisecondsSinceEpoch}';
    final got = Completer<bool>();
    final listen = client.channel(topic);
    listen.onBroadcast(
      event: 'ping',
      callback: (raw) {
        // The same unwrap every real handler uses — so this check fails on
        // a build whose handlers would drop the payload.
        final payload = RelayService.unwrapBroadcast(raw);
        if (!got.isCompleted) got.complete(payload['from'] == 'selftest');
      },
    ).subscribe();
    final send = client.channel(topic);
    try {
      // Give the join a moment, then send the way the app sends: over a
      // second, never-subscribed channel object (HTTP under the hood).
      await Future<void>.delayed(const Duration(seconds: 2));
      await send
          .sendBroadcastMessage(event: 'ping', payload: {'from': 'selftest'});
      return await got.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      return false;
    } finally {
      await client.removeChannel(listen);
      if (!identical(send, listen)) await client.removeChannel(send);
    }
  }
}
