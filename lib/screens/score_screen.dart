import 'package:flutter/material.dart' hide Badge;

import '../app_state.dart';
import '../models/chat.dart';
import '../state/chat_store.dart';
import '../state/score_store.dart';
import '../state/session.dart';
import '../state/streak_store.dart';
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
        animation: ScoreStore.instance,
        builder: (context, _) {
          final store = ScoreStore.instance;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              _ScoreCard(points: store.points, earned: store.earnedCount),
              const SizedBox(height: 16),
              const _VerifiedRow(),
              const SizedBox(height: 20),
              const _StreaksSection(),
              _sectionHeader(context, 'BADGES'),
              const SizedBox(height: 4),
              Text(
                'Tap an earned badge to feature it on your profile.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12.5),
              ),
              const SizedBox(height: 12),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.55,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                children: [
                  for (final badge in ScoreStore.catalog)
                    _BadgeCard(
                      badge: badge,
                      earned: store.isEarned(badge.id),
                      featured: store.featuredBadge == badge.id,
                      onTap: store.isEarned(badge.id)
                          ? () => store.setFeatured(
                              store.featuredBadge == badge.id ? null : badge.id)
                          : null,
                    ),
                ],
              ),
            ],
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
            Text('Message someone every day to grow a streak.',
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
                      child: Text('No streaks yet — keep a daily chat going.',
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF7A5CFF), Color(0xFF5B3CE0)],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          const Icon(Icons.local_fire_department, color: Colors.white, size: 34),
          const SizedBox(height: 6),
          Text(
            '$points',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 46,
              fontWeight: FontWeight.w800,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 2),
          const Text('Okay Score',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('$earned ${earned == 1 ? 'badge' : 'badges'} earned',
              style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
        ],
      ),
    );
  }
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
                TextButton(
                  onPressed: () => _setVerified(context, false),
                  child: const Text('Remove'),
                ),
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
                    Text('Verify your account with Okay Pro',
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Get verified'),
        content: const Text(
            'The blue check is part of Okay Pro (\$4.99/month). It marks your '
            'account as verified across your chats. Turn it on now?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Verify me'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      _setVerified(context, true);
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

  const _BadgeCard({
    required this.badge,
    required this.earned,
    required this.featured,
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
