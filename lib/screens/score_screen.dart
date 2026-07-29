import 'package:flutter/material.dart' hide Badge;
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../models/chat.dart';
import '../state/chat_store.dart';
import '../state/identity_verification.dart';
import 'identity_check_screen.dart';
import '../state/score_store.dart';
import '../state/session.dart';
import '../state/streak_store.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/streak_chip.dart';
import '../widgets/user_avatar.dart';
import '../widgets/verified_badge.dart';
import 'chat_screen.dart';

/// A section header used on the Okay Score screen.
Widget _sectionHeader(BuildContext context, String text) => Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.7,
        color:
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
      ),
    );

/// The Okay Score screen: a Snapchat-style running activity score, the badges
/// it unlocks, and a way to feature one badge on your profile.
class ScoreScreen extends StatelessWidget {
  const ScoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Okay Score')),
      body: AnimatedBuilder(
        animation: Listenable.merge(
            [ScoreStore.instance, StreakStore.instance]),
        builder: (context, _) {
          final store = ScoreStore.instance;
          final earnedFirst = [
            ...ScoreStore.catalog.where((b) => store.isEarned(b.id)),
            ...ScoreStore.catalog.where((b) => !store.isEarned(b.id)),
          ];
          return PullToRefresh(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              children: [
                _ScoreCard(points: store.points, earned: store.earnedCount),
                const SizedBox(height: 12),
                const _StatsRow(),
                const SizedBox(height: 12),
                const _NextBadgeCard(),
                const _VerifiedRow(),
                const SizedBox(height: 20),
                const _StreaksSection(),
                _sectionHeader(context, 'BADGES'),
                const SizedBox(height: 4),
                Text(
                  'Tap an earned badge to feature it on your profile, or any '
                  'badge to see what it takes.',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12.5),
                ),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: 1.45,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  children: [
                    // Earned first: what you have is more interesting than
                    // the long tail of what you don't.
                    for (final badge in earnedFirst)
                      _BadgeCard(
                        badge: badge,
                        earned: store.isEarned(badge.id),
                        featured: store.featuredBadge == badge.id,
                        progress: store.progressToward(badge.id),
                        points: store.points,
                        // Every badge is tappable now: an earned one features
                        // (or unfeatures), a locked one explains itself
                        // instead of being a dead square.
                        onTap: () => store.isEarned(badge.id)
                            ? store.setFeatured(
                                store.featuredBadge == badge.id
                                    ? null
                                    : badge.id)
                            : _explainBadge(context, badge, store),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                _sectionHeader(context, 'HOW POINTS WORK'),
                const SizedBox(height: 8),
                const _EarningRules(),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A leaderboard of the user's active conversation streaks, ranked longest
/// first — the Snapchat "best friends" view.
class _StreaksSection extends StatelessWidget {
  const _StreaksSection();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
          [StreakStore.instance, ChatStore.instance]),
      builder: (context, _) {
        final ranked = <(Chat, int)>[];
        for (final chat in ChatStore.instance.chats) {
          final s = StreakStore.instance.streakFor(chat.id);
          if (s > 0) ranked.add((chat, s));
        }
        ranked.sort((a, b) => b.$2.compareTo(a.$2));
        final top = ranked.take(10).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(context, 'STREAKS'),
            const SizedBox(height: 4),
            // The old line said "message someone every day", which is only
            // half the rule and left people wondering why a streak wasn't
            // moving. It takes *both* of you, on the same day.
            Text(
                'A streak grows on each day you and someone both send at '
                'least one message. Miss a day and it lapses.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12.5)),
            const SizedBox(height: 6),
            if (top.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Row(
                  children: [
                    Icon(Icons.local_fire_department_outlined,
                        color: Colors.grey.shade400),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                          StreakStore.instance.bestEver > 0
                              ? 'No live streaks — your best was '
                                  '${StreakStore.instance.bestEver} days. '
                                  'Swap a message with someone today to '
                                  'start again.'
                              : 'No streaks yet. Once you and someone else '
                                  'both message on the same day, a flame '
                                  'appears here and in the chat.',
                          style: TextStyle(color: Colors.grey.shade500)),
                    ),
                  ],
                ),
              )
            else
              for (var i = 0; i < top.length; i++)
                _StreakRow(
                  rank: i + 1,
                  chat: top[i].$1,
                  streak: top[i].$2,
                  expiring:
                      StreakStore.instance.isExpiringSoon(top[i].$1.id),
                ),
            const SizedBox(height: 20),
          ],
        );
      },
    );
  }
}

class _StreakRow extends StatelessWidget {
  final int rank;
  final Chat chat;
  final int streak;
  final bool expiring;
  const _StreakRow({
    required this.rank,
    required this.chat,
    required this.streak,
    required this.expiring,
  });

  static const _hint =
      TextStyle(fontSize: 11.5, color: Color(0xFFEF8A3C));

  /// Whose turn it is for today to count. Both sides have to send.
  String _todayNeeds() {
    final (sent, received) = StreakStore.instance.todayProgress(chat.id);
    if (!sent && !received) return 'Nobody has written today';
    if (sent) return 'Waiting on their reply today';
    return 'They wrote — reply today to keep it';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 22,
            child: Text('$rank',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: Colors.grey.shade500)),
          ),
          UserAvatar(user: chat.contact, radius: 20),
        ],
      ),
      title: Text(chat.contact.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      // What today is still waiting on, so a streak at risk names the thing
      // that would save it instead of just glowing orange.
      subtitle: expiring ? Text(_todayNeeds(), style: _hint) : null,
      trailing: StreakChip(count: streak, expiring: expiring, size: 18),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
      ),
    );
  }
}

class _ScoreCard extends StatelessWidget {
  final int points;
  final int earned;
  const _ScoreCard({required this.points, required this.earned});

  @override
  Widget build(BuildContext context) {
    final store = ScoreStore.instance;
    final next = store.nextLevelAt;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF7A5CFF), Color(0xFF5B3CE0)],
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF5B3CE0).withValues(alpha: 0.32),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          // The score sits inside its own progress ring, so "how far to the
          // next level" is the same object as the number itself rather than a
          // bar underneath it.
          SizedBox(
            width: 132,
            height: 132,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: store.levelProgress),
                    duration: const Duration(milliseconds: 650),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, _) => CircularProgressIndicator(
                      value: value,
                      strokeWidth: 9,
                      strokeCap: StrokeCap.round,
                      backgroundColor: Colors.white.withValues(alpha: 0.22),
                      valueColor: const AlwaysStoppedAnimation(Colors.white),
                    ),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.local_fire_department,
                        color: Colors.white, size: 22),
                    Text(
                      '$points',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 40,
                        fontWeight: FontWeight.w800,
                        height: 1.05,
                      ),
                    ),
                    const Text('Okay Score',
                        style: TextStyle(
                            color: Colors.white70,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('Level ${store.level} · ${store.levelTitle}',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13)),
          ),
          const SizedBox(height: 8),
          Text(
            next == null
                ? 'Top level — nothing left to climb'
                : '${next - points} points to '
                    '${ScoreStore.levelTitles[store.level]}',
            style: const TextStyle(color: Colors.white70, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

/// Three at-a-glance numbers under the score card: level, badges, streaks.
class _StatsRow extends StatelessWidget {
  const _StatsRow();

  @override
  Widget build(BuildContext context) {
    final score = ScoreStore.instance;
    final streaks = StreakStore.instance;
    final best = streaks.bestEver;
    return Row(
      children: [
        _stat(context, Icons.military_tech_outlined, '${score.earnedCount}',
            'of ${ScoreStore.catalog.length} badges'),
        const SizedBox(width: 10),
        _stat(context, Icons.local_fire_department_outlined,
            '${streaks.activeCount()}',
            streaks.activeCount() == 1 ? 'live streak' : 'live streaks'),
        const SizedBox(width: 10),
        // A best that already lapsed is still something that happened, so it
        // is shown as a record rather than quietly dropped.
        _stat(context, Icons.emoji_events_outlined, best == 0 ? '—' : '$best',
            'best streak'),
      ],
    );
  }

  Widget _stat(BuildContext context, IconData icon, String value,
          String label) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              Icon(icon, size: 18, color: Colors.grey.shade600),
              const SizedBox(height: 4),
              Text(value,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 1),
              Text(label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style:
                      TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            ],
          ),
        ),
      );
}

/// The nearest points badge and how far off it is. Disappears when every
/// points badge is earned rather than inventing a goal.
class _NextBadgeCard extends StatelessWidget {
  const _NextBadgeCard();

  @override
  Widget build(BuildContext context) {
    final store = ScoreStore.instance;
    final badge = store.nextBadge;
    if (badge == null) return const SizedBox.shrink();
    final left = store.pointsToNextBadge ?? 0;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Text(badge.emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Next up: ${badge.label}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                      left == 0
                          ? 'Earned — it will appear below'
                          : '$left more ${left == 1 ? 'point' : 'points'} '
                              '(${badge.description.toLowerCase()})',
                      style: TextStyle(
                          fontSize: 12.5, color: Colors.grey.shade600)),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: store.progressToward(badge.id),
                      minHeight: 6,
                      backgroundColor:
                          scheme.primary.withValues(alpha: 0.18),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What earns points, in plain numbers. The score used to be a figure that
/// went up for reasons nobody could see.
class _EarningRules extends StatelessWidget {
  const _EarningRules();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          for (final (label, points) in ScoreStore.earningRules)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
              child: Row(
                children: [
                  Expanded(
                      child: Text(label,
                          style: const TextStyle(fontSize: 13.5))),
                  Text('+$points',
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.primary)),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  'Your score is kept on this device and only travels to '
                  'people you message, the same way your name does.',
                  style:
                      TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Explains an unearned badge instead of leaving a locked square that does
/// nothing when tapped.
void _explainBadge(BuildContext context, Badge badge, ScoreStore store) {
  final target = badge.threshold;
  final left = target == null ? null : target - store.points;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(badge.emoji, style: const TextStyle(fontSize: 46)),
            const SizedBox(height: 10),
            Text(badge.label,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(badge.description,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600)),
            if (left != null && left > 0) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: store.progressToward(badge.id),
                  minHeight: 7,
                ),
              ),
              const SizedBox(height: 8),
              Text('${store.points} / $target points',
                  style: TextStyle(
                      fontSize: 12.5, color: Colors.grey.shade600)),
            ],
          ],
        ),
      ),
    ),
  );
}

/// Shows verified status, or a call to action to get the blue check via Pro.
class _VerifiedRow extends StatelessWidget {
  const _VerifiedRow();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: AppState.profile,
      builder: (context, me, _) {
        if (me.verified) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF1D9BF0).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const VerifiedBadge(size: 22),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('You\'re verified',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                // No "remove": the badge reflects a completed ID check, so
                // it isn't the device's to switch off.
                Icon(Icons.lock_outline,
                    size: 16, color: Colors.grey.shade500),
              ],
            ),
          );
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              const Icon(Icons.verified_outlined,
                  color: Color(0xFF1D9BF0), size: 22),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Get the blue check',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    SizedBox(height: 2),
                    Text('Add a blue check to your account',
                        style: TextStyle(fontSize: 12.5, color: Colors.grey)),
                  ],
                ),
              ),
              FilledButton(
                onPressed: () => _getVerified(context),
                child: const Text('Verify'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _getVerified(BuildContext context) async {
    final ok = await showAppConfirmDialog(
      context,
      icon: Icons.verified_outlined,
      title: 'Get verified',
      message: 'The blue check means your identity has actually been '
          'checked, so it takes a photo of a government ID and a selfie.\n\n'
          'The check is handled by Stripe. Your ID never reaches this app, '
          'and we only ever learn whether you passed.',
      confirmLabel: 'Continue',
      cancelLabel: 'Not now',
    );
    if (!ok || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final session = await IdentityVerification.instance.start();
    if (session == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not start verification. Try again later.')));
      return;
    }
    if (session.isAlreadyVerified) {
      // Already verified server-side — adopt it rather than pay for a
      // second check.
      if (context.mounted) _syncBadge(context);
      return;
    }
    if (!context.mounted) return;

    // In the app, on a screen of our own. Stripe still runs the check and
    // still holds the documents; it just isn't a browser any more. This holds
    // for a hosted-URL-only session too — that used to hand the user to
    // Safari, which is the one thing the flow shouldn't do.
    if (IdentityCheckScreen.canHost(session)) {
      await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => IdentityCheckScreen(session: session),
      ));
      if (context.mounted) await _syncBadge(context);
      return;
    }

    // No WebView here (the web build) — fall back to Stripe's hosted page.
    if (session.hostedUrl.isEmpty ||
        !await launchUrl(Uri.parse(session.hostedUrl),
            mode: LaunchMode.externalApplication)) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not open the verification page.')));
      return;
    }
    messenger.showSnackBar(const SnackBar(
        content: Text('Finish the ID check, then come back — the badge '
            'appears once Stripe confirms it.')));
  }

  /// Adopts whatever the server says. The badge is never set locally: a check
  /// mark a device could grant itself would mean nothing.
  Future<void> _syncBadge(BuildContext context) async {
    final verified = await IdentityVerification.instance.refresh() ==
        IdentityStatus.verified;
    if (!context.mounted) return;
    _setVerified(context, verified);
    if (verified) {
      ScoreStore.instance.recordFlag('verified');
      ScoreStore.instance.recordFlag('pro');
    }
  }

  void _setVerified(BuildContext context, bool value) {
    if (Session.instance.isSignedIn) {
      Session.instance.setVerified(value);
    } else {
      AppState.setVerified(value);
    }
    if (!value) ScoreStore.instance.clearFlag('verified');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(value ? 'You\'re now verified' : 'Verification removed')),
    );
  }
}

class _BadgeCard extends StatelessWidget {
  final Badge badge;
  final bool earned;
  final bool featured;
  final VoidCallback? onTap;

  /// How close an unearned points badge is, in [0, 1].
  final double progress;

  /// The current score, for the "38 / 50" line under a locked points badge.
  final int points;

  const _BadgeCard({
    required this.badge,
    required this.earned,
    required this.featured,
    this.progress = 0,
    this.points = 0,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: featured
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
          : (isDark ? const Color(0xFF23262D) : const Color(0xFFF2F4F6)),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: featured
                ? Border.all(
                    color: Theme.of(context).colorScheme.primary, width: 2)
                : null,
          ),
          child: Row(
            children: [
              Opacity(
                opacity: earned ? 1 : 0.35,
                child: Text(badge.emoji, style: const TextStyle(fontSize: 30)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            badge.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13.5,
                              color: earned ? null : Colors.grey,
                            ),
                          ),
                        ),
                        if (featured)
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(Icons.push_pin, size: 13),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      earned
                          ? (featured ? 'Featured on profile' : 'Unlocked')
                          : badge.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5, color: Colors.grey.shade500),
                    ),
                    // A points badge shows how close it is. A locked square
                    // that only says "reach 250 points" gives no sense of
                    // whether that's near or hopeless.
                    if (!earned && badge.threshold != null) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text('$points / ${badge.threshold}',
                          style: TextStyle(
                              fontSize: 10.5, color: Colors.grey.shade500)),
                    ],
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
