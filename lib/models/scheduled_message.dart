/// A message the user has composed to be sent automatically at [time].
class ScheduledMessage {
  final String id;
  final String chatId;
  final String contactPhone;
  final String text;
  final DateTime time;

  const ScheduledMessage({
    required this.id,
    required this.chatId,
    required this.contactPhone,
    required this.text,
    required this.time,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'chatId': chatId,
        'contactPhone': contactPhone,
        'text': text,
        'time': time.toIso8601String(),
      };

  factory ScheduledMessage.fromJson(Map<String, dynamic> json) =>
      ScheduledMessage(
        id: json['id'] as String,
        chatId: json['chatId'] as String,
        contactPhone: json['contactPhone'] as String? ?? '',
        text: json['text'] as String,
        time: DateTime.parse(json['time'] as String),
      );
}
