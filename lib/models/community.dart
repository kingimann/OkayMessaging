import 'message.dart';

/// The kind of a [Channel]. Text and announcement channels hold messages;
/// voice channels are places to gather for a call.
enum ChannelType { text, voice, announcement }

ChannelType _channelTypeFrom(String? s) {
  switch (s) {
    case 'voice':
      return ChannelType.voice;
    case 'announcement':
      return ChannelType.announcement;
    default:
      return ChannelType.text;
  }
}

String _channelTypeName(ChannelType t) => switch (t) {
      ChannelType.voice => 'voice',
      ChannelType.announcement => 'announcement',
      ChannelType.text => 'text',
    };

/// A channel inside a [Community] (Discord-style `#channel`). Channels are
/// grouped under a [category] header and can be text, voice, or announcement.
class Channel {
  final String id;
  final String name;
  final ChannelType type;

  /// The category header this channel sits under (e.g. 'Text Channels').
  final String category;

  /// A short description shown at the top of the channel.
  final String topic;
  final List<Message> messages;

  const Channel({
    required this.id,
    required this.name,
    this.type = ChannelType.text,
    this.category = 'Text Channels',
    this.topic = '',
    this.messages = const [],
  });

  Channel copyWith({
    String? name,
    ChannelType? type,
    String? category,
    String? topic,
    List<Message>? messages,
  }) =>
      Channel(
        id: id,
        name: name ?? this.name,
        type: type ?? this.type,
        category: category ?? this.category,
        topic: topic ?? this.topic,
        messages: messages ?? this.messages,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': _channelTypeName(type),
        'category': category,
        'topic': topic,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
        id: json['id'] as String,
        name: json['name'] as String,
        type: _channelTypeFrom(json['type'] as String?),
        category: json['category'] as String? ?? 'Text Channels',
        topic: json['topic'] as String? ?? '',
        messages: (json['messages'] as List? ?? const [])
            .map((m) => Message.fromJson(Map<String, dynamic>.from(m as Map)))
            .toList(),
      );
}

/// A member's role within a community, in descending order of privilege.
enum MemberRole { owner, admin, member }

MemberRole _roleFrom(String? s) => switch (s) {
      'owner' => MemberRole.owner,
      'admin' => MemberRole.admin,
      _ => MemberRole.member,
    };

String roleName(MemberRole r) => switch (r) {
      MemberRole.owner => 'Owner',
      MemberRole.admin => 'Admin',
      MemberRole.member => 'Member',
    };

/// A person in a community's roster.
class Member {
  final String id;
  final String name;
  final MemberRole role;
  final bool online;

  const Member({
    required this.id,
    required this.name,
    this.role = MemberRole.member,
    this.online = false,
  });

  Member copyWith({String? name, MemberRole? role, bool? online}) => Member(
        id: id,
        name: name ?? this.name,
        role: role ?? this.role,
        online: online ?? this.online,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role.name,
        'online': online,
      };

  factory Member.fromJson(Map<String, dynamic> json) => Member(
        id: json['id'] as String,
        name: json['name'] as String,
        role: _roleFrom(json['role'] as String?),
        online: json['online'] as bool? ?? false,
      );
}

/// A community / server: a named space grouping several [Channel]s and the
/// [Member]s who belong to it.
class Community {
  final String id;
  final String name;

  /// Avatar color as a hex string (e.g. '#7A5CFF').
  final String color;
  final List<Channel> channels;
  final List<Member> members;

  const Community({
    required this.id,
    required this.name,
    required this.color,
    this.channels = const [],
    this.members = const [],
  });

  /// Category headers in first-seen order, so channels render grouped.
  List<String> get categories {
    final seen = <String>[];
    for (final ch in channels) {
      if (!seen.contains(ch.category)) seen.add(ch.category);
    }
    return seen;
  }

  List<Channel> channelsIn(String category) =>
      channels.where((c) => c.category == category).toList();

  Community copyWith({
    String? name,
    String? color,
    List<Channel>? channels,
    List<Member>? members,
  }) =>
      Community(
        id: id,
        name: name ?? this.name,
        color: color ?? this.color,
        channels: channels ?? this.channels,
        members: members ?? this.members,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'channels': channels.map((c) => c.toJson()).toList(),
        'members': members.map((m) => m.toJson()).toList(),
      };

  factory Community.fromJson(Map<String, dynamic> json) => Community(
        id: json['id'] as String,
        name: json['name'] as String,
        color: json['color'] as String? ?? '#7A5CFF',
        channels: (json['channels'] as List? ?? const [])
            .map((c) => Channel.fromJson(Map<String, dynamic>.from(c as Map)))
            .toList(),
        members: (json['members'] as List? ?? const [])
            .map((m) => Member.fromJson(Map<String, dynamic>.from(m as Map)))
            .toList(),
      );
}
