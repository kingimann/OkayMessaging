import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../state/recent_searches.dart';
import '../state/saved_places_store.dart';
import '../util/geocoding.dart';
import '../util/geolocation.dart';
import '../utils/maps_link.dart';
import '../widgets/osm_map.dart';
import 'forward_screen.dart';
import 'map_screen.dart';
import 'route_map_screen.dart';

/// Quick "search nearby" categories, à la Apple Maps.
const List<(IconData, String, String)> _categories = [
  (Icons.restaurant, 'Food', 'restaurant'),
  (Icons.local_cafe, 'Coffee', 'cafe'),
  (Icons.local_bar, 'Bars', 'bar'),
  (Icons.local_gas_station, 'Fuel', 'fuel'),
  (Icons.hotel, 'Hotels', 'hotel'),
  (Icons.shopping_cart, 'Shops', 'supermarket'),
  (Icons.local_atm, 'ATMs', 'atm'),
  (Icons.local_parking, 'Parking', 'parking'),
];

/// A standalone, Apple-Maps-style map: search places or nearby categories, see
/// them on the map, read details with distance, save favourites, and get
/// in-app directions — no external maps needed.
class ExploreMapScreen extends StatefulWidget {
  /// Test/preview hook: a fixed "current location" fix, bypassing real GPS.
  final LatLng? debugMyLocation;

  /// Test hook: replaces the network place search.
  final Future<List<GeoResult>> Function(String query)? debugSearch;

  const ExploreMapScreen({super.key, this.debugMyLocation, this.debugSearch});

  @override
  State<ExploreMapScreen> createState() => _ExploreMapScreenState();
}

class _ExploreMapScreenState extends State<ExploreMapScreen> {
  final MapController _map = MapController();
  final TextEditingController _search = TextEditingController();
  bool _searching = false;
  List<GeoResult> _results = const [];

  LatLng? _me;
  GeoResult? _selected;
  bool _resolvingPin = false;

  Timer? _locTimer;
  Timer? _debounce;
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    _locate(recenter: true);
    // Keep the "you are here" dot fresh while the map is open.
    _locTimer = Timer.periodic(
        const Duration(seconds: 15), (_) => _locate(recenter: false));
  }

  @override
  void dispose() {
    _locTimer?.cancel();
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<List<GeoResult>> _doSearch(String q) {
    final debug = widget.debugSearch;
    if (debug != null) return debug(q);
    final c = _center;
    return searchPlaces(q, lat: c.latitude, lng: c.longitude, limit: 12);
  }

  /// Live, Apple-Maps-style suggestions while typing (debounced; stale
  /// responses are discarded).
  void _onQueryChanged(String text) {
    _debounce?.cancel();
    final q = text.trim();
    if (q.isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() {}); // refresh the clear button on the first keystroke
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      if (!mounted) return;
      final seq = ++_searchSeq;
      setState(() => _searching = true);
      final results = await _doSearch(q);
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _searching = false;
        _results = results;
      });
    });
  }

  Future<void> _locate({required bool recenter}) async {
    LatLng? fix = widget.debugMyLocation;
    if (fix == null) {
      final pos = await getCurrentLatLng();
      if (pos != null) fix = LatLng(pos.lat, pos.lng);
    }
    if (!mounted || fix == null) return;
    final first = _me == null;
    final target = fix;
    setState(() => _me = target);
    if (recenter || first) {
      // Defer so the FlutterMap has rendered at least once (initState can
      // reach here synchronously via the debug hook).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _map.move(target, 14);
      });
    }
  }

  LatLng get _center {
    try {
      return _map.camera.center;
    } catch (_) {
      return _me ?? const LatLng(37.7749, -122.4194);
    }
  }

  Future<void> _runSearch([String? term]) async {
    final q = (term ?? _search.text).trim();
    if (q.isEmpty) return;
    _debounce?.cancel();
    FocusScope.of(context).unfocus();
    final seq = ++_searchSeq;
    setState(() => _searching = true);
    final results = await _doSearch(q);
    if (!mounted || seq != _searchSeq) return;
    // Remember typed queries that found something (not the category chips).
    if (term == null && results.isNotEmpty) RecentSearches.maps.add(q);
    setState(() {
      _searching = false;
      _results = results;
      _selected = results.length == 1 ? results.first : null;
    });
    if (results.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nothing found for "$q" nearby.')),
      );
    } else if (results.length == 1) {
      _map.move(LatLng(results.first.lat, results.first.lng), 15);
    } else {
      // Frame every result pin at once, Apple-Maps style.
      _map.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(
              [for (final r in results) LatLng(r.lat, r.lng)]),
          padding: const EdgeInsets.fromLTRB(50, 140, 50, 120),
        ),
      );
    }
  }

  void _select(GeoResult r) {
    FocusScope.of(context).unfocus();
    _debounce?.cancel();
    ++_searchSeq; // discard any in-flight suggestion fetch
    // Picking a suggestion is the common path now — remember it.
    RecentSearches.maps.add(r.name.split(',').first.trim());
    setState(() {
      _selected = r;
      _search.text = r.name;
      _results = const [];
      _searching = false;
    });
    _map.move(LatLng(r.lat, r.lng), 16);
  }

  Future<void> _dropPin(LatLng point) async {
    setState(() {
      _selected = GeoResult(name: '', lat: point.latitude, lng: point.longitude);
      _resolvingPin = true;
      _results = const [];
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

  void _directions() {
    final s = _selected;
    if (s == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RouteMapScreen(
          dest: LatLng(s.lat, s.lng),
          from: _me,
          label: s.name.isEmpty ? 'Directions' : s.name,
        ),
      ),
    );
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
              return const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 28),
                child: Text('No saved places yet. Tap the star on a place to '
                    'save it here.'),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final p in places)
                  ListTile(
                    leading: const Icon(Icons.bookmark, color: Color(0xFFEB4B3F)),
                    title: Text(p.name, maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => SavedPlacesStore.instance.remove(p),
                    ),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _select(GeoResult(name: p.name, lat: p.lat, lng: p.lng));
                    },
                  ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Maps'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmark_border),
            tooltip: 'Saved places',
            onPressed: _showSaved,
          ),
          IconButton(
            icon: const Icon(Icons.group_outlined),
            tooltip: 'Friends',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MapScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.small(
        heroTag: 'exploreMe',
        onPressed: _goToMe,
        tooltip: 'My location',
        child: const Icon(Icons.my_location),
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _me ?? const LatLng(37.7749, -122.4194),
              initialZoom: 13,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onLongPress: (_, point) => _dropPin(point),
            ),
            children: [
              const LiveTileLayer(),
              MarkerLayer(
                markers: [
                  if (_me != null) myLocationMarker(_me!),
                  for (final r in _results)
                    Marker(
                      point: LatLng(r.lat, r.lng),
                      width: 30,
                      height: 30,
                      child: GestureDetector(
                        onTap: () => _select(r),
                        child: const Icon(Icons.place,
                            color: Color(0xFF0A84FF), size: 30),
                      ),
                    ),
                  if (selected != null)
                    mapPin(LatLng(selected.lat, selected.lng)),
                ],
              ),
              const Scalebar(
                alignment: Alignment.bottomLeft,
                padding: EdgeInsets.fromLTRB(10, 0, 0, 14),
              ),
              const LiveAttribution(),
            ],
          ),
          MapControls(controller: _map, bottom: selected == null ? 96 : 220),
          Positioned(
            top: 10,
            left: 12,
            right: 12,
            child: _SearchBox(
              controller: _search,
              searching: _searching,
              // Hide the suggestion list once a place is selected (its card
              // is showing); the pins for other results stay on the map.
              results: selected == null ? _results : const <GeoResult>[],
              origin: _me,
              onSubmit: () => _runSearch(),
              onPick: _select,
              onChanged: _onQueryChanged,
              onClear: () {
                _debounce?.cancel();
                ++_searchSeq;
                _search.clear();
                setState(() {
                  _results = const [];
                  _selected = null;
                  _searching = false;
                });
              },
            ),
          ),
          if (_results.isEmpty && selected == null) ...[
            Positioned(
              top: 70,
              left: 0,
              right: 0,
              child: _CategoryChips(onTap: (term) => _runSearch(term)),
            ),
            Positioned(
              top: 120,
              left: 12,
              right: 12,
              child: _RecentMapSearches(onPick: (q) {
                _search.text = q;
                _runSearch();
              }),
            ),
          ],
          if (selected != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 20,
              child: SafeArea(child: _placeCard(context, selected)),
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
                        style: TextStyle(color: Colors.grey.shade600)),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _directions,
                        icon: const Icon(Icons.directions, size: 18),
                        label: const Text('Directions'),
                      ),
                      OutlinedButton.icon(
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

/// The user's recent map searches, shown while the map is idle.
class _RecentMapSearches extends StatelessWidget {
  final ValueChanged<String> onPick;
  const _RecentMapSearches({required this.onPick});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: RecentSearches.maps,
      builder: (context, _) {
        final queries = RecentSearches.maps.queries.take(5).toList();
        if (queries.isEmpty) return const SizedBox.shrink();
        return Material(
          elevation: 2,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          color: Theme.of(context)
              .colorScheme
              .surface
              .withValues(alpha: 0.95),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final q in queries)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.history, size: 20),
                  title: Text(q,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => RecentSearches.maps.remove(q),
                  ),
                  onTap: () => onPick(q),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A horizontal row of "search nearby" category chips.
class _CategoryChips extends StatelessWidget {
  final ValueChanged<String> onTap;
  const _CategoryChips({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (icon, label, term) = _categories[i];
          return ActionChip(
            avatar: Icon(icon, size: 18),
            label: Text(label),
            elevation: 2,
            backgroundColor: Theme.of(context).colorScheme.surface,
            shadowColor: Colors.black45,
            onPressed: () => onTap(term),
          );
        },
      ),
    );
  }
}

/// A rounded search field with a dropdown of geocoded place results.
class _SearchBox extends StatelessWidget {
  final TextEditingController controller;
  final bool searching;
  final List<GeoResult> results;
  final LatLng? origin;
  final VoidCallback onSubmit;
  final ValueChanged<GeoResult> onPick;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;

  const _SearchBox({
    required this.controller,
    required this.searching,
    required this.results,
    required this.onSubmit,
    required this.onPick,
    this.origin,
    this.onChanged,
    this.onClear,
  });

  /// "Cafe · 350 m" style meta line for a result row.
  String? _meta(GeoResult r) {
    final parts = <String>[];
    if (r.category.isNotEmpty) parts.add(r.category);
    final o = origin;
    if (o != null) {
      parts.add(formatDistance(
          const Distance().distance(o, LatLng(r.lat, r.lng))));
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          elevation: 3,
          borderRadius: BorderRadius.circular(28),
          child: TextField(
            controller: controller,
            textInputAction: TextInputAction.search,
            onChanged: onChanged,
            onSubmitted: (_) => onSubmit(),
            decoration: InputDecoration(
              hintText: 'Search Maps',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : controller.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Clear search',
                          onPressed: onClear,
                        )
                      : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surface,
              contentPadding: const EdgeInsets.symmetric(vertical: 4),
            ),
          ),
        ),
        if (results.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 6),
            constraints: const BoxConstraints(maxHeight: 300),
            child: Material(
              elevation: 3,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: results.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final r = results[i];
                  final meta = _meta(r);
                  return ListTile(
                    dense: true,
                    leading: Icon(iconForPlaceCategory(r.category)),
                    title: Text(r.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: meta == null ? null : Text(meta),
                    onTap: () => onPick(r),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}
