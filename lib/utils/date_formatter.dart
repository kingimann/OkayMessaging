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
