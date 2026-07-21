import 'user.dart';

/// A status/story update posted by a contact.
class StatusUpdate {
  final String id;
  final AppUser user;
  final DateTime time;
  final bool viewed;

  /// Number of individual status frames the user has posted.
  final int frameCount;

  const StatusUpdate({
    required this.id,
    required this.user,
    required this.time,
    this.viewed = false,
    this.frameCount = 1,
  });
}
