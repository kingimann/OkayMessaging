import 'dart:async';


import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../state/saved_places_store.dart';
import '../util/geocoding.dart';
import '../util/geolocation.dart';
import '../utils/maps_link.dart';
import '../widgets/osm_map.dart';
import 'forward_screen.dart';

/// A standalone, Apple-Maps-style map: search places or nearby categories, see
/// them on the map, read details with distance, save favourites, and get
/// in-app directions — no external maps needed.
///
/// **Also the location picker.** Attaching a place to a chat used to open a
/// second, much poorer map: a centre pin over a submit-only search box, with
/// no suggestions as you type, no nearby categories, no saved places, no
/// recents, and nothing to name what you were pointing at — a shared spot
/// arrived as "Shared location" and a pair of coordinates. There is no reason
/// for the app to contain two maps, and the good one was not the one in the
/// chat. Opened with [picking] it returns the chosen place instead of
/// offering to forward it.
class ExploreMapScreen extends StatefulWidget {
  /// Test/preview hook: a fixed "current location" fix, bypassing real GPS.
  final LatLng? debugMyLocation;

  /// When true this is a chooser: the place card offers "Send this location",
  /// which pops with the selected [GeoResult]. Everything else about the map
  /// is unchanged, which is the entire point.
  final bool picking;

  const ExploreMapScreen({
    super.key,
    this.debugMyLocation,
    this.picking = false,
  });

  @override
  State<ExploreMapScreen> createState() => _ExploreMapScreenState();
}

class _ExploreMapScreenState extends State<ExploreMapScreen> {
  final MapController _map = MapController();

  /// The height of whatever is currently parked along the bottom edge that
  /// isn't the search sheet — the place card, or the results list.
  ///
  /// The search sheet is only mounted when neither of those is, so tracking
  /// the sheet alone left the tile credit and the zoom controls underneath
  /// them. Measured rather than assumed: the place card's height depends on
  /// how long the place's name is.
  double _bottomOverlay = 0;

  /// How far above the bottom edge the map credits have to sit to clear the
  /// place card, the only thing that parks down there now that the sheet is
  /// gone. Capped at half the screen so a tall card can't push the credit into
  /// the middle of the map.
  double _aboveSheet(BuildContext context) {
    final height = MediaQuery.of(context).size.height;
    return _bottomOverlay.clamp(0.0, height / 2);
  }

  void _setBottomOverlay(double height) {
    // Half a pixel of tolerance: a measurement that never quite settles would
    // setState on every frame forever.
    if (!mounted || (height - _bottomOverlay).abs() < 0.5) return;
    setState(() => _bottomOverlay = height);
  }

  LatLng? _me;
  GeoResult? _selected;
  bool _resolvingPin = false;
  bool _sendingCurrent = false;

  Timer? _locTimer;
  @override
  void initState() {
    super.initState();
    // Reopen where the user last left the map (GPS recenters on a fix).
    SharedPreferences.getInstance().then((prefs) {
      final raw = prefs.getString('map_last_view');
      if (raw == null || !mounted || _me != null || _mapTouched) return;
      final parts = raw.split(',');
      if (parts.length != 3) return;
      final lat = double.tryParse(parts[0]);
      final lng = double.tryParse(parts[1]);
      final zoom = double.tryParse(parts[2]);
      if (lat == null || lng == null || zoom == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _me == null && !_mapTouched) {
          _map.move(LatLng(lat, lng), zoom.clamp(2.0, 17.0));
        }
      });
    });
    _locate(recenter: true);
    // Keep the "you are here" dot fresh while the map is open.
    _locTimer = Timer.periodic(
        const Duration(seconds: 15), (_) => _locate(recenter: false));
  }

  @override
  void dispose() {
    // Remember the view for next time.
    try {
      final cam = _map.camera;
      final view = '${cam.center.latitude},${cam.center.longitude},'
          '${cam.zoom}';
      SharedPreferences.getInstance()
          .then((p) => p.setString('map_last_view', view));
    } catch (_) {}
    _locTimer?.cancel();
    super.dispose();
  }

  /// True once the user has panned/zoomed the map themselves, making the
  /// camera centre a meaningful "search here" point.
  bool _mapTouched = false;

  Future<void> _locate({required bool recenter}) async {
    LatLng? fix = widget.debugMyLocation;
    if (fix == null) {
      final pos = await getCurrentLatLng();
      if (pos != null) fix = LatLng(pos.lat, pos.lng);
    }
    if (!mounted || fix == null) return;
    final first = _me == null;
    final target = fix;
    // The periodic refresh only rebuilds when the dot actually moved —
    // pointless full-map rebuilds every 15 s make panning feel janky.
    if (!first &&
        !recenter &&
        const Distance().distance(_me!, target) < 3) {
      return;
    }
    setState(() => _me = target);
    if (recenter || first) {
      // Defer so the FlutterMap has rendered at least once (initState can
      // reach here synchronously via the debug hook).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _map.move(target, 14);
      });
    }
  }

  /// Selects a place — one you saved, or one you just dropped a pin on —
  /// and frames it under the card.
  void _select(GeoResult r) {
    FocusScope.of(context).unfocus();
    setState(() => _selected = r);
    _map.move(LatLng(r.lat, r.lng), 16);
  }

  Future<void> _dropPin(LatLng point) async {
    setState(() {
      _selected = GeoResult(name: '', lat: point.latitude, lng: point.longitude);
      _resolvingPin = true;
    });
    final place = await reverseGeocode(point.latitude, point.longitude);
    if (!mounted) return;
    setState(() {
      _resolvingPin = false;
      _selected = place ??
          GeoResult(
            name: '${point.latitude.toStringAsFixed(5)}, '
                '${point.longitude.toStringAsFixed(5)}',
            lat: point.latitude,
            lng: point.longitude,
          );
    });
  }

  /// Picking mode's primary action: send where you are right now. The full-bleed
  /// map has no locate button, and before a GPS fix lands there is nothing on
  /// screen to pick — so "share my location" needs its own button, or it can't
  /// be done at all. Reverse-geocoded so it arrives as a street, not two numbers.
  Future<void> _sendCurrentLocation() async {
    if (_sendingCurrent) return;
    setState(() => _sendingCurrent = true);
    var me = _me;
    if (me == null) {
      await _locate(recenter: true);
      me = _me;
    }
    if (!mounted) return;
    if (me == null) {
      setState(() => _sendingCurrent = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Turn on location access to share where you are.')));
      return;
    }
    final place = await reverseGeocode(me.latitude, me.longitude);
    if (!mounted) return;
    Navigator.of(context).pop(place ??
        GeoResult(name: 'My location', lat: me.latitude, lng: me.longitude));
  }

  void _sendToChat() {
    final s = _selected;
    if (s == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ForwardScreen(
          text: '',
          place: (
            lat: s.lat,
            lng: s.lng,
            label: s.name.isEmpty ? 'Shared location' : s.name,
          ),
        ),
      ),
    );
  }

  void _share() {
    final s = _selected;
    if (s == null) return;
    final isApple = Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.macOS;
    final uri =
        mapsUrl(lat: s.lat, lng: s.lng, label: s.name, apple: isApple);
    Clipboard.setData(ClipboardData(text: uri.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Place link copied to clipboard')),
    );
  }

  // Open to numberless accounts: browsing, searching and navigating are all
  // map tiles and local state, and place sharing rides the same anon-key
  // relay chat does. What quietly can't work without a session degrades to
  // a failed save rather than a locked door.
  @override
  Widget build(BuildContext context) => Builder(builder: _guarded);

  Widget _guarded(BuildContext context) {
    final selected = _selected;
    // Full-bleed, Apple-Maps-style: the map fills the screen and only the
    // back button and (when a pin is picked) the place card float over it.
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      extendBodyBehindAppBar: true,
      // The map must not squish (and reload tiles) every time the keyboard
      // opens — search UI floats over it instead, like Apple Maps.
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              minZoom: 2,
              maxZoom: 20.5,
              // Without a GPS fix, an honest world view beats pretending
              // everyone is in San Francisco; we fly to the fix on arrival.
              initialCenter: _me ?? const LatLng(20, 0),
              initialZoom: _me == null ? 2.2 : 13,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onPositionChanged: (camera, hasGesture) {
                if (!hasGesture) return;
                _mapTouched = true;
              },
              onTap: (_, __) => FocusScope.of(context).unfocus(),
              onLongPress: (_, point) => _dropPin(point),
            ),
            children: [
              const LiveTileLayer(),
              ListenableBuilder(
                listenable: SavedPlacesStore.instance,
                builder: (context, _) => MarkerLayer(
                  markers: [
                    // Saved places live on the idle map like Apple Maps
                    // favourites; hidden while a place card is open.
                    if (selected == null)
                      for (final p in SavedPlacesStore.instance.places)
                        Marker(
                          point: LatLng(p.lat, p.lng),
                          width: 30,
                          height: 30,
                          alignment: Alignment.topCenter,
                          child: GestureDetector(
                            onTap: () => _select(GeoResult(
                                name: p.name, lat: p.lat, lng: p.lng)),
                            child: const Icon(Icons.bookmark,
                                color: Color(0xFFEB4B3F),
                                size: 26,
                                shadows: [
                                  Shadow(blurRadius: 4, color: Colors.black45)
                                ]),
                          ),
                        ),
                    if (_me != null) myLocationMarker(_me!),
                    if (selected != null)
                      mapPin(LatLng(selected.lat, selected.lng)),
                  ],
                ),
              ),
              // Both of these ride above the sheet wherever it has been
              // dragged to. They used to be offset by the sheet's *minimum*
              // size, so at rest the tile credit sat underneath it — and a
              // credit nobody can see is one that isn't being given.
              Builder(
                builder: (context) {
                  final lift = _aboveSheet(context);
                  return Stack(
                    children: [
                      Scalebar(
                        alignment: Alignment.bottomLeft,
                        padding: EdgeInsets.fromLTRB(10, 0, 0, lift + 12),
                        textStyle: TextStyle(
                          color: dark ? Colors.white70 : Colors.black87,
                          fontSize: 12,
                        ),
                        lineColor: dark ? Colors.white70 : Colors.black87,
                      ),
                      Padding(
                        padding: EdgeInsets.only(bottom: lift + 4),
                        child: const LiveAttribution(),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
          // The floating control column (locate, saved, friends, style, zoom)
          // and the bottom sheet were removed for a clean, full-bleed map: a
          // long-press drops a pin, saved places show as markers, and the map
          // pinch-zooms. Only the back button floats over it.
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            child: _CircleButton(
              icon: Icons.arrow_back,
              tooltip: 'Back',
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ),
          if (selected != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 20,
              child: SafeArea(
                child: _MeasuredHeight(
                  // Plus the offset it is parked at, so the credit clears the
                  // card itself rather than the gap under it.
                  onHeight: (h) => _setBottomOverlay(h + 20),
                  child: _placeCard(context, selected),
                ),
              ),
            ),
          // Picking for a chat, nothing chosen yet: offer the current location
          // outright, since there is no other button to reach it.
          if (widget.picking && selected == null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 20,
              child: SafeArea(
                child: _MeasuredHeight(
                  onHeight: (h) => _setBottomOverlay(h + 20),
                  child: _pickingBar(context),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pickingBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: _sendingCurrent ? null : _sendCurrentLocation,
              icon: _sendingCurrent
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.my_location, size: 18),
              label: Text(_sendingCurrent
                  ? 'Finding you…'
                  : 'Send my current location'),
            ),
            const SizedBox(height: 8),
            Text(
              'Or long-press the map to drop a pin, or tap a saved place.',
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeCard(BuildContext context, GeoResult place) {
    final meta = <String>[];
    if (_me != null) {
      final d = const Distance()
          .distance(_me!, LatLng(place.lat, place.lng));
      meta.add('${formatDistance(d)} away');
    }
    if (place.category.isNotEmpty) meta.add(place.category);
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor:
                  Theme.of(context).colorScheme.primaryContainer,
              child: Icon(
                iconForPlaceCategory(place.category),
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _resolvingPin
                        ? 'Dropped pin…'
                        : (place.name.isEmpty ? 'Dropped pin' : place.name),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(meta.join(' · '),
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (widget.picking)
                        // The one action that makes sense when a chat is
                        // waiting for an answer: sending it somewhere ELSE
                        // while this chat waits is not an offer worth making.
                        FilledButton.icon(
                          onPressed: () => Navigator.of(context).pop(place),
                          icon: const Icon(Icons.send, size: 18),
                          label: const Text('Send this location'),
                        )
                      else
                        FilledButton.icon(
                          onPressed: _sendToChat,
                          icon: const Icon(Icons.chat_bubble_outline, size: 16),
                          label: const Text('Send'),
                        ),
                      OutlinedButton.icon(
                        onPressed: _share,
                        icon: const Icon(Icons.ios_share, size: 16),
                        label: const Text('Share'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              children: [
                ListenableBuilder(
                  listenable: SavedPlacesStore.instance,
                  builder: (context, _) {
                    final saved =
                        SavedPlacesStore.instance.isSaved(place.lat, place.lng);
                    return IconButton(
                      icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border,
                          color: saved ? const Color(0xFFEB4B3F) : null),
                      tooltip: saved ? 'Saved' : 'Save',
                      onPressed: () {
                        final now = SavedPlacesStore.instance.toggle(SavedPlace(
                            place.name.isEmpty ? 'Dropped pin' : place.name,
                            place.lat,
                            place.lng));
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(now ? 'Saved' : 'Removed'),
                          duration: const Duration(seconds: 1),
                        ));
                      },
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Clear',
                  onPressed: () => setState(() => _selected = null),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A floating circular surface button (back, etc.) matching the search pill.
class _CircleButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _CircleButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Matches the control cluster on the other side of the map: outlined and
    // slightly translucent, because a plain dark circle on a dark basemap is
    // nearly invisible.
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: dark ? 0.88 : 0.95),
        shape: BoxShape.circle,
        border: Border.all(
          color: (dark ? Colors.white : Colors.black)
              .withValues(alpha: dark ? 0.12 : 0.06),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.4 : 0.15),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: IconButton(
        icon: Icon(icon, size: 21),
        tooltip: tooltip,
        color: scheme.onSurface,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        padding: EdgeInsets.zero,
        onPressed: onTap,
      ),
    );
  }
}

/// Reports its own laid-out height to [onHeight].
///
/// The map's tile credit and zoom controls have to sit above whatever is
/// parked along the bottom edge, and what is parked there changes: a search
/// sheet, a results list, or a place card whose height depends on how long
/// the place's name turns out to be. Guessing a number for each one is how
/// the credit ended up underneath them.
class _MeasuredHeight extends StatefulWidget {
  final Widget child;
  final ValueChanged<double> onHeight;

  const _MeasuredHeight({required this.child, required this.onHeight});

  @override
  State<_MeasuredHeight> createState() => _MeasuredHeightState();
}

class _MeasuredHeightState extends State<_MeasuredHeight> {
  final GlobalKey _key = GlobalKey();
  double _last = -1;

  void _report(_) {
    final box = _key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final height = box.size.height;
    if ((height - _last).abs() < 0.5) return;
    _last = height;
    widget.onHeight(height);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback(_report);
    return KeyedSubtree(key: _key, child: widget.child);
  }

  @override
  void dispose() {
    // Gone from the screen: nothing to clear any more.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onHeight(0));
    super.dispose();
  }
}
