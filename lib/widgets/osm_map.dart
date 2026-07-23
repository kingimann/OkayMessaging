import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Identifies the app to the OpenStreetMap tile servers (required by their
/// usage policy).
const String kOsmUserAgent = 'com.okay.messaging';

/// The OpenStreetMap raster tile layer used across the app. Free to use with
/// attribution — see [OsmAttribution].
TileLayer osmTileLayer() => TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: kOsmUserAgent,
      maxZoom: 19,
    );

/// A red map pin marker sitting on [point], with its tip at the coordinate.
Marker mapPin(LatLng point, {Color color = const Color(0xFFEB4B3F)}) => Marker(
      point: point,
      width: 40,
      height: 40,
      alignment: Alignment.topCenter,
      child: Icon(Icons.location_pin, color: color, size: 40),
    );

/// The "© OpenStreetMap contributors" credit OSM's tile policy requires.
class OsmAttribution extends StatelessWidget {
  const OsmAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomRight,
      child: Container(
        margin: const EdgeInsets.all(6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text(
          '© OpenStreetMap',
          style: TextStyle(fontSize: 10, color: Colors.black87),
        ),
      ),
    );
  }
}

/// A small, non-interactive OpenStreetMap preview centred on ([lat], [lng])
/// with a pin — used inside a shared-location chat bubble.
class MiniMapPreview extends StatelessWidget {
  final double lat;
  final double lng;
  final double width;
  final double height;

  const MiniMapPreview({
    super.key,
    required this.lat,
    required this.lng,
    this.width = 220,
    this.height = 120,
  });

  @override
  Widget build(BuildContext context) {
    final point = LatLng(lat, lng);
    return SizedBox(
      width: width,
      height: height,
      child: AbsorbPointer(
        // The preview is a static image; taps are handled by the bubble.
        child: FlutterMap(
          options: MapOptions(
            initialCenter: point,
            initialZoom: 15,
            interactionOptions:
                const InteractionOptions(flags: InteractiveFlag.none),
          ),
          children: [
            osmTileLayer(),
            MarkerLayer(markers: [mapPin(point)]),
          ],
        ),
      ),
    );
  }
}
