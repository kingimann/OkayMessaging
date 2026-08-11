import 'public_forum_store.dart';

/// How a comment thread is ordered. Reddit's defaults, and the reason there
/// is more than one: a busy thread read newest-first is unreadable, and a
/// thread read top-first buries a good late answer forever.
enum ForumCommentSort {
  /// Score, then newest — the default, and what "Best" means here. Not a
  /// confidence-sorted ranking: this app has no per-rater matrix to compute
  /// one from, and calling a plain score sort "Best" is already generous.
  best,

  /// Newest first, so a live thread reads like a conversation.
  newest,

  /// Oldest first — how a thread actually unfolded.
  oldest,

  /// Highest score only, ignoring recency.
  top;

  String get label => switch (this) {
        ForumCommentSort.best => 'Best',
        ForumCommentSort.newest => 'New',
        ForumCommentSort.oldest => 'Old',
        ForumCommentSort.top => 'Top',
      };
}

/// One comment as it appears in a rendered thread: the comment, how deep it
/// sits, and how many replies hang beneath it.
class ThreadedComment {
  final PublicForumComment comment;

  /// 0 for a top-level reply to the post. Capped at [ForumThread.maxDepth].
  final int depth;

  /// Every descendant, not just direct children — what a collapsed comment
  /// says it is hiding.
  final int descendants;

  /// True when this comment is collapsed, so its subtree is not in the list.
  final bool collapsed;

  const ThreadedComment({
    required this.comment,
    required this.depth,
    required this.descendants,
    required this.collapsed,
  });
}

/// Turns the flat rows the server stores into the nested thread Reddit
/// readers expect.
///
/// The forum shipped with ONE level of replies — a reply to a reply had
/// nowhere to go and rendered as a sibling, so an argument three deep read as
/// four people talking past each other. This is the piece that makes a forum
/// a forum, and it is pure so the awkward parts are provable: a parent that
/// no longer exists, a cycle, and a thread deeper than the screen can indent.
abstract class ForumThread {
  /// How far replies indent before they stop. Beyond this a reply is rendered
  /// at the last level rather than dropped — Reddit continues the thread on
  /// its own page, which this app has no route for, and losing the comment
  /// entirely would be worse than losing the indent.
  static const int maxDepth = 6;

  /// Flattens [all] into render order, honouring [sort] at every level and
  /// omitting the subtree under anything in [collapsed].
  static List<ThreadedComment> build(
    List<PublicForumComment> all, {
    ForumCommentSort sort = ForumCommentSort.best,
    Set<String> collapsed = const {},
  }) {
    final byId = <String, PublicForumComment>{
      for (final c in all) c.id: c,
    };
    final children = <String, List<PublicForumComment>>{};
    final roots = <PublicForumComment>[];

    for (final c in all) {
      final parent = c.parentId;
      // A comment whose parent is gone becomes a root rather than vanishing.
      // Deleting a comment takes its replies in the schema, but a row can
      // also be hidden by the read policy (a banned author), and that must
      // not silently swallow everyone who answered them.
      if (parent == null || parent.isEmpty || !byId.containsKey(parent)) {
        roots.add(c);
      } else {
        (children[parent] ??= []).add(c);
      }
    }

    int compare(PublicForumComment a, PublicForumComment b) =>
        switch (sort) {
          ForumCommentSort.best => b.score != a.score
              ? b.score.compareTo(a.score)
              : b.createdAt.compareTo(a.createdAt),
          ForumCommentSort.top => b.score != a.score
              ? b.score.compareTo(a.score)
              : b.createdAt.compareTo(a.createdAt),
          ForumCommentSort.newest => b.createdAt.compareTo(a.createdAt),
          ForumCommentSort.oldest => a.createdAt.compareTo(b.createdAt),
        };

    for (final list in children.values) {
      list.sort(compare);
    }
    roots.sort(compare);

    // Descendant counts, computed once against the child map rather than by
    // walking during render — a collapsed comment has to know how much it is
    // hiding even though that subtree is never visited.
    final counts = <String, int>{};
    int count(String id, Set<String> seen) {
      if (counts.containsKey(id)) return counts[id]!;
      if (!seen.add(id)) return 0; // cycle
      var total = 0;
      for (final child in children[id] ?? const <PublicForumComment>[]) {
        total += 1 + count(child.id, seen);
      }
      return counts[id] = total;
    }

    final out = <ThreadedComment>[];
    // Explicit stack rather than recursion: a malicious or corrupted parent
    // chain could be thousands deep, and a blown Dart stack takes the whole
    // isolate rather than one screen.
    final visited = <String>{};
    void walk(PublicForumComment c, int depth) {
      if (!visited.add(c.id)) return; // a cycle never renders twice
      final isCollapsed = collapsed.contains(c.id);
      out.add(ThreadedComment(
        comment: c,
        depth: depth,
        descendants: count(c.id, <String>{}),
        collapsed: isCollapsed,
      ));
      if (isCollapsed) return;
      for (final child in children[c.id] ?? const <PublicForumComment>[]) {
        // Past the cap the thread keeps going at the same indent, so nothing
        // is lost — only the visual nesting stops.
        walk(child, depth < maxDepth ? depth + 1 : depth);
      }
    }

    for (final r in roots) {
      walk(r, 0);
    }
    return out;
  }
}
