import 'package:flutter/material.dart';

import '../state/sports_service.dart';
import '../theme/app_theme.dart';
import '../widgets/pull_to_refresh.dart';
import 'home_screen.dart' show HomeNavBar;

/// Scores and fixtures.
///
/// Two sections and no third: **Results** (finished, newest first) and
/// **Fixtures** (still to play, soonest first). There is deliberately no
/// "live" section — the provider's in-play feed is a paid tier, and a card
/// labelled LIVE over a scoreline that stopped updating an hour ago is worse
/// than no card. When a kickoff has passed and no score has been posted the
/// match stays under Fixtures, which is true either way.
class SportsScreen extends StatefulWidget {
  const SportsScreen({super.key, this.fromSidebar = false});

  final bool fromSidebar;

  @override
  State<SportsScreen> createState() => _SportsScreenState();
}

class _SportsScreenState extends State<SportsScreen> {
  /// '' means every league.
  String _league = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SportsService.instance.load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sports')),
      body: ListenableBuilder(
        listenable: SportsService.instance,
        builder: (context, _) {
          final svc = SportsService.instance;
          final all = svc.events;
          final leagues = SportsService.leaguesIn(all);
          final shown = _league.isEmpty
              ? all
              : [for (final e in all) if (e.league == _league) e];
          final results = SportsService.results(shown);
          final fixtures = SportsService.fixtures(shown);

          if (svc.loading && all.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          // "Not set up" and "nothing on today" look identical from a bare
          // empty list, so they are told apart here rather than left to be
          // guessed at.
          if (svc.configured == false) {
            return const _Empty(
              icon: Icons.sports_soccer_outlined,
              title: 'Scores aren\'t set up yet',
              body: 'This needs a sports data key on the server. Once it is '
                  'set, results and fixtures appear here.',
            );
          }
          if (all.isEmpty) {
            return PullToRefresh(
              onRefresh: svc.load,
              child: ListView(children: [
                const SizedBox(height: 80),
                _Empty(
                  icon: Icons.sports_soccer_outlined,
                  title: svc.error.isEmpty
                      ? 'Nothing scheduled'
                      : 'Scores couldn\'t be loaded',
                  body: svc.error.isEmpty
                      ? 'No results or fixtures right now. Pull down to '
                          'check again.'
                      : 'Pull down to try again.',
                ),
              ]),
            );
          }

          return PullToRefresh(
            onRefresh: svc.load,
            child: ListView(
              padding:
                  EdgeInsets.only(bottom: HomeNavBar.clearance(context)),
              children: [
                if (leagues.length > 1) _LeagueChips(
                  leagues: leagues,
                  selected: _league,
                  onSelect: (l) => setState(() => _league = l),
                ),
                if (results.isNotEmpty) ...[
                  const _SectionHeader('Results'),
                  for (final e in results) _MatchRow(event: e),
                ],
                if (fixtures.isNotEmpty) ...[
                  const _SectionHeader('Fixtures'),
                  for (final e in fixtures) _MatchRow(event: e),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                  child: Text(
                    'Results and fixtures only — an in-play score needs the '
                    'provider\'s live tier, and a stale one labelled "live" '
                    'would be worse than none.',
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: AppColors.subtle(context)),
                  ),
                ),
              ],
            ),
          );
        },
      ),
      // Floats over the content like it does on home, rather than sitting in
      // a slot the list stops above (the owner's call). Each list below pads
      // itself by HomeNavBar.clearance so nothing ends underneath it.
      extendBody: true,
      bottomNavigationBar: const HomeNavBar(),
    );
  }
}

class _LeagueChips extends StatelessWidget {
  const _LeagueChips(
      {required this.leagues, required this.selected, required this.onSelect});
  final List<String> leagues;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          for (final l in ['', ...leagues])
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(l.isEmpty ? 'All' : l),
                selected: selected == l,
                onSelected: (_) => onSelect(l),
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(label.toUpperCase(),
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
                color: AppColors.subtle(context))),
      );
}

class _MatchRow extends StatelessWidget {
  const _MatchRow({required this.event});
  final SportsEvent event;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
  ];

  /// The kickoff, in the reader's own zone.
  static String when(DateTime local) {
    final now = DateTime.now();
    final sameDay = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final time =
        '$h:${local.minute.toString().padLeft(2, '0')}${local.hour < 12 ? 'am' : 'pm'}';
    if (sameDay) return time;
    return '${_months[local.month - 1]} ${local.day} · $time';
  }

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(event.home,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(event.away,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  [
                    if (event.league.isNotEmpty) event.league,
                    when(event.kickoffLocal),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: subtle),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (event.hasScore)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${event.homeScore}',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('${event.awayScore}',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
              ],
            )
          else
            Text('vs', style: TextStyle(fontSize: 13, color: subtle)),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(
      {required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: Colors.grey.shade400),
              const SizedBox(height: 14),
              Text(title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(body,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 14, color: AppColors.subtle(context))),
            ],
          ),
        ),
      );
}
