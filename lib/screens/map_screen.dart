import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../app_state.dart';
import '../models/chat.dart';
import '../models/user.dart';
import '../state/call_service.dart';
import '../state/chat_store.dart';
import '../util/geolocation.dart';
import '../utils/friend_locations.dart';
import '../widgets/osm_map.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _locate();
  }

  Future<void> _locate() async {
    final pos = await getCurrentLatLng();
    if (!mounted || pos == null) return;
    setState(() => _me = LatLng(pos.lat, pos.lng));
    _map.move(_me, 13);
  }

  List<AppUser> get _friends => ChatStore.instance.chats
      .map((c) => c.contact)
      .where((u) => !u.isGroup)
      .toList();

  void _showFriend(AppUser user) {
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
              Text('On the map', style: TextStyle(color: Colors.grey.shade600)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        _message(user);
                      },
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('Message'),
                    ),
                  ),
                  const SizedBox(width: 12),
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
                ],
              ),
            ],
          ),
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
        listenable: ChatStore.instance,
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
                          Marker(
                            point: p.position,
                            width: 56,
                            height: 56,
                            child: GestureDetector(
                              onTap: () => _showFriend(p.user),
                              child: _AvatarPin(user: p.user),
                            ),
                          ),
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

  const _AvatarPin({
    required this.user,
    this.ringColor = Colors.white,
    this.isMe = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
