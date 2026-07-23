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

  /// How long the call was connected, in seconds (0 for missed/unanswered).
  final int durationSeconds;

  const CallRecord({
    required this.id,
    required this.user,
    required this.time,
    required this.type,
    required this.direction,
    this.durationSeconds = 0,
  });

  bool get isMissed => direction == CallDirection.missed;

  /// The connected duration as "m:ss" / "h:mm:ss", or null when there was none.
  String? get durationLabel {
    if (durationSeconds <= 0) return null;
    final h = durationSeconds ~/ 3600;
    final m = (durationSeconds % 3600) ~/ 60;
    final s = durationSeconds % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'user': user.toJson(),
        'time': time.toIso8601String(),
        'type': type.name,
        'direction': direction.name,
        'durationSeconds': durationSeconds,
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
        durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
      );
}
