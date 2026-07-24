import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../util/geolocation.dart';
import '../util/routing.dart';
import '../utils/maps_link.dart';
import '../widgets/osm_map.dart';

/// Draws a route on an OpenStreetMap from the user's location to [dest] with
/// a Drive / Walk / Cycle selector and turn-by-turn steps — and a fully
/// in-app navigation mode ("Go") that follows the user's GPS along the route.
class RouteMapScreen extends StatefulWidget {
  final LatLng dest;
  final String label;

  /// The starting point. When null, the device's current location is used.
  final LatLng? from;

  /// Test/preview hook: a pre-computed route, skipping the network fetch.
  final RouteResult? initialRoute;

  const RouteMapScreen({
    super.key,
    required this.dest,
    this.from,
    this.label = '',
    this.initialRoute,
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

  // In-app navigation state.
  bool _navigating = false;
  int _navStep = 0;
  LatLng? _navPos;
  Timer? _navTimer;
  bool _rerouting = false;
  DateTime? _lastReroute;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _navTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.initialRoute != null) {
      setState(() {
        _from = widget.from;
        _route = widget.initialRoute;
        _loading = false;
      });
      _fit(widget.from, widget.initialRoute);
      return;
    }
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
    if (mode == _mode || _navigating) return;
    setState(() {
      _mode = mode;
      _loading = true;
      _route = null;
      _error = null;
    });
    _load();
  }

  void _fit(LatLng? from, RouteResult? route) {
    final pts = route?.points ?? [if (from != null) from, widget.dest];
    if (pts.isEmpty) return;
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

  // ---- In-app navigation ----------------------------------------------

  void _startNav() {
    final r = _route;
    if (r == null) return;
    _navTimer?.cancel();
    setState(() {
      _navigating = true;
      // The upcoming maneuver: the first turn (step 1) when there is one.
      _navStep = r.steps.length > 1 ? 1 : 0;
      _navPos = _from;
    });
    final start = _navPos ?? r.points.first;
    _map.move(start, 16.5);
    _navTimer = Timer.periodic(const Duration(seconds: 4), (_) => _navTick());
    _navTick();
  }

  Future<void> _navTick() async {
    final pos = await getCurrentLatLng();
    if (!mounted || !_navigating || pos == null || _route == null) return;
    final user = LatLng(pos.lat, pos.lng);
    setState(() {
      _navPos = user;
      _navStep =
          advanceStep(steps: _route!.steps, current: _navStep, user: user);
    });
    _map.move(user, 16.5);

    // Strayed off the route? Fetch a fresh one from where the user actually
    // is (rate-limited so a failing router isn't hammered).
    final off = distanceToRouteMeters(user, _route!.points) > 60;
    final cooledDown = _lastReroute == null ||
        DateTime.now().difference(_lastReroute!) > const Duration(seconds: 15);
    if (off && !_rerouting && cooledDown) {
      _lastReroute = DateTime.now();
      setState(() => _rerouting = true);
      final fresh =
          await fetchRoute(from: user, to: widget.dest, mode: _mode);
      if (!mounted || !_navigating) return;
      setState(() {
        _rerouting = false;
        if (fresh != null) {
          _route = fresh;
          _navStep = fresh.steps.length > 1 ? 1 : 0;
        }
      });
    }
  }

  void _endNav() {
    _navTimer?.cancel();
    _navTimer = null;
    setState(() => _navigating = false);
    _fit(_from, _route);
  }

  bool get _arrived {
    final r = _route;
    if (r == null || r.steps.isEmpty || _navPos == null) return false;
    if (_navStep < r.steps.length - 1) return false;
    final loc = r.steps.last.location;
    if (loc == null) return false;
    return const Distance().distance(_navPos!, loc) <= 35;
  }

  // -----------------------------------------------------------------------

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
    final route = _route;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.label.isEmpty ? 'Directions' : widget.label),
        actions: [
          if (!_navigating)
            IconButton(
              icon: const Icon(Icons.open_in_new),
              tooltip: 'Open in Maps app (optional)',
              onPressed: _openExternally,
            ),
        ],
      ),
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
              if (route != null)
                PolylineLayer(
                  polylines: [
                    // Cased like Apple Maps: a white border makes the route
                    // pop on any base map.
                    Polyline(
                      points: route.points,
                      strokeWidth: 6,
                      color: const Color(0xFF0A84FF),
                      borderStrokeWidth: 2,
                      borderColor: Colors.white,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (_navPos != null || _from != null)
                    Marker(
                      point: _navPos ?? _from!,
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
              const Scalebar(
                alignment: Alignment.bottomLeft,
                padding: EdgeInsets.fromLTRB(10, 0, 0, 14),
              ),
              const LiveAttribution(),
            ],
          ),
          MapControls(controller: _map, bottom: _navigating ? 140 : 260),
          if (_navigating && route != null) ...[
            _NavBanner(
              arrived: _arrived,
              rerouting: _rerouting,
              step: route.steps.isEmpty ? null : route.steps[_navStep],
              user: _navPos,
            ),
            _NavBottomBar(
              route: route,
              navStep: _navStep,
              user: _navPos,
              onEnd: _endNav,
            ),
          ] else
            _DirectionsPanel(
              loading: _loading,
              route: route,
              error: _error,
              mode: _mode,
              onMode: _setMode,
              onGo: _startNav,
            ),
        ],
      ),
    );
  }
}

/// The big instruction banner shown while navigating.
class _NavBanner extends StatelessWidget {
  final bool arrived;
  final bool rerouting;
  final RouteStep? step;
  final LatLng? user;

  const _NavBanner({
    required this.arrived,
    required this.step,
    this.rerouting = false,
    this.user,
  });

  @override
  Widget build(BuildContext context) {
    String title;
    String? sub;
    if (arrived) {
      title = 'You\'ve arrived';
    } else if (rerouting) {
      title = 'Re-routing…';
    } else if (step == null) {
      title = 'Follow the route';
    } else {
      title = step!.instruction;
      final loc = step!.location;
      if (user != null && loc != null) {
        sub = 'in ${formatDistance(const Distance().distance(user!, loc))}';
      }
    }
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: Material(
        color: const Color(0xFF0A84FF),
        borderRadius: BorderRadius.circular(16),
        elevation: 6,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(
            children: [
              Icon(
                arrived
                    ? Icons.flag
                    : step == null
                        ? Icons.navigation
                        : iconForManeuver(step!.type, step!.modifier),
                color: Colors.white,
                size: 30,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700),
                    ),
                    if (sub != null)
                      Text(sub,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13.5)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Remaining distance / time plus the End button while navigating.
class _NavBottomBar extends StatelessWidget {
  final RouteResult route;
  final int navStep;
  final LatLng? user;
  final VoidCallback onEnd;

  const _NavBottomBar({
    required this.route,
    required this.navStep,
    required this.user,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    final left = remainingMeters(route: route, current: navStep, user: user);
    final frac =
        route.distanceMeters <= 0 ? 0.0 : (left / route.distanceMeters);
    final etaLeft = route.durationSeconds * frac.clamp(0.0, 1.0);
    final arrive = TimeOfDay.fromDateTime(
            DateTime.now().add(Duration(seconds: etaLeft.round())))
        .format(context);
    return Positioned(
      left: 12,
      right: 12,
      bottom: 20,
      child: SafeArea(
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(16),
          color: Theme.of(context).colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(formatDuration(etaLeft),
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w700)),
                      Text('${formatDistance(left)} left · arrive $arrive',
                          style: TextStyle(color: Colors.grey.shade600)),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: onEnd,
                  style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFE53935)),
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('End'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A draggable bottom panel: travel-mode picker, ETA + distance, the in-app
/// "Go", and the scrollable turn-by-turn steps.
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
                    onPressed: route == null ? null : onGo,
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
                  leading:
                      Icon(iconForManeuver(step.type, step.modifier), size: 22),
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
    final arrive = TimeOfDay.fromDateTime(
            DateTime.now().add(Duration(seconds: r.durationSeconds.round())))
        .format(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(formatDuration(r.durationSeconds),
            style:
                const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        Text(
            '${formatDistance(r.distanceMeters)} · '
            '${mode.label.toLowerCase()} · arrive $arrive',
            style: TextStyle(color: Colors.grey.shade600)),
      ],
    );
  }
}
