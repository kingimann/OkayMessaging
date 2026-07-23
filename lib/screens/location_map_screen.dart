import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/maps_link.dart';
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

  Future<void> _openExternally(BuildContext context) async {
    final isApple = Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.macOS;
    final uri = mapsUrl(lat: lat, lng: lng, label: label, apple: isApple);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      /* ignore — the in-app map is still shown */
    }
  }

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
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () => _openExternally(context),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Maps app'),
                    style: OutlinedButton.styleFrom(
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
