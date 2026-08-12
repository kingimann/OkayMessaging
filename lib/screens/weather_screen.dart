import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../state/weather_cities_store.dart';
import '../state/weather_service.dart';
import '../theme/app_theme.dart';
import '../util/geocoding.dart' show GeoResult, searchPlaces;
import '../widgets/pull_to_refresh.dart';
import 'home_screen.dart' show HomeNavBar;

/// Material icons by the name [weatherIconName] returns. Kept here rather
/// than in the service so that file stays pure data and can be tested
/// without Flutter.
IconData weatherIcon(int code, {bool isDay = true}) =>
    switch (weatherIconName(code, isDay: isDay)) {
      'sunny' => Icons.wb_sunny_outlined,
      'clear_night' => Icons.nightlight_outlined,
      'partly_cloudy_day' => Icons.wb_cloudy_outlined,
      'partly_cloudy_night' => Icons.nights_stay_outlined,
      'foggy' => Icons.foggy,
      'grain' => Icons.grain,
      'rainy' => Icons.water_drop_outlined,
      'ac_unit' => Icons.ac_unit,
      'thunderstorm' => Icons.thunderstorm_outlined,
      _ => Icons.cloud_outlined,
    };

/// The weather, for wherever this phone is.
///
/// Three things this screen is careful about, all stated on it:
///
///  * the position is **rounded to about 10km** before it is sent
///    ([WeatherService.coarsen]) — a forecast is the same across a town, so
///    the precision buys nothing and giving it away costs something;
///  * the forecast comes from **Open-Meteo**, a third party, which is named
///    rather than hidden behind "the weather";
///  * the CITY NAME shown is reverse-geocoded from that same rounded point
///    ([WeatherService.cityFor]), never the raw fix — naming a town costs
///    nothing beyond what the forecast request already sends, and it is
///    still a town, never a street or address (see [localityLabel]).
class WeatherScreen extends StatefulWidget {
  const WeatherScreen({super.key, this.fromSidebar = false});

  final bool fromSidebar;

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen> {
  WeatherReport? _report;
  bool _loading = true;
  String _error = '';
  bool _fahrenheit = false;
  String? _city;

  /// Which tab is showing: 0 is the device's own location; N is
  /// `WeatherCitiesStore.instance.cities[N - 1]`. Kept as an index rather
  /// than a [WeatherCity] so a removed city just falls back to 0 instead of
  /// pointing at something that no longer exists.
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    WeatherCitiesStore.instance.load();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      double lat, lon;
      String? knownLabel;
      if (_selected == 0) {
        final pos = await _position();
        if (pos == null) {
          if (mounted) {
            setState(() {
              _loading = false;
              _error = 'Location is off, so there is nowhere to forecast. '
                  'Turn it on in Settings to see your weather.';
            });
          }
          return;
        }
        lat = pos.$1;
        lon = pos.$2;
      } else {
        final cities = WeatherCitiesStore.instance.cities;
        final idx = _selected - 1;
        if (idx < 0 || idx >= cities.length) {
          // The city behind this tab is gone — removed from this screen or
          // another instance of it. Falling back to the device's own
          // location beats fetching a forecast for a place that no longer
          // exists in the list above it.
          _selected = 0;
          return _load();
        }
        final city = cities[idx];
        lat = city.lat;
        lon = city.lng;
        knownLabel = city.label;
      }
      final r = await WeatherService.instance
          .fetch(lat, lon, fahrenheit: _fahrenheit);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _report = r;
        _city = knownLabel;
        if (r == null) _error = 'The forecast could not be loaded.';
      });
      if (knownLabel == null) {
        // Best-effort, off the same rounded point, and never blocks the
        // forecast above — a reverse-geocode failure is a missing name, not
        // a missing weather screen. Only the device's own location needs
        // this: an added city already carries the name it was searched
        // for.
        final city = await WeatherService.instance.cityFor(lat, lon);
        if (mounted && city != null) setState(() => _city = city);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'The forecast could not be loaded.';
      });
    }
  }

  void _select(int index) {
    if (index == _selected) return;
    setState(() => _selected = index);
    _load();
  }

  Future<void> _addCity() async {
    final picked = await Navigator.of(context).push<GeoResult>(
      MaterialPageRoute(builder: (_) => const _AddCityScreen()),
    );
    if (picked == null || !mounted) return;
    final store = WeatherCitiesStore.instance;
    final city = WeatherCity(label: picked.name, lat: picked.lat, lng: picked.lng);
    final alreadyThere = store.contains(city);
    if (!store.add(city)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(alreadyThere
            ? '${city.label} is already added.'
            : 'You can track up to ${WeatherCitiesStore.maxCities} cities.'),
      ));
      return;
    }
    setState(() => _selected = store.cities.length);
    _load();
  }

  Future<void> _removeCity(WeatherCity city) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${city.label}?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final removedIndex =
        WeatherCitiesStore.instance.cities.indexWhere((c) => c.key == city.key);
    WeatherCitiesStore.instance.remove(city);
    if (removedIndex < 0) return;
    if (_selected == removedIndex + 1) {
      // The tab on screen was the one removed.
      setState(() => _selected = 0);
      _load();
    } else if (_selected > removedIndex + 1) {
      // A city before the selected one shifted left — follow it so the
      // forecast on screen doesn't silently jump to a neighbour.
      setState(() => _selected -= 1);
    }
  }

  /// The device's position, or null when it cannot be had. Deliberately
  /// quiet about WHY beyond permission: a forecast screen is not the place
  /// to explain location services.
  Future<(double, double)?> _position() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      final p = await Geolocator.getCurrentPosition()
          .timeout(const Duration(seconds: 12));
      return (p.latitude, p.longitude);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Weather'),
        actions: [
          TextButton(
            onPressed: () {
              setState(() => _fahrenheit = !_fahrenheit);
              _load();
            },
            child: Text(_fahrenheit ? '°F' : '°C',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: Column(
        children: [
          _CityTabs(
            selected: _selected,
            onSelect: _select,
            onAdd: _addCity,
            onRemove: _removeCity,
          ),
          Expanded(
            child: _loading && r == null
                ? const Center(child: CircularProgressIndicator())
                : PullToRefresh(
                    onRefresh: _load,
                    child: ListView(
                      padding: EdgeInsets.only(
                          bottom: HomeNavBar.clearance(context)),
                      children: [
                        if (_error.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 40, 20, 0),
                            child: Column(
                              children: [
                                Icon(Icons.cloud_off,
                                    size: 44, color: Colors.grey.shade400),
                                const SizedBox(height: 12),
                                Text(_error,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: AppColors.subtle(context))),
                              ],
                            ),
                          ),
                        if (r != null) ...[
                          _Now(report: r, city: _city),
                          if (r.hours.isNotEmpty) _HourStrip(report: r),
                          if (r.days.isNotEmpty) _WeekList(report: r),
                          _Provenance(
                            timezone: r.timezone,
                            city: _city,
                            ownLocation: _selected == 0,
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
      // Floats over the content like it does on home, rather than sitting in
      // a slot the list stops above (the owner's call). Each list below pads
      // itself by HomeNavBar.clearance so nothing ends underneath it.
      extendBody: true,
      bottomNavigationBar: const HomeNavBar(),
    );
  }
}

/// The row of tabs across the top: the device's own location, then every
/// saved [WeatherCity], then a way to add another. Rebuilds off
/// [WeatherCitiesStore] directly (via [ListenableBuilder]) rather than
/// threading the list through [_WeatherScreenState]'s own state, so adding
/// or removing a city updates this strip the moment the store changes.
class _CityTabs extends StatelessWidget {
  const _CityTabs({
    required this.selected,
    required this.onSelect,
    required this.onAdd,
    required this.onRemove,
  });

  final int selected;
  final ValueChanged<int> onSelect;
  final VoidCallback onAdd;
  final ValueChanged<WeatherCity> onRemove;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: WeatherCitiesStore.instance,
      builder: (context, _) {
        final cities = WeatherCitiesStore.instance.cities;
        return SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: const Text('My location'),
                  selected: selected == 0,
                  onSelected: (_) => onSelect(0),
                ),
              ),
              for (var i = 0; i < cities.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    // Removing needs a deliberate, separate gesture — a
                    // short tap only ever switches, never deletes, so a
                    // fumbled tap can't lose a saved city.
                    onLongPress: () => onRemove(cities[i]),
                    child: ChoiceChip(
                      // The first comma-separated part only ("Paris" rather
                      // than "Paris, France") — a full label is provenance
                      // text below, not something five tabs have room for.
                      label: Text(cities[i].label.split(',').first),
                      selected: selected == i + 1,
                      onSelected: (_) => onSelect(i + 1),
                    ),
                  ),
                ),
              if (cities.length < WeatherCitiesStore.maxCities)
                IconButton(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add_circle_outline),
                  tooltip: 'Add a city',
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A minimal search-and-pick screen for adding a city to the tab strip
/// above — deliberately smaller than [ShareLocationScreen]: no current
/// location, no saved places, no map fallback, because this is choosing
/// WHICH city to track rather than where the phone is right now. Pops with
/// the chosen [GeoResult], or null if the person backs out.
class _AddCityScreen extends StatefulWidget {
  const _AddCityScreen();

  @override
  State<_AddCityScreen> createState() => _AddCityScreenState();
}

class _AddCityScreenState extends State<_AddCityScreen> {
  final _search = TextEditingController();
  String _query = '';
  bool _searching = false;
  List<GeoResult> _results = const [];

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String raw) async {
    final q = raw.trim();
    setState(() => _query = q);
    if (q.isEmpty) {
      setState(() => _results = const []);
      return;
    }
    setState(() => _searching = true);
    final res = await searchPlaces(q);
    // Ignore a stale answer: the box has moved on since this went out.
    if (!mounted || _query != q) return;
    setState(() {
      _searching = false;
      if (res != null) _results = res;
    });
  }

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Add a city')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _search,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: (v) {
                if (v.trim().isEmpty) _runSearch('');
              },
              onSubmitted: _runSearch,
              decoration: InputDecoration(
                hintText: 'Search for a city',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_searching)
            const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            )
          else if (_query.isNotEmpty && _results.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('No matches for "$_query"',
                  style: TextStyle(color: subtle)),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, i) {
                final r = _results[i];
                return ListTile(
                  leading: const Icon(Icons.location_city_outlined),
                  title: Text(r.name),
                  onTap: () => Navigator.of(context).pop(r),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Now extends StatelessWidget {
  const _Now({required this.report, this.city});
  final WeatherReport report;
  final String? city;

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (city != null) ...[
            Row(
              children: [
                Icon(Icons.location_on_outlined, size: 15, color: subtle),
                const SizedBox(width: 4),
                Text(city!,
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600, color: subtle)),
              ],
            ),
            const SizedBox(height: 6),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(weatherIcon(report.code, isDay: report.isDay), size: 52),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${report.temp.round()}${report.unit}',
                      style: const TextStyle(
                          fontSize: 44,
                          fontWeight: FontWeight.w300,
                          height: 1.0)),
                  const SizedBox(height: 4),
                  Text(report.label,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          _DetailGrid(report: report),
        ],
      ),
    );
  }
}

/// Every number the "Feels like … humidity … wind" line used to squeeze onto
/// one line — now its own row of short chips, so wind direction, UV and
/// sunrise/sunset all fit without a line that scrolls off a narrow phone.
class _DetailGrid extends StatelessWidget {
  const _DetailGrid({required this.report});
  final WeatherReport report;

  static String _clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m${t.hour < 12 ? 'am' : 'pm'}';
  }

  @override
  Widget build(BuildContext context) {
    final today = report.today;
    final windDir = windDirectionLabel(report.windDirection);
    final uv = today == null ? '' : uvLabel(today.uvMax);
    final items = <(IconData, String)>[
      (Icons.thermostat_outlined,
          'Feels like ${report.feelsLike.round()}${report.unit}'),
      (Icons.water_drop_outlined, '${report.humidity}% humidity'),
      (
        Icons.air,
        '${report.wind.round()} ${report.windUnit}'
            '${windDir.isEmpty ? '' : ' $windDir'} wind',
      ),
      if (report.precipitation > 0)
        (
          Icons.umbrella_outlined,
          '${report.precipitation.toStringAsFixed(report.precipitation < 10 ? 1 : 0)}'
              '${report.precipUnit} precipitation',
        ),
      if (uv.isNotEmpty)
        (Icons.wb_sunny_outlined, 'UV ${today!.uvMax.round()} ($uv)'),
      if (today?.sunrise != null)
        (Icons.wb_twilight, 'Sunrise ${_clock(today!.sunrise!)}'),
      if (today?.sunset != null)
        (Icons.nights_stay_outlined, 'Sunset ${_clock(today!.sunset!)}'),
    ];
    final subtle = AppColors.subtle(context);
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        for (final (icon, text) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: subtle),
              const SizedBox(width: 4),
              Text(text, style: TextStyle(fontSize: 13, color: subtle)),
            ],
          ),
      ],
    );
  }
}

class _HourStrip extends StatelessWidget {
  const _HourStrip({required this.report});
  final WeatherReport report;

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    final hours = report.nextHours(
        DateTime.now().subtract(const Duration(minutes: 30)));
    if (hours.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 108,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        itemCount: hours.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (context, i) {
          final h = hours[i];
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_hourLabel(h.time),
                  style: TextStyle(fontSize: 12, color: subtle)),
              const SizedBox(height: 6),
              Icon(weatherIcon(h.code, isDay: _daylight(h.time)), size: 22),
              const SizedBox(height: 6),
              Text('${h.temp.round()}°',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              if (h.rainChance > 0) ...[
                const SizedBox(height: 3),
                Text('${h.rainChance}%',
                    style: TextStyle(fontSize: 11, color: subtle)),
              ],
            ],
          );
        },
      ),
    );
  }

  static bool _daylight(DateTime t) => t.hour >= 6 && t.hour < 20;

  static String _hourLabel(DateTime t) {
    final now = DateTime.now();
    if (t.hour == now.hour && t.day == now.day) return 'Now';
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h${t.hour < 12 ? 'am' : 'pm'}';
  }
}

class _WeekList extends StatelessWidget {
  const _WeekList({required this.report});
  final WeatherReport report;

  static const _days = [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun', //
  ];

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    final today = DateTime.now();
    return Column(
      children: [
        const Divider(height: 20),
        for (final d in report.days)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 7, 20, 7),
            child: Row(
              children: [
                SizedBox(
                  width: 46,
                  child: Text(
                    d.date.day == today.day && d.date.month == today.month
                        ? 'Today'
                        : _days[(d.date.weekday - 1) % 7],
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                Icon(weatherIcon(d.code), size: 20),
                const SizedBox(width: 8),
                if (d.rainChance > 0)
                  Text('${d.rainChance}%',
                      style: TextStyle(fontSize: 12, color: subtle)),
                const Spacer(),
                Text('${d.low.round()}°',
                    style: TextStyle(fontSize: 14, color: subtle)),
                const SizedBox(width: 12),
                SizedBox(
                  width: 34,
                  child: Text('${d.high.round()}°',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Where the numbers came from and what was sent to get them. Not fine
/// print: the whole reason the feature is acceptable in a privacy-first app
/// is the rounding, and a promise nobody is shown is not a promise.
class _Provenance extends StatelessWidget {
  const _Provenance({
    required this.timezone,
    this.city,
    required this.ownLocation,
  });
  final String timezone;
  final String? city;

  /// Whether this forecast is for the device's own position — the ONLY
  /// case the rounding story below applies to. A searched-and-added city
  /// carries no device fix to protect in the first place, so claiming its
  /// coordinates were rounded would be a promise this screen never made.
  final bool ownLocation;

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    final text = ownLocation
        ? 'Forecast by Open-Meteo${timezone.isEmpty ? '' : ' · $timezone'}. '
            'Your location is rounded to about 10km before it is sent, so '
            'the request names a town rather than an address'
            '${city == null ? '' : ' — the same rounded point names "$city" '
                'below, via a second, separate lookup (Photon/OpenStreetMap)'}.'
        : 'Forecast by Open-Meteo${timezone.isEmpty ? '' : ' · $timezone'} '
            'for ${city ?? 'this city'} — a place you searched for and '
            'added, not this device\'s location, so nothing about it needs '
            'rounding.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Text(text, style: TextStyle(fontSize: 12, height: 1.4, color: subtle)),
    );
  }
}
