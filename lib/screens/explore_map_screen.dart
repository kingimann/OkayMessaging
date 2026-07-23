import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../state/saved_places_store.dart';
import '../util/geocoding.dart';
import '../util/geolocation.dart';
import '../utils/maps_link.dart';
import '../widgets/osm_map.dart';
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
  const ExploreMapScreen({super.key});

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

  @override
  void initState() {
    super.initState();
    _locate();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    final pos = await getCurrentLatLng();
    if (!mounted || pos == null) return;
    setState(() => _me = LatLng(pos.lat, pos.lng));
    _map.move(_me!, 14);
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
    FocusScope.of(context).unfocus();
    setState(() => _searching = true);
    final c = _center;
    final results =
        await searchPlaces(q, lat: c.latitude, lng: c.longitude, limit: 12);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _results = results;
      _selected = results.length == 1 ? results.first : null;
    });
    if (results.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nothing found for "$q" nearby.')),
      );
    } else {
      _map.move(LatLng(results.first.lat, results.first.lng), 14);
    }
  }

  void _select(GeoResult r) {
    FocusScope.of(context).unfocus();
    setState(() {
      _selected = r;
      _search.text = r.name;
      _results = const [];
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
    final pos = await getCurrentLatLng();
    if (!mounted) return;
    if (pos == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn\'t get your location.')),
      );
      return;
    }
    setState(() => _me = LatLng(pos.lat, pos.lng));
    _map.move(_me!, 15);
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
              results: _results,
              onSubmit: () => _runSearch(),
              onPick: _select,
            ),
          ),
          if (_results.isEmpty && selected == null)
            Positioned(
              top: 70,
              left: 0,
              right: 0,
              child: _CategoryChips(onTap: (term) => _runSearch(term)),
            ),
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
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: _directions,
                        icon: const Icon(Icons.directions, size: 18),
                        label: const Text('Directions'),
                      ),
                      const SizedBox(width: 8),
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
  final VoidCallback onSubmit;
  final ValueChanged<GeoResult> onPick;

  const _SearchBox({
    required this.controller,
    required this.searching,
    required this.results,
    required this.onSubmit,
    required this.onPick,
  });

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
                  : IconButton(
                      icon: const Icon(Icons.arrow_forward),
                      onPressed: onSubmit),
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
        if (results.length > 1)
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
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.place_outlined),
                    title: Text(r.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: r.category.isEmpty ? null : Text(r.category),
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
