import 'user.dart';

enum CallType { voice, video }

enum CallDirection { incoming, outgoing, missed }

/// A single entry in the call log.
class CallRecord {
  final String id;
  final AppUser user;
  final DateTime time;
  final CallType type;
  final CallDirection direction;

  const CallRecord({
    required this.id,
    required this.user,
    required this.time,
    required this.type,
    required this.direction,
  });

  bool get isMissed => direction == CallDirection.missed;
}
