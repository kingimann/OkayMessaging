import 'dart:async';
import '../widgets/phone_gate.dart';
import '../theme/app_theme.dart';

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
import 'map_screen.dart';

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
  final DraggableScrollableController _sheet = DraggableScrollableController();

  /// The sheet collapsed to its search field and nothing else, as a fraction
  /// of the screen.
  ///
  /// The sheet used to rest at a flat 0.30 whatever was in it. With no saved
  /// places and no recent searches — every new account — that is a third of
  /// the screen given to an empty slab, and the map, which is the point of
  /// the screen, gets the rest. Measured rather than guessed so it stays
  /// right on any screen height.
  static double compactSheetFraction(BuildContext context) {
    final media = MediaQuery.of(context);
    // 8 top padding + 4 handle + 10 gap + ~52 search field + 12 breathing room.
    const contentPx = 86.0;
    return ((contentPx + media.padding.bottom) / media.size.height)
        .clamp(0.08, 0.34);
  }

  /// Where the sheet rests: at the search field when there is nothing behind
  /// it, tall enough to show favourites and recents when there is. Collapsing
  /// a sheet that has content in it would only hide it behind a drag.
  static double restingSheetFraction(BuildContext context,
          {required bool hasContent}) =>
      hasContent ? 0.34 : compactSheetFraction(context);

  double _resting = 0.34;

  /// The height of whatever is currently parked along the bottom edge that
  /// isn't the search sheet — the place card, or the results list.
  ///
  /// The search sheet is only mounted when neither of those is, so tracking
  /// the sheet alone left the tile credit and the zoom controls underneath
  /// them. Measured rather than assumed: the place card's height depends on
  /// how long the place's name is.
  double _bottomOverlay = 0;

  /// How far above the bottom edge the map credits have to sit to clear
  /// whatever is down there. Capped: at full height the credits would ride
  /// into the middle of the map rather than stay out of the way.
  double _aboveSheet(BuildContext context) {
    final height = MediaQuery.of(context).size.height;
    final size = _sheet.isAttached ? _sheet.size : _resting;
    final sheet = height * size.clamp(0.0, 0.5);
    return (_bottomOverlay > 0 ? _bottomOverlay : sheet).clamp(0.0, height / 2);
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
    _sheet.dispose();
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

  Future<void> _goToMe() async {
    LatLng? fix = widget.debugMyLocation;
    if (fix == null) {
      final pos = await getCurrentLatLng();
      if (pos != null) fix = LatLng(pos.lat, pos.lng);
    }
    if (!mounted) return;
    if (fix == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 5),
          content: Text(
            'Couldn\'t get your location. Allow location access for this '
            'site in your browser settings, then try again.',
          ),
        ),
      );
      return;
    }
    setState(() => _me = fix);
    _map.move(fix, 15);
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

  void _showSaved() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListenableBuilder(
          listenable: SavedPlacesStore.instance,
          builder: (context, _) {
            final places = SavedPlacesStore.instance.places;
            if (places.isEmpty) {
              // The save control on the place card is a bookmark, so the
              // hint says bookmark — this used to say "star", pointing at a
              // control that doesn't exist.
              return const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 28),
                child: Text('No saved places yet. Tap the bookmark on a '
                    'place to save it here.'),
              );
            }
            // Scrollable and capped: enough saved places used to overflow
            // the sheet instead of scrolling inside it.
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.6,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in places)
                    ListTile(
                      leading: const Icon(Icons.bookmark,
                          color: Color(0xFFEB4B3F)),
                      title: Text(p.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      // Where it is relative to me — a list of bare names
                      // makes picking between two "Tim's" a coin flip.
                      subtitle: _me == null
                          ? null
                          : Text(
                              '${formatDistance(const Distance().distance(_me!, LatLng(p.lat, p.lng)))} away',
                              style: const TextStyle(fontSize: 12.5)),
                      trailing: IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Remove',
                        onPressed: () => SavedPlacesStore.instance.remove(p),
                      ),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        _select(
                            GeoResult(name: p.name, lat: p.lat, lng: p.lng));
                      },
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PhoneGate(
        title: 'Maps',
        reason: 'Saving a place and sharing one both put it on the server '
            'under your account, and an account with no phone number has no '
            'session to put anything there with.',
        child: Builder(builder: _guarded),
      );

  Widget _guarded(BuildContext context) {
    final selected = _selected;
    // Full-bleed, Apple-Maps-style: the map fills the screen and every
    // control floats over it.
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Saved places only: recent searches went with the search bar, since a
    // remembered query cannot be re-run without one.
    final hasSheetContent = SavedPlacesStore.instance.places.isNotEmpty;
    final compact = compactSheetFraction(context);
    final resting = restingSheetFraction(context, hasContent: hasSheetContent);
    _resting = resting;
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
              AnimatedBuilder(
                animation: _sheet,
                builder: (context, _) {
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
          // Anchored to the sheet rather than the status bar. Up by the top
          // edge they were a stretch on a big phone — six controls parked
          // where a thumb has to leave the phone to reach them — and they
          // covered the part of the map someone is usually looking at.
          AnimatedBuilder(
            animation: _sheet,
            builder: (context, _) => MapControls(
              controller: _map,
              bottom: _aboveSheet(context) + 16,
              onMyLocation:
                  selected == null ? _goToMe : null,
              onSaved: _showSaved,
              onFriends: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const MapScreen())),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            child: _CircleButton(
              icon: Icons.arrow_back,
              tooltip: 'Back',
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ),
          // Apple Maps' signature: a draggable bottom sheet over the
          // full-bleed map. It holds saved places now that the search box
          // that used to head it is gone.
          if (selected == null)
            Positioned.fill(
              child: AnimatedPadding(
                duration: const Duration(milliseconds: 150),
                padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).viewInsets.bottom),
                child: DraggableScrollableSheet(
                  controller: _sheet,
                  // Rests at the height of the search field — the map is the
                  // point of the screen. The middle stop only exists when
                  // there are favourites or recents to stop at; without it,
                  // dragging landed on a screenful of nothing.
                  initialChildSize: resting,
                  minChildSize: compact,
                  maxChildSize: 0.88,
                  snap: true,
                  snapSizes: [compact, if (hasSheetContent) resting, 0.88],
                  builder: (context, scroll) => Material(
                    color: Theme.of(context).colorScheme.surface,
                    elevation: 12,
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(20)),
                    clipBehavior: Clip.antiAlias,
                    child: ListView(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      children: [
                        Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: 10),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade400,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        // Arriving from a chat, the map looks like every
                        // other map — so say what it wants. The old picker
                        // had a permanent centre pin and needed no
                        // instruction; this one is worth the sentence.
                        if (widget.picking && _selected == null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(6, 14, 6, 4),
                            child: Row(
                              children: [
                                Icon(Icons.touch_app_outlined,
                                    size: 18,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Press and hold the map to drop a pin, '
                                    'or pick one you have saved.',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        _FavoritesRow(
                          onPick: (p) => _select(GeoResult(
                              name: p.name, lat: p.lat, lng: p.lng)),
                        ),
                        // Renders nothing at all until something is saved, so
                        // a pulled-up sheet was a blank screen that looked
                        // broken rather than new.
                        if (!hasSheetContent)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(6, 18, 6, 8),
                            child: Text(
                              'Press and hold the map to drop a pin. Places '
                              'you save show up here.',
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.4,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
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
        ],
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

/// Apple-Maps-style Favourites: saved places as a row of tappable circles
/// at the top of the search sheet. Hidden until something is saved.
class _FavoritesRow extends StatelessWidget {
  final ValueChanged<SavedPlace> onPick;
  const _FavoritesRow({required this.onPick});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SavedPlacesStore.instance,
      builder: (context, _) {
        final places = SavedPlacesStore.instance.places;
        if (places.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text('Favourites',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.subtle(context))),
              ),
              SizedBox(
                height: 82,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: places.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 14),
                  itemBuilder: (context, i) {
                    final p = places[i];
                    return InkWell(
                      onTap: () => onPick(p),
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        width: 62,
                        child: Column(
                          children: [
                            CircleAvatar(
                              radius: 24,
                              backgroundColor: const Color(0xFFEB4B3F)
                                  .withValues(alpha: 0.14),
                              child: const Icon(Icons.bookmark,
                                  color: Color(0xFFEB4B3F), size: 22),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              p.name.split(',').first.trim(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11.5),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
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
