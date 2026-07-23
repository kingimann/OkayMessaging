import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../app_state.dart';
import '../models/chat.dart';
import '../models/user.dart';
import '../relay/relay_service.dart';
import '../state/call_service.dart';
import '../state/chat_store.dart';
import '../state/live_location_store.dart';
import '../util/geolocation.dart';
import '../utils/friend_locations.dart';
import '../utils/maps_link.dart';
import '../widgets/osm_map.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';
import 'route_map_screen.dart';

/// A Snapchat-style "Snap Map": a full-screen OpenStreetMap with your friends
/// shown as avatar pins around you. A privacy Ghost Mode hides your own pin.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _map = MapController();
  // Where "you" are. Starts at a neutral spot; recentres on real GPS if the
  // browser grants it.
  LatLng _me = const LatLng(37.7749, -122.4194);
  bool _hasGps = false;
  Timer? _shareTimer;

  @override
  void initState() {
    super.initState();
    _locate();
    // While the map is open, re-broadcast our position periodically so friends
    // see it move (only actually sends when sharing is on — see _broadcast).
    _shareTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _broadcast());
  }

  @override
  void dispose() {
    _shareTimer?.cancel();
    super.dispose();
  }

  Future<void> _locate() async {
    final pos = await getCurrentLatLng();
    if (!mounted || pos == null) return;
    setState(() {
      _me = LatLng(pos.lat, pos.lng);
      _hasGps = true;
    });
    _map.move(_me, 13);
    _broadcast();
  }

  /// Sends our real position to every contact — but only when the user has
  /// opted into live sharing and isn't in Ghost Mode, and only once we have a
  /// genuine GPS fix (never the placeholder centre).
  void _broadcast() {
    if (!_hasGps ||
        !AppState.shareLiveLocation.value ||
        AppState.ghostMode.value) {
      return;
    }
    for (final f in _friends) {
      RelayService.instance
          .sendLocation(f.phone, _me.latitude, _me.longitude);
    }
  }

  List<AppUser> get _friends => ChatStore.instance.chats
      .map((c) => c.contact)
      .where((u) => !u.isGroup)
      .toList();

  void _showFriend(AppUser user, LatLng at, {bool live = false}) {
    final meters = const Distance().distance(_me, at);
    final subtitle = live
        ? 'Sharing live · ${formatDistance(meters)} away'
        : '${formatDistance(meters)} away';
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              UserAvatar(user: user, radius: 30),
              const SizedBox(height: 10),
              Text(user.name,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (live) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFF0A84FF),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(subtitle, style: TextStyle(color: Colors.grey.shade600)),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  _message(user);
                },
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('Message'),
                style:
                    FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        CallService.instance.startOutgoing(user, video: false);
                      },
                      icon: const Icon(Icons.call_outlined),
                      label: const Text('Call'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        _directionsTo(at, user.name);
                      },
                      icon: const Icon(Icons.directions_outlined),
                      label: const Text('Directions'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _directionsTo(LatLng dest, String name) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RouteMapScreen(
          dest: dest,
          from: _hasGps ? _me : null,
          label: 'To $name',
        ),
      ),
    );
  }

  /// A friend's map marker: their real live position (blue ring) when they're
  /// sharing and it's fresh, otherwise their stable demo spot (white ring).
  Marker _friendMarker(FriendPlace p) {
    final live = LiveLocationStore.instance
        .locationFor(RelayService.digits(p.user.phone));
    final pos = live?.position ?? p.position;
    return Marker(
      point: pos,
      width: 56,
      height: 56,
      child: GestureDetector(
        onTap: () => _showFriend(p.user, pos, live: live != null),
        child: _AvatarPin(
          user: p.user,
          ringColor: live != null ? const Color(0xFF0A84FF) : Colors.white,
          live: live != null,
        ),
      ),
    );
  }

  void _message(AppUser user) {
    final chat = ChatStore.instance.chatWithContact(user.id) ??
        Chat(id: 'chat_${user.id}', contact: user, messages: const []);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Map'),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: AppState.shareLiveLocation,
            builder: (context, sharing, _) => IconButton(
              tooltip: sharing
                  ? 'Sharing your live location'
                  : 'Share your live location',
              icon: Icon(sharing
                  ? Icons.share_location
                  : Icons.location_off_outlined),
              onPressed: () {
                AppState.shareLiveLocation.value = !sharing;
                if (!sharing) _broadcast(); // just turned on
              },
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: AppState.ghostMode,
            builder: (context, ghost, _) => IconButton(
              tooltip: ghost ? 'Ghost Mode on' : 'Ghost Mode off',
              icon: Icon(ghost
                  ? Icons.visibility_off
                  : Icons.visibility_outlined),
              onPressed: () => AppState.ghostMode.value = !ghost,
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.small(
        heroTag: 'recenter',
        onPressed: () => _map.move(_me, 13),
        tooltip: 'Centre on me',
        child: const Icon(Icons.my_location),
      ),
      body: ListenableBuilder(
        // Rebuild when the contact list or any friend's live location changes.
        listenable: Listenable.merge(
            [ChatStore.instance, LiveLocationStore.instance]),
        builder: (context, _) {
          final places = friendPlaces(_me, _friends);
          return ValueListenableBuilder<bool>(
            valueListenable: AppState.ghostMode,
            builder: (context, ghost, __) => Stack(
              children: [
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: _me,
                    initialZoom: 13,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                    ),
                  ),
                  children: [
                    osmTileLayer(),
                    MarkerLayer(
                      markers: [
                        for (final p in places)
                          _friendMarker(p),
                        if (!ghost)
                          Marker(
                            point: _me,
                            width: 60,
                            height: 60,
                            child: _AvatarPin(
                              user: AppState.profile.value,
                              ringColor: const Color(0xFF25D366),
                              isMe: true,
                            ),
                          ),
                      ],
                    ),
                    const OsmAttribution(),
                  ],
                ),
                if (ghost) const _GhostBanner(),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A circular avatar "pin" with a white ring and drop shadow, à la Snap Map.
class _AvatarPin extends StatelessWidget {
  final AppUser user;
  final Color ringColor;
  final bool isMe;

  /// When true, shows a small blue "live" dot indicating a real-time position.
  final bool live;

  const _AvatarPin({
    required this.user,
    this.ringColor = Colors.white,
    this.isMe = false,
    this.live = false,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ringColor, width: 3),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: UserAvatar(user: user, radius: isMe ? 24 : 22),
    );
    if (!live) return avatar;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: 0,
          top: 0,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: const Color(0xFF0A84FF),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

/// A banner shown while Ghost Mode hides your location.
class _GhostBanner extends StatelessWidget {
  const _GhostBanner();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: Material(
        color: Colors.black.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(24),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.visibility_off, color: Colors.white, size: 18),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Ghost Mode is on — you\'re hidden from the map.',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
