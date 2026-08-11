import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../state/weather_service.dart';
import '../theme/app_theme.dart';
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
/// Two things this screen is careful about, both stated on it:
///
///  * the position is **rounded to about 10km** before it is sent
///    ([WeatherService.coarsen]) — a forecast is the same across a town, so
///    the precision buys nothing and giving it away costs something;
///  * the forecast comes from **Open-Meteo**, a third party, which is named
///    rather than hidden behind "the weather".
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
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
      final r = await WeatherService.instance
          .fetch(pos.$1, pos.$2, fahrenheit: _fahrenheit);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _report = r;
        if (r == null) _error = 'The forecast could not be loaded.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'The forecast could not be loaded.';
      });
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
      body: _loading && r == null
          ? const Center(child: CircularProgressIndicator())
          : PullToRefresh(
              onRefresh: _load,
              child: ListView(
                padding:
                    EdgeInsets.only(bottom: HomeNavBar.clearance(context)),
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
                    _Now(report: r),
                    if (r.hours.isNotEmpty) _HourStrip(report: r),
                    if (r.days.isNotEmpty) _WeekList(report: r),
                    _Provenance(timezone: r.timezone),
                  ],
                ],
              ),
            ),
      // Floats over the content like it does on home, rather than sitting in
      // a slot the list stops above (the owner's call). Each list below pads
      // itself by HomeNavBar.clearance so nothing ends underneath it.
      extendBody: true,
      bottomNavigationBar: const HomeNavBar(),
    );
  }
}

class _Now extends StatelessWidget {
  const _Now({required this.report});
  final WeatherReport report;

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
          const SizedBox(height: 12),
          Text(
            'Feels like ${report.feelsLike.round()}${report.unit} · '
            '${report.humidity}% humidity · '
            '${report.wind.round()} ${report.windUnit} wind',
            style: TextStyle(fontSize: 13, color: subtle),
          ),
        ],
      ),
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
  const _Provenance({required this.timezone});
  final String timezone;

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Text(
        'Forecast by Open-Meteo${timezone.isEmpty ? '' : ' · $timezone'}. '
        'Your location is rounded to about 10km before it is sent, so the '
        'request names a town rather than an address.',
        style: TextStyle(fontSize: 12, height: 1.4, color: subtle),
      ),
    );
  }
}
