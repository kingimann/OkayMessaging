import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../models/user.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../util/geolocation.dart';
import 'chat_store.dart';

/// Keeps "share my live location" actually live.
///
/// The map screen used to send your position exactly once, when it opened —
/// so a friend's pin appeared, went stale, and vanished ten minutes later
/// even though the toggle still said you were sharing. This broadcaster runs
/// app-wide: while sharing is on (and Ghost Mode is off) it re-reads the GPS
/// and fans your position out to your contacts every [interval], whatever
/// screen you're on. Positions ride the same ephemeral relay as everything
/// else — sent to each friend's inbox, stored nowhere.
class LiveLocationBroadcaster {
  LiveLocationBroadcaster._();
  static final LiveLocationBroadcaster instance = LiveLocationBroadcaster._();

  /// How often a fresh position goes out. Comfortably inside the receiving
  /// side's 10-minute freshness window, without hammering the GPS.
  static const Duration interval = Duration(minutes: 2);

  Timer? _timer;
  bool _started = false;

  /// Test hook: replaces the actual relay send.
  @visibleForTesting
  static void Function(String phone, double lat, double lng)? debugSendOverride;

  /// Begins reacting to the sharing toggle. Safe to call once at startup.
  void start() {
    if (_started) return;
    _started = true;
    AppState.shareLiveLocation.addListener(_onToggle);
    AppState.ghostMode.addListener(_onToggle);
    _onToggle();
  }

  void _onToggle() {
    final active =
        AppState.shareLiveLocation.value && !AppState.ghostMode.value;
    if (active && _timer == null) {
      // First position immediately, then keep it fresh.
      broadcastOnce();
      _timer = Timer.periodic(interval, (_) => broadcastOnce());
    } else if (!active) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// The people a live position goes to: everyone with a real 1:1 chat.
  /// Group members you've never messaged are deliberately excluded — being
  /// in a group with someone shouldn't hand them your location.
  static List<AppUser> targets(ChatStore store) => [
        for (final chat in store.chats)
          if (!chat.contact.isGroup &&
              RelayService.digits(chat.contact.phone).isNotEmpty)
            chat.contact
      ];

  /// Reads the GPS once and fans the position out. Returns how many contacts
  /// were sent to (0 when sharing is off, there's no fix, or nobody to tell).
  Future<int> broadcastOnce() async {
    if (!AppState.shareLiveLocation.value || AppState.ghostMode.value) {
      return 0;
    }
    if (debugSendOverride == null && !RelayConfig.isEnabled) return 0;
    final pos = await getCurrentLatLng();
    if (pos == null) return 0;
    final friends = targets(ChatStore.instance);
    for (final f in friends) {
      final send = debugSendOverride;
      if (send != null) {
        send(f.phone, pos.lat, pos.lng);
      } else {
        RelayService.instance.sendLocation(f.phone, pos.lat, pos.lng);
      }
    }
    return friends.length;
  }

  @visibleForTesting
  void resetForTest() {
    _timer?.cancel();
    _timer = null;
    if (_started) {
      AppState.shareLiveLocation.removeListener(_onToggle);
      AppState.ghostMode.removeListener(_onToggle);
    }
    _started = false;
  }
}
