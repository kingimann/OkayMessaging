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

  /// A GIF (or an attached photo as a data: URI) riding with the comment.
  /// Empty when it is words alone.
  final String gifUrl;

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
    this.gifUrl = '',
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
        gifUrl: gifUrl,
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
        if (gifUrl.isNotEmpty) 'gifUrl': gifUrl,
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
        gifUrl: j['gifUrl'] as String? ?? '',
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

  /// A GIF (or an attached photo as a data: URI) riding with the post.
  final String gifUrl;
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
    this.gifUrl = '',
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
    String? gifUrl,
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
        gifUrl: gifUrl ?? this.gifUrl,
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
        if (gifUrl.isNotEmpty) 'gifUrl': gifUrl,
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
        gifUrl: j['gifUrl'] as String? ?? '',
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

  /// The newest message that belongs to the ROOM, skipping thread replies —
  /// the channel counterpart of `Chat.lastMessage`. A channel's own preview
  /// (the server's channel list) must not show the latest reply to a side
  /// conversation as if it were the channel's own newest word.
  Message? get lastRoomMessage {
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].threadRootId == null) return messages[i];
    }
    return null;
  }

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

/// The permission tiers a custom role may confer, offered to the admin who
/// creates one. 'owner' is deliberately absent — a role can lift a member to
/// admin at most, never to the one seat that can delete the server.
const customRoleTiers = <MemberRole>[
  MemberRole.member,
  MemberRole.moderator,
  MemberRole.admin,
];

/// A server-defined role: a named, coloured label an admin creates and hands
/// to members — the Discord "role" people ask for. Beyond decoration it
/// carries a [tier], the base privilege it confers, so a custom role composes
/// with the built-in owner/admin/moderator/member ladder instead of replacing
/// the enforcement that already guards every action. A 'member'-tier role is
/// purely cosmetic (a "VIP" chip); a 'moderator'- or 'admin'-tier role grants
/// those powers to whoever wears it.
class CustomRole {
  final String id;
  final String name;

  /// Hex colour for the badge, e.g. '#E0533D'.
  final String color;

  /// The privilege this role grants. Never [MemberRole.owner].
  final MemberRole tier;

  /// An optional emoji badge shown beside the role name on a member — the
  /// Discord "role icon". Empty for a plain coloured chip.
  final String badge;

  const CustomRole({
    required this.id,
    required this.name,
    this.color = '#17708A',
    this.tier = MemberRole.member,
    this.badge = '',
  });

  CustomRole copyWith(
          {String? name, String? color, MemberRole? tier, String? badge}) =>
      CustomRole(
        id: id,
        name: name ?? this.name,
        color: color ?? this.color,
        tier: tier ?? this.tier,
        badge: badge ?? this.badge,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'tier': tier.name,
        if (badge.isNotEmpty) 'badge': badge,
      };

  factory CustomRole.fromJson(Map<String, dynamic> j) => CustomRole(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        color: j['color'] as String? ?? '#17708A',
        badge: j['badge'] as String? ?? '',
        // A tier from a newer build we don't understand, or 'owner' smuggled
        // in, both read as the harmless floor rather than granting power.
        tier: switch (j['tier'] as String?) {
          'admin' => MemberRole.admin,
          'moderator' => MemberRole.moderator,
          _ => MemberRole.member,
        },
      );
}

/// A person in a community's roster.
class Member {
  final String id;
  final String name;
  final MemberRole role;
  final bool online;

  /// Id of the [CustomRole] this member wears ('' = none). The role's colour
  /// and name badge them, and its tier can lift what they're allowed to do —
  /// see [Community.effectiveRole].
  final String roleId;

  const Member({
    required this.id,
    required this.name,
    this.role = MemberRole.member,
    this.online = false,
    this.roleId = '',
  });

  Member copyWith(
          {String? name, MemberRole? role, bool? online, String? roleId}) =>
      Member(
        id: id,
        name: name ?? this.name,
        role: role ?? this.role,
        online: online ?? this.online,
        roleId: roleId ?? this.roleId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role.name,
        'online': online,
        if (roleId.isNotEmpty) 'roleId': roleId,
      };

  factory Member.fromJson(Map<String, dynamic> json) => Member(
        id: json['id'] as String,
        name: json['name'] as String,
        role: _roleFrom(json['role'] as String?),
        online: json['online'] as bool? ?? false,
        roleId: json['roleId'] as String? ?? '',
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

  /// An optional SECOND accent colour (hex). When set, the server icon and its
  /// header run as a gradient from [color] to this; '' (the default) keeps the
  /// old look — [color] shaded darker.
  final String color2;

  /// The hex the icon/header gradient ends on: the chosen second colour, or the
  /// primary again when there is none (the UI shades that itself).
  String get gradientEndHex => color2.isEmpty ? color : color2;
  bool get hasGradient => color2.isNotEmpty;

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

  /// The server's custom roles, created by its admins. Empty on a plain
  /// server and on builds that predate the feature.
  final List<CustomRole> roles;

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

  /// Whether members' phones announce this server to anyone in Bluetooth
  /// range, and hand out the way in when asked.
  ///
  /// OFF UNLESS SOMEBODY SAYS OTHERWISE, and it is a real decision rather than
  /// a convenience: a beacon puts this server's name in the air for every
  /// stranger nearby, and answering the request that follows gives them the
  /// key that decrypts everything in it. That is the right trade for a café
  /// or a conference and the wrong one for four friends, so it is asked
  /// rather than assumed.
  final bool discoverableNearby;

  /// Messages and posts containing any of these words are refused.
  final List<String> bannedWords;

  /// People removed with "ban" — kept whole so they can be unbanned, and so
  /// a ban survives them trying to rejoin via invite.
  final List<Member> bannedMembers;

  /// Ids of members whose messages and posts are hidden for you.
  final List<String> mutedIds;

  // --- Paid membership ---------------------------------------------------

  /// Whether joining this server costs a monthly subscription. Off = a free
  /// server, the default and what every existing server is.
  ///
  /// Unlike a paid PUBLIC post, this is not access-control over readable
  /// content — a server's traffic is already E2E sealed under [secret], so the
  /// paywall gates getting IN (receiving the invite and its secret), not
  /// screening what's said. The honest limit that follows: a member who lapses
  /// keeps the secret they were handed, like any departed member, until the
  /// owner rotates the server key.
  final bool paid;

  /// The monthly price in cents when [paid]. Maps to one of the four IAP
  /// membership tiers, same shape as a creator subscription.
  final int priceCents;

  /// A short free-text pitch shown on the subscribe sheet ('' = none).
  final String subPitch;

  // --- Discovery ---------------------------------------------------------

  /// Whether this server is PUBLIC — listed in the world-readable Discover
  /// directory, so anyone with the app can find it and join without an invite.
  /// Off = private, the default and what every existing server is: reachable
  /// only through an invite/code.
  ///
  /// Listing a server publishes its whole invite snapshot — SECRET INCLUDED —
  /// to a table anyone can read (`docs/public_servers.sql`). That is the
  /// deliberate trade of a public server: "anyone may join" is the same
  /// decision as "anyone may hold the key". A PAID server can't be listed (its
  /// secret must stay behind the paywall), so this and [paid] are exclusive.
  final bool listed;

  const Community({
    required this.id,
    required this.name,
    required this.color,
    this.color2 = '',
    this.icon = '',
    this.secret = '',
    this.description = '',
    this.channels = const [],
    this.members = const [],
    this.roles = const [],
    this.slowModeSeconds = 0,
    this.membersCanCreateChannels = true,
    this.membersCanPost = true,
    this.membersCanMessage = true,
    this.invitePolicy = invitePolicyEveryone,
    this.discoverableNearby = false,
    this.bannedWords = const [],
    this.bannedMembers = const [],
    this.mutedIds = const [],
    this.paid = false,
    this.priceCents = 0,
    this.subPitch = '',
    this.listed = false,
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

  /// The custom role with [id], or null when there's no such role (or [id] is
  /// empty).
  CustomRole? roleById(String id) {
    if (id.isEmpty) return null;
    for (final r in roles) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// A member's real privilege: the higher of their built-in [Member.role] and
  /// the tier of any custom role they wear. This is the single place custom
  /// roles turn into power — [CommunityStore.myRole] reads it, so every
  /// permission check that already funnels through myRole picks a role's grant
  /// up for free, and no check gets a second, forgettable code path.
  MemberRole effectiveRole(Member m) {
    final custom = roleById(m.roleId);
    if (custom == null) return m.role;
    return roleRank(custom.tier) > roleRank(m.role) ? custom.tier : m.role;
  }

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
    String? color2,
    String? icon,
    String? description,
    List<Channel>? channels,
    List<Member>? members,
    List<CustomRole>? roles,
    int? slowModeSeconds,
    bool? membersCanCreateChannels,
    bool? membersCanPost,
    bool? membersCanMessage,
    bool? discoverableNearby,
    String? invitePolicy,
    List<String>? bannedWords,
    List<Member>? bannedMembers,
    List<String>? mutedIds,
    bool? paid,
    int? priceCents,
    String? subPitch,
    bool? listed,
  }) =>
      Community(
        id: id,
        name: name ?? this.name,
        color: color ?? this.color,
        color2: color2 ?? this.color2,
        icon: icon ?? this.icon,
        secret: secret,
        description: description ?? this.description,
        channels: channels ?? this.channels,
        members: members ?? this.members,
        roles: roles ?? this.roles,
        slowModeSeconds: slowModeSeconds ?? this.slowModeSeconds,
        membersCanCreateChannels:
            membersCanCreateChannels ?? this.membersCanCreateChannels,
        membersCanPost: membersCanPost ?? this.membersCanPost,
        membersCanMessage: membersCanMessage ?? this.membersCanMessage,
        discoverableNearby: discoverableNearby ?? this.discoverableNearby,
        invitePolicy: invitePolicy ?? this.invitePolicy,
        bannedWords: bannedWords ?? this.bannedWords,
        bannedMembers: bannedMembers ?? this.bannedMembers,
        mutedIds: mutedIds ?? this.mutedIds,
        paid: paid ?? this.paid,
        priceCents: priceCents ?? this.priceCents,
        subPitch: subPitch ?? this.subPitch,
        listed: listed ?? this.listed,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        if (color2.isNotEmpty) 'color2': color2,
        'icon': icon,
        'secret': secret,
        'description': description,
        'channels': channels.map((c) => c.toJson()).toList(),
        'members': members.map((m) => m.toJson()).toList(),
        'roles': roles.map((r) => r.toJson()).toList(),
        'slowModeSeconds': slowModeSeconds,
        'membersCanCreateChannels': membersCanCreateChannels,
        'membersCanPost': membersCanPost,
        'membersCanMessage': membersCanMessage,
        'discoverableNearby': discoverableNearby,
        'invitePolicy': invitePolicy,
        'bannedWords': bannedWords,
        'bannedMembers': bannedMembers.map((m) => m.toJson()).toList(),
        'mutedIds': mutedIds,
        if (paid) ...{
          'paid': true,
          'priceCents': priceCents,
          if (subPitch.isNotEmpty) 'subPitch': subPitch,
        },
        if (listed) 'listed': true,
      };

  factory Community.fromJson(Map<String, dynamic> json) => Community(
        id: json['id'] as String,
        name: json['name'] as String,
        color: json['color'] as String? ?? '#7A5CFF',
        color2: json['color2'] as String? ?? '',
        icon: json['icon'] as String? ?? '',
        secret: json['secret'] as String? ?? '',
        description: json['description'] as String? ?? '',
        channels: (json['channels'] as List? ?? const [])
            .map((c) => Channel.fromJson(Map<String, dynamic>.from(c as Map)))
            .toList(),
        members: (json['members'] as List? ?? const [])
            .map((m) => Member.fromJson(Map<String, dynamic>.from(m as Map)))
            .toList(),
        roles: (json['roles'] as List? ?? const [])
            .map((r) => CustomRole.fromJson(Map<String, dynamic>.from(r as Map)))
            .toList(),
        slowModeSeconds: (json['slowModeSeconds'] as num?)?.toInt() ?? 0,
        membersCanCreateChannels:
            json['membersCanCreateChannels'] as bool? ?? true,
        membersCanPost: json['membersCanPost'] as bool? ?? true,
        membersCanMessage: json['membersCanMessage'] as bool? ?? true,
        discoverableNearby:
            json['discoverableNearby'] as bool? ?? false,
        invitePolicy:
            json['invitePolicy'] as String? ?? invitePolicyEveryone,
        bannedWords:
            (json['bannedWords'] as List?)?.cast<String>() ?? const [],
        bannedMembers: (json['bannedMembers'] as List? ?? const [])
            .map((m) => Member.fromJson(Map<String, dynamic>.from(m as Map)))
            .toList(),
        mutedIds: (json['mutedIds'] as List?)?.cast<String>() ?? const [],
        paid: json['paid'] as bool? ?? false,
        priceCents: (json['priceCents'] as num?)?.toInt() ?? 0,
        subPitch: json['subPitch'] as String? ?? '',
        listed: json['listed'] as bool? ?? false,
      );
}
