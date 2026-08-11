import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'nostr_event.dart';
import 'nwc.dart';

/// Talks to a Nostr relay for exactly as long as one payment takes.
///
/// Deliberately NOT a long-lived connection. A wallet connection is a
/// spending key, and holding a socket open to a third-party relay for the
/// life of the app buys nothing here — there is no inbox to watch, only
/// request-and-reply. So: open, subscribe, publish, wait for the answer,
/// close. A dropped connection between payments cannot fail, because there
/// isn't one.
///
/// Every path ends in an [NwcResult]. There is no branch that returns
/// "probably fine": a timeout, a closed socket and a refusing relay all
/// produce a named failure, because the caller uses this to decide whether to
/// tell somebody their tip arrived.
class NwcClient {
  /// How long to wait for the wallet. Real payments settle in a second or
  /// two; a wallet that has not answered in this long is one the user should
  /// be told about rather than left watching a spinner.
  static const Duration timeout = Duration(seconds: 30);

  /// Swapped in tests, which have no relay to talk to. The whole socket layer
  /// is behind this one seam so everything above it stays testable.
  @visibleForTesting
  static Future<NwcResult> Function(NwcConnection, NostrEvent)? debugSend;

  /// Publishes [request] and waits for the wallet's reply.
  static Future<NwcResult> send(
      NwcConnection connection, NostrEvent request) async {
    final hook = debugSend;
    if (hook != null) return hook(connection, request);

    WebSocketChannel? socket;
    final done = Completer<NwcResult>();
    StreamSubscription<dynamic>? sub;
    Timer? timer;

    void finish(NwcResult r) {
      if (done.isCompleted) return;
      done.complete(r);
      timer?.cancel();
      sub?.cancel();
      socket?.sink.close();
    }

    try {
      socket = WebSocketChannel.connect(connection.relay);
      await socket.ready.timeout(timeout);
    } catch (e) {
      finish(NwcResult.failed('Could not reach ${connection.relay.host}'));
      return done.future;
    }

    // A subscription id only has to be unique on this socket, which lives for
    // one request — so the request's own id is the obvious choice.
    final subId = request.id.substring(0, 16);

    sub = socket.stream.listen(
      (raw) {
        Object? frame;
        try {
          frame = jsonDecode(raw is String ? raw : utf8.decode(raw as List<int>));
        } catch (_) {
          return; // Not JSON; relays send occasional noise.
        }
        if (frame is! List || frame.isEmpty) return;
        switch (frame[0]) {
          case 'EVENT':
            if (frame.length < 3) return;
            final event = NostrEvent.fromJson(frame[2]);
            if (event == null) return;
            // readResponse is what checks this is OUR wallet answering OUR
            // request; anything else on the subscription is ignored.
            final result = connection.readResponse(event, request.id);
            if (result != null) finish(result);
          case 'OK':
            // ["OK", <id>, <accepted>, <message>] — a relay refusing the
            // request event means the wallet will never see it, so there is
            // nothing to wait for.
            if (frame.length >= 3 && frame[1] == request.id && frame[2] == false) {
              final why = frame.length >= 4 ? '${frame[3]}' : '';
              finish(NwcResult.failed(
                  why.isEmpty ? 'The relay rejected the request' : why));
            }
          case 'CLOSED':
            if (frame.length >= 2 && frame[1] == subId) {
              finish(const NwcResult.failed('The relay closed the request'));
            }
        }
      },
      onError: (_) =>
          finish(const NwcResult.failed('The connection to the relay failed')),
      onDone: () =>
          finish(const NwcResult.failed('The relay closed the connection')),
      cancelOnError: true,
    );

    timer = Timer(timeout, () {
      // Honest wording: the request went out, so the payment may yet happen.
      // Saying it failed would be a guess in the direction that loses money
      // twice if the user retries.
      finish(const NwcResult.failed(
          'The wallet did not answer in time. Check your wallet before '
          'trying again — the payment may still have gone through.'));
    });

    // Subscribe BEFORE publishing, or a wallet that answers instantly answers
    // into a subscription that does not exist yet.
    socket.sink.add(jsonEncode([
      'REQ',
      subId,
      {
        'kinds': [NwcConnection.kindResponse],
        '#p': [connection.clientPubkey],
        '#e': [request.id],
        'limit': 1,
      }
    ]));
    socket.sink.add(jsonEncode(['EVENT', request.toJson()]));

    return done.future;
  }
}
