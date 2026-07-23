import 'message.dart';

/// The kind of a [Channel]. Text and announcement channels hold messages;
/// voice channels are places to gather for a call; forum channels hold
/// Reddit-style posts you can vote on and comment under.
enum ChannelType { text, voice, announcement, forum }

ChannelType _channelTypeFrom(String? s) {
  switch (s) {
    case 'voice':
      return ChannelType.voice;
    case 'announcement':
      return ChannelType.announcement;
    case 'forum':
      return ChannelType.forum;
    default:
      return ChannelType.text;
  }
}

String _channelTypeName(ChannelType t) => switch (t) {
      ChannelType.voice => 'voice',
      ChannelType.announcement => 'announcement',
      ChannelType.forum => 'forum',
      ChannelType.text => 'text',
    };

/// Applies a Reddit-style vote to a running net [score] given the voter's
/// current [myVote] (-1, 0, or 1) and a tapped [dir] (+1 up or -1 down).
/// Tapping the direction you already picked clears it. Returns the new
/// (score, myVote) pair.
(int, int) applyVote(int score, int myVote, int dir) {
  if (myVote == dir) return (score - dir, 0);
  return (score - myVote + dir, dir);
}

/// A comment under a [ForumPost].
class ForumComment {
  final String id;
  final String authorId;
  final String authorName;
  final DateTime time;
  final String body;
  final int score;
  final int myVote; // -1, 0, 1

  const ForumComment({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.time,
    required this.body,
    this.score = 0,
    this.myVote = 0,
  });

  ForumComment copyWith({int? score, int? myVote}) => ForumComment(
        id: id,
        authorId: authorId,
        authorName: authorName,
        time: time,
        body: body,
        score: score ?? this.score,
        myVote: myVote ?? this.myVote,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'authorId': authorId,
        'authorName': authorName,
        'time': time.toIso8601String(),
        'body': body,
        'score': score,
        'myVote': myVote,
      };

  factory ForumComment.fromJson(Map<String, dynamic> j) => ForumComment(
        id: j['id'] as String,
        authorId: j['authorId'] as String? ?? '',
        authorName: j['authorName'] as String? ?? '',
        time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime(2024),
        body: j['body'] as String? ?? '',
        score: (j['score'] as num?)?.toInt() ?? 0,
        myVote: (j['myVote'] as num?)?.toInt() ?? 0,
      );
}

/// A Reddit-style post inside a forum [Channel].
class ForumPost {
  final String id;
  final String authorId;
  final String authorName;
  final DateTime time;
  final String title;
  final String body;
  final int score;
  final int myVote; // -1, 0, 1
  final bool pinned;
  final bool edited;
  final List<ForumComment> comments;

  const ForumPost({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.time,
    required this.title,
    this.body = '',
    this.score = 1,
    this.myVote = 1,
    this.pinned = false,
    this.edited = false,
    this.comments = const [],
  });

  ForumPost copyWith({
    String? title,
    String? body,
    int? score,
    int? myVote,
    bool? pinned,
    bool? edited,
    List<ForumComment>? comments,
  }) =>
      ForumPost(
        id: id,
        authorId: authorId,
        authorName: authorName,
        time: time,
        title: title ?? this.title,
        body: body ?? this.body,
        score: score ?? this.score,
        myVote: myVote ?? this.myVote,
        pinned: pinned ?? this.pinned,
        edited: edited ?? this.edited,
        comments: comments ?? this.comments,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'authorId': authorId,
        'authorName': authorName,
        'time': time.toIso8601String(),
        'title': title,
        'body': body,
        'score': score,
        'myVote': myVote,
        'pinned': pinned,
        'edited': edited,
        'comments': comments.map((c) => c.toJson()).toList(),
      };

  factory ForumPost.fromJson(Map<String, dynamic> j) => ForumPost(
        id: j['id'] as String,
        authorId: j['authorId'] as String? ?? '',
        authorName: j['authorName'] as String? ?? '',
        time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime(2024),
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
        score: (j['score'] as num?)?.toInt() ?? 1,
        myVote: (j['myVote'] as num?)?.toInt() ?? 0,
        pinned: j['pinned'] as bool? ?? false,
        edited: j['edited'] as bool? ?? false,
        comments: (j['comments'] as List? ?? const [])
            .map((c) => ForumComment.fromJson(Map<String, dynamic>.from(c as Map)))
            .toList(),
      );
}

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

  /// Reddit-style posts, used only when [type] is [ChannelType.forum].
  final List<ForumPost> posts;

  const Channel({
    required this.id,
    required this.name,
    this.type = ChannelType.text,
    this.category = 'Text Channels',
    this.topic = '',
    this.messages = const [],
    this.posts = const [],
  });

  Channel copyWith({
    String? name,
    ChannelType? type,
    String? category,
    String? topic,
    List<Message>? messages,
    List<ForumPost>? posts,
  }) =>
      Channel(
        id: id,
        name: name ?? this.name,
        type: type ?? this.type,
        category: category ?? this.category,
        topic: topic ?? this.topic,
        messages: messages ?? this.messages,
        posts: posts ?? this.posts,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': _channelTypeName(type),
        'category': category,
        'topic': topic,
        'messages': messages.map((m) => m.toJson()).toList(),
        'posts': posts.map((p) => p.toJson()).toList(),
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
        posts: (json['posts'] as List? ?? const [])
            .map((p) => ForumPost.fromJson(Map<String, dynamic>.from(p as Map)))
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

  /// A short description of what the server is about.
  final String description;
  final List<Channel> channels;
  final List<Member> members;

  const Community({
    required this.id,
    required this.name,
    required this.color,
    this.description = '',
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
    String? description,
    List<Channel>? channels,
    List<Member>? members,
  }) =>
      Community(
        id: id,
        name: name ?? this.name,
        color: color ?? this.color,
        description: description ?? this.description,
        channels: channels ?? this.channels,
        members: members ?? this.members,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'description': description,
        'channels': channels.map((c) => c.toJson()).toList(),
        'members': members.map((m) => m.toJson()).toList(),
      };

  factory Community.fromJson(Map<String, dynamic> json) => Community(
        id: json['id'] as String,
        name: json['name'] as String,
        color: json['color'] as String? ?? '#7A5CFF',
        description: json['description'] as String? ?? '',
        channels: (json['channels'] as List? ?? const [])
            .map((c) => Channel.fromJson(Map<String, dynamic>.from(c as Map)))
            .toList(),
        members: (json['members'] as List? ?? const [])
            .map((m) => Member.fromJson(Map<String, dynamic>.from(m as Map)))
            .toList(),
      );
}
