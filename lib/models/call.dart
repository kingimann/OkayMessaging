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

  Map<String, dynamic> toJson() => {
        'id': id,
        'user': user.toJson(),
        'time': time.toIso8601String(),
        'type': type.name,
        'direction': direction.name,
      };

  factory CallRecord.fromJson(Map<String, dynamic> json) => CallRecord(
        id: json['id'] as String,
        user: AppUser.fromJson(Map<String, dynamic>.from(json['user'] as Map)),
        time: DateTime.tryParse(json['time'] as String? ?? '') ?? DateTime.now(),
        type: CallType.values.firstWhere(
          (t) => t.name == json['type'],
          orElse: () => CallType.voice,
        ),
        direction: CallDirection.values.firstWhere(
          (d) => d.name == json['direction'],
          orElse: () => CallDirection.incoming,
        ),
      );
}
