// Probes the live Realtime path end to end, exactly the way the app uses it:
// subscribe to an inbox channel, broadcast to it from a SECOND, unsubscribed
// channel (which goes over HTTP, like every send in the app), and report
// whether the ping arrives over the socket. Run: dart tool/probe_realtime.dart
//
// This proved the wire shape: the callback receives the whole envelope
// ({event, payload, type}), which is what RelayService.unwrapBroadcast peels.
// realtime_client is a transitive dep of supabase_flutter — fine for a
// diagnostic that must mirror exactly what the app links.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:io';

import 'package:realtime_client/realtime_client.dart';

const url = 'https://trbdqucphtsstnrwwfnw.supabase.co';
const anon = 'sb_publishable_PrY-Aru0AryWyhHgfD2Tow_uXca1owt';

Future<void> main() async {
  final socket = RealtimeClient(
    '${url.replaceFirst('https', 'wss')}/realtime/v1',
    params: {'apikey': anon},
    logger: (kind, msg, data) => stdout.writeln('[$kind] $msg $data'),
  );

  final got = Completer<Map<String, dynamic>>();
  final listen = socket.channel('inbox_9998887777');
  listen.onBroadcast(
    event: 'typing',
    callback: (payload) {
      if (!got.isCompleted) got.complete(Map<String, dynamic>.from(payload));
    },
  ).subscribe((status, [error]) {
    stdout.writeln('subscribe status: $status ${error ?? ''}');
  });

  // Give the join a moment, like a chat already open on the recipient's phone.
  await Future<void>.delayed(const Duration(seconds: 4));

  // The sender side: an unsubscribed channel broadcasts over HTTP.
  final send = socket.channel('inbox_9998887777');
  try {
    final res = await send.sendBroadcastMessage(
      event: 'typing',
      payload: {'from': '+1 555 000 0001'},
    );
    stdout.writeln('send result: $res');
  } catch (e) {
    stdout.writeln('send FAILED: $e');
  }

  try {
    final payload = await got.future.timeout(const Duration(seconds: 8));
    stdout.writeln('LIVE DELIVERY OK: $payload');
    exitCode = 0;
  } on TimeoutException {
    stdout.writeln('LIVE DELIVERY FAILED: broadcast never arrived');
    exitCode = 1;
  }
  socket.disconnect();
  exit(exitCode);
}
