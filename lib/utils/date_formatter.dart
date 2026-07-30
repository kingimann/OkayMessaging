import 'package:intl/intl.dart';

/// Formatting helpers that mimic WhatsApp's relative time labels.
class DateFormatter {
  DateFormatter._();

  /// Short label for a chat list row: time for today, "Yesterday",
  /// weekday for the last week, else a numeric date.
  static String chatListLabel(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(time.year, time.month, time.day);
    final diff = today.difference(that).inDays;

    if (diff == 0) return DateFormat('HH:mm').format(time);
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return DateFormat('EEEE').format(time);
    return DateFormat('dd/MM/yyyy').format(time);
  }

  /// A timeline age: "now", "2m", "5h", "3d", then a date.
  ///
  /// Different from [chatListLabel] on purpose. A chat row has one line for a
  /// whole conversation and can spend it on "Yesterday"; a post sits beside a
  /// name and a handle with a few characters to spare, so the unit is a single
  /// letter and the switch to a date happens at a week. [now] is a parameter so
  /// the rule is testable rather than dependent on the clock.
  static String postAge(DateTime time, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final seconds = at.difference(time).inSeconds;
    // A post from a device whose clock is ahead reads as the future; "now" is
    // the least wrong thing to say about it.
    if (seconds < 60) return 'now';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return '${minutes}m';
    final hours = minutes ~/ 60;
    if (hours < 24) return '${hours}h';
    final days = hours ~/ 24;
    if (days < 7) return '${days}d';
    // Beyond a week the year only matters when it is not this one.
    return time.year == at.year
        ? DateFormat('d MMM').format(time)
        : DateFormat('d MMM yy').format(time);
  }

  /// Time shown inside a message bubble.
  static String messageTime(DateTime time) => DateFormat('HH:mm').format(time);

  /// Header separating messages by day within a conversation.
  static String messageDayHeader(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(time.year, time.month, time.day);
    final diff = today.difference(that).inDays;

    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return DateFormat('EEEE').format(time);
    return DateFormat('dd MMMM yyyy').format(time);
  }

  /// Label for a scheduled send time, e.g. "Today 18:30" / "12 Aug 09:00".
  static String scheduleLabel(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(time.year, time.month, time.day);
    final diff = that.difference(today).inDays;

    final t = DateFormat('HH:mm').format(time);
    if (diff == 0) return 'Today $t';
    if (diff == 1) return 'Tomorrow $t';
    if (diff > 1 && diff < 7) return '${DateFormat('EEEE').format(time)} $t';
    return '${DateFormat('d MMM').format(time)} $t';
  }

  /// Label used in the call log.
  static String callLabel(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(time.year, time.month, time.day);
    final diff = today.difference(that).inDays;

    final t = DateFormat('HH:mm').format(time);
    if (diff == 0) return 'Today, $t';
    if (diff == 1) return 'Yesterday, $t';
    return '${DateFormat('dd MMM').format(time)}, $t';
  }
}
