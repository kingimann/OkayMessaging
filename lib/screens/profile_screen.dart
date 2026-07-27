import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/user.dart';
import '../state/feed_store.dart';
import '../state/follow_store.dart';
import '../utils/date_formatter.dart';
import '../widgets/user_avatar.dart';
import '../widgets/verified_badge.dart';
import 'edit_profile_screen.dart';
import 'feed_screen.dart';
import 'my_qr_screen.dart';
import 'score_screen.dart';

/// The "You" tab: a social-media-style profile — big avatar, handle, bio,
/// stats, action buttons, and your recent posts. Settings live behind the
/// gear in the app bar, not here.
class ProfileView extends StatelessWidget {
  const ProfileView({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppUser>(
      valueListenable: AppState.profile,
      builder: (context, me, _) => ListenableBuilder(
        listenable: Listenable.merge([FollowStore.instance, FeedStore.instance]),
        builder: (context, _) {
          final myPosts = FeedStore.instance
              .recentPosts(limit: 100)
              .where((p) =>
                  p.authorUsername == 'you' ||
                  (me.username.isNotEmpty &&
                      p.authorUsername == me.username))
              .take(20)
              .toList();
          return ListView(
            padding: const EdgeInsets.only(bottom: 110),
            children: [
              const SizedBox(height: 18),
              Center(child: UserAvatar(user: me, radius: 46)),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(me.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w800)),
                  ),
                  if (me.verified) ...[
                    const SizedBox(width: 6),
                    const VerifiedBadge(size: 20),
                  ],
                ],
              ),
              if (me.handle.isNotEmpty)
                Text(me.handle,
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 15, color: Colors.grey.shade600)),
              if (me.pronouns.trim().isNotEmpty)
                Text(me.pronouns.trim(),
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 13, color: Colors.grey.shade500)),
              if (me.about.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 10, 32, 0),
                  child: Text(me.about.trim(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14.5, height: 1.35)),
                ),
              if (me.link.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.link,
                          size: 15, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 4),
                      Text(me.link.trim(),
                          style: TextStyle(
                              fontSize: 13.5,
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
              // Stats row — tap through to the relevant screens.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _Stat(
                      value: '${myPosts.length}',
                      label: 'Posts',
                      onTap: null),
                  _statDivider(context),
                  _Stat(
                      value: '${FollowStore.instance.followingCount}',
                      label: 'Following',
                      onTap: null),
                  _statDivider(context),
                  _Stat(
                      value: '${me.score}',
                      label: 'Okay Score',
                      onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const ScoreScreen()))),
                ],
              ),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const EditProfileScreen())),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: const Text('Edit profile'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const MyQrScreen())),
                        icon: const Icon(Icons.qr_code, size: 18),
                        label: const Text('Share'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              const Divider(height: 28, indent: 24, endIndent: 24),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text('POSTS',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: Colors.grey.shade500)),
              ),
              if (myPosts.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 12, 32, 0),
                  child: Text(
                    'Nothing posted yet. Share something in a server\'s feed '
                    'and it shows up here.',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: Colors.grey.shade500, fontSize: 13.5),
                  ),
                )
              else
                for (final p in myPosts)
                  ListTile(
                    leading: UserAvatar(user: me, radius: 20),
                    title: Text(p.text,
                        maxLines: 3, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        '${DateFormatter.callLabel(p.time)} · '
                        '${p.likes} likes · ${p.replies} replies',
                        style: TextStyle(
                            fontSize: 12.5, color: Colors.grey.shade500)),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => FeedPostScreen(postId: p.id))),
                  ),
            ],
          );
        },
      ),
    );
  }

  Widget _statDivider(BuildContext context) => Container(
        width: 1,
        height: 30,
        margin: const EdgeInsets.symmetric(horizontal: 22),
        color: Theme.of(context).dividerColor,
      );
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  final VoidCallback? onTap;
  const _Stat({required this.value, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        children: [
          Text(value,
              style:
                  const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
        ],
      ),
    );
  }
}
