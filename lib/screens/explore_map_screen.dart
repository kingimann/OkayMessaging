import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../util/geocoding.dart';
import '../util/geolocation.dart';
import '../utils/maps_link.dart';
import '../widgets/osm_map.dart';
import 'map_screen.dart';
import 'route_map_screen.dart';

/// A standalone, Apple-Maps-style map: search any place, see it on the map,
/// read its details, and get in-app directions — no external maps needed.
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

  // The currently selected place (from search, a tap, or a long-press).
  LatLng? _pin;
  String _pinName = '';
  bool _resolvingPin = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final q = _search.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    final results = await searchPlaces(q);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _results = results;
    });
    if (results.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No places found for "$q".')),
      );
    }
  }

  void _selectResult(GeoResult r) {
    FocusScope.of(context).unfocus();
    setState(() {
      _results = const [];
      _search.text = r.name;
      _pin = LatLng(r.lat, r.lng);
      _pinName = r.name;
    });
    _map.move(_pin!, 15);
  }

  Future<void> _dropPin(LatLng point) async {
    setState(() {
      _pin = point;
      _pinName = '';
      _resolvingPin = true;
    });
    final place = await reverseGeocode(point.latitude, point.longitude);
    if (!mounted) return;
    setState(() {
      _resolvingPin = false;
      _pinName = place?.name ??
          '${point.latitude.toStringAsFixed(5)}, '
              '${point.longitude.toStringAsFixed(5)}';
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
    _map.move(LatLng(pos.lat, pos.lng), 15);
  }

  void _directions() {
    if (_pin == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RouteMapScreen(
          dest: _pin!,
          label: _pinName.isEmpty ? 'Directions' : _pinName,
        ),
      ),
    );
  }

  void _sharePlace() {
    if (_pin == null) return;
    final isApple = Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.macOS;
    final uri = mapsUrl(
        lat: _pin!.latitude,
        lng: _pin!.longitude,
        label: _pinName,
        apple: isApple);
    Clipboard.setData(ClipboardData(text: uri.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Place link copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Maps'),
        actions: [
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
              initialCenter: const LatLng(37.7749, -122.4194),
              initialZoom: 12,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onLongPress: (_, point) => _dropPin(point),
            ),
            children: [
              const LiveTileLayer(),
              if (_pin != null) MarkerLayer(markers: [mapPin(_pin!)]),
              const LiveAttribution(),
            ],
          ),
          MapControls(controller: _map, bottom: _pin == null ? 96 : 220),
          Positioned(
            top: 10,
            left: 12,
            right: 12,
            child: _SearchBox(
              controller: _search,
              searching: _searching,
              results: _results,
              onSubmit: _runSearch,
              onPick: _selectResult,
            ),
          ),
          if (_pin != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 20,
              child: SafeArea(child: _placeCard(context)),
            ),
        ],
      ),
    );
  }

  Widget _placeCard(BuildContext context) {
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _resolvingPin
                        ? 'Dropped pin…'
                        : (_pinName.isEmpty ? 'Dropped pin' : _pinName),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: _directions,
                        icon: const Icon(Icons.directions, size: 18),
                        label: const Text('Directions'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _sharePlace,
                        icon: const Icon(Icons.ios_share, size: 16),
                        label: const Text('Share'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Clear',
              onPressed: () => setState(() {
                _pin = null;
                _pinName = '';
              }),
            ),
          ],
        ),
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
                  return ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(r.name,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
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
