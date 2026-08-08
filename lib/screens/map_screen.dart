import 'dart:async';
import '../theme/app_theme.dart';

import 'package:flutter/material.dart';
import '../widgets/sidebar_menu_button.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/chat.dart';
import '../models/user.dart';
import '../relay/relay_service.dart';
import '../state/call_service.dart';
import '../state/chat_store.dart';
import '../state/follow_store.dart';
import '../state/live_location_store.dart';
import '../state/saved_places_store.dart';
import '../state/status_store.dart';
import '../util/geocoding.dart';
import '../util/geolocation.dart';
import '../utils/friend_locations.dart';
import '../utils/maps_link.dart';
import '../widgets/osm_map.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';
import 'route_map_screen.dart';
import 'status_screen.dart';

/// A Snapchat-style "Snap Map": a full-screen OpenStreetMap with your friends
/// shown as avatar pins around you. A privacy Ghost Mode hides your own pin.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, this.fromSidebar = false});

  /// True when opened from the sidebar — shows a ☰ that reopens the sidebar
  /// instead of a back arrow.
  final bool fromSidebar;

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

  /// A pin the user long-pressed to drop, so the Snap Map keeps the pin-drop
  /// the old bare map had. Null when nothing is dropped.
  GeoResult? _dropped;

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

  /// The people on the map: your 1:1 contacts (which include anyone you follow
  /// that you've also chatted with). A followed handle you've never messaged
  /// can't be reached on-device — that needs the server-side follower channel.
  List<AppUser> get _friends => ChatStore.instance.chats
      .map((c) => c.contact)
      .where((u) => !u.isGroup && RelayService.digits(u.phone).isNotEmpty)
      .toList();

  /// Whether the map is showing anyone this device follows — used only to word
  /// the empty state honestly.
  bool get _followsAnyone => FollowStore.instance.following.isNotEmpty;

  void _showFriend(AppUser user, LatLng at,
      {bool live = false, StatusThread? story}) {
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
                  Text(subtitle, style: TextStyle(color: AppColors.subtle(context))),
                ],
              ),
              const SizedBox(height: 16),
              if (story != null) ...[
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    _openStory(story);
                  },
                  icon: const Icon(Icons.auto_stories_outlined),
                  label: const Text('View story'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    backgroundColor: const Color(0xFFFF5F6D),
                  ),
                ),
                const SizedBox(height: 10),
              ],
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
    final story = _storyFor(p.user);
    return Marker(
      point: pos,
      width: 58,
      height: 58,
      child: GestureDetector(
        onTap: () => _showFriend(p.user, pos, live: live != null, story: story),
        child: _AvatarPin(
          user: p.user,
          ringColor: live != null ? const Color(0xFF0A84FF) : Colors.white,
          live: live != null,
          hasStory: story != null,
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

  /// The friend's active story, if they have one — matched on any id the map
  /// and the status store might share. Null when they have no active story.
  StatusThread? _storyFor(AppUser u) {
    final digits = RelayService.digits(u.phone);
    for (final t in StatusStore.instance.otherThreads()) {
      if (t.authorId == u.id ||
          (u.username.isNotEmpty && t.authorId == u.username) ||
          (digits.isNotEmpty && t.authorId == digits)) {
        return t;
      }
    }
    return null;
  }

  void _openStory(StatusThread thread) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => StatusViewerScreen(thread: thread)));
  }

  /// Long-press to drop a pin — the pin-drop the bare map had, now inside the
  /// Snap Map. Reverse-geocodes for a name, then offers the place actions.
  Future<void> _dropPin(LatLng point) async {
    setState(() => _dropped =
        GeoResult(name: '', lat: point.latitude, lng: point.longitude));
    final place = await reverseGeocode(point.latitude, point.longitude);
    if (!mounted) return;
    final resolved = place ??
        GeoResult(
          name: '${point.latitude.toStringAsFixed(5)}, '
              '${point.longitude.toStringAsFixed(5)}',
          lat: point.latitude,
          lng: point.longitude,
        );
    setState(() => _dropped = resolved);
    _showPlaceSheet(resolved);
  }

  void _showPlaceSheet(GeoResult place) {
    final at = LatLng(place.lat, place.lng);
    final name = place.name.isEmpty ? 'Dropped pin' : place.name;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  _directionsTo(at, name);
                },
                icon: const Icon(Icons.directions_outlined),
                label: const Text('Directions'),
                style:
                    FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        final now = SavedPlacesStore.instance
                            .toggle(SavedPlace(name, place.lat, place.lng));
                        Navigator.of(sheetContext).pop();
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(now ? 'Saved' : 'Removed'),
                            duration: const Duration(seconds: 1)));
                      },
                      icon: const Icon(Icons.bookmark_border),
                      label: const Text('Save'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        final isApple = Theme.of(context).platform ==
                                TargetPlatform.iOS ||
                            Theme.of(context).platform == TargetPlatform.macOS;
                        Clipboard.setData(ClipboardData(
                            text: mapsUrl(
                                    lat: place.lat,
                                    lng: place.lng,
                                    label: name,
                                    apple: isApple)
                                .toString()));
                        Navigator.of(sheetContext).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Place link copied')));
                      },
                      icon: const Icon(Icons.ios_share),
                      label: const Text('Share'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(() {
      if (mounted) setState(() => _dropped = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: widget.fromSidebar ? const SidebarMenuButton() : null,
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
        // Rebuild when the contact list, a friend's live location, saved
        // places, follows, or stories change.
        listenable: Listenable.merge([
          ChatStore.instance,
          LiveLocationStore.instance,
          SavedPlacesStore.instance,
          StatusStore.instance,
          FollowStore.instance,
        ]),
        builder: (context, _) {
          // Only real, live-shared positions — no simulated friend pins.
          final places = <FriendPlace>[
            for (final f in _friends)
              if (LiveLocationStore.instance
                      .locationFor(RelayService.digits(f.phone))
                  case final live?)
                FriendPlace(f, live.position),
          ];
          return ValueListenableBuilder<bool>(
            valueListenable: AppState.ghostMode,
            builder: (context, ghost, __) => Stack(
              children: [
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    minZoom: 2,
                    maxZoom: 20.5,
                    initialCenter: _me,
                    initialZoom: 13,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                    ),
                    // Long-press to drop a pin, like the old bare map.
                    onLongPress: (_, point) => _dropPin(point),
                  ),
                  children: [
                    const LiveTileLayer(),
                    MarkerLayer(
                      markers: [
                        // Saved places, so they're reachable from the main map.
                        for (final sp in SavedPlacesStore.instance.places)
                          Marker(
                            point: LatLng(sp.lat, sp.lng),
                            width: 30,
                            height: 30,
                            alignment: Alignment.topCenter,
                            child: GestureDetector(
                              onTap: () => _showPlaceSheet(GeoResult(
                                  name: sp.name, lat: sp.lat, lng: sp.lng)),
                              child: const Icon(Icons.bookmark,
                                  color: Color(0xFFEB4B3F),
                                  size: 26,
                                  shadows: [
                                    Shadow(blurRadius: 4, color: Colors.black45)
                                  ]),
                            ),
                          ),
                        if (_dropped case final d?)
                          Marker(
                            point: LatLng(d.lat, d.lng),
                            width: 40,
                            height: 40,
                            alignment: Alignment.topCenter,
                            child: const Icon(Icons.location_on,
                                color: Color(0xFFEB4B3F),
                                size: 38,
                                shadows: [
                                  Shadow(blurRadius: 4, color: Colors.black45)
                                ]),
                          ),
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
                    const LiveAttribution(),
                  ],
                ),
                MapControls(controller: _map, bottom: 92),
                if (ghost) const _GhostBanner(),
                if (places.isEmpty)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 24,
                    child: SafeArea(
                      child: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(14),
                        color: Theme.of(context).colorScheme.surface,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: Text(
                            _followsAnyone
                                ? 'Friends and people you follow appear here '
                                    'when they turn on live location. '
                                    'Long-press the map to drop a pin.'
                                : 'People appear here when they turn on live '
                                    'location sharing. Long-press the map to '
                                    'drop a pin.',
                            style: TextStyle(
                                fontSize: 13.5,
                                color: AppColors.subtle(context)),
                          ),
                        ),
                      ),
                    ),
                  ),
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

  /// When true, wraps the pin in a Snapchat/Instagram-style gradient story ring.
  final bool hasStory;

  const _AvatarPin({
    required this.user,
    this.ringColor = Colors.white,
    this.isMe = false,
    this.live = false,
    this.hasStory = false,
  });

  @override
  Widget build(BuildContext context) {
    Widget avatar = Container(
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
    if (hasStory) {
      // An outer gradient ring says "tap to see their story", like the feed.
      avatar = Container(
        padding: const EdgeInsets.all(2.5),
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFF5F6D), Color(0xFFFFC371)],
          ),
        ),
        child: avatar,
      );
    }
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
