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
  TravelMode _mode = TravelMode.car;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var from = _from ?? widget.from;
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
    final route = await fetchRoute(from: from, to: widget.dest, mode: _mode);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _route = route;
      _error = route == null ? 'Couldn\'t find a route.' : null;
    });
    _fit(from, route);
  }

  void _setMode(TravelMode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _loading = true;
      _route = null;
      _error = null;
    });
    _load();
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
              const LiveTileLayer(),
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
              const LiveAttribution(),
            ],
          ),
          MapControls(controller: _map, bottom: 260),
          _DirectionsPanel(
            loading: _loading,
            route: _route,
            error: _error,
            mode: _mode,
            onMode: _setMode,
            onGo: _openExternally,
          ),
        ],
      ),
    );
  }
}

/// A draggable bottom panel: travel-mode picker, ETA + distance, a "Go"
/// hand-off, and the scrollable turn-by-turn steps.
class _DirectionsPanel extends StatelessWidget {
  final bool loading;
  final RouteResult? route;
  final String? error;
  final TravelMode mode;
  final ValueChanged<TravelMode> onMode;
  final VoidCallback onGo;

  const _DirectionsPanel({
    required this.loading,
    required this.route,
    required this.error,
    required this.mode,
    required this.onMode,
    required this.onGo,
  });

  IconData _modeIcon(TravelMode m) => switch (m) {
        TravelMode.car => Icons.directions_car,
        TravelMode.foot => Icons.directions_walk,
        TravelMode.bike => Icons.directions_bike,
      };

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return DraggableScrollableSheet(
      initialChildSize: 0.28,
      minChildSize: 0.16,
      maxChildSize: 0.85,
      builder: (context, controller) => Material(
        color: surface,
        elevation: 8,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: ListView(
          controller: controller,
          padding: EdgeInsets.zero,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<TravelMode>(
                  segments: [
                    for (final m in TravelMode.values)
                      ButtonSegment(
                        value: m,
                        icon: Icon(_modeIcon(m)),
                        label: Text(m.label),
                      ),
                  ],
                  selected: {mode},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => onMode(s.first),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Expanded(child: _summary(context)),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: onGo,
                    icon: const Icon(Icons.navigation_outlined, size: 18),
                    label: const Text('Go'),
                  ),
                ],
              ),
            ),
            if (route != null && route!.steps.isNotEmpty) ...[
              const Divider(height: 1),
              for (final step in route!.steps)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.turn_right, size: 20),
                  title: Text(step.instruction),
                  trailing: step.distanceMeters > 0
                      ? Text(formatDistance(step.distanceMeters),
                          style: TextStyle(color: Colors.grey.shade600))
                      : null,
                ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }

  Widget _summary(BuildContext context) {
    if (loading) {
      return const Row(
        children: [
          SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Text('Finding the best route…'),
        ],
      );
    }
    final r = route;
    if (r == null) {
      return Text(error ?? 'No route available',
          style: TextStyle(color: Colors.grey.shade700));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(formatDuration(r.durationSeconds),
            style:
                const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        Text('${formatDistance(r.distanceMeters)} · ${mode.label.toLowerCase()}',
            style: TextStyle(color: Colors.grey.shade600)),
      ],
    );
  }
}
