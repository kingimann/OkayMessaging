/// The moderation console's own ordering and arithmetic, kept out of the
/// screen so it can be tested without a server.
///
/// Everything here is PURE. Nothing fetches, nothing decides who is allowed
/// to do anything — the Edge Function re-checks the caller's role before it
/// acts, and this only decides what a moderator is shown first.
library;

import 'platform_moderation.dart';

/// One reported account, with everything needed to rank it.
class ReportGroup {
  final String phone;
  final String handle;
  final List<ModerationReport> reports;

  /// The sanction already standing against this account, or null.
  final SanctionEntry? standing;

  const ReportGroup({
    required this.phone,
    required this.handle,
    required this.reports,
    this.standing,
  });

  int get count => reports.length;

  /// The longest anything in this pile has been waiting.
  DateTime get oldest => reports
      .map((r) => r.createdAt)
      .reduce((a, b) => a.isBefore(b) ? a : b);

  DateTime get newest => reports
      .map((r) => r.createdAt)
      .reduce((a, b) => a.isAfter(b) ? a : b);

  /// The distinct reasons given, in the order they first appear.
  List<String> get reasons {
    final seen = <String>{};
    for (final r in reports) {
      if (r.reason.isNotEmpty) seen.add(r.reason);
    }
    return seen.toList();
  }
}

/// How the queue is ordered, and the whole of it.
///
/// THREE SIGNALS, in this order, and the first is the one that was missing:
///
/// 1. **Nothing done about it yet.** An account already banned collects
///    reports that mostly need no second ban — the card says so, and it
///    belongs below the piles nobody has looked at. This is a DEFAULT, not a
///    hiding place: the group is still in the list, further down.
/// 2. **How many people reported it.** The original rule, and still the
///    strongest signal that something is really wrong.
/// 3. **How long the oldest has waited.** The signal a count alone loses: one
///    report sitting for a week is worse than three that arrived this
///    morning, and without this a queue is worked in arbitrary order.
List<ReportGroup> groupReports(
  Iterable<ModerationReport> reports, {
  Iterable<SanctionEntry> sanctions = const [],
}) {
  final standing = <String, SanctionEntry>{
    for (final s in sanctions) s.phone: s,
  };
  final byPhone = <String, List<ModerationReport>>{};
  for (final r in reports) {
    if (r.targetPhone.isEmpty) continue;
    byPhone.putIfAbsent(r.targetPhone, () => []).add(r);
  }
  final groups = [
    for (final e in byPhone.entries)
      ReportGroup(
        phone: e.key,
        handle: e.value
            .map((r) => r.targetHandle)
            .firstWhere((h) => h.isNotEmpty, orElse: () => ''),
        reports: e.value,
        standing: standing[e.key],
      ),
  ];
  groups.sort((a, b) {
    final acted = (a.standing != null ? 1 : 0) - (b.standing != null ? 1 : 0);
    if (acted != 0) return acted;
    final byCount = b.count.compareTo(a.count);
    if (byCount != 0) return byCount;
    return a.oldest.compareTo(b.oldest);
  });
  return groups;
}

/// Reports with no account attached — shown after the grouped ones, oldest
/// first, since there is nothing to rank them by but the wait.
List<ModerationReport> looseReports(Iterable<ModerationReport> reports) {
  final loose = [for (final r in reports) if (r.targetPhone.isEmpty) r]
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return loose;
}

/// The one line at the top of the console: what is waiting, right now.
///
/// The OLDEST WAIT is the number that belongs here rather than a total. A
/// count says how much there is; only the wait says whether the queue is
/// being kept up with, which is the question somebody opening this screen is
/// actually asking.
class ModerationSummary {
  final int openReports;
  final int reportedAccounts;
  final int activeSanctions;
  final Duration? oldestWait;

  const ModerationSummary({
    this.openReports = 0,
    this.reportedAccounts = 0,
    this.activeSanctions = 0,
    this.oldestWait,
  });

  bool get isClear => openReports == 0;

  factory ModerationSummary.of({
    required Iterable<ModerationReport> reports,
    required Iterable<SanctionEntry> sanctions,
    required DateTime now,
  }) {
    final list = reports.toList();
    final phones = <String>{
      for (final r in list)
        if (r.targetPhone.isNotEmpty) r.targetPhone
    };
    Duration? oldest;
    for (final r in list) {
      final waited = now.difference(r.createdAt);
      if (oldest == null || waited > oldest) oldest = waited;
    }
    return ModerationSummary(
      openReports: list.length,
      reportedAccounts: phones.length,
      activeSanctions: sanctions.length,
      // A negative wait is a clock disagreement, not a report from the
      // future; it reads as "just now" rather than as a wrong number.
      oldestWait: (oldest != null && oldest.isNegative) ? Duration.zero : oldest,
    );
  }
}

/// "3d" / "4h" / "just now" — short enough to sit in a dense row.
///
/// Deliberately coarse: a moderator wants to know whether something has been
/// waiting hours or days, and a queue that says "2h 14m" is claiming a
/// precision nobody acts on.
String shortWait(Duration d) {
  if (d.inDays >= 1) return '${d.inDays}d';
  if (d.inHours >= 1) return '${d.inHours}h';
  if (d.inMinutes >= 1) return '${d.inMinutes}m';
  return 'just now';
}

/// Whether [user] matches what was typed into the roster's search box.
///
/// Matches the handle and the display name, case-insensitively — the two
/// things a moderator has in front of them when somebody is reported. It
/// deliberately does NOT match the phone: the roster never carries one (the
/// directory function returns no number at all), so a box that appeared to
/// search by number would be a search that could never hit.
bool adminUserMatches(AdminUser user, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return user.username.toLowerCase().contains(q) ||
      user.name.toLowerCase().contains(q);
}

/// Whether an audit entry matches the trail's search box — the action, either
/// party, or the reason.
bool auditEntryMatches(ModerationLogEntry entry, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return entry.action.toLowerCase().contains(q) ||
      entry.actorPhone.toLowerCase().contains(q) ||
      entry.targetPhone.toLowerCase().contains(q) ||
      entry.actorRole.toLowerCase().contains(q) ||
      entry.reason.toLowerCase().contains(q);
}
