import 'dart:math';

/// What one post is worth to one reader, and why.
class RankedPost<T> {
  final T post;
  final double score;
  const RankedPost(this.post, this.score);
}

/// The signals a post carries, lifted off [PublicPost] so the ranking can be
/// reasoned about — and tested — without the store, the network or a model.
class RankSignals {
  final String author;
  final DateTime createdAt;
  final int likes;
  final int replies;
  final int reposts;
  final int views;

  /// A reply is a fragment of somebody else's conversation. It reads badly
  /// on a timeline that is not showing the thing it answers.
  final bool isReply;

  const RankSignals({
    required this.author,
    required this.createdAt,
    this.likes = 0,
    this.replies = 0,
    this.reposts = 0,
    this.views = 0,
    this.isReply = false,
  });
}

/// Ranks the public timeline.
///
/// **What was there before.** Nothing. "For you" was
/// `order('created_at', descending)` over every post on the platform — the
/// enum said For you and it served a firehose. That works with twenty
/// accounts and is unusable at two thousand, and it is the one mechanic
/// that makes a feed read like a feed.
///
/// **The honest limit, stated rather than discovered: this reorders a
/// PAGE.** The fetch is newest-first with a `limit`, so nothing here can
/// surface a good post from last week that fell off the end — it can only
/// order what was asked for. [candidateWindow] is why the fetch now asks for
/// more than it shows: ranking three hundred and rendering fifty is a real
/// feed, ranking fifty and rendering fifty is a shuffle. A true ranked feed
/// scores server-side over everything, which needs a job and a table; this
/// is the client-side half and it is worth having on its own.
///
/// **Nothing is hidden.** The output is a permutation of the input, always
/// — a test pins that. Muting, blocking and every sanction still decide what
/// is in the list at all, so ranking can never reach past them; and a reader
/// who scrolls far enough sees everything they would have seen before, in a
/// different order.
class FeedRanking {
  FeedRanking._();

  /// How many posts to FETCH so there is something to rank. Six times what
  /// a screen shows, which is one extra page of latency and the difference
  /// between ordering a feed and shuffling one.
  static const int candidateWindow = 300;

  /// How long a post takes to lose half its engagement weight.
  ///
  /// Six hours, deliberately short. A social timeline's job is "what is
  /// happening", and a long half-life is what makes a feed show the same
  /// popular post for three days.
  static const Duration halfLife = Duration(hours: 6);

  /// A post from somebody you follow is worth this much more.
  ///
  /// **Deliberately large, and the number was chosen against the curve
  /// rather than picked.** The engagement term is `1 + log1p(e)`, which runs
  /// from 1.0 at nothing to about 9.5 at five thousand — so a boost of 3
  /// meant a stranger's SIX likes outranked a post from somebody you follow.
  /// That is the single most common complaint about an algorithmic feed
  /// ("I don't see the people I follow"), and it was measured: the first
  /// version of this failed its own test for exactly that reason.
  ///
  /// At 6.0 a stranger needs roughly four hundred weighted acts to beat a
  /// followed post with none — genuinely viral still reaches you, which is
  /// the honest other half and is pinned by its own test.
  static const double followedBoost = 6.0;

  /// A reply is worth this much of a top-level post. Not zero: a reply can
  /// be the best thing on the timeline, and dropping them outright is how a
  /// feed loses its conversations.
  static const double replyWeight = 0.35;

  /// Engagement, weighted by how much each act costs the person doing it.
  /// A repost puts their own name on it, a reply costs them words, a like
  /// is one tap. Views are the scale the other three are read against, so
  /// they count for very little on their own.
  static const double likeWeight = 1.0;
  static const double replyEngagementWeight = 2.0;
  static const double repostWeight = 3.0;
  static const double viewWeight = 0.02;

  /// One post's score for one reader.
  ///
  /// `log1p` on engagement, not the raw count: without it one post with a
  /// thousand likes outranks everything else on the timeline for as long as
  /// it is in the window, which is exactly the failure mode people mean
  /// when they say an algorithmic feed is "all the same posts".
  static double scoreFor(
    RankSignals s, {
    required Set<String> following,
    required DateTime now,
  }) {
    final engagement = s.likes * likeWeight +
        s.replies * replyEngagementWeight +
        s.reposts * repostWeight +
        s.views * viewWeight;
    final hours = now.difference(s.createdAt).inMinutes / 60.0;
    // A post from the future is a clock disagreeing, not a fresher post —
    // clamped, or a wrong device clock would pin its own posts to the top.
    final age = hours < 0 ? 0.0 : hours;
    final decay = pow(0.5, age / halfLife.inHours).toDouble();
    final affinity =
        following.contains(s.author.toLowerCase()) ? followedBoost : 1.0;
    final kind = s.isReply ? replyWeight : 1.0;
    // The +1 floor is what keeps a brand-new post with no engagement in the
    // running at all. Without it a timeline can only ever show what is
    // already popular, and nothing new could start.
    return (1.0 + log(1 + max(0.0, engagement))) * decay * affinity * kind;
  }

  /// The whole ranking: a permutation of [posts], best first.
  ///
  /// [signalsOf] lifts the signals off whatever type the caller holds, so
  /// this file needs to know nothing about the store.
  static List<T> rank<T>(
    List<T> posts, {
    required RankSignals Function(T) signalsOf,
    required Set<String> following,
    required DateTime now,
  }) {
    final follows = {for (final f in following) f.trim().toLowerCase()}
      ..remove('');
    final scored = [
      for (var i = 0; i < posts.length; i++)
        (
          i,
          posts[i],
          scoreFor(signalsOf(posts[i]), following: follows, now: now)
        ),
    ]..sort((a, b) {
        final byScore = b.$3.compareTo(a.$3);
        // Ties keep the order they arrived in — which is newest-first, the
        // order this feed has always used. A comparator that is not total
        // makes the list reshuffle between two identical builds.
        return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
      });
    return [for (final s in scored) s.$2];
  }
}
