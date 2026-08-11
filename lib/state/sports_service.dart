import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../relay/relay_config.dart';

/// Scores and fixtures, through the `sports` Edge Function.
///
/// **The provider key stays server-side.** A sports API key in the app is a
/// key in the binary, so the client only ever calls our own function and the
/// function holds the secret — the same shape as `ai-chat` and
/// `moderation-screen`.
///
/// **Read-only, and honest about what that means.** This shows finished
/// results and upcoming fixtures. It does NOT show a running in-play score:
/// that needs the provider's paid live tier, and a card that said "LIVE"
/// while showing a stale scoreline would be worse than not showing one.
///
/// Parsing and grouping are pure so they can be proven without a network.
class SportsService extends ChangeNotifier {
  SportsService._();
  static final SportsService instance = SportsService._();

  List<SportsEvent> _events = const [];
  List<SportsEvent> get events => List.unmodifiable(_events);

  bool _loading = false;
  bool get loading => _loading;

  /// Null until a fetch has answered. False means the project has no
  /// provider key — a different thing from "no matches", and the screen says
  /// which.
  bool? _configured;
  bool? get configured => _configured;

  String _error = '';
  String get error => _error;

  DateTime? _fetchedAt;
  DateTime? get fetchedAt => _fetchedAt;

  /// Test seam: what [load] gets instead of calling the function.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function()? debugFetchOverride;

  @visibleForTesting
  void resetForTest() {
    _events = const [];
    _loading = false;
    _configured = null;
    _error = '';
    _fetchedAt = null;
    debugFetchOverride = null;
  }

  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    _error = '';
    notifyListeners();
    try {
      final Map<String, dynamic> data;
      final over = debugFetchOverride;
      if (over != null) {
        data = await over();
      } else if (!RelayConfig.isEnabled) {
        // No relay means no function to ask. Answered as "not set up"
        // rather than an empty scoreboard, which is what the web build and
        // the whole test suite run as.
        data = const {'configured': false, 'events': []};
      } else {
        final res = await Supabase.instance.client.functions
            .invoke('sports', body: {'what': 'scoreboard'});
        final d = res.data;
        data = d is Map ? Map<String, dynamic>.from(d) : const {};
      }
      _configured = data['configured'] == true;
      _events = parseEvents(data['events']);
      _fetchedAt = DateTime.now();
      final err = data['error'];
      if (err != null) _error = '$err';
    } catch (e) {
      _error = 'Scores could not be loaded.';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Reads the function's `events` array. Tolerant: a row missing the parts
  /// that make it a match is dropped rather than rendered half-blank.
  static List<SportsEvent> parseEvents(Object? raw) {
    if (raw is! List) return const [];
    final out = <SportsEvent>[];
    for (final r in raw) {
      if (r is! Map) continue;
      final e = SportsEvent.fromJson(Map<String, dynamic>.from(r));
      if (e != null) out.add(e);
    }
    return out;
  }

  /// Finished matches, newest first.
  static List<SportsEvent> results(List<SportsEvent> all) {
    final out = all.where((e) => e.isFinal).toList();
    out.sort((a, b) => b.kickoff.compareTo(a.kickoff));
    return out;
  }

  /// Matches still to play, soonest first.
  ///
  /// A fixture whose kickoff has passed but which carries no score is still
  /// listed here, not quietly dropped: it is either in progress or the
  /// provider has not posted the result, and both are "not finished".
  static List<SportsEvent> fixtures(List<SportsEvent> all) {
    final out = all.where((e) => !e.isFinal).toList();
    out.sort((a, b) => a.kickoff.compareTo(b.kickoff));
    return out;
  }

  /// The league names present, in the order they first appear — what the
  /// filter chips offer, so a league with nothing on never gets a chip.
  static List<String> leaguesIn(List<SportsEvent> all) {
    final seen = <String>{};
    final out = <String>[];
    for (final e in all) {
      if (e.league.isEmpty || !seen.add(e.league)) continue;
      out.add(e.league);
    }
    return out;
  }
}

/// One match.
class SportsEvent {
  final String id;
  final String league;
  final String sport;
  final String home;
  final String away;
  final String homeBadge;
  final String awayBadge;

  /// Null until the provider posts a score.
  final int? homeScore;
  final int? awayScore;

  /// UTC. [kickoffLocal] is what a screen should show.
  final DateTime kickoff;
  final bool isFinal;
  final String round;

  const SportsEvent({
    required this.id,
    required this.league,
    required this.sport,
    required this.home,
    required this.away,
    required this.homeBadge,
    required this.awayBadge,
    required this.homeScore,
    required this.awayScore,
    required this.kickoff,
    required this.isFinal,
    required this.round,
  });

  DateTime get kickoffLocal => kickoff.toLocal();

  bool get hasScore => homeScore != null && awayScore != null;

  /// The scoreline, or an em dash when there isn't one yet. Never invents a
  /// 0-0 for a match that has not been played.
  String get scoreLine => hasScore ? '$homeScore – $awayScore' : '–';

  /// One line, which is also what a shared match message says.
  String get summary => hasScore
      ? '$home $homeScore – $awayScore $away'
      : '$home vs $away';

  static SportsEvent? fromJson(Map<String, dynamic> j) {
    final id = '${j['id'] ?? ''}';
    final home = '${j['home'] ?? ''}';
    final away = '${j['away'] ?? ''}';
    if (id.isEmpty || home.isEmpty || away.isEmpty) return null;
    // The provider stamps UTC without a zone marker, so parse it as UTC
    // rather than letting Dart read it as local — an hour's drift on every
    // kickoff time is the kind of wrong nobody reports and everybody sees.
    final rawTime = '${j['kickoff'] ?? ''}';
    final parsed = DateTime.tryParse(
        rawTime.endsWith('Z') || rawTime.contains('+')
            ? rawTime
            : '${rawTime}Z');
    if (parsed == null) return null;
    int? score(Object? v) {
      if (v == null) return null;
      if (v is num) return v.round();
      return int.tryParse('$v');
    }

    return SportsEvent(
      id: id,
      league: '${j['league'] ?? ''}',
      sport: '${j['sport'] ?? ''}',
      home: home,
      away: away,
      homeBadge: '${j['homeBadge'] ?? ''}',
      awayBadge: '${j['awayBadge'] ?? ''}',
      homeScore: score(j['homeScore']),
      awayScore: score(j['awayScore']),
      kickoff: parsed.toUtc(),
      isFinal: '${j['status'] ?? ''}' == 'final',
      round: '${j['round'] ?? ''}',
    );
  }
}
