/// Planning a meeting in a conversation: what it is, when it is, and who
/// said they are coming.
///
/// **A meeting is a poll with three fixed answers and a date**, and it is
/// built as one on purpose — the same call [FormSpec] made. An RSVP rides
/// the poll vote path (`pollVotes` / `pollVotesBy`, the `'poll'` relay
/// event), which already carries the voter's identity, already lets someone
/// change their mind without duplicating, already seals, already mailboxes
/// for an offline recipient, and is already in the sealed-event roster a
/// test pins. A second, meeting-shaped event would have needed every one of
/// those again — and this file's own history is that an event missing from
/// one of those three registrations is silently dropped.
///
/// So nothing about a meeting reaches a server: it is a message, its answers
/// are answers to a poll, and both are end-to-end encrypted like every other
/// message in the conversation.
library;

/// The three answers, in the order they are stored as poll options. The
/// INDEX is the wire format, so these may be reordered only alongside a
/// migration — a stored `1` has to keep meaning Maybe.
enum MeetingRsvp {
  going('Going'),
  maybe('Maybe'),
  cant("Can't");

  const MeetingRsvp(this.label);

  /// What the button says, and what the poll option is stored as.
  final String label;

  // The poll option index each answer occupies is the enum's own `index`,
  // which is declaration order — hence the warning at the top of this enum
  // about reordering.

  /// The answer at that index, or null for anything outside the three — a
  /// payload naming option 7 is not a fourth kind of yes.
  static MeetingRsvp? fromIndex(int index) =>
      index >= 0 && index < MeetingRsvp.values.length
          ? MeetingRsvp.values[index]
          : null;

  /// The option list a meeting message carries, so the poll machinery
  /// underneath has something of the right length to tally into.
  static List<String> get options =>
      [for (final r in MeetingRsvp.values) r.label];
}

/// How many people gave each answer, indexed like [MeetingRsvp].
///
/// Counts PEOPLE, deliberately unlike [weightedPollTally]: a group poll can
/// weigh an admin's ballot at two because it is deciding something, and a
/// meeting is a headcount — "3 going" has to mean three people or the
/// number is a lie about how many chairs to find. Pure.
List<int> meetingRsvpCounts(Map<String, int> votesBy) {
  final counts = List<int>.filled(MeetingRsvp.values.length, 0);
  for (final choice in votesBy.values) {
    if (choice >= 0 && choice < counts.length) counts[choice]++;
  }
  return counts;
}

/// Who answered [rsvp], as voter phone digits. Pure.
List<String> meetingRespondents(Map<String, int> votesBy, MeetingRsvp rsvp) =>
    [
      for (final e in votesBy.entries)
        if (e.value == rsvp.index) e.key
    ];

/// How long before the start a reminder fires. Not a setting: one lead time
/// everybody understands beats a picker on a sheet that already asks for
/// four things, and half an hour is long enough to leave for something
/// nearby and short enough not to be forgotten again.
const Duration meetingReminderLead = Duration(minutes: 30);

/// When to remind about a meeting starting at [start], or null when there
/// is no useful moment left — a meeting less than the lead time away would
/// otherwise schedule a reminder in the past, which iOS delivers instantly
/// and reads as a bug rather than a reminder. Pure, with [now] injected so
/// the boundary is testable rather than dependent on the clock.
DateTime? meetingReminderAt(DateTime start, {DateTime? now}) {
  final at = start.subtract(meetingReminderLead);
  return at.isAfter(now ?? DateTime.now()) ? at : null;
}

/// Whether a meeting starting at [start] is over — used to retire the RSVP
/// buttons rather than the card, since what happened last Tuesday and who
/// came is still worth being able to scroll back to.
bool meetingIsPast(DateTime start, {DateTime? now}) =>
    (now ?? DateTime.now()).isAfter(start);
