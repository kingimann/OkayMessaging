import 'package:flutter/foundation.dart';

/// One person worth following, and WHY — the reason is not decoration.
///
/// A suggestion with no stated reason is indistinguishable from an ad, and
/// this app has a standing rule against inventing people or activity. Every
/// reason below is a fact this device can point at.
class FollowSuggestion {
  final String username;
  final String name;

  /// Shown under the name, in the person's own terms.
  final String reason;

  /// Higher is offered first. Never displayed — a score on screen invites
  /// the question of what it means.
  final int score;

  const FollowSuggestion({
    required this.username,
    required this.name,
    required this.reason,
    required this.score,
  });
}

/// Where a candidate came from, ordered by how strong the signal is.
///
/// The ORDER is the ranking, so it is written down once here rather than as
/// magic numbers at four call sites.
enum SuggestionSource {
  /// They follow you and you don't follow back. The strongest signal there
  /// is: somebody already reached toward this account.
  followsYou,

  /// Several people you follow follow them. The classic second-degree
  /// signal, and what makes a feed fill out rather than stay a straight
  /// line.
  followedByFollows,

  /// You have a real conversation with them and never followed them.
  contact,

  /// Their posts are already in front of you.
  inYourFeed,
}

/// Who to follow, from what this device can honestly answer.
///
/// **Why this exists.** A new account's first session was a dead end. The
/// Following timeline is empty BY CONSTRUCTION — the store's own comment
/// says "following nobody means an empty timeline, not the whole feed" —
/// and nothing anywhere suggested a single person. So the path from signing
/// up to having a feed worth opening did not exist.
///
/// **It needs no migration and no new server work**, which is why it is
/// first. `public_followers` and `public_following` are already granted to
/// anon, so the two graph signals are free; the other two are read off what
/// the device already holds and cost no network at all.
///
/// **Nothing here is invented.** There is no "popular accounts" list,
/// because the server cannot answer one without a new table and because a
/// hand-picked list is an editorial decision the app has no business
/// making. Every candidate is somebody who really followed you, is really
/// followed by people you follow, is really in your contacts, or is really
/// already on your screen.
class FollowSuggestions {
  FollowSuggestions._();

  /// How many to offer. A row somebody scrolls past is fine; a wall of
  /// strangers is what makes a suggestion surface feel like advertising.
  static const int maxSuggestions = 12;

  /// How many of your follows to ask about for the second-degree pass. Each
  /// is one round trip, so this is the whole cost of the feature — bounded
  /// rather than "everybody you follow", which for a heavy account would be
  /// hundreds of calls.
  static const int graphProbe = 8;

  /// How many of your follows must follow somebody before that is a reason
  /// worth SAYING. One is a coincidence.
  static const int secondDegreeFloor = 2;

  /// The whole ranking, pure so every branch is testable without a server.
  ///
  /// [followsYou] — handles that follow this account.
  /// [followedByFollows] — handle → how many of your follows follow them.
  /// [contacts] — handles you have a real conversation with.
  /// [feedAuthors] — handles whose posts are already loaded.
  /// [names] — a display name per handle where one is known.
  /// [alreadyFollowing] and [me] are removed, always: offering somebody you
  /// already follow is noise, and offering yourself is a bug people notice.
  static List<FollowSuggestion> rank({
    Set<String> followsYou = const {},
    Map<String, int> followedByFollows = const {},
    Set<String> contacts = const {},
    Set<String> feedAuthors = const {},
    Map<String, String> names = const {},
    Set<String> alreadyFollowing = const {},
    String me = '',
    int limit = maxSuggestions,
  }) {
    String norm(String u) => u.trim().toLowerCase().replaceFirst('@', '');
    final skip = {
      for (final u in alreadyFollowing) norm(u),
      if (me.trim().isNotEmpty) norm(me),
    }..remove('');

    // Best source per candidate, rather than one entry per source: the same
    // person arriving twice with two reasons is a list that looks padded.
    final best = <String, (SuggestionSource, int)>{};
    void offer(String raw, SuggestionSource source, int weight) {
      final u = norm(raw);
      if (u.isEmpty || skip.contains(u)) return;
      final had = best[u];
      if (had == null || source.index < had.$1.index) {
        best[u] = (source, weight);
      }
    }

    for (final u in followsYou) {
      offer(u, SuggestionSource.followsYou, 1);
    }
    followedByFollows.forEach((u, count) {
      if (count >= secondDegreeFloor) {
        offer(u, SuggestionSource.followedByFollows, count);
      }
    });
    for (final u in contacts) {
      offer(u, SuggestionSource.contact, 1);
    }
    for (final u in feedAuthors) {
      offer(u, SuggestionSource.inYourFeed, 1);
    }

    final out = [
      for (final e in best.entries)
        FollowSuggestion(
          username: e.key,
          name: (names[e.key] ?? names['@${e.key}'] ?? '').trim(),
          reason: reasonFor(e.value.$1, e.value.$2),
          // The source dominates; the weight only breaks ties inside one
          // source, so a heavily-followed stranger can never outrank
          // somebody who actually followed you.
          score: (4 - e.value.$1.index) * 1000 + e.value.$2.clamp(0, 999),
        ),
    ]..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        // Alphabetical under a tie, so the list does not reshuffle between
        // two identical builds — a list that moves under the thumb is worse
        // than one in a boring order.
        return byScore != 0 ? byScore : a.username.compareTo(b.username);
      });
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  /// The sentence under a name. Pure, so the copy is pinned by a test.
  static String reasonFor(SuggestionSource source, int count) =>
      switch (source) {
        SuggestionSource.followsYou => 'Follows you',
        SuggestionSource.followedByFollows =>
          'Followed by $count people you follow',
        SuggestionSource.contact => 'You talk to them',
        SuggestionSource.inYourFeed => 'Posts you have seen',
      };

  @visibleForTesting
  static String debugReason(SuggestionSource s, int n) => reasonFor(s, n);
}
