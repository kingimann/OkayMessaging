import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../app_state.dart';

/// Identifies the app to the OpenStreetMap tile servers (required by their
/// usage policy).
const String kOsmUserAgent = 'com.okay.messaging';

/// The selectable base map styles. All use free, CORS-enabled tile servers.
enum MapLayer {
  standard('Standard', Icons.map_outlined),
  dark('Dark', Icons.dark_mode_outlined),
  satellite('Satellite', Icons.satellite_alt_outlined),
  terrain('Terrain', Icons.terrain_outlined);

  const MapLayer(this.label, this.icon);
  final String label;
  final IconData icon;

  static MapLayer fromName(String? name) =>
      values.firstWhere((l) => l.name == name, orElse: () => MapLayer.standard);
}

/// The raster tile layer for a given [layer].
///
/// Standard and Dark use CARTO's basemaps (rendered from up-to-date
/// OpenStreetMap data): a clean, modern cartographic style served as crisp
/// @2x retina tiles — a big visual upgrade over the classic OSM tiles.
TileLayer tileLayerFor(MapLayer layer) {
  switch (layer) {
    case MapLayer.satellite:
      return TileLayer(
        urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/'
            'World_Imagery/MapServer/tile/{z}/{y}/{x}',
        userAgentPackageName: kOsmUserAgent,
        maxZoom: 19,
      );
    case MapLayer.terrain:
      return TileLayer(
        urlTemplate: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
        subdomains: const ['a', 'b', 'c'],
        userAgentPackageName: kOsmUserAgent,
        maxZoom: 17,
      );
    case MapLayer.dark:
      return TileLayer(
        urlTemplate:
            'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
        subdomains: const ['a', 'b', 'c', 'd'],
        userAgentPackageName: kOsmUserAgent,
        retinaMode: true,
        maxZoom: 20,
      );
    case MapLayer.standard:
      return TileLayer(
        urlTemplate: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/'
            '{z}/{x}/{y}{r}.png',
        subdomains: const ['a', 'b', 'c', 'd'],
        userAgentPackageName: kOsmUserAgent,
        retinaMode: true,
        maxZoom: 20,
      );
  }
}

/// The credit line a given [layer]'s tiles require.
String attributionFor(MapLayer layer) => switch (layer) {
      MapLayer.satellite => '© Esri, Maxar',
      MapLayer.terrain => '© OpenTopoMap (CC-BY-SA)',
      MapLayer.dark => '© OpenStreetMap · © CARTO',
      MapLayer.standard => '© OpenStreetMap · © CARTO',
    };

/// The OpenStreetMap raster tile layer used across the app. Free to use with
/// attribution — see [OsmAttribution].
TileLayer osmTileLayer() => tileLayerFor(MapLayer.standard);

/// An icon for a search result's category — businesses get a matching glyph,
/// plain addresses a road pin. Pure, so it's easy to test.
IconData iconForPlaceCategory(String category) {
  final c = category.toLowerCase();
  if (c.isEmpty) return Icons.location_on_outlined; // plain address
  if (c.contains('cafe') || c.contains('coffee')) return Icons.local_cafe;
  if (c.contains('restaurant') || c.contains('food')) return Icons.restaurant;
  if (c.contains('bar') || c.contains('pub')) return Icons.local_bar;
  if (c.contains('hotel') || c.contains('hostel') || c.contains('guest')) {
    return Icons.hotel;
  }
  if (c.contains('fuel') || c.contains('charging')) {
    return Icons.local_gas_station;
  }
  if (c.contains('supermarket') ||
      c.contains('convenience') ||
      c.contains('mall') ||
      c.contains('shop') ||
      c.contains('store')) {
    return Icons.storefront;
  }
  if (c.contains('bank') || c.contains('atm')) return Icons.local_atm;
  if (c.contains('parking')) return Icons.local_parking;
  if (c.contains('hospital') || c.contains('clinic') || c.contains('pharm')) {
    return Icons.local_hospital;
  }
  if (c.contains('school') || c.contains('universit')) return Icons.school;
  if (c.contains('park') || c.contains('garden')) return Icons.park;
  return Icons.place_outlined; // some other kind of business/POI
}

/// The classic blue "you are here" dot with a white ring and a soft halo.
class MyLocationDot extends StatelessWidget {
  const MyLocationDot({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF0A84FF).withValues(alpha: 0.18),
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: const Color(0xFF0A84FF),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A marker rendering [MyLocationDot] at [point].
Marker myLocationMarker(LatLng point) => Marker(
      point: point,
      width: 44,
      height: 44,
      child: const MyLocationDot(),
    );

/// A red map pin marker sitting on [point], with its tip at the coordinate.
Marker mapPin(LatLng point, {Color color = const Color(0xFFEB4B3F)}) => Marker(
      point: point,
      width: 40,
      height: 40,
      alignment: Alignment.topCenter,
      child: Icon(Icons.location_pin, color: color, size: 40),
    );

/// The tile credit the active base layer requires (defaults to OSM).
class OsmAttribution extends StatelessWidget {
  final MapLayer layer;
  const OsmAttribution({super.key, this.layer = MapLayer.standard});

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
        child: Text(
          attributionFor(layer),
          style: const TextStyle(fontSize: 10, color: Colors.black87),
        ),
      ),
    );
  }
}

/// The base tile layer bound to the user's chosen [MapLayer]; rebuilds when
/// they switch styles.
class LiveTileLayer extends StatelessWidget {
  const LiveTileLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: AppState.mapLayer,
      builder: (context, name, _) => tileLayerFor(MapLayer.fromName(name)),
    );
  }
}

/// The credit for the user's chosen [MapLayer]; rebuilds on switch.
class LiveAttribution extends StatelessWidget {
  const LiveAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: AppState.mapLayer,
      builder: (context, name, _) =>
          OsmAttribution(layer: MapLayer.fromName(name)),
    );
  }
}

/// Floating controls stacked on the right of an interactive map: a base-layer
/// switcher and zoom in / out buttons.
class MapControls extends StatelessWidget {
  final MapController controller;

  /// Extra bottom offset so the controls clear a screen's own bottom UI.
  final double bottom;

  const MapControls({super.key, required this.controller, this.bottom = 120});

  void _zoom(double delta) {
    final cam = controller.camera;
    controller.move(cam.center, (cam.zoom + delta).clamp(2.0, 20.0));
  }

  Future<void> _pickLayer(BuildContext context) async {
    final chosen = await showModalBottomSheet<MapLayer>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final l in MapLayer.values)
              ValueListenableBuilder<String>(
                valueListenable: AppState.mapLayer,
                builder: (context, name, _) => ListTile(
                  leading: Icon(l.icon),
                  title: Text(l.label),
                  trailing: MapLayer.fromName(name) == l
                      ? Icon(Icons.check,
                          color: Theme.of(sheetContext).colorScheme.primary)
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(l),
                ),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) AppState.mapLayer.value = chosen.name;
  }

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, String tip, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: 3,
            shape: const CircleBorder(),
            child: IconButton(icon: Icon(icon), tooltip: tip, onPressed: onTap),
          ),
        );
    return Positioned(
      right: 12,
      bottom: bottom,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          btn(Icons.layers_outlined, 'Map style', () => _pickLayer(context)),
          btn(Icons.add, 'Zoom in', () => _zoom(1)),
          btn(Icons.remove, 'Zoom out', () => _zoom(-1)),
        ],
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
