import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../util/geocoding.dart';
import '../util/geolocation.dart';
import '../widgets/osm_map.dart';

/// Lets the user pick a point on an OpenStreetMap to share. The map pans under
/// a fixed centre pin; "Send this location" returns the centre coordinate.
class LocationPickerScreen extends StatefulWidget {
  /// Where the map starts centred (defaults to a neutral world view).
  final LatLng initialCenter;

  const LocationPickerScreen({
    super.key,
    this.initialCenter = const LatLng(37.7749, -122.4194),
  });

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final MapController _map = MapController();
  final TextEditingController _search = TextEditingController();
  late LatLng _center = widget.initialCenter;
  bool _locating = false;
  bool _searching = false;
  List<GeoResult> _results = const [];

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

  void _pickResult(GeoResult r) {
    final here = LatLng(r.lat, r.lng);
    _map.move(here, 16);
    setState(() {
      _center = here;
      _results = const [];
      _search.text = r.name;
    });
    FocusScope.of(context).unfocus();
  }

  Future<void> _useMyLocation() async {
    setState(() => _locating = true);
    final pos = await getCurrentLatLng();
    if (!mounted) return;
    setState(() => _locating = false);
    if (pos == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Couldn\'t get your location — pick it on the map.'),
        ),
      );
      return;
    }
    final here = LatLng(pos.lat, pos.lng);
    _map.move(here, 16);
    setState(() => _center = here);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Choose location')),
      body: Stack(
        alignment: Alignment.center,
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: widget.initialCenter,
              initialZoom: 14,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onPositionChanged: (camera, _) =>
                  setState(() => _center = camera.center),
            ),
            children: const [
              LiveTileLayer(),
              LiveAttribution(),
            ],
          ),
          MapControls(controller: _map, bottom: 160),
          // A fixed centre pin: its tip marks the spot the map is centred on.
          const Padding(
            padding: EdgeInsets.only(bottom: 40),
            child: Icon(Icons.location_pin, size: 44, color: Color(0xFFEB4B3F)),
          ),
          // Search a place by name (OpenStreetMap / Photon geocoder).
          Positioned(
            top: 10,
            left: 12,
            right: 12,
            child: _SearchBox(
              controller: _search,
              searching: _searching,
              results: _results,
              onSubmit: _runSearch,
              onPick: _pickResult,
            ),
          ),
          Positioned(
            right: 16,
            bottom: 96,
            child: FloatingActionButton.small(
              heroTag: 'useMyLocation',
              onPressed: _locating ? null : _useMyLocation,
              tooltip: 'Use my location',
              child: _locating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${_center.latitude.toStringAsFixed(5)}, '
                      '${_center.longitude.toStringAsFixed(5)}',
                      style: const TextStyle(
                          fontSize: 12.5, color: Colors.black87),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(_center),
                    icon: const Icon(Icons.send),
                    label: const Text('Send this location'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
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
              hintText: 'Search a place or address',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.arrow_forward),
                      onPressed: onSubmit,
                    ),
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
            constraints: const BoxConstraints(maxHeight: 260),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 8,
                ),
              ],
            ),
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
      ],
    );
  }
}
