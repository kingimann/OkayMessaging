import 'dart:async';
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

  /// Fired when a member is removed (kick, ban, or their own leave), so the
  /// relay can rotate the server's sender-key epoch — a fresh chain the
  /// departed member's stored copy can no longer follow. Separate from
  /// [onStructureChanged] because a channel rename must not churn keys.
  /// Remote applies never fire it.
  void Function(String communityId)? onMemberRemoved;

  /// Fired when a PUBLIC (listed) server's directory row needs to be
  /// (re)published or removed — flipping the [Community.listed] toggle, or a
  /// roster/settings change to a server that is listed. The relay publishes the
  /// invite snapshot to the world-readable Discover directory, or deletes the
  /// row when the server is no longer listed. Remote applies never fire it.
  void Function(String communityId)? onListedChanged;

  /// Fired after any forum action taken on THIS device (post, comment,
  /// vote, edit, delete, pin, lock) so the relay can carry it to the other
  /// members. The forum used to be per-device: a delete only ever happened
  /// on the screen it was tapped on, and everybody else kept the post
  /// forever. Remote applies never fire it — no echo storms.
  void Function(String communityId, String event, Map<String, dynamic> body)?
      onForumEvent;

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

  /// Channel messages the user starred for personal reference — the channel
  /// counterpart of `ChatStore`'s starred set, same shape: a message id set,
  /// device-local, never synced or relayed (starring is a note to yourself,
  /// not something the rest of the server should hear about).
  static const _starredChannelMessagesKey = 'community_starred_msgs_v1';
  Set<String> _starredChannelMessages = {};

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

  // Message ids are only unique WITHIN a channel (like ChatStore's own
  // `_starKey` comment says for chat ids) — a shared timestamp-based scheme
  // could in principle collide across two different channels, so the star
  // key is the pair, not the bare message id.
  String _channelStarKey(String channelId, String messageId) =>
      '$channelId::$messageId';

  /// Whether a channel message is starred on this device — the channel
  /// counterpart of `ChatStore.isStarred`.
  bool isChannelMessageStarred(String channelId, String messageId) =>
      _starredChannelMessages.contains(_channelStarKey(channelId, messageId));

  /// Stars/unstars a channel message.
  void toggleChannelMessageStarred(String channelId, String messageId) {
    final key = _channelStarKey(channelId, messageId);
    if (!_starredChannelMessages.remove(key)) {
      _starredChannelMessages.add(key);
    }
    _prefs?.setString(
        _starredChannelMessagesKey, jsonEncode(_starredChannelMessages.toList()));
    notifyListeners();
  }

  /// Every starred channel message, paired with the community/channel it
  /// belongs to — the channel counterpart of `ChatStore.starredMessages()`.
  List<({Community community, Channel channel, Message message})>
      starredChannelMessages() {
    final out = <({Community community, Channel channel, Message message})>[];
    for (final c in _communities) {
      for (final ch in c.channels) {
        for (final m in ch.messages) {
          if (_starredChannelMessages.contains(_channelStarKey(ch.id, m.id))) {
            out.add((community: c, channel: ch, message: m));
          }
        }
      }
    }
    out.sort((a, b) => b.message.time.compareTo(a.message.time));
    return out;
  }

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
      final starredRaw = prefs.getString(_starredChannelMessagesKey);
      if (starredRaw != null) {
        _starredChannelMessages =
            (jsonDecode(starredRaw) as List).whereType<String>().toSet();
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

  /// The single funnel every channel message insertion goes through — a
  /// device's own outgoing post (from `_post` in `communities.dart`) AND an
  /// incoming one (via `addRemoteChannelMessage`) both land here, which is
  /// exactly where the disappearing-messages stamp belongs: mirroring
  /// `ChatStore.addMessage`, it is applied fresh on THIS device based on
  /// THIS device's own `Channel.disappearingSeconds`, regardless of who
  /// sent the message or what the sender's own setting was — the same
  /// "each side decides for itself" rule chat's disappearing messages
  /// already follows, and why the setting never needs to ride the wire.
  void postMessage(String communityId, String channelId, Message message) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      var msg = message;
      final ttl = ch.disappearingSeconds;
      if (ttl > 0 && msg.expiresAt == null) {
        msg = msg.copyWith(expiresAt: msg.time.add(Duration(seconds: ttl)));
      }
      return ch.copyWith(messages: [...ch.messages, msg]);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// Sets (or clears, with 0) the disappearing-messages timer for a
  /// channel — the channel counterpart of `ChatStore.setDisappearing`.
  /// Local-only, like the chat version: not published to other members.
  void setChannelDisappearing(
      String communityId, String channelId, int seconds) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      return ch.copyWith(disappearingSeconds: seconds);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// Deletes every expired channel message across every server this device
  /// knows about — the channel counterpart of `ChatStore.sweepExpired`.
  /// `now` is injectable for tests. Returns the count removed.
  int sweepExpiredChannelMessages([DateTime? now]) {
    final at = now ?? DateTime.now();
    var removed = 0;
    for (var i = 0; i < _communities.length; i++) {
      final community = _communities[i];
      var changedHere = false;
      final channels = community.channels.map((ch) {
        final kept = ch.messages
            .where((m) => m.expiresAt == null || m.expiresAt!.isAfter(at))
            .toList();
        if (kept.length != ch.messages.length) {
          removed += ch.messages.length - kept.length;
          changedHere = true;
          return ch.copyWith(messages: kept);
        }
        return ch;
      }).toList();
      if (changedHere) {
        _communities[i] = community.copyWith(channels: channels);
      }
    }
    if (removed > 0) notifyListeners();
    return removed;
  }

  Timer? _sweeper;

  /// Starts a periodic sweep that deletes expired (disappearing) channel
  /// messages even while their channel isn't open — the channel
  /// counterpart of `ChatStore.startSweeper`. Safe to call once at startup.
  void startSweeper() {
    _sweeper ??= Timer.periodic(
        const Duration(seconds: 20), (_) => sweepExpiredChannelMessages());
  }

  /// Every reply hanging under [rootId] in this channel — the channel
  /// counterpart of `ChatStore.threadReplies`/`threadReplyCount`.
  List<Message> channelThreadReplies(
      String communityId, String channelId, String rootId) {
    final channel = byId(communityId)
        ?.channels
        .cast<Channel?>()
        .firstWhere((c) => c?.id == channelId, orElse: () => null);
    return channel == null
        ? const []
        : channel.messages.where((m) => m.threadRootId == rootId).toList();
  }

  int channelThreadReplyCount(
          String communityId, String channelId, String rootId) =>
      channelThreadReplies(communityId, channelId, rootId).length;

  /// Marks a channel "view once" message as opened, so it can't be viewed
  /// again — the channel counterpart of `ChatStore.markViewOnceOpened`,
  /// including the same received-ghost-text wipe (the sender's own copy
  /// keeps its words; the far side's 'chvopen' receipt marks THEIR copy).
  void markChannelViewOnceOpened(
      String communityId, String channelId, String messageId) {
    final community = byId(communityId);
    if (community == null) return;
    var changed = false;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final msgs = ch.messages.map((m) {
        if (m.id == messageId && m.viewOnce && !m.viewOnceOpened) {
          changed = true;
          final wipe = !m.isMe && !m.isImage;
          return m.copyWith(viewOnceOpened: true, text: wipe ? '' : null);
        }
        return m;
      }).toList();
      return ch.copyWith(messages: msgs);
    }).toList();
    if (changed) _replace(community.copyWith(channels: channels));
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

  /// Records which key protected a channel message this device SENT — see
  /// [ChatStore.noteMessageEnc] for why it is recorded rather than inferred.
  /// Called after the seal, so a message that never reached the bus (no
  /// relay, no server secret) keeps saying it has no record instead of
  /// claiming a key it never met.
  void noteChannelMessageEnc(
      String communityId, String channelId, String messageId, int enc) {
    final community = byId(communityId);
    if (community == null || enc < 0) return;
    var changed = false;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final msgs = ch.messages.map((m) {
        if (m.id != messageId || m.enc == enc) return m;
        changed = true;
        return m.copyWith(enc: enc);
      }).toList();
      return ch.copyWith(messages: msgs);
    }).toList();
    if (changed) _replace(community.copyWith(channels: channels));
  }

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

  /// A mutable deep copy of a message's per-emoji reactor map — mirrors
  /// ChatStore's own private helper of the same shape.
  static Map<String, List<String>> _copyReactionsBy(Message m) => {
        for (final e in m.reactionsBy.entries) e.key: List<String>.from(e.value)
      };

  /// Toggles an emoji reaction on a channel message FOR [reactor] (their
  /// digits), and reports whether it is now on — the caller needs to know
  /// which way it went to tell the other members, because a toggle applied
  /// twice on two devices cancels itself. Empty [reactor] keeps the old
  /// anonymous, message-wide toggle (an older wire that carried no sender).
  bool toggleChannelReaction(
      String communityId, String channelId, String messageId, String emoji,
      {String reactor = ''}) {
    final message = messageInChannel(communityId, channelId, messageId);
    final on = reactor.isEmpty
        ? !(message?.reactions.contains(emoji) ?? false)
        : !(message?.reactionsBy[emoji]?.contains(reactor) ?? false);
    setChannelReaction(communityId, channelId, messageId, emoji,
        add: on, reactor: reactor);
    return on;
  }

  /// Sets an emoji reaction on or off, whoever asked for it. The remote half
  /// of [toggleChannelReaction]; same shape as the 1:1 chat's
  /// `setReactionState`. [reactor] (their digits) is recorded in
  /// [Message.reactionsBy] so "who reacted" can name them — this used to be
  /// anonymous and message-wide, so ANY member's tap toggled the SAME shared
  /// emoji off for everyone (the model held one flag per emoji, not one per
  /// reactor); an empty [reactor] keeps that old behaviour for a legacy wire
  /// that carried no sender.
  void setChannelReaction(String communityId, String channelId,
      String messageId, String emoji,
      {required bool add, String reactor = ''}) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final msgs = ch.messages.map((m) {
        if (m.id != messageId) return m;
        if (reactor.isEmpty) {
          if (add == m.reactions.contains(emoji)) return m;
          final reactions = [...m.reactions];
          if (add) {
            reactions.add(emoji);
          } else {
            reactions.remove(emoji);
          }
          return m.copyWith(reactions: reactions);
        }
        final reactions = List<String>.from(m.reactions);
        final by = _copyReactionsBy(m);
        final list = by.putIfAbsent(emoji, () => <String>[]);
        final had = list.contains(reactor);
        if (add && !had) {
          list.add(reactor);
        } else if (!add && had) {
          list.remove(reactor);
        } else {
          return m; // nothing to do — a duplicate event
        }
        if (list.isEmpty) {
          by.remove(emoji);
          reactions.remove(emoji);
        } else if (!reactions.contains(emoji)) {
          reactions.add(emoji);
        }
        return m.copyWith(reactions: reactions, reactionsBy: by);
      }).toList();
      return ch.copyWith(messages: msgs);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// Applies a REMOTE 'chvopen' receipt — a channel bus event reaches every
  /// member, but only the message's actual SENDER's device should learn "it
  /// was opened" (their own bubble flips to "Opened"). Anyone else who
  /// merely holds a copy of the same message must not have theirs silently
  /// marked spent by someone else's open, which is why this checks
  /// [Message.isMe] rather than reusing [markChannelViewOnceOpened] (the
  /// LOCAL "I just opened this" action, called with no such guard because
  /// it only ever runs on the device that is actually doing the opening).
  void applyChannelViewOnceOpened(
      String communityId, String channelId, String messageId) {
    final community = byId(communityId);
    if (community == null) return;
    var changed = false;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final msgs = ch.messages.map((m) {
        if (m.id == messageId && m.isMe && m.viewOnce && !m.viewOnceOpened) {
          changed = true;
          return m.copyWith(viewOnceOpened: true);
        }
        return m;
      }).toList();
      return ch.copyWith(messages: msgs);
    }).toList();
    if (changed) _replace(community.copyWith(channels: channels));
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
    ScoreStore.instance.award(ScoreStore.pointsPerForumPost, source: 'forum');
    ScoreStore.instance.recordFlag('forum_post');
    onForumEvent?.call(communityId, 'frpost',
        {'channelId': channelId, 'post': post.toJson()});
  }

  /// Applies a [dir] (+1/-1) vote to a forum post.
  void voteForumPost(
      String communityId, String channelId, String postId, int dir) {
    final community = byId(communityId);
    if (community == null) return;
    var delta = 0;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        final (score, myVote) = applyVote(p.score, p.myVote, dir);
        delta = score - p.score;
        return p.copyWith(score: score, myVote: myVote);
      }).toList();
      return ch.copyWith(posts: posts);
    }).toList();
    _replace(community.copyWith(channels: channels));
    // The DELTA travels, not the new total: every member keeps their own
    // running score, and totals would let two crossing votes erase each
    // other.
    if (delta != 0) {
      onForumEvent?.call(communityId, 'frvote',
          {'channelId': channelId, 'postId': postId, 'delta': delta});
    }
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
    ScoreStore.instance.award(ScoreStore.pointsPerForumComment, source: 'forumComment');
    onForumEvent?.call(communityId, 'frcom', {
      'channelId': channelId,
      'postId': postId,
      'comment': comment.toJson(),
    });
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
    bool? now;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        now = !p.locked;
        return p.copyWith(locked: now);
      }).toList();
      return ch.copyWith(posts: posts);
    }).toList();
    _replace(community.copyWith(channels: channels));
    // The resulting STATE travels, not the toggle: two crossing toggles
    // must converge rather than flip each other back.
    if (now != null) {
      onForumEvent?.call(communityId, 'frlock',
          {'channelId': channelId, 'postId': postId, 'locked': now});
    }
  }

  /// Applies a [dir] (+1/-1) vote to a comment under a forum post.
  void voteForumComment(String communityId, String channelId, String postId,
      String commentId, int dir) {
    final community = byId(communityId);
    if (community == null) return;
    var delta = 0;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        final comments = p.comments.map((c) {
          if (c.id != commentId) return c;
          final (score, myVote) = applyVote(c.score, c.myVote, dir);
          delta = score - c.score;
          return c.copyWith(score: score, myVote: myVote);
        }).toList();
        return p.copyWith(comments: comments);
      }).toList();
      return ch.copyWith(posts: posts);
    }).toList();
    _replace(community.copyWith(channels: channels));
    if (delta != 0) {
      onForumEvent?.call(communityId, 'frvote', {
        'channelId': channelId,
        'postId': postId,
        'commentId': commentId,
        'delta': delta,
      });
    }
  }

  /// Removes a forum post entirely — here and, through the relay, on every
  /// member's device.
  void deleteForumPost(String communityId, String channelId, String postId) {
    _deleteForumPostLocal(communityId, channelId, postId);
    onForumEvent?.call(
        communityId, 'frdel', {'channelId': channelId, 'postId': postId});
  }

  void _deleteForumPostLocal(
      String communityId, String channelId, String postId) {
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
    final text = body.trim();
    if (text.isEmpty) return;
    _editForumCommentLocal(communityId, channelId, postId, commentId, text);
    onForumEvent?.call(communityId, 'frcedt', {
      'channelId': channelId,
      'postId': postId,
      'commentId': commentId,
      'body': text,
    });
  }

  void _editForumCommentLocal(String communityId, String channelId,
      String postId, String commentId, String text) {
    final community = byId(communityId);
    if (community == null) return;
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

  /// Removes a comment from a forum post — everywhere, like the post itself.
  void deleteForumComment(String communityId, String channelId, String postId,
      String commentId) {
    _deleteForumCommentLocal(communityId, channelId, postId, commentId);
    onForumEvent?.call(communityId, 'frcdel', {
      'channelId': channelId,
      'postId': postId,
      'commentId': commentId,
    });
  }

  void _deleteForumCommentLocal(String communityId, String channelId,
      String postId, String commentId) {
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
    bool? now;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        now = !p.pinned;
        return p.copyWith(pinned: now);
      }).toList();
      return ch.copyWith(posts: posts);
    }).toList();
    _replace(community.copyWith(channels: channels));
    if (now != null) {
      onForumEvent?.call(communityId, 'frpin',
          {'channelId': channelId, 'postId': postId, 'pinned': now});
    }
  }

  // --- Remote forum events (applied, never re-broadcast) ------------------

  /// A post another member wrote. Idempotent: the same post can arrive live
  /// AND from the offline mailbox, and once is enough.
  void applyRemoteForumPost(
      String communityId, String channelId, ForumPost post) {
    final community = byId(communityId);
    if (community == null) return;
    if (community.channels.any((ch) => ch.posts.any((p) => p.id == post.id))) {
      return;
    }
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      // The author's self-upvote arrives inside the score; the VOTE itself
      // is theirs — this device hasn't cast one.
      return ch.copyWith(posts: [post.copyWith(myVote: 0), ...ch.posts]);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// A comment another member wrote. Dropped silently when its post isn't
  /// here (the mailbox drains in order, so that means the post was deleted).
  /// A locked thread still accepts it — the comment was sent before the
  /// lock reached its author, and dropping it would fork the two copies.
  void applyRemoteForumComment(String communityId, String channelId,
      String postId, ForumComment comment) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        if (p.comments.any((c) => c.id == comment.id)) return p;
        return p.copyWith(
            comments: [...p.comments, comment.copyWith(myVote: 0)]);
      }).toList();
      return ch.copyWith(posts: posts);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  /// Another member's vote, as a score delta.
  void applyRemoteForumVote(
      String communityId, String channelId, String postId,
      {String? commentId, required int delta}) {
    final community = byId(communityId);
    if (community == null || delta == 0) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        if (commentId == null) return p.copyWith(score: p.score + delta);
        return p.copyWith(comments: [
          for (final c in p.comments)
            c.id == commentId ? c.copyWith(score: c.score + delta) : c
        ]);
      }).toList();
      return ch.copyWith(posts: posts);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  void applyRemoteForumPostDelete(
          String communityId, String channelId, String postId) =>
      _deleteForumPostLocal(communityId, channelId, postId);

  void applyRemoteForumCommentDelete(String communityId, String channelId,
          String postId, String commentId) =>
      _deleteForumCommentLocal(communityId, channelId, postId, commentId);

  void applyRemoteForumPostEdit(String communityId, String channelId,
          String postId, String title, String body,
          {String? tag, String? gifUrl}) =>
      _editForumPostLocal(communityId, channelId, postId, title, body,
          tag: tag, gifUrl: gifUrl);

  void applyRemoteForumCommentEdit(String communityId, String channelId,
          String postId, String commentId, String body) =>
      _editForumCommentLocal(communityId, channelId, postId, commentId, body);

  /// A moderator's pin or lock, as absolute state.
  void applyRemoteForumFlag(
      String communityId, String channelId, String postId,
      {bool? pinned, bool? locked}) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        return p.copyWith(pinned: pinned, locked: locked);
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
    // The effective role folds in any custom role's tier, so a member handed
    // a moderator- or admin-tier role gets those powers through the same
    // funnel every permission check already reads.
    return me == null ? null : community.effectiveRole(me);
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

  /// Sets the server's optional SECOND accent colour ('' = a solid look).
  void setCommunityColor2(String communityId, String color2) {
    final community = byId(communityId);
    if (community == null) return;
    _replace(community.copyWith(color2: color2));
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

  /// Turns paid membership on or off for a server (owner/admin only). Off
  /// clears the price and pitch so a free server carries none. A price of 0
  /// can't be "paid" — that's a free server said the long way.
  void setPaidMembership(String communityId,
      {required bool paid, int priceCents = 0, String pitch = ''}) {
    final community = byId(communityId);
    if (community == null || !canManageServer(communityId)) return;
    final on = paid && priceCents > 0;
    _replace(community.copyWith(
      paid: on,
      priceCents: on ? priceCents : 0,
      subPitch: on ? pitch.trim() : '',
    ));
    // Turning on a paywall pulls a server out of the public directory — a
    // public server's secret is world-readable, which a paid one's must not be.
    if (on && community.listed) {
      _replace(byId(communityId)!.copyWith(listed: false));
      onListedChanged?.call(communityId);
    }
    onStructureChanged?.call(communityId);
  }

  /// Makes a server PUBLIC (listed in the Discover directory, anyone can find
  /// and join) or PRIVATE (invite-only, the default). Owner/admin only. A PAID
  /// server can't be listed — its secret must stay behind the paywall — so
  /// listing is refused while paid. Publishing/removing the directory row is
  /// the relay's job, fired through [onListedChanged].
  void setListed(String communityId, bool on) {
    final community = byId(communityId);
    if (community == null || !canManageServer(communityId)) return;
    if (on && community.paid) return; // a paid server is never publicly listed
    if (community.listed == on) return;
    _replace(community.copyWith(listed: on));
    onListedChanged?.call(communityId);
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
    onMemberRemoved?.call(communityId);
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
      {String? tag, String? gifUrl}) {
    if (title.trim().isEmpty) return;
    _editForumPostLocal(communityId, channelId, postId, title.trim(),
        body.trim(),
        tag: tag, gifUrl: gifUrl);
    onForumEvent?.call(communityId, 'fredt', {
      'channelId': channelId,
      'postId': postId,
      'title': title.trim(),
      'body': body.trim(),
      if (tag != null) 'tag': tag,
      if (gifUrl != null) 'gifUrl': gifUrl,
    });
  }

  void _editForumPostLocal(String communityId, String channelId,
      String postId, String title, String body,
      {String? tag, String? gifUrl}) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final posts = ch.posts.map((p) {
        if (p.id != postId) return p;
        return p.copyWith(
            title: title, body: body, edited: true, tag: tag, gifUrl: gifUrl);
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

  // --- Custom roles ------------------------------------------------------

  /// Creates a custom role on [communityId] and returns it (or null when the
  /// caller can't manage the server or the name is blank). Admins and the
  /// owner only — the same gate every structural change uses. A role's tier is
  /// clamped so it can never mint an owner.
  CustomRole? addRole(String communityId, String name,
      {String color = '#17708A',
      MemberRole tier = MemberRole.member,
      String badge = ''}) {
    final community = byId(communityId);
    if (community == null || !canManageServer(communityId)) return null;
    final clean = name.trim();
    if (clean.isEmpty) return null;
    final safeTier =
        tier == MemberRole.owner ? MemberRole.admin : tier;
    final role = CustomRole(
      id: '${communityId}_role_${community.roles.length}_${clean.hashCode}',
      name: clean,
      color: color,
      tier: safeTier,
      badge: badge,
    );
    _replace(community.copyWith(roles: [...community.roles, role]));
    onStructureChanged?.call(communityId);
    return role;
  }

  /// Edits a role's name, colour, tier or badge (admins/owner only).
  void updateRole(String communityId, String roleId,
      {String? name, String? color, MemberRole? tier, String? badge}) {
    final community = byId(communityId);
    if (community == null || !canManageServer(communityId)) return;
    final roles = community.roles.map((r) {
      if (r.id != roleId) return r;
      final safeTier = tier == MemberRole.owner ? MemberRole.admin : tier;
      final cleanName = name?.trim();
      return r.copyWith(
        name: (cleanName == null || cleanName.isEmpty) ? null : cleanName,
        color: color,
        tier: safeTier,
        badge: badge,
      );
    }).toList();
    _replace(community.copyWith(roles: roles));
    onStructureChanged?.call(communityId);
  }

  /// Deletes a role and strips it from everyone wearing it, so no member is
  /// left pointing at a role that no longer exists (admins/owner only).
  void deleteRole(String communityId, String roleId) {
    final community = byId(communityId);
    if (community == null || !canManageServer(communityId)) return;
    final roles = community.roles.where((r) => r.id != roleId).toList();
    final members = community.members
        .map((m) => m.roleId == roleId ? m.copyWith(roleId: '') : m)
        .toList();
    _replace(community.copyWith(roles: roles, members: members));
    onStructureChanged?.call(communityId);
  }

  /// Assigns [roleId] to a member (or clears it with ''). Admins/owner only.
  /// The owner's own entry can be badged but never demoted — its built-in
  /// role stays owner regardless.
  void assignRole(String communityId, String memberId, String roleId) {
    final community = byId(communityId);
    if (community == null || !canManageServer(communityId)) return;
    // Clearing is always fine; assigning requires the role to exist.
    if (roleId.isNotEmpty && community.roleById(roleId) == null) return;
    final members = community.members
        .map((m) => m.id == memberId ? m.copyWith(roleId: roleId) : m)
        .toList();
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
    onMemberRemoved?.call(communityId);
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

  /// An admin/owner adds [members] to the roster directly — the WhatsApp-group
  /// "add people" the invite-and-wait flow can't do — and broadcasts the new
  /// roster so every existing member converges. Returns the invite snapshot to
  /// hand each newcomer (their device joins on receipt), or null when the
  /// caller can't manage the server. The snapshot is flagged `added` so the
  /// recipient auto-joins rather than being shown a tap-to-join card. Banned
  /// or already-present ids are skipped by [addMember].
  Map<String, dynamic>? addMembersByAdmin(String communityId, List<Member> members,
      {required String myDigits, required String myName}) {
    final community = byId(communityId);
    if (community == null || !canManageServer(communityId)) return null;
    for (final m in members) {
      addMember(communityId, m);
    }
    onStructureChanged?.call(communityId);
    final snapshot =
        exportInvite(communityId, myDigits: myDigits, myName: myName);
    if (snapshot != null) snapshot['added'] = true;
    return snapshot;
  }

  /// A short, shareable invite code derived from the community id, and the
  /// deep-link an invitee would open.
  static String inviteCode(Community community) =>
      community.id.hashCode.toRadixString(36).replaceAll('-', '').padLeft(6, '0');

  static String inviteLink(Community community) =>
      'https://okay.chat/join/${inviteCode(community)}';

  /// A REAL, self-contained join code: the full invite snapshot (identity,
  /// channels, and the E2E secret) encoded so it can be typed or pasted into
  /// "Join with a code". Unlike [inviteCode] — a one-way hash of the id with
  /// nothing on the other end to resolve it — this carries everything a device
  /// needs to join, so no server-side registry is required.
  ///
  /// It carries the secret, so it is exactly as sensitive as the invite card:
  /// anyone holding it can join. Share it the same way you would a private link.
  static const invitePrefix = 'OKAY-';

  String? inviteToken(String communityId,
      {required String myDigits, required String myName}) {
    final snapshot =
        exportInvite(communityId, myDigits: myDigits, myName: myName);
    if (snapshot == null) return null;
    return invitePrefix +
        base64Url.encode(utf8.encode(jsonEncode(snapshot)));
  }

  /// Decodes a pasted join code back to an invite snapshot, or null if it
  /// isn't one. Tolerant of what a person actually pastes: the bare code, the
  /// code inside a URL, or (as a fallback) a raw JSON snapshot.
  static Map<String, dynamic>? decodeInviteToken(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    // A pasted URL: keep only the last path segment.
    if (s.startsWith('http')) {
      final slash = s.lastIndexOf('/');
      if (slash != -1) s = s.substring(slash + 1);
    }
    s = s.trim();
    // A raw JSON snapshot (e.g. forwarded from the invite card).
    if (s.startsWith('{')) {
      try {
        final d = jsonDecode(s);
        return d is Map ? Map<String, dynamic>.from(d) : null;
      } catch (_) {
        return null;
      }
    }
    if (s.startsWith(invitePrefix)) s = s.substring(invitePrefix.length);
    try {
      final bytes = base64Url.decode(base64Url.normalize(s));
      final d = jsonDecode(utf8.decode(bytes));
      return d is Map ? Map<String, dynamic>.from(d) : null;
    } catch (_) {
      return null;
    }
  }

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
      if (community.color2.isNotEmpty) 'color2': community.color2,
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
      // Custom roles (name, colour, tier, badge) ride the invite/structure so
      // every member's copy shows the same badges — the readers
      // (applyRemoteStructure, joinFromInvite) already parse this key.
      if (community.roles.isNotEmpty)
        'roles': community.roles.map((r) => r.toJson()).toList(),
      // Paid membership travels with the invite so the recipient sees the
      // price before joining and the join button can gate on it.
      if (community.paid) ...{
        'paid': true,
        'priceCents': community.priceCents,
        if (community.subPitch.isNotEmpty) 'subPitch': community.subPitch,
      },
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
      color2: snapshot['color2'] as String? ?? mine.color2,
      icon: snapshot['icon'] as String? ?? mine.icon,
      description:
          snapshot['description'] as String? ?? mine.description,
      channels: channels,
      roles: [
        for (final raw in (snapshot['roles'] as List? ?? const []))
          if (raw is Map) CustomRole.fromJson(Map<String, dynamic>.from(raw)),
      ],
      members: [
        for (final m in members)
          if (m.id != wireId(myDigits)) m,
        // My own entry keeps its local 'me' identity, at the role — and now
        // the custom-role badge — the roster assigns it.
        () {
          final mine = members.cast<Member?>().firstWhere(
              (m) => m?.id == wireId(myDigits),
              orElse: () => null);
          return Member(
            id: 'me',
            name: 'You',
            role: mine?.role ?? me?.role ?? MemberRole.member,
            roleId: mine?.roleId ?? me?.roleId ?? '',
            online: true,
          );
        }(),
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

  /// Reconciles this device's local copy of a community against the
  /// server-authoritative rows fetched from `community_servers` /
  /// `community_channels` / `community_roles` / `community_members` /
  /// `community_bans` (docs/community_structure.sql) — the durable,
  /// permission-checked backstop over the existing peer-broadcast structure.
  ///
  /// A SEPARATE method from [applyRemoteStructure], not a replacement: that
  /// one applies a full JSON snapshot arriving over the gossip protocol
  /// (broadcast/mailbox/mesh) and stays exactly as it is — this one applies
  /// rows from a SQL fetch, which have a different shape (channels/roles are
  /// lists of column maps, members/bans are keyed by phone, not a wire id)
  /// and a different trust model (server-side RLS already checked who could
  /// write them, so there is no per-field "trust the newer timestamp"
  /// question the gossip path has to reason about).
  ///
  /// Never CREATES a community — like [applyRemoteStructure], a fetch can
  /// only refine something this device already has a local copy of (from a
  /// real invite/join/mesh sync). Rebuilding channels/roles/members wholesale
  /// from the fetched rows is what deletes anything no longer present
  /// server-side (a channel removed, a role deleted, a member gone) — there
  /// is no separate "diff and delete" pass because the rebuild already
  /// behaves that way, the same trick [applyRemoteStructure] already relies
  /// on for its own snapshot. Local-only fields — messages, pinned ids, forum
  /// posts, mutedIds, discoverableNearby — are preserved by carrying them
  /// over from the existing channel/community rather than being reset.
  void applyAuthoritativeStructure({
    required String communityId,
    Map<String, dynamic>? server,
    List<Map<String, dynamic>> channels = const [],
    List<Map<String, dynamic>> roles = const [],
    List<Map<String, dynamic>> members = const [],
    List<Map<String, dynamic>> bans = const [],
    required String myDigits,
  }) {
    final mine = byId(communityId);
    if (mine == null || server == null) return;
    final me = mine.members
        .cast<Member?>()
        .firstWhere((m) => m?.id == 'me', orElse: () => null);

    // Reused public factories (Channel.fromJson/CustomRole.fromJson), not a
    // second hand-rolled parse of the wire type/tier strings — this table
    // stores them in the exact same string shape Channel.toJson/CustomRole.toJson
    // already produce, since that's what RelayService.publishCommunityStructure
    // writes them from.
    final byChannelId = {for (final ch in mine.channels) ch.id: ch};
    final newChannels = <Channel>[
      for (final row in channels)
        () {
          final meta = Channel.fromJson({
            'id': row['id'],
            'name': row['name'] ?? '',
            'type': row['type'] ?? 'text',
            'category': row['category'] ?? '',
            'topic': row['topic'] ?? '',
          });
          final existing = byChannelId[meta.id];
          return existing == null
              ? meta
              : existing.copyWith(
                  name: meta.name,
                  type: meta.type,
                  category: meta.category,
                  topic: meta.topic,
                );
        }(),
    ];

    // community_members carries no display name (this table's job is
    // structure/permissions, not identity) — a member's name comes from
    // wherever it already does today (the gossip protocol, a contact match).
    // A member new to this device shows the fallback Member() gives an empty
    // name; preserving the existing local name for one already known avoids
    // a name that briefly blanks out on every fetch.
    final byMemberId = {for (final m in mine.members) m.id: m};
    final fetchedMembers = [
      for (final row in members)
        () {
          final id = wireId((row['member_phone'] as String? ?? ''));
          final existing = byMemberId[id];
          // Member.fromJson for the role parse only (the same string shape
          // Member.toJson already writes) — not a second hand-rolled switch.
          final parsed = Member.fromJson({
            'id': id,
            'name': '',
            'role': row['role'] ?? 'member',
          });
          return parsed.copyWith(
            name: existing?.name,
            roleId: row['role_id'] as String? ?? '',
            online: existing?.online,
          );
        }(),
    ];
    final myRow = fetchedMembers
        .cast<Member?>()
        .firstWhere((m) => m?.id == wireId(myDigits), orElse: () => null);

    _replace(mine.copyWith(
      name: server['name'] as String? ?? mine.name,
      color: server['color'] as String? ?? mine.color,
      color2: server['color2'] as String? ?? mine.color2,
      icon: server['icon'] as String? ?? mine.icon,
      description: server['description'] as String? ?? mine.description,
      channels: newChannels,
      roles: [
        for (final row in roles)
          CustomRole.fromJson({
            'id': row['id'],
            'name': row['name'] ?? '',
            'color': row['color'] ?? '#17708A',
            'badge': row['badge'] ?? '',
            'tier': row['tier'] ?? 'member',
          }),
      ],
      // Owner sorted to the front regardless of the fetch's row order — the
      // rest of this app trusts members.first for who owns a server (see
      // e.g. RelayService._syncCommunityStructure below), and Postgres row
      // order is not something to depend on for that.
      members: () {
        final rebuilt = [
          for (final m in fetchedMembers)
            if (m.id != wireId(myDigits)) m,
          // My own entry keeps its local 'me' identity — same reasoning as
          // applyRemoteStructure — but the role/roleId now come from the
          // authoritative row when this device has one (the owner's row is
          // seeded by the community_servers_seed_owner trigger and never
          // appears here as an ordinary fetched row edit target).
          Member(
            id: 'me',
            name: 'You',
            role: myRow?.role ?? me?.role ?? MemberRole.member,
            roleId: myRow?.roleId ?? me?.roleId ?? '',
            online: true,
          ),
        ];
        final owner = rebuilt
            .cast<Member?>()
            .firstWhere((m) => m?.role == MemberRole.owner, orElse: () => null);
        if (owner == null) return rebuilt;
        return [owner, ...rebuilt.where((m) => m.id != owner.id)];
      }(),
      slowModeSeconds:
          (server['slow_mode_seconds'] as num?)?.toInt() ??
              mine.slowModeSeconds,
      membersCanCreateChannels:
          server['members_can_create_channels'] as bool? ??
              mine.membersCanCreateChannels,
      membersCanPost:
          server['members_can_post'] as bool? ?? mine.membersCanPost,
      membersCanMessage:
          server['members_can_message'] as bool? ?? mine.membersCanMessage,
      invitePolicy: server['invite_policy'] as String? ?? mine.invitePolicy,
      bannedWords: (server['banned_words'] as List?)?.cast<String>() ??
          mine.bannedWords,
      bannedMembers: [
        for (final row in bans)
          Member(
            id: wireId((row['member_phone'] as String? ?? '')),
            name: row['member_name'] as String? ?? '',
          ),
      ],
      paid: server['paid'] as bool? ?? mine.paid,
      priceCents: (server['price_cents'] as num?)?.toInt() ?? mine.priceCents,
      subPitch: server['sub_pitch'] as String? ?? mine.subPitch,
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
      color2: snapshot['color2'] as String? ?? '',
      icon: snapshot['icon'] as String? ?? '',
      secret: snapshot['secret'] as String? ?? '',
      description: snapshot['description'] as String? ?? '',
      channels: [
        for (final raw in (snapshot['channels'] as List? ?? const []))
          if (raw is Map)
            Channel.fromJson(Map<String, dynamic>.from(raw)),
      ],
      roles: [
        for (final raw in (snapshot['roles'] as List? ?? const []))
          if (raw is Map) CustomRole.fromJson(Map<String, dynamic>.from(raw)),
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
  /// Returns whether it was actually added — the mailbox replays the same
  /// message on every relaunch until it drains, and only a message that is
  /// genuinely NEW here should trigger a delivered ack back to its sender.
  bool addRemoteChannelMessage(
      String communityId, String channelId, Message message) {
    final community = byId(communityId);
    if (community == null) return false;
    final channel = community.channels
        .cast<Channel?>()
        .firstWhere((c) => c?.id == channelId, orElse: () => null);
    if (channel == null) return false;
    if (channel.messages.any((m) => m.id == message.id)) return false;
    if (isChannelMessageDeleted(message.id)) return false;
    postMessage(communityId, channelId, message);
    _maybeNoteMention(community, channel, message);
    return true;
  }

  /// Upgrades every OWN message in a channel to at least [status] — the
  /// channel counterpart of `ChatStore.setOutgoingStatus`. A single ack from
  /// any ONE member is enough to move the whole channel's ticks, the same
  /// coarse "first responder" rule the group chat already runs on: the ticks
  /// say SOMEONE, and [noteChannelSeenUpTo] plus the seen-by sheet say WHO.
  void setChannelOutgoingStatus(
      String communityId, String channelId, MessageStatus status) {
    final community = byId(communityId);
    if (community == null) return;
    var changed = false;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final msgs = ch.messages.map((m) {
        if (m.isMe && m.status.index < status.index) {
          changed = true;
          return m.copyWith(status: status);
        }
        return m;
      }).toList();
      return ch.copyWith(messages: msgs);
    }).toList();
    if (changed) _replace(community.copyWith(channels: channels));
  }

  /// Records that [readerDigits] has read up to [messageId] in a channel —
  /// the channel counterpart of `ChatStore.noteSeenUpTo`, feeding the "Seen
  /// by N of M" line under the newest own message and the sheet it opens.
  void noteChannelSeenUpTo(String communityId, String channelId,
      String messageId, String readerDigits) {
    final community = byId(communityId);
    if (community == null || readerDigits.isEmpty) return;
    var changed = false;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      final msgs = ch.messages;
      final upTo = msgs.indexWhere((m) => m.id == messageId);
      if (upTo == -1) return ch;
      final next = [
        for (var j = 0; j < msgs.length; j++)
          () {
            final m = msgs[j];
            if (j > upTo || !m.isMe || m.seenBy.contains(readerDigits)) {
              return m;
            }
            changed = true;
            return m.copyWith(seenBy: [...m.seenBy, readerDigits]);
          }()
      ];
      return ch.copyWith(messages: next);
    }).toList();
    if (changed) _replace(community.copyWith(channels: channels));
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
  /// Fired when a remote member joins a server THIS DEVICE OWNS, so the
  /// relay can hand the newcomer the feed history. Owner-only on purpose:
  /// every member sees the join, and all of them backfilling at once would
  /// stampede one mailbox with the same posts.
  void Function(String communityId, Member member)? onMemberJoined;

  void applyRemoteJoin(String communityId, Member member) {
    if (member.id == 'me') return;
    addMember(communityId, member);
    if (myRole(communityId) == MemberRole.owner) {
      onMemberJoined?.call(communityId, member);
    }
  }

  /// Somebody left of their own accord, announced over the community bus.
  ///
  /// Leaving used to be PURELY LOCAL: the server vanished from the leaver's
  /// device and nobody else was told. So every remaining device kept them on
  /// the roster forever — the member count stayed wrong, mailbox copies of
  /// every message kept being queued for them, and, because nothing removed
  /// them, `onMemberRemoved` never fired and the sender keys were never
  /// rotated. Departure is exactly when rotation earns its keep.
  ///
  /// [memberDigits] is the event's own sender, not a name in its body: the
  /// bus signs a sender-key event, so a member can announce their own
  /// departure and nobody else's.
  void applyRemoteLeave(String communityId, String memberDigits) {
    final community = byId(communityId);
    if (community == null) return;
    final id = wireId(memberDigits);
    // removeMember refuses to drop an owner, which is the behaviour we want
    // here too — an owner leaving is a server hand-over, not a roster edit.
    if (!community.members.any((m) => m.id == id)) return;
    removeMember(communityId, id);
  }

  @visibleForTesting
  void resetForTest() {
    _communities = _seed();
    _prefs = null;
    _seen.clear();
    _mutedChannels.clear();
    _deletedChannelMessages.clear();
    _starredChannelMessages.clear();
    onStructureChanged = null;
    onMemberJoined = null;
    notifyListeners();
  }
}
