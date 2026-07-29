import 'dart:convert';

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

/// A comment under a [ForumPost]. Comments nest one level: a reply carries
/// the [parentId] of the top-level comment it sits under.
class ForumComment {
  final String id;
  final String authorId;
  final String authorName;
  final DateTime time;
  final String body;
  final int score;
  final int myVote; // -1, 0, 1

  /// Id of the top-level comment this replies to; null for top-level.
  final String? parentId;
  final bool edited;

  const ForumComment({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.time,
    required this.body,
    this.score = 0,
    this.myVote = 0,
    this.parentId,
    this.edited = false,
  });

  ForumComment copyWith({String? body, int? score, int? myVote, bool? edited}) =>
      ForumComment(
        id: id,
        authorId: authorId,
        authorName: authorName,
        time: time,
        body: body ?? this.body,
        score: score ?? this.score,
        myVote: myVote ?? this.myVote,
        parentId: parentId,
        edited: edited ?? this.edited,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'authorId': authorId,
        'authorName': authorName,
        'time': time.toIso8601String(),
        'body': body,
        'score': score,
        'myVote': myVote,
        'parentId': parentId,
        'edited': edited,
      };

  factory ForumComment.fromJson(Map<String, dynamic> j) => ForumComment(
        id: j['id'] as String,
        authorId: j['authorId'] as String? ?? '',
        authorName: j['authorName'] as String? ?? '',
        time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime(2024),
        body: j['body'] as String? ?? '',
        score: (j['score'] as num?)?.toInt() ?? 0,
        myVote: (j['myVote'] as num?)?.toInt() ?? 0,
        parentId: j['parentId'] as String?,
        edited: j['edited'] as bool? ?? false,
      );
}

/// The tags a forum post can carry, shown as a colored chip and usable as a
/// feed filter. Kept as plain strings so old posts (no tag) stay valid.
const forumTags = <String>['Discussion', 'Question', 'Help', 'News'];

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

  /// A locked thread is closed to new comments; moderators can still unlock
  /// it. Existing comments stay readable.
  final bool locked;

  /// One of [forumTags], or '' for an untagged post.
  final String tag;
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
    this.locked = false,
    this.tag = '',
    this.comments = const [],
  });

  ForumPost copyWith({
    String? title,
    String? body,
    int? score,
    int? myVote,
    bool? pinned,
    bool? edited,
    bool? locked,
    String? tag,
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
        locked: locked ?? this.locked,
        tag: tag ?? this.tag,
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
        if (locked) 'locked': true,
        'tag': tag,
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
        locked: j['locked'] as bool? ?? false,
        tag: j['tag'] as String? ?? '',
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

  /// Ids of messages pinned to the top of the channel, oldest pin first.
  final List<String> pinnedMessageIds;

  /// Reddit-style posts, used only when [type] is [ChannelType.forum].
  final List<ForumPost> posts;

  const Channel({
    required this.id,
    required this.name,
    this.type = ChannelType.text,
    this.category = 'Text Channels',
    this.topic = '',
    this.messages = const [],
    this.pinnedMessageIds = const [],
    this.posts = const [],
  });

  /// Pinned messages that still exist, in pin order.
  List<Message> get pinnedMessages => [
        for (final id in pinnedMessageIds)
          ...messages.where((m) => m.id == id)
      ];

  Channel copyWith({
    String? name,
    ChannelType? type,
    String? category,
    String? topic,
    List<Message>? messages,
    List<String>? pinnedMessageIds,
    List<ForumPost>? posts,
  }) =>
      Channel(
        id: id,
        name: name ?? this.name,
        type: type ?? this.type,
        category: category ?? this.category,
        topic: topic ?? this.topic,
        messages: messages ?? this.messages,
        pinnedMessageIds: pinnedMessageIds ?? this.pinnedMessageIds,
        posts: posts ?? this.posts,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': _channelTypeName(type),
        'category': category,
        'topic': topic,
        'messages': messages.map((m) => m.toJson()).toList(),
        'pinnedMessageIds': pinnedMessageIds,
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
        pinnedMessageIds:
            (json['pinnedMessageIds'] as List?)?.cast<String>() ?? const [],
        posts: (json['posts'] as List? ?? const [])
            .map((p) => ForumPost.fromJson(Map<String, dynamic>.from(p as Map)))
            .toList(),
      );
}

/// A member's role within a community, in descending order of privilege.
///
///  * **owner**     — created the server; full control, can't be removed.
///  * **admin**     — manages the server: settings, channels, roles, members.
///  * **moderator** — keeps the peace: delete/pin messages, mute, kick/ban
///                    members below them. No settings or role control.
///  * **member**    — takes part.
enum MemberRole { owner, admin, moderator, member }

MemberRole _roleFrom(String? s) => switch (s) {
      'owner' => MemberRole.owner,
      'admin' => MemberRole.admin,
      'moderator' => MemberRole.moderator,
      _ => MemberRole.member,
    };

String roleName(MemberRole r) => switch (r) {
      MemberRole.owner => 'Owner',
      MemberRole.admin => 'Admin',
      MemberRole.moderator => 'Moderator',
      MemberRole.member => 'Member',
    };

/// Rank for privilege comparisons — higher outranks lower.
int roleRank(MemberRole r) => switch (r) {
      MemberRole.owner => 3,
      MemberRole.admin => 2,
      MemberRole.moderator => 1,
      MemberRole.member => 0,
    };

/// Whether [r] can perform moderator actions (delete/pin/mute/kick/ban).
bool roleCanModerate(MemberRole r) => roleRank(r) >= roleRank(MemberRole.moderator);

/// Whether [r] can change server settings, channels, and roles.
bool roleCanManageServer(MemberRole r) => roleRank(r) >= roleRank(MemberRole.admin);

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

/// Who may share a server's invite. Stored as strings so old JSON stays
/// valid and unknown future values degrade to the strictest reading.
const invitePolicyEveryone = 'everyone';
const invitePolicyModerators = 'moderators';
const invitePolicyAdmins = 'admins';

/// Whether [role] may invite people under [policy]. Pure. An unknown policy
/// string (from a newer build) is read as admins-only — failing closed keeps
/// a privacy choice meaningful on devices that don't understand it yet.
bool roleCanInvite(MemberRole role, String policy) => switch (policy) {
      invitePolicyEveryone => true,
      invitePolicyModerators => roleCanModerate(role),
      _ => roleCanManageServer(role),
    };

/// Returns the first entry of [words] found in [text] (case-insensitive,
/// whole string match anywhere), or null when nothing is filtered. Pure.
String? blockedWord(List<String> words, String text) {
  final lower = text.toLowerCase();
  for (final w in words) {
    final needle = w.trim().toLowerCase();
    if (needle.isNotEmpty && lower.contains(needle)) return w;
  }
  return null;
}

/// A community / server: a named space grouping several [Channel]s and the
/// [Member]s who belong to it.
class Community {
  final String id;
  final String name;

  /// Avatar color as a hex string (e.g. '#7A5CFF').
  final String color;

  /// An emoji shown as the server icon instead of the name's first letter
  /// ('' = use the letter).
  final String icon;

  /// The server's shared encryption key (base64, 32 random bytes), minted
  /// when the server is created and handed to members inside the E2E
  /// encrypted invite. Channel traffic over the relay is sealed with it, so
  /// only members can read it. Empty on servers from older builds.
  final String secret;

  /// A short description of what the server is about.
  final String description;
  final List<Channel> channels;
  final List<Member> members;

  // --- Moderation ---------------------------------------------------------

  /// Seconds a non-moderator must wait between channel messages (0 = off).
  final int slowModeSeconds;

  /// Whether plain members may create channels / forum posts. Moderators
  /// always can.
  final bool membersCanCreateChannels;
  final bool membersCanPost;

  /// Whether plain members may send channel messages at all. Off makes the
  /// server broadcast-only: everyone reads, moderators speak.
  final bool membersCanMessage;

  /// Who may share this server's invite: one of [invitePolicyEveryone],
  /// [invitePolicyModerators], [invitePolicyAdmins].
  final String invitePolicy;

  /// Messages and posts containing any of these words are refused.
  final List<String> bannedWords;

  /// People removed with "ban" — kept whole so they can be unbanned, and so
  /// a ban survives them trying to rejoin via invite.
  final List<Member> bannedMembers;

  /// Ids of members whose messages and posts are hidden for you.
  final List<String> mutedIds;

  const Community({
    required this.id,
    required this.name,
    required this.color,
    this.icon = '',
    this.secret = '',
    this.description = '',
    this.channels = const [],
    this.members = const [],
    this.slowModeSeconds = 0,
    this.membersCanCreateChannels = true,
    this.membersCanPost = true,
    this.membersCanMessage = true,
    this.invitePolicy = invitePolicyEveryone,
    this.bannedWords = const [],
    this.bannedMembers = const [],
    this.mutedIds = const [],
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

  /// The decoded [secret] bytes, or null when this server predates secrets.
  List<int>? get secretBytes {
    if (secret.isEmpty) return null;
    try {
      return base64Decode(secret);
    } catch (_) {
      return null;
    }
  }

  Community copyWith({
    String? name,
    String? color,
    String? icon,
    String? description,
    List<Channel>? channels,
    List<Member>? members,
    int? slowModeSeconds,
    bool? membersCanCreateChannels,
    bool? membersCanPost,
    bool? membersCanMessage,
    String? invitePolicy,
    List<String>? bannedWords,
    List<Member>? bannedMembers,
    List<String>? mutedIds,
  }) =>
      Community(
        id: id,
        name: name ?? this.name,
        color: color ?? this.color,
        icon: icon ?? this.icon,
        secret: secret,
        description: description ?? this.description,
        channels: channels ?? this.channels,
        members: members ?? this.members,
        slowModeSeconds: slowModeSeconds ?? this.slowModeSeconds,
        membersCanCreateChannels:
            membersCanCreateChannels ?? this.membersCanCreateChannels,
        membersCanPost: membersCanPost ?? this.membersCanPost,
        membersCanMessage: membersCanMessage ?? this.membersCanMessage,
        invitePolicy: invitePolicy ?? this.invitePolicy,
        bannedWords: bannedWords ?? this.bannedWords,
        bannedMembers: bannedMembers ?? this.bannedMembers,
        mutedIds: mutedIds ?? this.mutedIds,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'icon': icon,
        'secret': secret,
        'description': description,
        'channels': channels.map((c) => c.toJson()).toList(),
        'members': members.map((m) => m.toJson()).toList(),
        'slowModeSeconds': slowModeSeconds,
        'membersCanCreateChannels': membersCanCreateChannels,
        'membersCanPost': membersCanPost,
        'membersCanMessage': membersCanMessage,
        'invitePolicy': invitePolicy,
        'bannedWords': bannedWords,
        'bannedMembers': bannedMembers.map((m) => m.toJson()).toList(),
        'mutedIds': mutedIds,
      };

  factory Community.fromJson(Map<String, dynamic> json) => Community(
        id: json['id'] as String,
        name: json['name'] as String,
        color: json['color'] as String? ?? '#7A5CFF',
        icon: json['icon'] as String? ?? '',
        secret: json['secret'] as String? ?? '',
        description: json['description'] as String? ?? '',
        channels: (json['channels'] as List? ?? const [])
            .map((c) => Channel.fromJson(Map<String, dynamic>.from(c as Map)))
            .toList(),
        members: (json['members'] as List? ?? const [])
            .map((m) => Member.fromJson(Map<String, dynamic>.from(m as Map)))
            .toList(),
        slowModeSeconds: (json['slowModeSeconds'] as num?)?.toInt() ?? 0,
        membersCanCreateChannels:
            json['membersCanCreateChannels'] as bool? ?? true,
        membersCanPost: json['membersCanPost'] as bool? ?? true,
        membersCanMessage: json['membersCanMessage'] as bool? ?? true,
        invitePolicy:
            json['invitePolicy'] as String? ?? invitePolicyEveryone,
        bannedWords:
            (json['bannedWords'] as List?)?.cast<String>() ?? const [],
        bannedMembers: (json['bannedMembers'] as List? ?? const [])
            .map((m) => Member.fromJson(Map<String, dynamic>.from(m as Map)))
            .toList(),
        mutedIds: (json['mutedIds'] as List?)?.cast<String>() ?? const [],
      );
}
