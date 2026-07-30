import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../widgets/osm_map.dart';
import 'route_map_screen.dart';

/// A full-screen, interactive OpenStreetMap view of a shared location, with a
/// button to hand off to the device's maps app (Apple Maps / Google Maps).
class LocationMapScreen extends StatefulWidget {
  final double lat;
  final double lng;
  final String label;

  const LocationMapScreen({
    super.key,
    required this.lat,
    required this.lng,
    this.label = '',
  });

  @override
  State<LocationMapScreen> createState() => _LocationMapScreenState();
}

class _LocationMapScreenState extends State<LocationMapScreen> {
  final MapController _map = MapController();

  double get lat => widget.lat;
  double get lng => widget.lng;
  String get label => widget.label;


  @override
  Widget build(BuildContext context) {
    final point = LatLng(lat, lng);
    return Scaffold(
      appBar: AppBar(title: Text(label.isEmpty ? 'Location' : label)),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              minZoom: 2,
              maxZoom: 20.5,
              initialCenter: point,
              initialZoom: 15,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              const LiveTileLayer(),
              MarkerLayer(markers: [mapPin(point)]),
              const LiveAttribution(),
            ],
          ),
          MapControls(controller: _map, bottom: 96),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => RouteMapScreen(
                            dest: LatLng(lat, lng),
                            label: label.isEmpty ? 'Directions' : label,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.directions_outlined),
                      label: const Text('Directions'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
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
