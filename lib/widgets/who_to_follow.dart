import 'package:flutter/material.dart';

import '../state/follow_store.dart';
import '../state/follow_suggestions.dart';
import '../state/public_feed_store.dart';
import '../theme/app_theme.dart';
import '../widgets/feed_post_parts.dart';
import '../widgets/phone_gate.dart';

/// "Who to follow" — the way out of a dead first session.
///
/// **What it is answering.** A new account's Following timeline is empty BY
/// CONSTRUCTION (the store: "following nobody means an empty timeline, not
/// the whole feed") and nothing anywhere suggested a single person. So there
/// was no path from signing up to having a feed worth opening — the one
/// thing a social app has to get right in the first minute.
///
/// **Every row says WHY.** A suggestion with no reason is indistinguishable
/// from an ad, and this app has a standing rule against inventing people or
/// activity — see [FollowSuggestions] for where each candidate really comes
/// from. Nothing here is editorial and nothing is paid.
///
/// **It draws NOTHING while loading, and nothing when there is nothing to
/// say.** A card that appears empty, or that pops in half a second after the
/// timeline settles, is worse than one that was never there.
class WhoToFollow extends StatefulWidget {
  /// A heading is right above a timeline and wrong on an empty state, where
  /// the surrounding copy has already said what this is.
  final bool heading;

  const WhoToFollow({super.key, this.heading = true});

  /// Test seam: stands in for the four lookups behind a suggestion, two of
  /// which are network. Nothing in the suite has a graph to ask.
  @visibleForTesting
  static Future<List<FollowSuggestion>> Function()? debugSuggestions;

  @override
  State<WhoToFollow> createState() => _WhoToFollowState();
}

class _WhoToFollowState extends State<WhoToFollow> {
  List<FollowSuggestion>? _people;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final fetch = WhoToFollow.debugSuggestions;
    try {
      final people = await (fetch != null
          ? fetch()
          : PublicFeedStore.instance.suggestedFollows());
      if (mounted) setState(() => _people = people);
    } catch (_) {
      // A graph that cannot be reached is not an error worth a red box on
      // somebody's timeline — it is simply no suggestions this time.
      if (mounted) setState(() => _people = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    if (people == null || people.isEmpty) return const SizedBox.shrink();
    final subtle = AppColors.subtle(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.heading) ...[
            const Text('Who to follow',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
          ],
          for (final p in people.take(3)) _Row(person: p),
          if (people.length > 3)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Follow a few and your timeline fills out.',
                style: TextStyle(fontSize: 12, color: subtle),
              ),
            ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final FollowSuggestion person;
  const _Row({required this.person});

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return ListenableBuilder(
      listenable: FollowStore.instance,
      builder: (context, _) {
        final following = FollowStore.instance.isFollowing(person.username);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              FeedAvatar(username: person.username, name: person.name),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                        person.name.isNotEmpty
                            ? person.name
                            : '@${person.username}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(person.reason,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: subtle)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              following
                  ? OutlinedButton(
                      onPressed: null,
                      style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact),
                      child: const Text('Following'),
                    )
                  : FilledButton(
                      style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact),
                      // The SEVENTH gated follow call site. An authenticated
                      // write needs a real identity to attribute it to, and
                      // the local flip is refused too — so the button never
                      // lies about having worked.
                      onPressed: () {
                        if (postNeedsPhone(context, what: 'Following')) return;
                        FollowStore.instance.toggle(person.username);
                      },
                      child: const Text('Follow'),
                    ),
            ],
          ),
        );
      },
    );
  }
}
