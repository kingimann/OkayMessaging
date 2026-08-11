import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Weather, from Open-Meteo.
///
/// **No API key, deliberately.** Open-Meteo serves forecasts to anonymous
/// callers, which matters here for a reason beyond convenience: a keyed
/// provider means a secret in the binary or another Edge Function to keep
/// running, and neither buys anything a public forecast endpoint doesn't
/// already give.
///
/// **The location is rounded before it leaves the device** — see
/// [coarsen]. Weather is the same across a city, so nothing is lost, and the
/// request cannot pinpoint whoever made it. This is the whole privacy story
/// of the feature and the screen says it out loud.
///
/// Everything except [fetch] is pure, so the parsing, the code table and the
/// rounding are provable without a network.
class WeatherService {
  WeatherService._();
  static final WeatherService instance = WeatherService._();

  /// How coarse a position gets before it is sent: 0.1° is roughly 11km
  /// north-south, and less east-west the further from the equator. Big
  /// enough that the answer names a town rather than a street; small enough
  /// that the forecast is still yours.
  static const double gridDegrees = 0.1;

  /// Rounds a position to the [gridDegrees] grid.
  ///
  /// Pure, and the one place the rule lives — a caller that reached for the
  /// raw fix would quietly undo the only privacy promise this file makes.
  static (double, double) coarsen(double lat, double lon) {
    double snap(double v) =>
        (v / gridDegrees).roundToDouble() * gridDegrees;
    // Clamped to the real world: a bad fix must not become a request for a
    // latitude that does not exist.
    final la = snap(lat).clamp(-90.0, 90.0);
    var lo = snap(lon);
    // Longitude wraps rather than clamps, and only PAST the antimeridian:
    // 180 is a real meridian, so snapping 179.97 up to it is right and is
    // left alone. Anything beyond comes back round the other side instead
    // of being sent as a longitude that does not exist.
    if (lo > 180) lo -= 360;
    if (lo < -180) lo += 360;
    // Two decimals: the grid has no more precision than that, and a full
    // double would put spurious digits on the wire.
    return (
      double.parse(la.toStringAsFixed(2)),
      double.parse(lo.toStringAsFixed(2)),
    );
  }

  /// The URL a position turns into. Separate from [fetch] so a test can
  /// prove the coarse position — and nothing finer — is what gets sent.
  static Uri urlFor(double lat, double lon, {bool fahrenheit = false}) {
    final (la, lo) = coarsen(lat, lon);
    return Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': '$la',
      'longitude': '$lo',
      'current': 'temperature_2m,apparent_temperature,relative_humidity_2m,'
          'weather_code,wind_speed_10m,is_day',
      'hourly': 'temperature_2m,weather_code,precipitation_probability',
      'daily': 'weather_code,temperature_2m_max,temperature_2m_min,'
          'precipitation_probability_max',
      'timezone': 'auto',
      'forecast_days': '7',
      if (fahrenheit) 'temperature_unit': 'fahrenheit',
      if (fahrenheit) 'wind_speed_unit': 'mph',
    });
  }

  /// Test seam: what [fetch] returns instead of calling out.
  @visibleForTesting
  static Future<WeatherReport?> Function(double lat, double lon,
      {bool fahrenheit})? debugFetchOverride;

  Future<WeatherReport?> fetch(double lat, double lon,
      {bool fahrenheit = false}) async {
    final over = debugFetchOverride;
    if (over != null) return over(lat, lon, fahrenheit: fahrenheit);
    try {
      final res = await http
          .get(urlFor(lat, lon, fahrenheit: fahrenheit))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      return WeatherReport.parse(res.body, fahrenheit: fahrenheit);
    } catch (_) {
      // A forecast that cannot be fetched is a screen that says so, never a
      // thrown error over a chat list.
      return null;
    }
  }
}

/// One hour of the forecast.
class WeatherHour {
  final DateTime time;
  final double temp;
  final int code;

  /// Chance of precipitation, 0-100. -1 when the provider did not say.
  final int rainChance;

  const WeatherHour({
    required this.time,
    required this.temp,
    required this.code,
    required this.rainChance,
  });
}

/// One day of the forecast.
class WeatherDay {
  final DateTime date;
  final double high;
  final double low;
  final int code;
  final int rainChance;

  const WeatherDay({
    required this.date,
    required this.high,
    required this.low,
    required this.code,
    required this.rainChance,
  });
}

/// A whole forecast: now, the next hours, and the week.
class WeatherReport {
  final double temp;
  final double feelsLike;
  final int humidity;
  final double wind;
  final int code;
  final bool isDay;
  final String timezone;
  final bool fahrenheit;
  final List<WeatherHour> hours;
  final List<WeatherDay> days;

  const WeatherReport({
    required this.temp,
    required this.feelsLike,
    required this.humidity,
    required this.wind,
    required this.code,
    required this.isDay,
    required this.timezone,
    required this.fahrenheit,
    required this.hours,
    required this.days,
  });

  String get unit => fahrenheit ? '°F' : '°C';
  String get windUnit => fahrenheit ? 'mph' : 'km/h';

  String get label => weatherLabel(code);

  /// A one-line summary, which is also what a shared weather message says.
  String get summary =>
      '${temp.round()}$unit · $label';

  /// Reads the real Open-Meteo response. Tolerant on purpose: every block
  /// except `current` is optional, so a trimmed or partial answer renders
  /// what it has rather than nothing at all.
  static WeatherReport? parse(String body, {bool fahrenheit = false}) {
    try {
      final j = jsonDecode(body);
      if (j is! Map) return null;
      final cur = j['current'];
      if (cur is! Map) return null;

      double num0(Object? v) =>
          v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
      int int0(Object? v) =>
          v is num ? v.round() : int.tryParse('$v') ?? 0;

      List<T> zip<T>(
        Object? block,
        String key,
        T Function(DateTime t, int i, Map b) build,
      ) {
        if (block is! Map) return const [];
        final times = block['time'];
        if (times is! List) return const [];
        final out = <T>[];
        for (var i = 0; i < times.length; i++) {
          final t = DateTime.tryParse('${times[i]}');
          if (t == null) continue;
          out.add(build(t, i, block));
        }
        return out;
      }

      Object? at(Map b, String key, int i) {
        final list = b[key];
        return list is List && i < list.length ? list[i] : null;
      }

      final hours = zip<WeatherHour>(j['hourly'], 'time', (t, i, b) {
        final p = at(b, 'precipitation_probability', i);
        return WeatherHour(
          time: t,
          temp: num0(at(b, 'temperature_2m', i)),
          code: int0(at(b, 'weather_code', i)),
          rainChance: p == null ? -1 : int0(p),
        );
      });
      final days = zip<WeatherDay>(j['daily'], 'time', (t, i, b) {
        final p = at(b, 'precipitation_probability_max', i);
        return WeatherDay(
          date: t,
          high: num0(at(b, 'temperature_2m_max', i)),
          low: num0(at(b, 'temperature_2m_min', i)),
          code: int0(at(b, 'weather_code', i)),
          rainChance: p == null ? -1 : int0(p),
        );
      });

      return WeatherReport(
        temp: num0(cur['temperature_2m']),
        feelsLike: num0(cur['apparent_temperature'] ?? cur['temperature_2m']),
        humidity: int0(cur['relative_humidity_2m']),
        wind: num0(cur['wind_speed_10m']),
        code: int0(cur['weather_code']),
        // Open-Meteo answers 1/0, not a bool.
        isDay: int0(cur['is_day']) != 0,
        timezone: '${j['timezone'] ?? ''}',
        fahrenheit: fahrenheit,
        hours: hours,
        days: days,
      );
    } catch (_) {
      return null;
    }
  }

  /// The hours from [from] onwards, capped — the strip shows the rest of
  /// today and a bit beyond, not the whole week hour by hour.
  List<WeatherHour> nextHours(DateTime from, {int count = 12}) {
    final out = [
      for (final h in hours)
        if (!h.time.isBefore(from)) h
    ];
    return out.length <= count ? out : out.sublist(0, count);
  }
}

/// WMO weather code → a phrase somebody would actually say.
///
/// The table is the provider's, and the codes it does not define fall
/// through to a plain word rather than a blank: a forecast that renders
/// nothing reads as a broken screen.
String weatherLabel(int code) => switch (code) {
      0 => 'Clear',
      1 => 'Mostly clear',
      2 => 'Partly cloudy',
      3 => 'Overcast',
      45 || 48 => 'Fog',
      51 => 'Light drizzle',
      53 => 'Drizzle',
      55 => 'Heavy drizzle',
      56 || 57 => 'Freezing drizzle',
      61 => 'Light rain',
      63 => 'Rain',
      65 => 'Heavy rain',
      66 || 67 => 'Freezing rain',
      71 => 'Light snow',
      73 => 'Snow',
      75 => 'Heavy snow',
      77 => 'Snow grains',
      80 => 'Light showers',
      81 => 'Showers',
      82 => 'Heavy showers',
      85 => 'Snow showers',
      86 => 'Heavy snow showers',
      95 => 'Thunderstorm',
      96 || 99 => 'Thunderstorm with hail',
      _ => 'Unsettled',
    };

/// The glyph for a code. Day and night differ for the clear-ish codes only —
/// rain at night is still rain, and a moon over a downpour is decoration.
///
/// Returns a Material icon codepoint name via [weatherIconName] so this file
/// stays free of Flutter and can be tested as data.
String weatherIconName(int code, {bool isDay = true}) => switch (code) {
      0 || 1 => isDay ? 'sunny' : 'clear_night',
      2 => isDay ? 'partly_cloudy_day' : 'partly_cloudy_night',
      3 => 'cloud',
      45 || 48 => 'foggy',
      >= 51 && <= 57 => 'grain',
      >= 61 && <= 67 => 'rainy',
      >= 71 && <= 77 => 'ac_unit',
      >= 80 && <= 82 => 'rainy',
      85 || 86 => 'ac_unit',
      >= 95 => 'thunderstorm',
      _ => 'cloud',
    };
