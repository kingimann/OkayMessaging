import 'package:flutter/material.dart';

import '../state/saved_places_store.dart';
import '../theme/app_theme.dart';
import '../util/geocoding.dart';
import '../util/geolocation.dart';
import 'explore_map_screen.dart';

/// A dedicated place-picker for sharing a location in chat — deliberately NOT
/// the full Maps map. Sharing where you are is a list, not an exploration: your
/// current location up top, a search box, your saved places, and — only for the
/// rare "somewhere with no address" case — a way onto the map to drop a pin.
///
/// Pops with the chosen [GeoResult], which the chat turns into a location
/// message.
class ShareLocationScreen extends StatefulWidget {
  const ShareLocationScreen({super.key});

  @override
  State<ShareLocationScreen> createState() => _ShareLocationScreenState();
}

class _ShareLocationScreenState extends State<ShareLocationScreen> {
  final _search = TextEditingController();

  double? _lat;
  double? _lng;
  String _address = '';
  bool _locating = true;

  String _query = '';
  bool _searchingNet = false;
  List<GeoResult> _results = const [];

  @override
  void initState() {
    super.initState();
    _resolveCurrent();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Best-effort: get a fix, then reverse-geocode it for a friendly address.
  /// The fix alone is enough to send; the address is a nicety on top.
  Future<void> _resolveCurrent() async {
    final pos = await getCurrentLatLng();
    if (!mounted) return;
    setState(() {
      _lat = pos?.lat;
      _lng = pos?.lng;
      _locating = false;
    });
    if (pos == null) return;
    final place = await reverseGeocode(pos.lat, pos.lng);
    if (!mounted) return;
    setState(() => _address = place?.name ?? '');
  }

  void _sendResult(GeoResult r) => Navigator.of(context).pop(r);

  Future<void> _sendCurrent() async {
    var lat = _lat, lng = _lng;
    if (lat == null || lng == null) {
      final pos = await getCurrentLatLng();
      lat = pos?.lat;
      lng = pos?.lng;
    }
    if (!mounted) return;
    if (lat == null || lng == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Turn on location access to share where you are.')));
      return;
    }
    _sendResult(GeoResult(
        name: _address.isNotEmpty ? _address : 'My location',
        lat: lat,
        lng: lng));
  }

  Future<void> _runSearch(String raw) async {
    final q = raw.trim();
    setState(() => _query = q);
    if (q.isEmpty) {
      setState(() => _results = const []);
      return;
    }
    setState(() => _searchingNet = true);
    final res = await searchPlaces(q, lat: _lat, lng: _lng);
    // Ignore a stale response: the box has moved on since this went out.
    if (!mounted || _query != q) return;
    setState(() {
      _searchingNet = false;
      if (res != null) _results = res;
    });
  }

  Future<void> _chooseOnMap() async {
    final picked = await Navigator.of(context).push<GeoResult>(
      MaterialPageRoute(builder: (_) => const ExploreMapScreen(picking: true)),
    );
    if (picked != null && mounted) _sendResult(picked);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final places = SavedPlacesStore.instance.places;
    final searching = _query.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Share location')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onChanged: (v) {
                if (v.trim().isEmpty) _runSearch('');
              },
              onSubmitted: _runSearch,
              decoration: InputDecoration(
                hintText: 'Search for a place or address',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _search.clear();
                          _runSearch('');
                        },
                      ),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          // Current location — the primary way to share where you are.
          ListTile(
            leading: CircleAvatar(
              backgroundColor: scheme.primary,
              child: Icon(Icons.my_location, color: scheme.onPrimary, size: 20),
            ),
            title: const Text('Send your current location',
                style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(_locating
                ? 'Finding you…'
                : _lat == null
                    ? 'Location off — tap to try again'
                    : (_address.isNotEmpty
                        ? _address
                        : 'Using your current position')),
            onTap: _sendCurrent,
          ),

          if (searching) ...[
            const _SectionLabel('SEARCH RESULTS'),
            if (_searchingNet && _results.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_results.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Text('No places found for "$_query".',
                    style: TextStyle(color: AppColors.subtle(context))),
              )
            else
              for (final r in _results)
                ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(r.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: r.category.isEmpty ? null : Text(r.category),
                  onTap: () => _sendResult(r),
                ),
          ] else ...[
            if (places.isNotEmpty) ...[
              const _SectionLabel('SAVED PLACES'),
              for (final p in places)
                ListTile(
                  leading: const Icon(Icons.bookmark_outline),
                  title: Text(p.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => _sendResult(
                      GeoResult(name: p.name, lat: p.lat, lng: p.lng)),
                ),
            ],
            const Divider(height: 8),
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: const Text('Choose on the map'),
              subtitle: const Text('Drop a pin anywhere'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _chooseOnMap,
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: AppColors.subtle(context))),
      );
}
