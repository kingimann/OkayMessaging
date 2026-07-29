import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../util/geolocation.dart';
import '../util/routing.dart';
import '../util/speech.dart';
import '../utils/maps_link.dart';
import '../widgets/osm_map.dart';
import 'forward_screen.dart';

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

  /// Test/preview hook: pre-computed routes with alternatives.
  final List<RouteResult>? initialRoutes;

  const RouteMapScreen({
    super.key,
    required this.dest,
    this.from,
    this.label = '',
    this.initialRoute,
    this.initialRoutes,
  });

  @override
  State<RouteMapScreen> createState() => _RouteMapScreenState();
}

class _RouteMapScreenState extends State<RouteMapScreen> {
  final MapController _map = MapController();

  /// The directions sheet, so the things that must stay clear of it can
  /// follow where it actually is instead of guessing.
  final DraggableScrollableController _panel =
      DraggableScrollableController();

  /// Where the sheet rests, and how far up the map's furniture has to sit.
  static const double _panelResting = 0.30;

  double _abovePanel(BuildContext context) {
    if (_navigating) return 150; // the nav bar takes the bottom instead
    final size = _panel.isAttached ? _panel.size : _panelResting;
    return MediaQuery.of(context).size.height * size.clamp(0.0, 0.5);
  }
  List<RouteResult> _routes = const [];
  int _routeIndex = 0;
  LatLng? _from;
  bool _loading = true;
  String? _error;
  TravelMode _mode = TravelMode.values.firstWhere(
      (m) => m.name == AppState.defaultTravelMode.value,
      orElse: () => TravelMode.car);

  /// The currently chosen route (primary or a picked alternative).
  RouteResult? get _route =>
      _routes.isEmpty ? null : _routes[_routeIndex.clamp(0, _routes.length - 1)];

  // In-app navigation state.
  bool _navigating = false;
  int _navStep = 0;
  LatLng? _navPos;
  Timer? _navTimer;
  bool _rerouting = false;
  DateTime? _lastReroute;

  // Voice guidance: which step was last announced (-1 = none yet).
  bool _voiceOn = AppState.navVoice.value;
  int _lastSpoken = -1;

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
    if (widget.initialRoutes != null || widget.initialRoute != null) {
      setState(() {
        _from = widget.from;
        _routes = widget.initialRoutes ?? [widget.initialRoute!];
        _routeIndex = 0;
        _loading = false;
      });
      _fit(widget.from, _route);
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
    final routes = await fetchRoutes(from: from, to: widget.dest, mode: _mode);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _routes = routes ?? const [];
      _routeIndex = 0;
      _error = routes == null ? 'Couldn\'t find a route.' : null;
    });
    _fit(from, _route);
  }

  void _setMode(TravelMode mode) {
    if (mode == _mode || _navigating) return;
    setState(() {
      _mode = mode;
      _loading = true;
      _routes = const [];
      _routeIndex = 0;
      _error = null;
    });
    _load();
  }

  void _pickRoute(int i) {
    if (i == _routeIndex || i < 0 || i >= _routes.length) return;
    setState(() => _routeIndex = i);
    _fit(_from, _route);
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
          // A 20 m route must not zoom past the deepest real tiles.
          maxZoom: 17.5,
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
    _lastSpoken = -1;
    _maybeAnnounce();
    _navTimer = Timer.periodic(const Duration(seconds: 4), (_) => _navTick());
    _navTick();
  }

  /// Speaks the upcoming maneuver whenever it changes (and the arrival).
  void _maybeAnnounce() {
    final r = _route;
    if (!_voiceOn || !_navigating || r == null || r.steps.isEmpty) return;
    if (_arrived) {
      if (_lastSpoken != _kSpokenArrived) {
        _lastSpoken = _kSpokenArrived;
        speak('You have arrived at your destination.');
      }
      return;
    }
    if (_navStep == _lastSpoken || _navStep >= r.steps.length) return;
    _lastSpoken = _navStep;
    final step = r.steps[_navStep];
    final user = _navPos;
    final loc = step.location;
    final dist =
        user != null && loc != null ? const Distance().distance(user, loc) : null;
    speak(dist != null && dist >= 60
        ? 'In ${spokenDistance(dist)}, ${step.instruction}.'
        : '${step.instruction}.');
  }

  static const int _kSpokenArrived = 1 << 20;

  Future<void> _navTick() async {
    final pos = await getCurrentLatLng();
    if (!mounted || !_navigating || pos == null || _route == null) return;
    final user = LatLng(pos.lat, pos.lng);
    final prev = _navPos;
    setState(() {
      _navPos = user;
      _navStep =
          advanceStep(steps: _route!.steps, current: _navStep, user: user);
    });
    _maybeAnnounce();
    // Rotate the map so the direction of travel points up, like real
    // turn-by-turn navigation (only once actually moving).
    if (prev != null && const Distance().distance(prev, user) > 5) {
      _map.moveAndRotate(user, 16.5, -const Distance().bearing(prev, user));
    } else {
      _map.move(user, 16.5);
    }

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
          _routes = [fresh];
          _routeIndex = 0;
          _navStep = fresh.steps.length > 1 ? 1 : 0;
          _lastSpoken = -1; // announce the new route's first turn
        }
      });
      _maybeAnnounce();
    }
  }

  /// The full step list mid-navigation (tap the banner) with the upcoming
  /// maneuver highlighted.
  void _showNavSteps(RouteResult route) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (var i = 0; i < route.steps.length; i++)
              ListTile(
                dense: true,
                selected: i == _navStep,
                leading: Icon(
                    iconForManeuver(
                        route.steps[i].type, route.steps[i].modifier),
                    size: 22),
                title: Text(route.steps[i].instruction),
                trailing: route.steps[i].distanceMeters > 0
                    ? Text(formatDistance(route.steps[i].distanceMeters))
                    : null,
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _endNav() {
    _navTimer?.cancel();
    _navTimer = null;
    stopSpeaking();
    setState(() => _navigating = false);
    _map.rotate(0); // back to north-up
    _fit(_from, _route);
  }

  /// Sends "on my way, arriving ~HH:MM" into a chat.
  void _shareEta() {
    final route = _route;
    if (route == null) return;
    final left =
        remainingMeters(route: route, current: _navStep, user: _navPos);
    final frac =
        route.distanceMeters <= 0 ? 0.0 : left / route.distanceMeters;
    final secs = route.durationSeconds * frac.clamp(0.0, 1.0);
    final arrive = TimeOfDay.fromDateTime(
            DateTime.now().add(Duration(seconds: secs.round())))
        .format(context);
    final where = widget.label.isEmpty ? 'my destination' : widget.label;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ForwardScreen(text: 'On my way to $where — arriving around '
                '$arrive.'),
      ),
    );
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
              minZoom: 2,
              maxZoom: 20.5,
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
                    // Unpicked alternatives sit under the chosen route in
                    // grey, Apple-Maps style.
                    if (!_navigating)
                      for (var i = 0; i < _routes.length; i++)
                        if (i != _routeIndex)
                          Polyline(
                            points: _routes[i].points,
                            strokeWidth: 5,
                            color: const Color(0xFF9E9E9E),
                            borderStrokeWidth: 2,
                            borderColor: Colors.white,
                          ),
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
              // The credit and the scale bar were pinned to the bottom edge
              // while the directions sheet covered the bottom third, so both
              // sat underneath it — and the tile credit is a licence term,
              // not decoration. They ride above the sheet now, wherever it
              // has been dragged to.
              AnimatedBuilder(
                animation: _panel,
                builder: (context, _) {
                  final lift = _abovePanel(context);
                  return Stack(
                    children: [
                      Scalebar(
                        alignment: Alignment.bottomLeft,
                        padding: EdgeInsets.fromLTRB(10, 0, 0, lift + 14),
                      ),
                      Padding(
                        padding: EdgeInsets.only(bottom: lift),
                        child: const LiveAttribution(),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
          AnimatedBuilder(
            animation: _panel,
            builder: (context, _) =>
                MapControls(controller: _map, bottom: _abovePanel(context) + 16),
          ),
          if (_navigating && route != null) ...[
            _NavBanner(
              arrived: _arrived,
              rerouting: _rerouting,
              step: route.steps.isEmpty ? null : route.steps[_navStep],
              nextStep: _navStep + 1 < route.steps.length
                  ? route.steps[_navStep + 1]
                  : null,
              user: _navPos,
              onTap: () => _showNavSteps(route),
            ),
            _NavBottomBar(
              route: route,
              navStep: _navStep,
              user: _navPos,
              voiceOn: _voiceOn,
              onToggleVoice: () {
                setState(() => _voiceOn = !_voiceOn);
                if (!_voiceOn) stopSpeaking();
              },
              onShareEta: _shareEta,
              onEnd: _endNav,
            ),
          ] else
            _DirectionsPanel(
              controller: _panel,
              loading: _loading,
              route: route,
              routes: _routes,
              routeIndex: _routeIndex,
              error: _error,
              mode: _mode,
              onMode: _setMode,
              onRoute: _pickRoute,
              onGo: _startNav,
              onRetry: () {
                setState(() {
                  _loading = true;
                  _error = null;
                });
                _load();
              },
              onStep: (step) {
                final loc = step.location;
                if (loc != null) _map.move(loc, 17);
              },
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
  final RouteStep? nextStep;
  final LatLng? user;
  final VoidCallback? onTap;

  const _NavBanner({
    required this.arrived,
    required this.step,
    this.nextStep,
    this.rerouting = false,
    this.user,
    this.onTap,
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
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
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
                // Apple-style "then" preview of the maneuver after this one.
                if (!arrived && !rerouting && nextStep != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(
                            iconForManeuver(
                                nextStep!.type, nextStep!.modifier),
                            color: Colors.white70,
                            size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'then ${nextStep!.instruction}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
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
  final bool voiceOn;
  final VoidCallback onToggleVoice;
  final VoidCallback onShareEta;
  final VoidCallback onEnd;

  const _NavBottomBar({
    required this.route,
    required this.navStep,
    required this.user,
    required this.voiceOn,
    required this.onToggleVoice,
    required this.onShareEta,
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
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(voiceOn ? Icons.volume_up : Icons.volume_off),
                  tooltip: voiceOn ? 'Mute voice' : 'Unmute voice',
                  onPressed: onToggleVoice,
                ),
                IconButton(
                  icon: const Icon(Icons.ios_share),
                  tooltip: 'Share ETA',
                  onPressed: onShareEta,
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
  final DraggableScrollableController controller;
  final bool loading;
  final RouteResult? route;
  final List<RouteResult> routes;
  final int routeIndex;
  final String? error;
  final TravelMode mode;
  final ValueChanged<TravelMode> onMode;
  final ValueChanged<int> onRoute;
  final VoidCallback onGo;
  final VoidCallback onRetry;
  final ValueChanged<RouteStep> onStep;

  const _DirectionsPanel({
    required this.controller,
    required this.loading,
    required this.route,
    required this.routes,
    required this.routeIndex,
    required this.error,
    required this.mode,
    required this.onMode,
    required this.onRoute,
    required this.onGo,
    required this.onRetry,
    required this.onStep,
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
      controller: controller,
      initialChildSize: _RouteMapScreenState._panelResting,
      minChildSize: 0.16,
      maxChildSize: 0.85,
      // Without snapping the sheet stayed wherever a finger left it, which
      // on a screen whose whole job is "route above, steps below" meant
      // never quite getting either.
      snap: true,
      snapSizes: const [0.16, _RouteMapScreenState._panelResting, 0.85],
      builder: (context, scrollController) => Material(
        color: surface,
        elevation: 8,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: ListView(
          controller: scrollController,
          padding: EdgeInsets.zero,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant
                      .withValues(alpha: 0.4),
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
            // Route alternatives, when OSRM offers more than one. Labelled by
            // how much longer they take than the quickest, which is the only
            // reason anyone reads this row — "Route 2" says nothing.
            if (routes.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (var i = 0; i < routes.length; i++)
                      ChoiceChip(
                        label: Text(routeChoiceLabel(routes, i)),
                        selected: i == routeIndex,
                        onSelected: (_) => onRoute(i),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Expanded(child: _summary(context)),
                  const SizedBox(width: 12),
                  if (route == null && !loading && error != null)
                    // A failed route used to be the end of the screen: a line
                    // of grey text and no way to ask again short of backing
                    // out and starting over.
                    FilledButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Try again'),
                    )
                  else
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
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))
                      : null,
                  // Peek at this turn on the map.
                  onTap: () => onStep(step),
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
      // Was grey.shade700: near-invisible on a dark surface, which is where
      // this sits most of the time.
      return Text(error ?? 'No route available',
          style: TextStyle(color: Theme.of(context).colorScheme.error));
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
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    );
  }
}
