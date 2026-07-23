import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../util/geolocation.dart';
import '../util/routing.dart';
import '../utils/maps_link.dart';
import '../widgets/osm_map.dart';

/// Draws a driving route on an OpenStreetMap from the user's location to
/// [dest], showing distance + ETA, with a fall-back to the native maps app.
class RouteMapScreen extends StatefulWidget {
  final LatLng dest;
  final String label;

  /// The starting point. When null, the device's current location is used.
  final LatLng? from;

  const RouteMapScreen({
    super.key,
    required this.dest,
    this.from,
    this.label = '',
  });

  @override
  State<RouteMapScreen> createState() => _RouteMapScreenState();
}

class _RouteMapScreenState extends State<RouteMapScreen> {
  final MapController _map = MapController();
  RouteResult? _route;
  LatLng? _from;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var from = widget.from;
    if (from == null) {
      final pos = await getCurrentLatLng();
      if (pos != null) from = LatLng(pos.lat, pos.lng);
    }
    if (!mounted) return;
    if (from == null) {
      setState(() {
        _loading = false;
        _error = 'Turn on location to see directions from where you are.';
      });
      return;
    }
    _from = from;
    final route = await fetchRoute(from: from, to: widget.dest);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _route = route;
      if (route == null) _error = 'Couldn\'t find a route.';
    });
    _fit(from, route);
  }

  void _fit(LatLng from, RouteResult? route) {
    final pts = route?.points ?? [from, widget.dest];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _map.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(pts),
          padding: const EdgeInsets.fromLTRB(50, 80, 50, 180),
        ),
      );
    });
  }

  Future<void> _openExternally() async {
    final isApple = Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.macOS;
    final uri = directionsUrl(
        lat: widget.dest.latitude, lng: widget.dest.longitude, apple: isApple);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      /* ignore */
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.label.isEmpty ? 'Directions' : widget.label)),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: widget.dest,
              initialZoom: 13,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              osmTileLayer(),
              if (_route != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _route!.points,
                      strokeWidth: 5,
                      color: const Color(0xFF0A84FF),
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (_from != null)
                    Marker(
                      point: _from!,
                      width: 22,
                      height: 22,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF0A84FF),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                        ),
                      ),
                    ),
                  mapPin(widget.dest),
                ],
              ),
              const OsmAttribution(),
            ],
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 20,
            child: SafeArea(child: _summaryCard(context)),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(BuildContext context) {
    final route = _route;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(16),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            Expanded(
              child: _loading
                  ? const Row(
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 12),
                        Text('Finding the best route…'),
                      ],
                    )
                  : route != null
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              formatDuration(route.durationSeconds),
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.w700),
                            ),
                            Text(
                              '${formatDistance(route.distanceMeters)} · driving',
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          ],
                        )
                      : Text(_error ?? 'No route available',
                          style: TextStyle(color: Colors.grey.shade700)),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _openExternally,
              icon: const Icon(Icons.navigation_outlined, size: 18),
              label: const Text('Go'),
            ),
          ],
        ),
      ),
    );
  }
}
