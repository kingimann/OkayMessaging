import 'message.dart';

/// A text channel inside a [Community] (Discord-style `#channel`).
class Channel {
  final String id;
  final String name;
  final List<Message> messages;

  const Channel({
    required this.id,
    required this.name,
    this.messages = const [],
  });

  Channel copyWith({String? name, List<Message>? messages}) => Channel(
        id: id,
        name: name ?? this.name,
        messages: messages ?? this.messages,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
        id: json['id'] as String,
        name: json['name'] as String,
        messages: (json['messages'] as List? ?? const [])
            .map((m) => Message.fromJson(Map<String, dynamic>.from(m as Map)))
            .toList(),
      );
}

/// A community / server: a named space grouping several [Channel]s.
class Community {
  final String id;
  final String name;

  /// Avatar color as a hex string (e.g. '#7A5CFF').
  final String color;
  final List<Channel> channels;

  const Community({
    required this.id,
    required this.name,
    required this.color,
    this.channels = const [],
  });

  Community copyWith({String? name, String? color, List<Channel>? channels}) =>
      Community(
        id: id,
        name: name ?? this.name,
        color: color ?? this.color,
        channels: channels ?? this.channels,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'channels': channels.map((c) => c.toJson()).toList(),
      };

  factory Community.fromJson(Map<String, dynamic> json) => Community(
        id: json['id'] as String,
        name: json['name'] as String,
        color: json['color'] as String? ?? '#7A5CFF',
        channels: (json['channels'] as List? ?? const [])
            .map((c) => Channel.fromJson(Map<String, dynamic>.from(c as Map)))
            .toList(),
      );
}
