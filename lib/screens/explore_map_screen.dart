import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../state/recent_searches.dart';
import '../state/saved_places_store.dart';
import '../util/geocoding.dart';
import '../util/geolocation.dart';
import '../utils/maps_link.dart';
import '../widgets/osm_map.dart';
import 'forward_screen.dart';
import 'map_screen.dart';
import 'route_map_screen.dart';

/// Quick "search nearby" categories, à la Apple Maps. The third field is an
/// Overpass tag filter — a *category* lookup (every cafe near here), not a
/// name search.
const List<(IconData, String, String)> _categories = [
  (Icons.restaurant, 'Food', 'amenity~"^(restaurant|fast_food|food_court)\$"'),
  (Icons.local_cafe, 'Coffee', 'amenity~"^(cafe|ice_cream)\$"'),
  (Icons.local_bar, 'Bars', 'amenity~"^(bar|pub|biergarten)\$"'),
  (Icons.local_gas_station, 'Fuel', 'amenity~"^(fuel|charging_station)\$"'),
  (Icons.hotel, 'Hotels', 'tourism~"^(hotel|hostel|motel|guest_house)\$"'),
  (
    Icons.shopping_cart,
    'Shops',
    'shop~"^(supermarket|convenience|mall|department_store)\$"'
  ),
  (Icons.local_atm, 'ATMs', 'amenity~"^(atm|bank)\$"'),
  (Icons.local_parking, 'Parking', 'amenity=parking'),
];

/// A standalone, Apple-Maps-style map: search places or nearby categories, see
/// them on the map, read details with distance, save favourites, and get
/// in-app directions — no external maps needed.
class ExploreMapScreen extends StatefulWidget {
  /// Test/preview hook: a fixed "current location" fix, bypassing real GPS.
  final LatLng? debugMyLocation;

  /// Test hook: replaces the network place search (null = request failed).
  final Future<List<GeoResult>?> Function(String query)? debugSearch;

  const ExploreMapScreen({super.key, this.debugMyLocation, this.debugSearch});

  @override
  State<ExploreMapScreen> createState() => _ExploreMapScreenState();
}

class _ExploreMapScreenState extends State<ExploreMapScreen> {
  final MapController _map = MapController();
  final TextEditingController _search = TextEditingController();
  bool _searching = false;
  List<GeoResult> _results = const [];

  LatLng? _me;
  GeoResult? _selected;
  bool _resolvingPin = false;

  Timer? _locTimer;
  Timer? _debounce;
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    _locate(recenter: true);
    // Keep the "you are here" dot fresh while the map is open.
    _locTimer = Timer.periodic(
        const Duration(seconds: 15), (_) => _locate(recenter: false));
  }

  @override
  void dispose() {
    _locTimer?.cancel();
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// True once the user has panned/zoomed the map themselves, making the
  /// camera centre a meaningful "search here" point.
  bool _mapTouched = false;

  /// True while the suggestion dropdown is dismissed (map tap) — the result
  /// pins stay on the map; typing brings the list back.
  bool _hideSuggestions = false;

  /// True after a submitted search with several hits: they're listed in a
  /// bottom results sheet (Apple-Maps style) instead of the dropdown.
  bool _showResultsSheet = false;

  /// The last submitted query, so "Search this area" can re-run it where the
  /// user has panned to.
  String? _lastQuery;

  /// The last category chip search (label, Overpass filter) — the nearby
  /// counterpart of [_lastQuery] for "Search this area".
  (String, String)? _lastNearby;

  /// True once the user pans away from a search's results — shows the
  /// "Search this area" button.
  bool _showSearchHere = false;

  Future<List<GeoResult>?> _doSearch(String q, {LatLng? biasOverride}) {
    final debug = widget.debugSearch;
    if (debug != null) return debug(q);
    // Bias to where the user actually is — or where they've panned the map
    // to. Never bias to the untouched placeholder centre: that would rank a
    // far-away city's results first for everyone without a GPS fix.
    final LatLng? bias = biasOverride ?? _me ?? (_mapTouched ? _center : null);
    return searchPlaces(q,
        lat: bias?.latitude, lng: bias?.longitude, limit: 12);
  }

  /// Live, Apple-Maps-style suggestions while typing (debounced; stale
  /// responses are discarded).
  void _onQueryChanged(String text) {
    _debounce?.cancel();
    final q = text.trim();
    if (q.isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
        _hideSuggestions = false;
      });
      return;
    }
    // Refresh the clear button and re-show a dismissed suggestion list.
    setState(() => _hideSuggestions = false);
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      if (!mounted) return;
      final seq = ++_searchSeq;
      setState(() => _searching = true);
      final results = await _doSearch(q);
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _searching = false;
        // A failed request (null) keeps the previous suggestions on screen
        // instead of blanking them mid-typing.
        if (results != null) _results = results;
      });
    });
  }

  Future<void> _locate({required bool recenter}) async {
    LatLng? fix = widget.debugMyLocation;
    if (fix == null) {
      final pos = await getCurrentLatLng();
      if (pos != null) fix = LatLng(pos.lat, pos.lng);
    }
    if (!mounted || fix == null) return;
    final first = _me == null;
    final target = fix;
    // The periodic refresh only rebuilds when the dot actually moved —
    // pointless full-map rebuilds every 15 s make panning feel janky.
    if (!first &&
        !recenter &&
        const Distance().distance(_me!, target) < 3) {
      return;
    }
    setState(() => _me = target);
    if (recenter || first) {
      // Defer so the FlutterMap has rendered at least once (initState can
      // reach here synchronously via the debug hook).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _map.move(target, 14);
      });
    }
  }

  LatLng get _center {
    try {
      return _map.camera.center;
    } catch (_) {
      return _me ?? const LatLng(20, 0);
    }
  }

  Future<void> _runSearch({String? term, bool nearCenter = false}) async {
    final q = (term ?? _search.text).trim();
    if (q.isEmpty) return;
    _debounce?.cancel();
    FocusScope.of(context).unfocus();
    final seq = ++_searchSeq;
    setState(() {
      _searching = true;
      _showSearchHere = false;
    });
    final results =
        await _doSearch(q, biasOverride: nearCenter ? _center : null);
    if (!mounted || seq != _searchSeq) return;
    if (results == null) {
      setState(() => _searching = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Search failed — check your connection and try '
                'again.')),
      );
      return;
    }
    // Remember typed queries that found something (not the category chips).
    if (term == null && results.isNotEmpty) RecentSearches.maps.add(q);
    _lastQuery = q;
    _lastNearby = null;
    _showFound(results, 'Nothing found for "$q" nearby.');
  }

  /// A true nearby-category search (every cafe/restaurant/… around [bias])
  /// via Overpass — what the chips run instead of a name search.
  Future<void> _runNearby(String label, String filter,
      {LatLng? biasOverride}) async {
    final bias = biasOverride ?? _me ?? (_mapTouched ? _center : null);
    if (bias == null) return; // callers guard and explain
    _debounce?.cancel();
    FocusScope.of(context).unfocus();
    final seq = ++_searchSeq;
    setState(() {
      _searching = true;
      _showSearchHere = false;
      _search.text = label;
    });
    final debug = widget.debugSearch;
    final results = debug != null
        ? await debug(label.toLowerCase())
        : await searchNearby(
            filter: filter, lat: bias.latitude, lng: bias.longitude);
    if (!mounted || seq != _searchSeq) return;
    if (results == null) {
      setState(() => _searching = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Search failed — check your connection and try '
                'again.')),
      );
      return;
    }
    _lastQuery = null;
    _lastNearby = (label, filter);
    _showFound(results, 'No ${label.toLowerCase()} found nearby.');
  }

  /// Shared landing for search results: sheet/card state, camera framing,
  /// and the empty-result message.
  void _showFound(List<GeoResult> results, String emptyMessage) {
    setState(() {
      _searching = false;
      _results = results;
      // Several hits go to the bottom results sheet, not the dropdown.
      _hideSuggestions = results.length > 1;
      _showResultsSheet = results.length > 1;
      _selected = results.length == 1 ? results.first : null;
    });
    if (results.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(emptyMessage)),
      );
    } else if (results.length == 1) {
      _map.move(LatLng(results.first.lat, results.first.lng), 15);
    } else {
      // Frame every result pin at once, Apple-Maps style.
      _map.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(
              [for (final r in results) LatLng(r.lat, r.lng)]),
          padding: const EdgeInsets.fromLTRB(50, 140, 50, 120),
        ),
      );
    }
  }

  void _select(GeoResult r) {
    FocusScope.of(context).unfocus();
    _debounce?.cancel();
    ++_searchSeq; // discard any in-flight suggestion fetch
    // Picking a suggestion is the common path now — remember it.
    RecentSearches.maps.add(r.name.split(',').first.trim());
    setState(() {
      _selected = r;
      _search.text = r.name;
      // Picks from the results sheet keep the other pins (and the sheet
      // comes back when the place card is closed); dropdown picks clear.
      if (!_showResultsSheet) _results = const [];
      _searching = false;
      _showSearchHere = false;
    });
    _map.move(LatLng(r.lat, r.lng), 16);
  }

  Future<void> _dropPin(LatLng point) async {
    setState(() {
      _selected = GeoResult(name: '', lat: point.latitude, lng: point.longitude);
      _resolvingPin = true;
      _results = const [];
      _showResultsSheet = false;
    });
    final place = await reverseGeocode(point.latitude, point.longitude);
    if (!mounted) return;
    setState(() {
      _resolvingPin = false;
      _selected = place ??
          GeoResult(
            name: '${point.latitude.toStringAsFixed(5)}, '
                '${point.longitude.toStringAsFixed(5)}',
            lat: point.latitude,
            lng: point.longitude,
          );
    });
  }

  Future<void> _goToMe() async {
    LatLng? fix = widget.debugMyLocation;
    if (fix == null) {
      final pos = await getCurrentLatLng();
      if (pos != null) fix = LatLng(pos.lat, pos.lng);
    }
    if (!mounted) return;
    if (fix == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 5),
          content: Text(
            'Couldn\'t get your location. Allow location access for this '
            'site in your browser settings, then try again.',
          ),
        ),
      );
      return;
    }
    setState(() => _me = fix);
    _map.move(fix, 15);
  }

  void _directions() {
    final s = _selected;
    if (s == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RouteMapScreen(
          dest: LatLng(s.lat, s.lng),
          from: _me,
          label: s.name.isEmpty ? 'Directions' : s.name,
        ),
      ),
    );
  }

  void _sendToChat() {
    final s = _selected;
    if (s == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ForwardScreen(
          text: '',
          place: (
            lat: s.lat,
            lng: s.lng,
            label: s.name.isEmpty ? 'Shared location' : s.name,
          ),
        ),
      ),
    );
  }

  void _share() {
    final s = _selected;
    if (s == null) return;
    final isApple = Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.macOS;
    final uri =
        mapsUrl(lat: s.lat, lng: s.lng, label: s.name, apple: isApple);
    Clipboard.setData(ClipboardData(text: uri.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Place link copied to clipboard')),
    );
  }

  void _showSaved() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListenableBuilder(
          listenable: SavedPlacesStore.instance,
          builder: (context, _) {
            final places = SavedPlacesStore.instance.places;
            if (places.isEmpty) {
              return const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 28),
                child: Text('No saved places yet. Tap the star on a place to '
                    'save it here.'),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final p in places)
                  ListTile(
                    leading: const Icon(Icons.bookmark, color: Color(0xFFEB4B3F)),
                    title: Text(p.name, maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => SavedPlacesStore.instance.remove(p),
                    ),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _select(GeoResult(name: p.name, lat: p.lat, lng: p.lng));
                    },
                  ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    // Full-bleed, Apple-Maps-style: the map fills the screen and every
    // control floats over it.
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      extendBodyBehindAppBar: true,
      // The map must not squish (and reload tiles) every time the keyboard
      // opens — search UI floats over it instead, like Apple Maps.
      resizeToAvoidBottomInset: false,
      // Hidden while a place card or the results sheet is up — it would sit
      // right on top of them.
      floatingActionButton: selected == null && !_showResultsSheet
          ? FloatingActionButton.small(
              heroTag: 'exploreMe',
              onPressed: _goToMe,
              tooltip: 'My location',
              child: const Icon(Icons.my_location),
            )
          : null,
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              // Without a GPS fix, an honest world view beats pretending
              // everyone is in San Francisco; we fly to the fix on arrival.
              initialCenter: _me ?? const LatLng(20, 0),
              initialZoom: _me == null ? 2.2 : 13,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onPositionChanged: (camera, hasGesture) {
                if (!hasGesture) return;
                _mapTouched = true;
                // Panning away from a search's results offers to re-run it
                // around the new spot, Apple-Maps style.
                if (_results.isNotEmpty &&
                    (_lastQuery != null || _lastNearby != null) &&
                    !_showSearchHere) {
                  setState(() => _showSearchHere = true);
                }
              },
              onTap: (_, __) {
                // Tapping the map puts the map first: drop the keyboard and
                // tuck the suggestion list away (pins stay).
                FocusScope.of(context).unfocus();
                if (_results.isNotEmpty && !_hideSuggestions) {
                  setState(() => _hideSuggestions = true);
                }
              },
              onLongPress: (_, point) => _dropPin(point),
            ),
            children: [
              const LiveTileLayer(),
              MarkerLayer(
                markers: [
                  if (_me != null) myLocationMarker(_me!),
                  for (final r in _results)
                    Marker(
                      point: LatLng(r.lat, r.lng),
                      width: 30,
                      height: 30,
                      child: GestureDetector(
                        onTap: () => _select(r),
                        child: const Icon(Icons.place,
                            color: Color(0xFF0A84FF), size: 30),
                      ),
                    ),
                  if (selected != null)
                    mapPin(LatLng(selected.lat, selected.lng)),
                ],
              ),
              Scalebar(
                alignment: Alignment.bottomLeft,
                padding: const EdgeInsets.fromLTRB(10, 0, 0, 14),
                textStyle: TextStyle(
                  color: dark ? Colors.white70 : Colors.black87,
                  fontSize: 12,
                ),
                lineColor: dark ? Colors.white70 : Colors.black87,
              ),
              const LiveAttribution(),
            ],
          ),
          MapControls(
            controller: _map,
            bottom: selected != null
                ? 220
                : _showResultsSheet && _results.length > 1
                    ? 340
                    : 96,
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _CircleButton(
                        icon: Icons.arrow_back,
                        tooltip: 'Back',
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _SearchBox(
                          controller: _search,
                          searching: _searching,
                          // Hide the suggestion list once a place is selected
                          // (its card is showing) or the user tapped the map;
                          // the result pins stay either way.
                          results: selected == null && !_hideSuggestions
                              ? _results
                              : const <GeoResult>[],
                          origin: _me,
                          onSubmit: () => _runSearch(),
                          onPick: _select,
                          onChanged: _onQueryChanged,
                          onClear: () {
                            _debounce?.cancel();
                            ++_searchSeq;
                            _search.clear();
                            setState(() {
                              _results = const [];
                              _selected = null;
                              _searching = false;
                              _hideSuggestions = false;
                              _showResultsSheet = false;
                              _showSearchHere = false;
                              _lastQuery = null;
                              _lastNearby = null;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  if (_results.isEmpty && selected == null) ...[
                    const SizedBox(height: 10),
                    _CategoryChips(
                      onTap: (label, filter) {
                        // Nearby search needs a "near" — a GPS fix or a spot
                        // the user has panned to. Without one the results
                        // would be random places around the globe.
                        if (_me == null && !_mapTouched) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Move the map to an area first — '
                                  'or tap the location button — so nearby '
                                  'search knows where to look.'),
                            ),
                          );
                          return;
                        }
                        _runNearby(label, filter);
                      },
                      onSaved: _showSaved,
                      onFriends: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const MapScreen()),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _RecentMapSearches(onPick: (q) {
                      _search.text = q;
                      _runSearch();
                    }),
                  ],
                  if (_showSearchHere &&
                      selected == null &&
                      _results.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Center(
                      child: FilledButton.tonalIcon(
                        onPressed: () {
                          final nearby = _lastNearby;
                          if (nearby != null) {
                            _runNearby(nearby.$1, nearby.$2,
                                biasOverride: _center);
                          } else {
                            _runSearch(term: _lastQuery, nearCenter: true);
                          }
                        },
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Search this area'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_showResultsSheet && selected == null && _results.length > 1)
            _resultsSheet(context),
          if (selected != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 20,
              child: SafeArea(child: _placeCard(context, selected)),
            ),
        ],
      ),
    );
  }

  /// "Cafe · 350 m" meta line for a results-sheet row.
  String? _placeMeta(GeoResult r) {
    final parts = <String>[];
    if (r.category.isNotEmpty) parts.add(r.category);
    final me = _me;
    if (me != null) {
      parts.add(formatDistance(
          const Distance().distance(me, LatLng(r.lat, r.lng))));
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// The Apple-Maps-style bottom sheet listing a submitted search's results.
  Widget _resultsSheet(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Material(
          elevation: 12,
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_results.length} places',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Close results',
                      onPressed: () => setState(() {
                        _showResultsSheet = false;
                        _results = const [];
                        _search.clear();
                      }),
                    ),
                  ],
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 236),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: _results.length,
                  itemBuilder: (context, i) {
                    final r = _results[i];
                    final meta = _placeMeta(r);
                    return ListTile(
                      leading: Icon(iconForPlaceCategory(r.category)),
                      title: Text(r.name.split(',').first.trim(),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: meta == null ? null : Text(meta),
                      onTap: () => _select(r),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeCard(BuildContext context, GeoResult place) {
    final meta = <String>[];
    if (_me != null) {
      final d = const Distance()
          .distance(_me!, LatLng(place.lat, place.lng));
      meta.add('${formatDistance(d)} away');
    }
    if (place.category.isNotEmpty) meta.add(place.category);
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor:
                  Theme.of(context).colorScheme.primaryContainer,
              child: Icon(
                iconForPlaceCategory(place.category),
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _resolvingPin
                        ? 'Dropped pin…'
                        : (place.name.isEmpty ? 'Dropped pin' : place.name),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(meta.join(' · '),
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _directions,
                        icon: const Icon(Icons.directions, size: 18),
                        label: const Text('Directions'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _sendToChat,
                        icon: const Icon(Icons.chat_bubble_outline, size: 16),
                        label: const Text('Send'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _share,
                        icon: const Icon(Icons.ios_share, size: 16),
                        label: const Text('Share'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              children: [
                ListenableBuilder(
                  listenable: SavedPlacesStore.instance,
                  builder: (context, _) {
                    final saved =
                        SavedPlacesStore.instance.isSaved(place.lat, place.lng);
                    return IconButton(
                      icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border,
                          color: saved ? const Color(0xFFEB4B3F) : null),
                      tooltip: saved ? 'Saved' : 'Save',
                      onPressed: () {
                        final now = SavedPlacesStore.instance.toggle(SavedPlace(
                            place.name.isEmpty ? 'Dropped pin' : place.name,
                            place.lat,
                            place.lng));
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(now ? 'Saved' : 'Removed'),
                          duration: const Duration(seconds: 1),
                        ));
                      },
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Clear',
                  onPressed: () => setState(() => _selected = null),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A floating circular surface button (back, etc.) matching the search pill.
class _CircleButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _CircleButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 3,
      shape: const CircleBorder(),
      color: Theme.of(context).colorScheme.surface,
      child: IconButton(icon: Icon(icon), tooltip: tooltip, onPressed: onTap),
    );
  }
}

/// The user's recent map searches, shown while the map is idle.
class _RecentMapSearches extends StatelessWidget {
  final ValueChanged<String> onPick;
  const _RecentMapSearches({required this.onPick});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: RecentSearches.maps,
      builder: (context, _) {
        final queries = RecentSearches.maps.queries.take(5).toList();
        if (queries.isEmpty) return const SizedBox.shrink();
        return Material(
          elevation: 2,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          color: Theme.of(context)
              .colorScheme
              .surface
              .withValues(alpha: 0.95),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final q in queries)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.history, size: 20),
                  title: Text(q,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => RecentSearches.maps.remove(q),
                  ),
                  onTap: () => onPick(q),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A horizontal row of chips: Saved places and Friends first, then the
/// "search nearby" categories.
class _CategoryChips extends StatelessWidget {
  final void Function(String label, String filter) onTap;
  final VoidCallback onSaved;
  final VoidCallback onFriends;

  const _CategoryChips({
    required this.onTap,
    required this.onSaved,
    required this.onFriends,
  });

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    ActionChip chip(IconData icon, String label, VoidCallback onPressed) =>
        ActionChip(
          avatar: Icon(icon, size: 18),
          label: Text(label),
          elevation: 2,
          backgroundColor: surface,
          shadowColor: Colors.black45,
          onPressed: onPressed,
        );
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _categories.length + 2,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          if (i == 0) return chip(Icons.bookmark, 'Saved', onSaved);
          if (i == 1) return chip(Icons.group, 'Friends', onFriends);
          final (icon, label, filter) = _categories[i - 2];
          return chip(icon, label, () => onTap(label, filter));
        },
      ),
    );
  }
}

/// A rounded search field with a dropdown of geocoded place results.
class _SearchBox extends StatelessWidget {
  final TextEditingController controller;
  final bool searching;
  final List<GeoResult> results;
  final LatLng? origin;
  final VoidCallback onSubmit;
  final ValueChanged<GeoResult> onPick;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;

  const _SearchBox({
    required this.controller,
    required this.searching,
    required this.results,
    required this.onSubmit,
    required this.onPick,
    this.origin,
    this.onChanged,
    this.onClear,
  });

  /// "Cafe · 350 m" style meta line for a result row.
  String? _meta(GeoResult r) {
    final parts = <String>[];
    if (r.category.isNotEmpty) parts.add(r.category);
    final o = origin;
    if (o != null) {
      parts.add(formatDistance(
          const Distance().distance(o, LatLng(r.lat, r.lng))));
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          elevation: 3,
          borderRadius: BorderRadius.circular(28),
          child: TextField(
            controller: controller,
            textInputAction: TextInputAction.search,
            onChanged: onChanged,
            onSubmitted: (_) => onSubmit(),
            decoration: InputDecoration(
              hintText: 'Search Maps',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : controller.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Clear search',
                          onPressed: onClear,
                        )
                      : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surface,
              contentPadding: const EdgeInsets.symmetric(vertical: 4),
            ),
          ),
        ),
        if (results.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 6),
            constraints: const BoxConstraints(maxHeight: 300),
            child: Material(
              elevation: 3,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: results.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final r = results[i];
                  final meta = _meta(r);
                  return ListTile(
                    dense: true,
                    leading: Icon(iconForPlaceCategory(r.category)),
                    title: Text(r.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: meta == null ? null : Text(meta),
                    onTap: () => onPick(r),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}
