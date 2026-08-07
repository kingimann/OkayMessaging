import 'dart:async';

import 'package:flutter/foundation.dart';

import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../util/geolocation.dart';
import 'live_share_store.dart';

/// Keeps per-chat live shares actually live.
///
/// While you have any active [LiveShareStore] share running, this re-reads the
/// GPS and pushes your position to each of those contacts every [interval],
/// whatever screen you're on — and stops the moment a share's window closes.
/// Positions ride the same ephemeral 'loc' relay event the Snap Map uses
/// (`RelayService.sendLocation`), stored nowhere on the server.
class LiveShareBroadcaster {
  LiveShareBroadcaster._();
  static final LiveShareBroadcaster instance = LiveShareBroadcaster._();

  /// How often a fresh position goes out — frequent enough to feel live,
  /// comfortably inside the receiver's 10-minute freshness window.
  static const Duration interval = Duration(seconds: 30);

  Timer? _timer;
  bool _started = false;

  /// Test hook: replaces the real relay send.
  @visibleForTesting
  static void Function(String phone, double lat, double lng)? debugSendOverride;

  /// Begins reacting to shares starting and stopping. Safe to call once.
  void start() {
    if (_started) return;
    _started = true;
    LiveShareStore.instance.addListener(_sync);
    _sync();
  }

  void _sync() {
    if (LiveShareStore.instance.anyActive) {
      if (_timer == null) {
        broadcastOnce();
        _timer = Timer.periodic(interval, (_) => broadcastOnce());
      }
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Reads the GPS once and pushes it to every contact with an active share.
  /// Returns how many contacts were updated (0 when nothing is live or there's
  /// no fix). Expired shares are pruned first, so a lapsed window sends nothing.
  Future<int> broadcastOnce() async {
    await LiveShareStore.instance.pruneExpired();
    final shares = LiveShareStore.instance.active;
    if (shares.isEmpty) return 0;
    if (debugSendOverride == null && !RelayConfig.isEnabled) return 0;
    final pos = await getCurrentLatLng();
    if (pos == null) return 0;
    for (final s in shares) {
      final send = debugSendOverride;
      if (send != null) {
        send(s.phone, pos.lat, pos.lng);
      } else {
        RelayService.instance.sendLocation(s.phone, pos.lat, pos.lng);
      }
      await LiveShareStore.instance
          .updatePosition(LiveShareStore.digitsOf(s.phone), pos.lat, pos.lng);
    }
    return shares.length;
  }

  @visibleForTesting
  void resetForTest() {
    _timer?.cancel();
    _timer = null;
    if (_started) LiveShareStore.instance.removeListener(_sync);
    _started = false;
    debugSendOverride = null;
  }
}
