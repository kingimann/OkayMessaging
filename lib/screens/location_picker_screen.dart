import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

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
  late LatLng _center = widget.initialCenter;
  bool _locating = false;

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
            children: [
              osmTileLayer(),
              const OsmAttribution(),
            ],
          ),
          // A fixed centre pin: its tip marks the spot the map is centred on.
          const Padding(
            padding: EdgeInsets.only(bottom: 40),
            child: Icon(Icons.location_pin, size: 44, color: Color(0xFFEB4B3F)),
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
