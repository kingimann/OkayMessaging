import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/community.dart';
import '../models/message.dart';

/// Local store for Discord-style communities (servers) and their channels.
/// Everything lives on the device and is persisted to [SharedPreferences];
/// nothing is stored on a server.
class CommunityStore extends ChangeNotifier {
  CommunityStore._();
  static final CommunityStore instance = CommunityStore._();

  static const _key = 'communities_v1';

  List<Community> _communities = [];
  SharedPreferences? _prefs;

  List<Community> get communities => List.unmodifiable(_communities);

  /// A serializable snapshot of every community (used by chat backup).
  List<Map<String, dynamic>> toJsonList() =>
      _communities.map((c) => c.toJson()).toList();

  /// Replaces all communities from a backup snapshot and persists them.
  void hydrate(List<dynamic> json) {
    try {
      _communities = json
          .map((c) => Community.fromJson(Map<String, dynamic>.from(c as Map)))
          .toList();
      _save();
      notifyListeners();
    } catch (_) {}
  }

  /// Loads persisted communities, seeding a sample one on first run.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        _communities = (jsonDecode(raw) as List)
            .map((c) => Community.fromJson(Map<String, dynamic>.from(c as Map)))
            .toList();
      } catch (_) {
        _communities = _seed();
      }
    } else {
      _communities = _seed();
      _save();
    }
    notifyListeners();
  }

  List<Community> _seed() => [
        Community(
          id: 'seed_design',
          name: 'Design Team',
          color: '#7A5CFF',
          description: 'Where the product design crew shares work, '
              'gives feedback, and hangs out.',
          channels: [
            Channel(
              id: 'seed_announce',
              name: 'announcements',
              type: ChannelType.announcement,
              category: 'Information',
              topic: 'Team-wide updates.',
              messages: [
                Message(
                  id: 'seed_m0',
                  text: 'Welcome to the Design Team community! 🎨',
                  time: DateTime(2024, 1, 1, 9),
                  isMe: false,
                ),
              ],
            ),
            Channel(
              id: 'seed_general',
              name: 'general',
              category: 'Text Channels',
              topic: 'Chat about anything.',
              messages: [
                Message(
                  id: 'seed_m1',
                  text: 'What is everyone working on today?',
                  time: DateTime(2024, 1, 1, 9, 30),
                  isMe: false,
                ),
              ],
            ),
            const Channel(
                id: 'seed_ideas',
                name: 'ideas',
                category: 'Text Channels',
                topic: 'Pitch and refine concepts.'),
            const Channel(
                id: 'seed_random', name: 'random', category: 'Text Channels'),
            Channel(
              id: 'seed_forum',
              name: 'discussion',
              type: ChannelType.forum,
              category: 'Forums',
              topic: 'Ask questions, share wins, and vote.',
              posts: [
                ForumPost(
                  id: 'seed_post_1',
                  authorId: 'm_ada',
                  authorName: 'Ada Lovelace',
                  time: DateTime(2024, 1, 2, 9),
                  title: 'What design tools is everyone using in 2024?',
                  body: 'Curious what the team has settled on for handoff — '
                      'still Figma, or has anyone moved on?',
                  score: 42,
                  myVote: 0,
                  comments: [
                    ForumComment(
                      id: 'seed_c1',
                      authorId: 'm_grace',
                      authorName: 'Grace Hopper',
                      time: DateTime(2024, 1, 2, 10),
                      body: 'Figma + a few Framer prototypes for motion.',
                      score: 12,
                    ),
                    ForumComment(
                      id: 'seed_c2',
                      authorId: 'm_alan',
                      authorName: 'Alan Turing',
                      time: DateTime(2024, 1, 2, 11),
                      body: 'Same here. Dev-mode has been a big help.',
                      score: 5,
                    ),
                  ],
                ),
                ForumPost(
                  id: 'seed_post_2',
                  authorId: 'm_grace',
                  authorName: 'Grace Hopper',
                  time: DateTime(2024, 1, 3, 14),
                  title: 'New brand palette — feedback wanted 🎨',
                  body: 'Dropped v2 of the palette in the files. '
                      'Vote and comment if the contrast works for you.',
                  score: 27,
                  myVote: 1,
                ),
              ],
            ),
            const Channel(
                id: 'seed_lounge',
                name: 'Lounge',
                type: ChannelType.voice,
                category: 'Voice Channels'),
            const Channel(
                id: 'seed_standup',
                name: 'Standup',
                type: ChannelType.voice,
                category: 'Voice Channels'),
          ],
          members: const [
            Member(
                id: 'me', name: 'You', role: MemberRole.owner, online: true),
            Member(
                id: 'm_ada',
                name: 'Ada Lovelace',
                role: MemberRole.admin,
                online: true),
            Member(id: 'm_grace', name: 'Grace Hopper', online: true),
            Member(id: 'm_alan', name: 'Alan Turing'),
          ],
        ),
      ];

  void _save() {
    _prefs?.setString(
        _key, jsonEncode(_communities.map((c) => c.toJson()).toList()));
  }

  /// Notifies listeners without changing data — backs pull-to-refresh.
  void touch() => notifyListeners();

  Community? byId(String id) {
    final i = _communities.indexWhere((c) => c.id == id);
    return i == -1 ? null : _communities[i];
  }

  void _replace(Community community) {
    final i = _communities.indexWhere((c) => c.id == community.id);
    if (i != -1) {
      _communities[i] = community;
      _save();
      notifyListeners();
    }
  }

  /// Creates a community with a starter set of channels and the creator as
  /// owner.
  Community createCommunity(String name, {String color = '#7A5CFF'}) {
    final id = 'c_${name.hashCode}_${_communities.length}';
    final community = Community(
      id: id,
      name: name.trim(),
      color: color,
      channels: [
        Channel(
            id: '${id}_general',
            name: 'general',
            category: 'Text Channels'),
        Channel(
            id: '${id}_voice',
            name: 'General',
            type: ChannelType.voice,
            category: 'Voice Channels'),
      ],
      members: const [
        Member(id: 'me', name: 'You', role: MemberRole.owner, online: true),
      ],
    );
    _communities.add(community);
    _save();
    notifyListeners();
    return community;
  }

  /// Normalizes a channel name: voice/announcement keep spaces and case,
  /// text channels are lower-kebab-cased like Discord.
  static String _cleanChannelName(String raw, ChannelType type) {
    final trimmed = raw.trim();
    if (type == ChannelType.voice) return trimmed;
    return trimmed
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'[^a-z0-9\-_]'), '');
  }

  void addChannel(
    String communityId,
    String channelName, {
    ChannelType type = ChannelType.text,
    String? category,
  }) {
    final community = byId(communityId);
    if (community == null) return;
    final clean = _cleanChannelName(channelName, type);
    if (clean.isEmpty) return;
    final cat = category ??
        switch (type) {
          ChannelType.voice => 'Voice Channels',
          ChannelType.announcement => 'Information',
          ChannelType.forum => 'Forums',
          ChannelType.text => 'Text Channels',
        };
    final channel = Channel(
      id: '${communityId}_${clean.hashCode}_${community.channels.length}',
      name: clean,
      type: type,
      category: cat,
    );
    _replace(community.copyWith(channels: [...community.channels, channel]));
  }

  void renameChannel(String communityId, String channelId, String newName) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final clean = _cleanChannelName(newName, ch.type);
      return clean.isEmpty ? ch : ch.copyWith(name: clean);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  void setChannelTopic(String communityId, String channelId, String topic) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      return ch.copyWith(topic: topic.trim());
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  void deleteChannel(String communityId, String channelId) {
    final community = byId(communityId);
    if (community == null) return;
    final channels =
        community.channels.where((c) => c.id != channelId).toList();
    _replace(community.copyWith(channels: channels));
  }

  void postMessage(String communityId, String channelId, Message message) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      return ch.copyWith(messages: [...ch.messages, message]);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// Records the local user's vote on a poll message in a channel, moving it
  /// from any previous choice.
  void votePollInChannel(
      String communityId, String channelId, String messageId, int option) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final msgs = ch.messages.map((m) {
        if (m.id != messageId || !m.isPoll) return m;
        if (option < 0 || option >= m.pollOptions.length) return m;
        if (m.pollMyVote == option) return m;
        final votes = [...m.pollVotes];
        while (votes.length < m.pollOptions.length) {
          votes.add(0);
        }
        final prev = m.pollMyVote;
        if (prev >= 0 && prev < votes.length && votes[prev] > 0) votes[prev]--;
        votes[option]++;
        return m.copyWith(pollVotes: votes, pollMyVote: option);
      }).toList();
      return ch.copyWith(messages: msgs);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  // --- Forum channels ----------------------------------------------------

  /// Adds a Reddit-style [post] to a forum channel (newest additions are
  /// prepended so they show first under "New").
  void addForumPost(String communityId, String channelId, ForumPost post) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      return ch.copyWith(posts: [post, ...ch.posts]);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// Applies a [dir] (+1/-1) vote to a forum post.
  void voteForumPost(
      String communityId, String channelId, String postId, int dir) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        final (score, myVote) = applyVote(p.score, p.myVote, dir);
        return p.copyWith(score: score, myVote: myVote);
      }).toList();
      return ch.copyWith(posts: posts);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// Adds a [comment] under a forum post.
  void addForumComment(String communityId, String channelId, String postId,
      ForumComment comment) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        return p.copyWith(comments: [...p.comments, comment]);
      }).toList();
      return ch.copyWith(posts: posts);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// Applies a [dir] (+1/-1) vote to a comment under a forum post.
  void voteForumComment(String communityId, String channelId, String postId,
      String commentId, int dir) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        final comments = p.comments.map((c) {
          if (c.id != commentId) return c;
          final (score, myVote) = applyVote(c.score, c.myVote, dir);
          return c.copyWith(score: score, myVote: myVote);
        }).toList();
        return p.copyWith(comments: comments);
      }).toList();
      return ch.copyWith(posts: posts);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// Removes a forum post entirely.
  void deleteForumPost(String communityId, String channelId, String postId) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      return ch.copyWith(
          posts: ch.posts.where((p) => p.id != postId).toList());
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// Removes a comment from a forum post.
  void deleteForumComment(String communityId, String channelId, String postId,
      String commentId) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        return p.copyWith(
            comments: p.comments.where((c) => c.id != commentId).toList());
      }).toList();
      return ch.copyWith(posts: posts);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// Pins or unpins a forum post (moderator action).
  void togglePinForumPost(
      String communityId, String channelId, String postId) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        return p.copyWith(pinned: !p.pinned);
      }).toList();
      return ch.copyWith(posts: posts);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// Whether the local user (always represented as member `me`) can moderate
  /// [community] — i.e. is its owner or an admin.
  bool canModerate(String communityId) {
    final community = byId(communityId);
    if (community == null) return false;
    final me = community.members
        .cast<Member?>()
        .firstWhere((m) => m?.id == 'me', orElse: () => null);
    return me != null &&
        (me.role == MemberRole.owner || me.role == MemberRole.admin);
  }

  void deleteCommunity(String communityId) {
    _communities.removeWhere((c) => c.id == communityId);
    _save();
    notifyListeners();
  }

  // --- Server management -------------------------------------------------

  void renameCommunity(String communityId, String name) {
    final community = byId(communityId);
    if (community == null || name.trim().isEmpty) return;
    _replace(community.copyWith(name: name.trim()));
  }

  void setCommunityColor(String communityId, String color) {
    final community = byId(communityId);
    if (community == null) return;
    _replace(community.copyWith(color: color));
  }

  void setCommunityDescription(String communityId, String description) {
    final community = byId(communityId);
    if (community == null) return;
    _replace(community.copyWith(description: description.trim()));
  }

  /// Edits a forum post's title/body (author or moderator) and flags it edited.
  void editForumPost(String communityId, String channelId, String postId,
      String title, String body) {
    final community = byId(communityId);
    if (community == null || title.trim().isEmpty) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        return p.copyWith(
            title: title.trim(), body: body.trim(), edited: true);
      }).toList();
      return ch.copyWith(posts: posts);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// Promotes/demotes a member. The owner role can't be changed here.
  void setMemberRole(String communityId, String memberId, MemberRole role) {
    final community = byId(communityId);
    if (community == null) return;
    final members = community.members.map((m) {
      if (m.id != memberId || m.role == MemberRole.owner) return m;
      return m.copyWith(role: role);
    }).toList();
    _replace(community.copyWith(members: members));
  }

  /// Removes a member (the owner can't be removed).
  void removeMember(String communityId, String memberId) {
    final community = byId(communityId);
    if (community == null) return;
    final members = community.members
        .where((m) => m.id != memberId || m.role == MemberRole.owner)
        .toList();
    _replace(community.copyWith(members: members));
  }

  /// Adds a member (used when someone joins via an invite).
  void addMember(String communityId, Member member) {
    final community = byId(communityId);
    if (community == null) return;
    if (community.members.any((m) => m.id == member.id)) return;
    _replace(community.copyWith(members: [...community.members, member]));
  }

  /// A short, shareable invite code derived from the community id, and the
  /// deep-link an invitee would open.
  static String inviteCode(Community community) =>
      community.id.hashCode.toRadixString(36).replaceAll('-', '').padLeft(6, '0');

  static String inviteLink(Community community) =>
      'https://okay.chat/join/${inviteCode(community)}';

  @visibleForTesting
  void resetForTest() {
    _communities = _seed();
    _prefs = null;
    notifyListeners();
  }
}
