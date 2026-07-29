import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:latlong2/latlong.dart';

import '../app_state.dart';

/// Identifies the app to the tile servers (required by OSM's usage policy,
/// and good manners everywhere else).
const String kOsmUserAgent = 'com.okay.messaging';

/// Mapbox public access token, e.g. `pk.eyJ1...`.
///
/// Set with `--dart-define=MAPBOX_TOKEN=pk...`. Public tokens are designed to
/// ship in a client and should be URL-restricted in the Mapbox dashboard.
///
/// Leaving it unset is a supported state, not a broken one: every style falls
/// back to the free servers the app used before. That keeps CI, the web build
/// and anyone without a token on a working map rather than a grey rectangle,
/// and it means a blown Mapbox quota degrades instead of failing.
/// Trimmed, because a token pasted into a CI secret usually arrives with a
/// trailing newline and Mapbox rejects the request without saying why.
final String kMapboxToken =
    const String.fromEnvironment('MAPBOX_TOKEN', defaultValue: '').trim();

/// Whether [token] is a Mapbox *public* token.
///
/// A secret token (`sk.`) authenticates from a server and 401s from a client.
/// The tiles then fail, [freeUrlFor] quietly serves them instead, and the map
/// looks exactly like a build with no token at all — so this refuses anything
/// that isn't `pk.` rather than shipping a basemap that can only fail.
///
/// Whitespace inside it is refused too. A real token is one unbroken word; a
/// value with a space in it is a description or a sentence that got pasted
/// along with the token, and it would build a tile URL that 401s on every
/// request. One did worse than that — pasted into an unquoted shell variable,
/// it split the build command and failed the whole iOS build.
bool isPublicMapboxToken(String token) {
  final t = token.trim();
  return t.startsWith('pk.') && !RegExp(r'\s').hasMatch(t);
}

/// Test hook. The token is compiled in and `flutter test` takes no
/// `--dart-define`, so without this the entire Mapbox path — the one the app
/// ships with a token — could never be run by the suite.
@visibleForTesting
bool? debugMapboxEnabledOverride;

bool get mapboxEnabled =>
    debugMapboxEnabledOverride ?? isPublicMapboxToken(kMapboxToken);

/// Why the map is drawing free tiles when Mapbox was expected, or empty when
/// Mapbox is what's drawing.
///
/// Every one of these states looks identical on screen — a working map from
/// the free servers — so without this the only way to tell a missing token
/// from a wrong one is to read the build command.
String mapboxOffReason(String token) {
  if (isPublicMapboxToken(token)) return '';
  final t = token.trim();
  if (t.isEmpty) return 'no MAPBOX_TOKEN was set for this build';
  if (RegExp(r'\s').hasMatch(t)) {
    return 'MAPBOX_TOKEN has spaces in it; paste only the token';
  }
  if (t.startsWith('sk.')) {
    return 'MAPBOX_TOKEN is a secret token; Mapbox needs the public pk. one';
  }
  return 'MAPBOX_TOKEN is not a Mapbox token';
}

/// Who is drawing the basemap, for the map style sheet.
String basemapSource() => mapboxEnabled ? 'Mapbox' : 'OpenStreetMap';

/// The Mapbox style each layer maps to. Their dark style is designed to be
/// read at night, which is why [darkMapLift] is not applied over it.
String mapboxStyleFor(MapLayer layer) => switch (layer) {
      // auto never reaches here — effectiveLayer resolves it first — but the
      // switch has to be total, and standard is what it resolves to by day.
      MapLayer.auto || MapLayer.standard => 'mapbox/streets-v12',
      MapLayer.dark => 'mapbox/dark-v11',
      MapLayer.satellite => 'mapbox/satellite-streets-v12',
      MapLayer.terrain => 'mapbox/outdoors-v12',
    };

/// Mapbox raster tiles for [layer]. 256px tiles so this drops straight into
/// the same slippy-map arithmetic the free servers use; `{r}` becomes `@2x`
/// for retina.
String mapboxUrlFor(MapLayer layer) =>
    'https://api.mapbox.com/styles/v1/${mapboxStyleFor(layer)}'
    '/tiles/256/{z}/{x}/{y}{r}?access_token=$kMapboxToken';

/// The selectable base map styles.
enum MapLayer {
  /// Light or dark, whichever the app theme is on.
  ///
  /// This behaviour used to be hidden inside "Standard": picking Standard in
  /// dark mode drew the Dark map, so the check mark sat next to a style the
  /// map was not using and choosing it appeared to do nothing at all. It is
  /// its own choice now, and Standard means standard.
  auto('Automatic', Icons.brightness_auto_outlined),
  standard('Standard', Icons.map_outlined),
  dark('Dark', Icons.dark_mode_outlined),
  satellite('Satellite', Icons.satellite_alt_outlined),
  terrain('Terrain', Icons.terrain_outlined);

  const MapLayer(this.label, this.icon);
  final String label;
  final IconData icon;

  static MapLayer fromName(String? name) =>
      values.firstWhere((l) => l.name == name, orElse: () => MapLayer.auto);
}

/// Brightness lift applied to the Dark basemap's tiles.
///
/// CARTO's `dark_all` sits at roughly #0E1013 — near-black, so at night the
/// map reads as an empty screen and the streets vanish into the background.
/// This is a standard 5x4 colour matrix that scales each channel slightly
/// (0.82, keeping some contrast) and then adds a flat +38 offset, moving the
/// background to about #3A3C3F — a charcoal that still reads as "dark" while
/// letting roads, water and labels separate. Alpha is untouched.
const List<double> darkMapLift = <double>[
  0.82, 0, 0, 0, 38, //
  0, 0.82, 0, 0, 38, //
  0, 0, 0.82, 0, 38, //
  0, 0, 0, 1, 0, //
];

/// The channel value [v] (0-255) as the lift above renders it. Pure, so the
/// "is it actually lighter" question is testable rather than eyeballed.
double liftedChannel(double v) => (v * 0.82 + 38).clamp(0, 255);

/// The raster tile layer for a given [layer].
///
/// Standard and Dark use CARTO's basemaps (rendered from up-to-date
/// OpenStreetMap data): a clean, modern cartographic style served as crisp
/// @2x retina tiles — a big visual upgrade over the classic OSM tiles.
/// Test hook: replaces the tile provider (the cancellable provider's dio
/// timers never settle inside the fake-async test zone).
@visibleForTesting
TileProvider Function()? debugTileProviderOverride;

TileLayer tileLayerFor(MapLayer layer, {bool lowData = false}) {
  // Cancels tile requests the moment their tile pans out of view. Browsers
  // only run a handful of requests per host at once, so without this a fast
  // pan/zoom queues dozens of stale tiles ahead of the visible ones and the
  // map sits grey — the single biggest map speed fix on the web.
  final provider =
      debugTileProviderOverride?.call() ?? CancellableNetworkTileProvider();
  // Low data mode drops the crisp @2x tiles for standard 1x ones — about a
  // quarter of the pixels per tile — for slow cellular connections.
  final retina = !lowData;
  // maxZoom is a hard display cutoff — past it the map renders NOTHING
  // (framing a 20 m route zooms right past every server's deepest tiles and
  // the screen goes grey). maxNativeZoom marks the deepest tiles the server
  // actually has; beyond that, flutter_map scales those tiles up instead.
  // One vendor for every style when a token is set: consistent cartography,
  // consistent labelling, and a dark style built to be legible rather than
  // one corrected after the fact.
  //
  // fallbackUrl is the safety net, and it matters more than it looks. A
  // revoked token, an exhausted quota or a style id Mapbox has retired would
  // otherwise leave a grey rectangle where the map should be; instead each
  // failed tile quietly comes from the free server the app used before.
  if (mapboxEnabled) {
    return TileLayer(
      urlTemplate: mapboxUrlFor(layer),
      fallbackUrl: freeUrlFor(layer),
      userAgentPackageName: kOsmUserAgent,
      tileProvider: provider,
      retinaMode: retina,
      maxNativeZoom: layer == MapLayer.satellite ? 22 : 20,
      maxZoom: 22,
    );
  }

  switch (layer) {
    case MapLayer.satellite:
      return TileLayer(
        urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/'
            'World_Imagery/MapServer/tile/{z}/{y}/{x}',
        userAgentPackageName: kOsmUserAgent,
        tileProvider: provider,
        maxNativeZoom: 19,
        maxZoom: 22,
      );
    case MapLayer.terrain:
      return TileLayer(
        urlTemplate: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
        subdomains: const ['a', 'b', 'c'],
        userAgentPackageName: kOsmUserAgent,
        tileProvider: provider,
        maxNativeZoom: 17,
        maxZoom: 22,
      );
    case MapLayer.dark:
      return TileLayer(
        urlTemplate:
            'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
        subdomains: const ['a', 'b', 'c', 'd'],
        userAgentPackageName: kOsmUserAgent,
        tileProvider: provider,
        retinaMode: retina,
        maxNativeZoom: 20,
        maxZoom: 22,
        // CARTO's dark basemap is nearly black, which reads as a blank screen
        // at night and buries the streets. Lift it to a charcoal so roads and
        // labels separate from the background.
        tileBuilder: (context, tileWidget, tile) => ColorFiltered(
          colorFilter: const ColorFilter.matrix(darkMapLift),
          child: tileWidget,
        ),
      );
    case MapLayer.auto:
    case MapLayer.standard:
      return TileLayer(
        urlTemplate: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/'
            '{z}/{x}/{y}{r}.png',
        subdomains: const ['a', 'b', 'c', 'd'],
        userAgentPackageName: kOsmUserAgent,
        tileProvider: provider,
        retinaMode: retina,
        maxNativeZoom: 20,
        maxZoom: 22,
      );
  }
}

/// The free tile server each style used before Mapbox, kept as the fallback.
/// No `{s}` subdomain placeholder — a fallback URL is fetched directly, so it
/// has to be a complete address.
String freeUrlFor(MapLayer layer) => switch (layer) {
      MapLayer.satellite => 'https://server.arcgisonline.com/ArcGIS/rest/'
          'services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      MapLayer.terrain => 'https://a.tile.opentopomap.org/{z}/{x}/{y}.png',
      MapLayer.dark =>
        'https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
      MapLayer.auto || MapLayer.standard =>
        'https://a.basemaps.cartocdn.com/rastertiles/'
            'voyager/{z}/{x}/{y}{r}.png',
    };

/// The credit line a given [layer]'s tiles require.
String attributionFor(MapLayer layer) {
  // Mapbox's terms require crediting both them and OpenStreetMap, whichever
  // style is showing.
  if (mapboxEnabled) return '© Mapbox · © OpenStreetMap';
  return switch (layer) {
    MapLayer.satellite => '© Esri, Maxar',
    MapLayer.terrain => '© OpenTopoMap (CC-BY-SA)',
    MapLayer.dark => '© OpenStreetMap · © CARTO',
    MapLayer.auto || MapLayer.standard => '© OpenStreetMap · © CARTO',
  };
}

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
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Align(
      alignment: Alignment.bottomRight,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(6, 6, 8, 6),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            // Legally required, so it can't be hidden — but a solid slab
            // parked on the map is louder than a credit line needs to be.
            color: (dark ? Colors.black : Colors.white).withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            attributionFor(layer),
            style: TextStyle(
              fontSize: 9.5,
              height: 1.1,
              color: (dark ? Colors.white : Colors.black)
                  .withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}

/// The effective layer for the current theme: when the user hasn't picked a
/// special style (satellite/terrain/dark), the Standard map automatically
/// switches to the Dark style in dark mode so the map matches the app.
MapLayer effectiveLayer(String name, Brightness brightness) {
  final chosen = MapLayer.fromName(name);
  if (chosen != MapLayer.auto) return chosen;
  return brightness == Brightness.dark ? MapLayer.dark : MapLayer.standard;
}

/// The base tile layer bound to the user's chosen [MapLayer]; rebuilds when
/// they switch styles and follows the app theme for the Standard style.
class LiveTileLayer extends StatelessWidget {
  const LiveTileLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return ValueListenableBuilder<String>(
      valueListenable: AppState.mapLayer,
      builder: (context, name, _) => ValueListenableBuilder<bool>(
        valueListenable: AppState.mapLowData,
        builder: (context, lowData, _) =>
            tileLayerFor(effectiveLayer(name, brightness), lowData: lowData),
      ),
    );
  }
}

/// The credit for the user's chosen [MapLayer]; rebuilds on switch.
class LiveAttribution extends StatelessWidget {
  const LiveAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return ValueListenableBuilder<String>(
      valueListenable: AppState.mapLayer,
      builder: (context, name, _) =>
          OsmAttribution(layer: effectiveLayer(name, brightness)),
    );
  }
}

/// Floating controls stacked on the right of an interactive map: a base-layer
/// switcher and zoom in / out buttons.
class MapControls extends StatelessWidget {
  /// Optional extras: saved places and the friends map, shown above zoom.
  final VoidCallback? onSaved;
  final VoidCallback? onFriends;

  final MapController controller;

  /// Extra bottom offset so the controls clear a screen's own bottom UI.
  final double bottom;

  /// When set, the controls anchor below the top edge instead (Apple-Maps
  /// style, clear of bottom sheets); [bottom] is ignored.
  final double? top;

  /// When set, a my-location button leads the control stack.
  final VoidCallback? onMyLocation;

  const MapControls({
    super.key,
    required this.controller,
    this.bottom = 120,
    this.top,
    this.onMyLocation,
    this.onSaved,
    this.onFriends,
  });

  void _zoom(double delta) {
    final cam = controller.camera;
    controller.move(cam.center, (cam.zoom + delta).clamp(2.0, 20.0));
  }

  Future<void> _pickLayer(BuildContext context) async {
    final chosen = await showModalBottomSheet<MapLayer>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        // Four styles, a switch and a credit line don't fit a short screen —
        // a phone in landscape overflowed the sheet rather than scrolling it.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final l in MapLayer.values)
                ValueListenableBuilder<String>(
                  valueListenable: AppState.mapLayer,
                  builder: (context, name, _) => ListTile(
                    leading: Icon(l.icon),
                    title: Text(l.label),
                    // Only Automatic needs explaining; the rest are the name
                    // of the map you get.
                    subtitle: l == MapLayer.auto
                        ? const Text('Light or dark, following the app')
                        : null,
                    trailing: MapLayer.fromName(name) == l
                        ? Icon(Icons.check,
                            color: Theme.of(sheetContext).colorScheme.primary)
                        : null,
                    onTap: () => Navigator.of(sheetContext).pop(l),
                  ),
                ),
              const Divider(height: 1),
              ValueListenableBuilder<bool>(
                valueListenable: AppState.mapLowData,
                builder: (context, lowData, _) => SwitchListTile.adaptive(
                  secondary: const Icon(Icons.data_saver_on_outlined),
                  title: const Text('Low data mode'),
                  subtitle: const Text('Lighter tiles for slow connections'),
                  value: lowData,
                  onChanged: (v) => AppState.mapLowData.value = v,
                ),
              ),
              const _BasemapSourceLine(),
            ],
          ),
        ),
      ),
    );
    if (chosen != null) AppState.mapLayer.value = chosen.name;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    Widget icon(IconData glyph, String tip, VoidCallback onTap) => IconButton(
          icon: Icon(glyph, size: 21),
          tooltip: tip,
          color: scheme.onSurface,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 44, height: 44),
          padding: EdgeInsets.zero,
          onPressed: onTap,
        );

    /// Related controls travel together in one rounded slab rather than as
    /// separate floating circles. Six identical dots down the edge of a map
    /// read as clutter and say nothing about which belong together.
    Widget cluster(List<Widget> children) => Container(
          margin: const EdgeInsets.only(top: 10),
          decoration: BoxDecoration(
            // Slightly translucent so it reads as chrome floating over the
            // map, and outlined so it separates from a dark basemap — a
            // plain dark circle on a dark map is nearly invisible.
            color: scheme.surface.withValues(alpha: dark ? 0.88 : 0.95),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: (dark ? Colors.white : Colors.black)
                  .withValues(alpha: dark ? 0.12 : 0.06),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.4 : 0.15),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        );

    Widget divider() => Container(
          height: 1,
          width: 28,
          color: scheme.onSurface.withValues(alpha: 0.12),
        );

    final actions = <Widget>[
      if (onMyLocation != null)
        icon(Icons.my_location, 'My location', onMyLocation!),
      if (onSaved != null)
        icon(Icons.bookmark_outline, 'Saved places', onSaved!),
      if (onFriends != null)
        icon(Icons.group_outlined, 'Friends map', onFriends!),
      icon(Icons.layers_outlined, 'Map style', () => _pickLayer(context)),
    ];

    return Positioned(
      right: 12,
      top: top,
      bottom: top == null ? bottom : null,
      // Only guard the edge this stack is actually anchored to. A caller
      // passing `top` has already added the status-bar inset itself, so
      // guarding the top here too would push the controls down twice.
      child: SafeArea(
        top: false,
        bottom: top == null,
        left: false,
        right: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (actions.isNotEmpty)
              cluster([
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) divider(),
                  actions[i],
                ],
              ]),
            // Zoom is its own pair — one control with two ends, not two
            // unrelated buttons that happen to be adjacent.
            cluster([
              icon(Icons.add, 'Zoom in', () => _zoom(1)),
              divider(),
              icon(Icons.remove, 'Zoom out', () => _zoom(-1)),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Names who is drawing the map, at the foot of the style sheet.
///
/// Mapbox and the free servers produce a working map either way, so the only
/// previous way to know which one a build had was to read the build command.
/// Outside release the reason a token didn't take is shown too — the failure
/// modes (missing, secret instead of public, mangled) are indistinguishable on
/// screen, and all three end up looking like "it's still OpenStreetMap".
class _BasemapSourceLine extends StatelessWidget {
  const _BasemapSourceLine();

  @override
  Widget build(BuildContext context) {
    final reason = mapboxEnabled ? '' : mapboxOffReason(kMapboxToken);
    final detail = kReleaseMode || reason.isEmpty ? '' : ' — $reason';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 14),
      child: Row(
        children: [
          Icon(Icons.public,
              size: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Maps by ${basemapSource()}$detail',
              style: TextStyle(
                fontSize: 11.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
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
            // Follows the chosen style, theme, and low-data mode like the
            // full-screen maps do.
            const LiveTileLayer(),
            MarkerLayer(markers: [mapPin(point)]),
          ],
        ),
      ),
    );
  }
}
