import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../models/community.dart';
import '../models/message.dart';
import 'feed_store.dart';
import 'score_store.dart';

/// Store for Discord-style communities (servers) and their channels. Kept on
/// the device in [SharedPreferences] and, unlike one-to-one chats, also saved
/// to the server through [CloudSync] — encrypted here first — so servers,
/// channels and their posts survive a reinstall and follow you to a new
/// device.
class CommunityStore extends ChangeNotifier {
  CommunityStore._();
  static final CommunityStore instance = CommunityStore._();

  static const _key = 'communities_v1';

  List<Community> _communities = [];
  SharedPreferences? _prefs;

  /// Fired after any structural change a member makes (channels, roster,
  /// settings, identity) so the relay can broadcast the new shape to the
  /// other members. Remote applies never fire it — no echo storms.
  void Function(String communityId)? onStructureChanged;

  /// How many messages of each channel this device has seen, for unread
  /// badges. Persisted separately from the communities themselves.
  static const _seenKey = 'community_seen_v1';
  Map<String, int> _seen = {};

  /// Channels the user has muted. A muted channel still receives messages and
  /// shows its own unread count when you look at it — it just stops pushing
  /// the server's badge, so one busy channel can't make everything look unread.
  static const _mutedChannelsKey = 'community_muted_channels_v1';
  Set<String> _mutedChannels = {};

  /// Ids of channel messages deleted on this device. The community bus
  /// replays whatever is still queued in the mailbox, and the "already got
  /// it?" check looks in the channel — where a deleted message no longer is,
  /// so without these it comes straight back.
  static const _deletedChannelMessagesKey = 'community_deleted_msgs_v1';
  static const int _maxDeletedChannelMessages = 5000;
  Set<String> _deletedChannelMessages = {};

  List<Community> get communities => List.unmodifiable(_communities);

  /// Whether [channelId] is muted for this device.
  bool isChannelMuted(String channelId) => _mutedChannels.contains(channelId);

  /// Mutes/unmutes a channel; returns true when it is now muted.
  bool toggleChannelMute(String channelId) {
    final nowMuted = !_mutedChannels.remove(channelId);
    if (nowMuted) _mutedChannels.add(channelId);
    _prefs?.setString(_mutedChannelsKey, jsonEncode(_mutedChannels.toList()));
    notifyListeners();
    return nowMuted;
  }

  /// Whether [messageId] was deleted here and must not be re-added.
  bool isChannelMessageDeleted(String messageId) =>
      _deletedChannelMessages.contains(messageId);

  void _tombstoneChannelMessages(Iterable<String> ids) {
    _deletedChannelMessages.addAll(ids);
    if (_deletedChannelMessages.length > _maxDeletedChannelMessages) {
      final excess =
          _deletedChannelMessages.length - _maxDeletedChannelMessages;
      _deletedChannelMessages
          .removeAll(_deletedChannelMessages.take(excess).toList());
    }
    _prefs?.setString(_deletedChannelMessagesKey,
        jsonEncode(_deletedChannelMessages.toList()));
  }

  /// Unread messages in one channel (never negative).
  int unreadInChannel(Channel ch) {
    final unread = ch.messages.length - _seenWithin(ch);
    return unread < 0 ? 0 : unread;
  }

  /// How many messages of [channelId] this device had already seen. Read once
  /// when a channel opens, to place the "new messages" divider before the
  /// screen marks everything read.
  int seenCountFor(String channelId) => _seen[channelId] ?? 0;

  /// The seen count, never past the end of the channel.
  ///
  /// Deleting messages shortens a channel without moving the count, which
  /// left it pointing beyond the last message — and everything arriving after
  /// that was silently treated as already read. A channel could take a dozen
  /// new messages, including ones naming you, and still look caught up.
  int _seenWithin(Channel ch) {
    final seen = _seen[ch.id] ?? 0;
    return seen > ch.messages.length ? ch.messages.length : seen;
  }

  /// The id of the first message in [ch] the user hasn't seen, or null when
  /// they're caught up. Pure — this is what the unread divider anchors to, so
  /// it survives muted-member filtering that would shift plain indices.
  String? firstUnreadIdIn(Channel ch) {
    final seen = _seenWithin(ch);
    if (seen <= 0 || seen >= ch.messages.length) return null;
    return ch.messages[seen].id;
  }

  /// How many of [ch]'s unread messages @mention the local user.
  ///
  /// Counted from the unread window rather than a stored flag, so it can't
  /// drift out of step with the badge beside it. Deliberately ignores mute:
  /// muting a channel says "stop shouting about every message", not "hide it
  /// when someone is talking to me".
  int unreadMentionsIn(Channel ch) {
    final seen = _seenWithin(ch);
    if (seen >= ch.messages.length) return 0;
    final me = AppState.profile.value;
    var count = 0;
    for (final m in ch.messages.skip(seen)) {
      if (m.isMe || m.text.isEmpty) continue;
      if (FeedStore.mentionsMe(m.text,
          myName: me.name, myUsername: me.username)) {
        count++;
      }
    }
    return count;
  }

  /// Unread mentions across every channel of a server.
  int unreadMentionsInCommunity(Community c) {
    var total = 0;
    for (final ch in c.channels) {
      total += unreadMentionsIn(ch);
    }
    return total;
  }

  /// Total unread across a server's message channels. Muted channels are
  /// excluded — that's the whole point of muting one.
  int unreadInCommunity(Community c) {
    var total = 0;
    for (final ch in c.channels) {
      if (isChannelMuted(ch.id)) continue;
      total += unreadInChannel(ch);
    }
    return total;
  }

  /// Marks a channel fully read. No-op (and no rebuild) when already there.
  void markChannelSeen(String channelId, int count) {
    if (_seen[channelId] == count) return;
    _seen[channelId] = count;
    _prefs?.setString(_seenKey, jsonEncode(_seen));
    notifyListeners();
  }

  /// A serializable snapshot of every community (used by chat backup).
  List<Map<String, dynamic>> toJsonList() =>
      _communities.map((c) => c.toJson()).toList();

  /// Replaces all communities from a backup snapshot and persists them.
  void hydrate(List<dynamic> json) {
    try {
      final incoming = json
          .map((c) => Community.fromJson(Map<String, dynamic>.from(c as Map)))
          .toList();
      final incomingIds = {for (final c in incoming) c.id};
      // Merge, don't replace. The blob was uploaded at some earlier moment,
      // so a server joined or created since then isn't in it — and a
      // pull-to-refresh is enough to pull one down, which would silently
      // destroy it. Use clearAll() when a wipe is what's actually wanted.
      final localOnly = [
        for (final c in _communities)
          if (!incomingIds.contains(c.id)) c
      ];
      _communities = [...incoming, ...localOnly];
      _save();
      notifyListeners();
    } catch (_) {}
  }

  /// Drops every server. Used when a restore should start from an empty
  /// device rather than merge onto what is already here.
  void clearAll() {
    _communities = [];
    _save();
    notifyListeners();
  }

  /// Loads persisted communities, seeding a sample one on first run.
  ///
  /// Release builds never seed the bundled sample server (its fake members
  /// like "Ada Lovelace" are dev/demo only) and strip it out if an earlier
  /// build had already persisted it.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    try {
      final seenRaw = prefs.getString(_seenKey);
      if (seenRaw != null) {
        _seen = Map<String, int>.from(
            (jsonDecode(seenRaw) as Map).map((k, v) =>
                MapEntry(k as String, (v as num).toInt())));
      }
      final mutedRaw = prefs.getString(_mutedChannelsKey);
      if (mutedRaw != null) {
        _mutedChannels =
            (jsonDecode(mutedRaw) as List).whereType<String>().toSet();
      }
      final deletedRaw = prefs.getString(_deletedChannelMessagesKey);
      if (deletedRaw != null) {
        _deletedChannelMessages =
            (jsonDecode(deletedRaw) as List).whereType<String>().toSet();
      }
    } catch (_) {}
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        _communities = (jsonDecode(raw) as List)
            .map((c) => Community.fromJson(Map<String, dynamic>.from(c as Map)))
            .toList();
      } catch (_) {
        _communities = _seedForMode();
      }
    } else {
      _communities = _seedForMode();
      _save();
    }
    if (kReleaseMode) {
      final before = _communities.length;
      _communities =
          _communities.where((c) => !c.id.startsWith('seed_')).toList();
      if (_communities.length != before) _save();
    }
    notifyListeners();
  }

  /// The bundled sample server is dev/test-only; release builds start empty.
  List<Community> _seedForMode() => kReleaseMode ? <Community>[] : _seed();

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
                  senderName: 'Ada Lovelace',
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
                  tag: 'Question',
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
                      parentId: 'seed_c1',
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
                  tag: 'Discussion',
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

  /// A fresh 32-byte server secret, base64-encoded.
  static String mintSecret() {
    final rng = Random.secure();
    return base64Encode(List<int>.generate(32, (_) => rng.nextInt(256)));
  }

  /// Creates a community with a starter set of channels, its own encryption
  /// secret, and the creator as owner. The optional settings let the create
  /// screen bake privacy choices in from the first moment, instead of the
  /// server existing wide-open until someone finds the settings screen.
  Community createCommunity(
    String name, {
    String color = '#7A5CFF',
    String icon = '',
    String description = '',
    String invitePolicy = invitePolicyEveryone,
    bool membersCanMessage = true,
    bool membersCanCreateChannels = true,
    bool membersCanPost = true,
    int slowModeSeconds = 0,
  }) {
    final id = 'c_${name.hashCode}_${_communities.length}';
    final community = Community(
      id: id,
      name: name.trim(),
      color: color,
      icon: icon.trim(),
      description: description.trim(),
      secret: mintSecret(),
      invitePolicy: invitePolicy,
      membersCanMessage: membersCanMessage,
      membersCanCreateChannels: membersCanCreateChannels,
      membersCanPost: membersCanPost,
      slowModeSeconds: slowModeSeconds < 0 ? 0 : slowModeSeconds,
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
    onStructureChanged?.call(communityId);
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
    onStructureChanged?.call(communityId);
  }

  void setChannelTopic(String communityId, String channelId, String topic) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      return ch.copyWith(topic: topic.trim());
    }).toList();
    _replace(community.copyWith(channels: channels));
    onStructureChanged?.call(communityId);
  }

  /// Moves a channel under a different category header, creating the header
  /// if it's new.
  void setChannelCategory(
      String communityId, String channelId, String category) {
    final community = byId(communityId);
    final cat = category.trim();
    if (community == null || cat.isEmpty) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      return ch.copyWith(category: cat);
    }).toList();
    _replace(community.copyWith(channels: channels));
    onStructureChanged?.call(communityId);
  }

  void deleteChannel(String communityId, String channelId) {
    final community = byId(communityId);
    if (community == null) return;
    final channels =
        community.channels.where((c) => c.id != channelId).toList();
    _replace(community.copyWith(channels: channels));
    onStructureChanged?.call(communityId);
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

  /// Deletes a message from a channel (and drops any pin pointing at it).
  void deleteChannelMessage(
      String communityId, String channelId, String messageId) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      return ch.copyWith(
        messages: ch.messages.where((m) => m.id != messageId).toList(),
        pinnedMessageIds:
            ch.pinnedMessageIds.where((id) => id != messageId).toList(),
      );
    }).toList();
    _tombstoneChannelMessages([messageId]);
    // A shorter channel must not leave the seen count past its end.
    final shortened =
        channels.cast<Channel?>().firstWhere((c) => c?.id == channelId,
            orElse: () => null);
    if (shortened != null) {
      final seen = _seen[channelId];
      if (seen != null && seen > shortened.messages.length) {
        _seen[channelId] = shortened.messages.length;
        _prefs?.setString(_seenKey, jsonEncode(_seen));
      }
    }
    _replace(community.copyWith(channels: channels));
  }

  /// Rewrites the text of the local user's own channel message, keeping the
  /// original wording so "edited" isn't a black box.
  void editChannelMessage(String communityId, String channelId,
          String messageId, String newText) =>
      _editChannelMessage(communityId, channelId, messageId, newText,
          mine: true);

  /// Applies an edit its author made on their own device. The local path
  /// insists on [Message.isMe] so nobody rewrites somebody else's words; the
  /// same guard would throw away every relayed edit, since a message from
  /// another member is never `isMe` here.
  void applyRemoteChannelEdit(String communityId, String channelId,
          String messageId, String newText) =>
      _editChannelMessage(communityId, channelId, messageId, newText,
          mine: false);

  void _editChannelMessage(String communityId, String channelId,
      String messageId, String newText,
      {required bool mine}) {
    final community = byId(communityId);
    final text = newText.trim();
    if (community == null || text.isEmpty) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final msgs = ch.messages.map((m) {
        if (m.id != messageId || m.isMe != mine || m.text == text) return m;
        return m.copyWith(
            text: text, edited: true, originalText: m.originalText ?? m.text);
      }).toList();
      return ch.copyWith(messages: msgs);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// Pins or unpins, and reports which it did — a pin banner every member
  /// sees has to converge, and a toggle relayed as a toggle cannot.
  bool togglePinChannelMessage(
      String communityId, String channelId, String messageId) {
    final channel = byId(communityId)
        ?.channels
        .cast<Channel?>()
        .firstWhere((c) => c?.id == channelId, orElse: () => null);
    final pinned = !(channel?.pinnedMessageIds.contains(messageId) ?? false);
    setChannelMessagePinned(communityId, channelId, messageId,
        pinned: pinned);
    return pinned;
  }

  void setChannelMessagePinned(
      String communityId, String channelId, String messageId,
      {required bool pinned}) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      if (pinned == ch.pinnedMessageIds.contains(messageId)) return ch;
      final pins = pinned
          ? [...ch.pinnedMessageIds, messageId]
          : ch.pinnedMessageIds.where((id) => id != messageId).toList();
      return ch.copyWith(pinnedMessageIds: pins);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// Toggles an emoji reaction on a channel message, and reports whether it is
  /// now on — the caller needs to know which way it went to tell the other
  /// members, because a toggle applied twice on two devices cancels itself.
  bool toggleChannelReaction(String communityId, String channelId,
      String messageId, String emoji) {
    final on = !(messageInChannel(communityId, channelId, messageId)
            ?.reactions
            .contains(emoji) ??
        false);
    setChannelReaction(communityId, channelId, messageId, emoji, add: on);
    return on;
  }

  /// Sets an emoji reaction on or off, whoever asked for it. The remote half
  /// of [toggleChannelReaction]; same shape as the 1:1 chat's
  /// `setReactionState`, and lossy the same way — the model holds a set of
  /// emoji, not who reacted, so two people's 👍 is one 👍.
  void setChannelReaction(String communityId, String channelId,
      String messageId, String emoji,
      {required bool add}) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final msgs = ch.messages.map((m) {
        if (m.id != messageId) return m;
        if (add == m.reactions.contains(emoji)) return m;
        final reactions = [...m.reactions];
        if (add) {
          reactions.add(emoji);
        } else {
          reactions.remove(emoji);
        }
        return m.copyWith(reactions: reactions);
      }).toList();
      return ch.copyWith(messages: msgs);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// One channel message, or null when the server, channel or message is gone.
  Message? messageInChannel(
      String communityId, String channelId, String messageId) {
    final channel = byId(communityId)
        ?.channels
        .cast<Channel?>()
        .firstWhere((c) => c?.id == channelId, orElse: () => null);
    return channel?.messages
        .cast<Message?>()
        .firstWhere((m) => m?.id == messageId, orElse: () => null);
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
    ScoreStore.instance.award(ScoreStore.pointsPerForumPost);
    ScoreStore.instance.recordFlag('forum_post');
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
  /// Adds a comment to a forum post. Returns false when the thread is locked,
  /// so the caller can say why instead of dropping the comment silently.
  bool addForumComment(String communityId, String channelId, String postId,
      ForumComment comment) {
    final community = byId(communityId);
    if (community == null) return false;
    if (isForumPostLocked(communityId, channelId, postId)) return false;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        return p.copyWith(comments: [...p.comments, comment]);
      }).toList();
      return ch.copyWith(posts: posts);
    }).toList();
    _replace(community.copyWith(channels: channels));
    ScoreStore.instance.award(ScoreStore.pointsPerForumComment);
    return true;
  }

  /// Whether a forum thread is closed to new comments.
  bool isForumPostLocked(
      String communityId, String channelId, String postId) {
    final post = byId(communityId)
        ?.channels
        .cast<Channel?>()
        .firstWhere((c) => c?.id == channelId, orElse: () => null)
        ?.posts
        .cast<ForumPost?>()
        .firstWhere((p) => p?.id == postId, orElse: () => null);
    return post?.locked ?? false;
  }

  /// Locks or unlocks a forum thread (moderator action). A locked thread
  /// stays readable and votable — it just takes no new comments.
  void toggleLockForumPost(
      String communityId, String channelId, String postId) {
    final community = byId(communityId);
    if (community == null || !canModerate(communityId)) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts
          .map((p) => p.id == postId ? p.copyWith(locked: !p.locked) : p)
          .toList();
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

  /// Rewrites the body of the local user's own forum comment.
  void editForumComment(String communityId, String channelId, String postId,
      String commentId, String body) {
    final community = byId(communityId);
    final text = body.trim();
    if (community == null || text.isEmpty) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        final comments = p.comments.map((c) {
          if (c.id != commentId || c.body == text) return c;
          return c.copyWith(body: text, edited: true);
        }).toList();
        return p.copyWith(comments: comments);
      }).toList();
      return ch.copyWith(posts: posts);
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
        // A deleted comment takes its whole reply subtree with it — not just
        // its direct replies, or a reply-to-a-reply survives orphaned,
        // pointing at a comment that no longer exists.
        final doomed = <String>{commentId};
        for (var grew = true; grew;) {
          grew = false;
          for (final c in p.comments) {
            if (!doomed.contains(c.id) && doomed.contains(c.parentId)) {
              doomed.add(c.id);
              grew = true;
            }
          }
        }
        return p.copyWith(
            comments:
                p.comments.where((c) => !doomed.contains(c.id)).toList());
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

  /// The local user's role in [community], or null if not a member.
  MemberRole? myRole(String communityId) {
    final community = byId(communityId);
    if (community == null) return null;
    final me = community.members
        .cast<Member?>()
        .firstWhere((m) => m?.id == 'me', orElse: () => null);
    return me?.role;
  }

  /// Whether the local user can moderate [community] — delete/pin messages,
  /// mute, kick, ban. Owners, admins, and moderators.
  bool canModerate(String communityId) {
    final role = myRole(communityId);
    return role != null && roleCanModerate(role);
  }

  /// Whether the local user can change server settings, channels, and member
  /// roles — owners and admins only.
  bool canManageServer(String communityId) {
    final role = myRole(communityId);
    return role != null && roleCanManageServer(role);
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
    onStructureChanged?.call(communityId);
  }

  void setCommunityColor(String communityId, String color) {
    final community = byId(communityId);
    if (community == null) return;
    _replace(community.copyWith(color: color));
    onStructureChanged?.call(communityId);
  }

  void setCommunityDescription(String communityId, String description) {
    final community = byId(communityId);
    if (community == null) return;
    _replace(community.copyWith(description: description.trim()));
    onStructureChanged?.call(communityId);
  }

  /// Sets the server's emoji icon ('' returns to the letter avatar).
  void setCommunityIcon(String communityId, String icon) {
    final community = byId(communityId);
    if (community == null) return;
    _replace(community.copyWith(icon: icon.trim()));
    onStructureChanged?.call(communityId);
  }

  // --- Moderation settings -------------------------------------------------

  void setSlowMode(String communityId, int seconds) {
    final community = byId(communityId);
    if (community == null || seconds < 0) return;
    _replace(community.copyWith(slowModeSeconds: seconds));
    onStructureChanged?.call(communityId);
  }

  void setMembersCanCreateChannels(String communityId, bool allowed) {
    final community = byId(communityId);
    if (community == null) return;
    _replace(community.copyWith(membersCanCreateChannels: allowed));
    onStructureChanged?.call(communityId);
  }

  void setMembersCanPost(String communityId, bool allowed) {
    final community = byId(communityId);
    if (community == null) return;
    _replace(community.copyWith(membersCanPost: allowed));
    onStructureChanged?.call(communityId);
  }

  void setMembersCanMessage(String communityId, bool allowed) {
    final community = byId(communityId);
    if (community == null) return;
    _replace(community.copyWith(membersCanMessage: allowed));
    onStructureChanged?.call(communityId);
  }

  /// Turns "anyone nearby can find this and ask to join" on or off.
  ///
  /// Not broadcast to the other members as a structure change: whether YOUR
  /// phone beacons is your decision about your own radio, and one member
  /// flipping it should not start every other member's phone advertising.
  void setDiscoverableNearby(String communityId, bool on) {
    final community = byId(communityId);
    if (community == null) return;
    _replace(community.copyWith(discoverableNearby: on));
  }

  void setInvitePolicy(String communityId, String policy) {
    final community = byId(communityId);
    if (community == null) return;
    _replace(community.copyWith(invitePolicy: policy));
    onStructureChanged?.call(communityId);
  }

  /// Adds a word to the server's filter (deduplicated, case-insensitive).
  void addBannedWord(String communityId, String word) {
    final community = byId(communityId);
    final w = word.trim();
    if (community == null || w.isEmpty) return;
    if (community.bannedWords
        .any((e) => e.toLowerCase() == w.toLowerCase())) {
      return;
    }
    _replace(
        community.copyWith(bannedWords: [...community.bannedWords, w]));
    onStructureChanged?.call(communityId);
  }

  void removeBannedWord(String communityId, String word) {
    final community = byId(communityId);
    if (community == null) return;
    _replace(community.copyWith(
        bannedWords:
            community.bannedWords.where((w) => w != word).toList()));
    onStructureChanged?.call(communityId);
  }

  /// The filtered word [text] trips in this server, or null when it's clean.
  /// Moderators are exempt — filters exist to protect the room from members.
  String? filterHit(String communityId, String text) {
    final community = byId(communityId);
    if (community == null || canModerate(communityId)) return null;
    return blockedWord(community.bannedWords, text);
  }

  /// Removes a member and records the ban so an invite can't bring them back.
  /// The owner can't be banned.
  void banMember(String communityId, String memberId) {
    final community = byId(communityId);
    if (community == null) return;
    final target = community.members
        .cast<Member?>()
        .firstWhere((m) => m?.id == memberId, orElse: () => null);
    if (target == null || target.role == MemberRole.owner) return;
    _replace(community.copyWith(
      members:
          community.members.where((m) => m.id != memberId).toList(),
      bannedMembers: [...community.bannedMembers, target],
      mutedIds:
          community.mutedIds.where((id) => id != memberId).toList(),
    ));
    onStructureChanged?.call(communityId);
  }

  /// Lifts a ban. The person is not re-added — they can rejoin via invite.
  void unbanMember(String communityId, String memberId) {
    final community = byId(communityId);
    if (community == null) return;
    _replace(community.copyWith(
        bannedMembers: community.bannedMembers
            .where((m) => m.id != memberId)
            .toList()));
    onStructureChanged?.call(communityId);
  }

  /// Hides (or shows again) everything a member says, just for you.
  void toggleMuteMember(String communityId, String memberId) {
    final community = byId(communityId);
    if (community == null || memberId == 'me') return;
    final muted = community.mutedIds.contains(memberId)
        ? community.mutedIds.where((id) => id != memberId).toList()
        : [...community.mutedIds, memberId];
    _replace(community.copyWith(mutedIds: muted));
  }

  /// Whether the local user may add channels / posts here: moderators always,
  /// members only while the matching switch is on.
  bool canCreateChannels(String communityId) =>
      canModerate(communityId) ||
      (byId(communityId)?.membersCanCreateChannels ?? true);

  bool canPost(String communityId) =>
      canModerate(communityId) || (byId(communityId)?.membersCanPost ?? true);

  /// Whether the local user may send channel messages here: moderators
  /// always, members only while the server isn't broadcast-only.
  bool canSendMessages(String communityId) =>
      canModerate(communityId) ||
      (byId(communityId)?.membersCanMessage ?? true);

  /// Whether a message may be sent into one specific channel: the server has
  /// to allow it, the channel has to be one that takes messages at all, and an
  /// announcement channel only takes them from an owner or admin.
  ///
  /// The channel composer decides the same thing inline; this exists so
  /// somewhere that is *not* the channel — forwarding, say — can offer only
  /// the channels that would actually accept the message, rather than
  /// swallowing it silently.
  bool canSendToChannel(String communityId, String channelId) {
    if (!canSendMessages(communityId)) return false;
    final channel = byId(communityId)
        ?.channels
        .cast<Channel?>()
        .firstWhere((c) => c?.id == channelId, orElse: () => null);
    if (channel == null) return false;
    if (channel.type == ChannelType.voice ||
        channel.type == ChannelType.forum) {
      return false;
    }
    if (channel.type != ChannelType.announcement) return true;
    final role = myRole(communityId);
    return role == MemberRole.owner || role == MemberRole.admin;
  }

  /// Whether the local user may share this server's invite, per its policy.
  bool canInvite(String communityId) {
    final role = myRole(communityId);
    if (role == null) return false;
    return roleCanInvite(
        role, byId(communityId)?.invitePolicy ?? invitePolicyEveryone);
  }

  /// Edits a forum post's title/body (author or moderator) and flags it edited.
  void editForumPost(String communityId, String channelId, String postId,
      String title, String body,
      {String? tag}) {
    final community = byId(communityId);
    if (community == null || title.trim().isEmpty) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        return p.copyWith(
            title: title.trim(), body: body.trim(), edited: true, tag: tag);
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
    onStructureChanged?.call(communityId);
  }

  /// Removes a member (the owner can't be removed).
  void removeMember(String communityId, String memberId) {
    final community = byId(communityId);
    if (community == null) return;
    final members = community.members
        .where((m) => m.id != memberId || m.role == MemberRole.owner)
        .toList();
    _replace(community.copyWith(members: members));
    onStructureChanged?.call(communityId);
  }

  /// Adds a member (used when someone joins via an invite). Banned people
  /// stay out until they're unbanned.
  void addMember(String communityId, Member member) {
    final community = byId(communityId);
    if (community == null) return;
    if (community.members.any((m) => m.id == member.id)) return;
    if (community.bannedMembers.any((m) => m.id == member.id)) return;
    _replace(community.copyWith(members: [...community.members, member]));
  }

  /// A short, shareable invite code derived from the community id, and the
  /// deep-link an invitee would open.
  static String inviteCode(Community community) =>
      community.id.hashCode.toRadixString(36).replaceAll('-', '').padLeft(6, '0');

  static String inviteLink(Community community) =>
      'https://okay.chat/join/${inviteCode(community)}';

  // --- Real membership: invites over chat, traffic over the relay ---------

  /// The roster id a member is known by across devices.
  static String wireId(String digits) => 'u_$digits';

  /// The phone digits behind a wire id, or null for local-only ids ('me',
  /// seeded members) that have no reachable inbox.
  static String? digitsOfWireId(String id) =>
      id.startsWith('u_') ? id.substring(2) : null;

  /// The invite snapshot that travels (E2E encrypted) inside a chat message:
  /// the server's identity, its secret, its channel layout — but nobody's
  /// message history. The sender's local 'me' entry is translated to their
  /// wire id so the roster means the same thing on every device.
  Map<String, dynamic>? exportInvite(String communityId,
      {required String myDigits, required String myName}) {
    final community = byId(communityId);
    if (community == null) return null;
    return {
      'v': 1,
      'id': community.id,
      'name': community.name,
      'color': community.color,
      'icon': community.icon,
      'secret': community.secret,
      'description': community.description,
      'channels': [
        for (final ch in community.channels)
          {
            'id': ch.id,
            'name': ch.name,
            'type': ch.toJson()['type'],
            'category': ch.category,
            'topic': ch.topic,
          }
      ],
      'members': [
        for (final m in community.members)
          (m.id == 'me'
                  ? Member(id: wireId(myDigits), name: myName, role: m.role)
                  : m)
              .toJson()
      ],
      // Settings travel inside the invite so a joiner's client enforces
      // them from the first moment, not only after the next structure
      // broadcast happens to land.
      'slowModeSeconds': community.slowModeSeconds,
      'membersCanCreateChannels': community.membersCanCreateChannels,
      'membersCanPost': community.membersCanPost,
      'membersCanMessage': community.membersCanMessage,
      'invitePolicy': community.invitePolicy,
      'bannedWords': community.bannedWords,
    };
  }

  /// The full shareable shape of a server — the invite snapshot plus its
  /// ban list — broadcast to members whenever a structural change lands, so
  /// every copy converges.
  Map<String, dynamic>? exportStructure(String communityId,
      {required String myDigits, required String myName}) {
    final base = exportInvite(communityId,
        myDigits: myDigits, myName: myName);
    final community = byId(communityId);
    if (base == null || community == null) return null;
    return {
      ...base,
      'bannedMembers':
          community.bannedMembers.map((m) => m.toJson()).toList(),
    };
  }

  /// Applies a structure broadcast from another member: channel layout,
  /// identity, roster and settings converge while everything local-only —
  /// message history, forum posts, pins, who I muted — stays put. A device
  /// whose member entry vanished from the roster was removed or banned, and
  /// its copy of the server goes with it.
  void applyRemoteStructure(Map<String, dynamic> snapshot,
      {required String myDigits}) {
    final id = snapshot['id'] as String?;
    if (id == null) return;
    final mine = byId(id);
    if (mine == null) return;
    final me = mine.members
        .cast<Member?>()
        .firstWhere((m) => m?.id == 'me', orElse: () => null);
    final members = [
      for (final raw in (snapshot['members'] as List? ?? const []))
        if (raw is Map) Member.fromJson(Map<String, dynamic>.from(raw)),
    ];
    final stillIn = members.any((m) => m.id == wireId(myDigits));
    if (!stillIn && me?.role != MemberRole.owner) {
      deleteCommunity(id);
      return;
    }
    final byChannelId = {for (final ch in mine.channels) ch.id: ch};
    final channels = <Channel>[
      for (final raw in (snapshot['channels'] as List? ?? const []))
        if (raw is Map)
          () {
            final meta =
                Channel.fromJson(Map<String, dynamic>.from(raw));
            final existing = byChannelId[meta.id];
            return existing == null
                ? meta
                : existing.copyWith(
                    name: meta.name,
                    category: meta.category,
                    topic: meta.topic,
                  );
          }(),
    ];
    _replace(mine.copyWith(
      name: snapshot['name'] as String? ?? mine.name,
      color: snapshot['color'] as String? ?? mine.color,
      icon: snapshot['icon'] as String? ?? mine.icon,
      description:
          snapshot['description'] as String? ?? mine.description,
      channels: channels,
      members: [
        for (final m in members)
          if (m.id != wireId(myDigits)) m,
        // My own entry keeps its local 'me' identity, at the role the
        // roster now assigns it.
        Member(
            id: 'me',
            name: 'You',
            role: members
                .cast<Member?>()
                .firstWhere((m) => m?.id == wireId(myDigits),
                    orElse: () => null)
                ?.role ??
                me?.role ??
                MemberRole.member,
            online: true),
      ],
      slowModeSeconds:
          (snapshot['slowModeSeconds'] as num?)?.toInt() ??
              mine.slowModeSeconds,
      membersCanCreateChannels:
          snapshot['membersCanCreateChannels'] as bool? ??
              mine.membersCanCreateChannels,
      membersCanPost:
          snapshot['membersCanPost'] as bool? ?? mine.membersCanPost,
      membersCanMessage:
          snapshot['membersCanMessage'] as bool? ?? mine.membersCanMessage,
      invitePolicy:
          snapshot['invitePolicy'] as String? ?? mine.invitePolicy,
      bannedWords: (snapshot['bannedWords'] as List?)?.cast<String>() ??
          mine.bannedWords,
      bannedMembers: [
        for (final raw in (snapshot['bannedMembers'] as List? ?? const []))
          if (raw is Map) Member.fromJson(Map<String, dynamic>.from(raw)),
      ],
    ));
  }

  /// Joins a server from an invite snapshot. Channels arrive empty (history
  /// stays with its owners); the joiner is added to the roster as a member.
  /// Re-joining an already-joined server is a no-op returning the existing
  /// copy.
  Community? joinFromInvite(Map<String, dynamic> snapshot,
      {required String myDigits, required String myName}) {
    final id = snapshot['id'] as String?;
    final name = snapshot['name'] as String?;
    if (id == null || name == null || name.isEmpty) return null;
    final existing = byId(id);
    if (existing != null) return existing;
    final members = [
      for (final raw in (snapshot['members'] as List? ?? const []))
        if (raw is Map) Member.fromJson(Map<String, dynamic>.from(raw)),
    ].where((m) => m.id != 'me' && m.id != wireId(myDigits)).toList();
    final community = Community(
      id: id,
      name: name,
      color: snapshot['color'] as String? ?? '#7A5CFF',
      icon: snapshot['icon'] as String? ?? '',
      secret: snapshot['secret'] as String? ?? '',
      description: snapshot['description'] as String? ?? '',
      channels: [
        for (final raw in (snapshot['channels'] as List? ?? const []))
          if (raw is Map)
            Channel.fromJson(Map<String, dynamic>.from(raw)),
      ],
      members: [
        ...members,
        const Member(id: 'me', name: 'You', online: true),
      ],
      slowModeSeconds:
          (snapshot['slowModeSeconds'] as num?)?.toInt() ?? 0,
      membersCanCreateChannels:
          snapshot['membersCanCreateChannels'] as bool? ?? true,
      membersCanPost: snapshot['membersCanPost'] as bool? ?? true,
      membersCanMessage: snapshot['membersCanMessage'] as bool? ?? true,
      invitePolicy:
          snapshot['invitePolicy'] as String? ?? invitePolicyEveryone,
      bannedWords:
          (snapshot['bannedWords'] as List?)?.cast<String>() ?? const [],
    );
    _communities.add(community);
    _save();
    notifyListeners();
    return community;
  }

  /// Applies a channel message that arrived over the relay from another
  /// member. Ignored for servers this device isn't in; deduped by id.
  void addRemoteChannelMessage(
      String communityId, String channelId, Message message) {
    final community = byId(communityId);
    if (community == null) return;
    final channel = community.channels
        .cast<Channel?>()
        .firstWhere((c) => c?.id == channelId, orElse: () => null);
    if (channel == null) return;
    if (channel.messages.any((m) => m.id == message.id)) return;
    if (isChannelMessageDeleted(message.id)) return;
    postMessage(communityId, channelId, message);
    _maybeNoteMention(community, channel, message);
  }

  /// Pings the local user when an incoming channel message @mentions them, so
  /// a mention in a busy channel isn't just highlighted text they never see.
  void _maybeNoteMention(Community community, Channel channel, Message m) {
    if (m.isMe || m.text.isEmpty) return;
    final me = AppState.profile.value;
    if (!FeedStore.mentionsMe(m.text,
        myName: me.name, myUsername: me.username)) {
      return;
    }
    FeedStore.instance.noteChannelMention(
      messageId: m.id,
      communityId: community.id,
      channelId: channel.id,
      channelName: channel.name,
      actorName: m.senderName.isEmpty ? 'A member' : m.senderName,
      preview: m.text,
      time: m.time,
    );
  }

  /// Applies a member-joined event from the relay.
  void applyRemoteJoin(String communityId, Member member) {
    if (member.id == 'me') return;
    addMember(communityId, member);
  }

  @visibleForTesting
  void resetForTest() {
    _communities = _seed();
    _prefs = null;
    _seen.clear();
    _mutedChannels.clear();
    _deletedChannelMessages.clear();
    onStructureChanged = null;
    notifyListeners();
  }
}
