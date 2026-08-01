import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../app_state.dart';
import '../crypto/e2e.dart';
import '../mesh/mesh_service.dart';
import '../crypto/key_exchange.dart';
import '../models/chat.dart';
import '../models/community.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../state/call_service.dart';
import '../state/chat_store.dart';
import '../state/community_store.dart';
import '../state/push_service.dart';
import '../state/feed_store.dart';
import '../state/file_transfer.dart';
import '../state/live_location_store.dart';
import '../state/score_store.dart';
import '../state/session.dart';
import '../state/channel_typing_store.dart';
import '../state/streak_store.dart';
import '../state/voice_presence_store.dart';
import 'relay_config.dart';

/// Delivers messages between devices with **nothing stored on a server**.
///
/// Each user subscribes to their own inbox channel (`inbox_<digits>`) to
/// *receive*. To *send*, we broadcast to the recipient's inbox over REST (an
/// unsubscribed channel falls back to an HTTP POST), so a sender never joins —
/// and therefore can never eavesdrop on — someone else's inbox. Messages ride
/// an ephemeral Realtime broadcast; each device keeps its own local copy.
///
/// The message-mapping logic is static and pure so it can be unit-tested
/// without a live connection.
class RelayService {
  RelayService._();
  static final RelayService instance = RelayService._();

  bool _initialized = false;
  RealtimeChannel? _inbox;
  RealtimeChannel? _feedChannel;
  final Map<String, RealtimeChannel> _sendChannels = {};

  /// Phone digits we've already sent our public key to this session (avoids
  /// re-broadcasting the key on every message / handshake reply loop).
  final Set<String> _sentKeyTo = {};

  /// Digits of whoever most recently sent a "typing" ping; the counter bumps
  /// on every ping so listeners always fire (even for the same sender).
  String? typingFromDigits;
  final ValueNotifier<int> typingPing = ValueNotifier<int>(0);

  /// Same pattern for "online" presence pings.
  String? presenceFromDigits;
  final ValueNotifier<int> presencePing = ValueNotifier<int>(0);

  SupabaseClient get _client => Supabase.instance.client;

  /// Only the digits of a phone number, for use in a channel name.
  static String digits(String phone) => phone.replaceAll(RegExp(r'\D'), '');

  /// The inbox channel a user listens on / is reached at.
  static String inboxChannel(String phone) => 'inbox_${digits(phone)}';

  /// Builds the broadcast payload for an outgoing message. The **entire**
  /// message body — text, the sender's display name and username, and all
  /// media metadata — is bundled into one JSON blob and end-to-end encrypted
  /// into the single `c` field, so the relay forwards a ciphertext it cannot
  /// read: it never sees who is talking, what they wrote, or what they sent.
  /// Only routing data (`id`, `from`, `enc`, `spk`, `ts`) stays in the clear.
  ///
  ///  * enc 2 — AES-256-GCM keyed by an ECDH shared secret ([ecdhSecret]); the
  ///    sender's public key rides along as `spk` so the recipient can derive
  ///    the same secret. This is the strong path, used once keys are exchanged.
  ///  * enc 1 — AES-256-GCM keyed by the phone-number-derived secret (the
  ///    fallback until the ECDH handshake completes).
  ///  * enc 0 — plaintext JSON (no recipient key available yet).
  static Map<String, dynamic> encode({
    required Message message,
    required String fromPhone,
    required String fromName,
    String fromUsername = '',
    String fromAvatarColor = '',
    String fromAbout = '',
    String fromEmoji = '',
    String fromPronouns = '',
    String fromLink = '',
    bool fromVerified = false,
    int fromScore = 0,
    int fromStreak = 0,
    String toPhone = '',
    String groupId = '',
    String groupName = '',
    List<AppUser> groupMembers = const [],
    List<int>? ecdhSecret,
    String? senderPublicKey,
  }) {
    // Everything sensitive goes inside this blob — nothing but routing leaks.
    // The full message is carried so replies, forwards, shared location /
    // contacts and disappearing timers survive delivery, not just plain text.
    // Avatar color and about ride along only when the sender's privacy
    // settings permit sharing them with this recipient — an empty string means
    // "withheld", so the data never leaves the device.
    final content = jsonEncode({
      'text': message.text,
      'fromName': fromName,
      // Group routing rides *inside* the sealed blob: the relay never learns
      // that a group exists, who is in it, or what it's called.
      if (groupId.isNotEmpty) 'groupId': groupId,
      if (groupId.isNotEmpty) 'groupName': groupName,
      if (groupId.isNotEmpty)
        'groupMembers': groupMembers.map(_memberSummary).toList(),
      'fromUsername': fromUsername,
      'fromAvatarColor': fromAvatarColor,
      'fromAbout': fromAbout,
      'fromEmoji': fromEmoji,
      'fromPronouns': fromPronouns,
      'fromLink': fromLink,
      'fromVerified': fromVerified,
      'fromScore': fromScore,
      'fromStreak': fromStreak,
      'isImage': message.isImage,
      'imageSeed': message.imageSeed,
      'imageUrl': message.imageUrl,
      'isVoice': message.isVoice,
      'voiceSeconds': message.voiceSeconds,
      'isVoicemail': message.isVoicemail,
      'forwarded': message.forwarded,
      'replyTo': message.replyTo?.toJson(),
      'isLocation': message.isLocation,
      'locationLat': message.locationLat,
      'locationLng': message.locationLng,
      'locationLabel': message.locationLabel,
      'isContact': message.isContact,
      'contactName': message.contactName,
      'contactPhone': message.contactPhone,
      'isPayment': message.isPayment,
      'paymentAmountCents': message.paymentAmountCents,
      'paymentCurrency': message.paymentCurrency,
      'paymentStatus': message.paymentStatus,
      'isPoll': message.isPoll,
      'pollQuestion': message.pollQuestion,
      'pollOptions': message.pollOptions,
      'pollVotes': message.pollVotes,
      if (message.serverInvite.isNotEmpty)
        'serverInvite': message.serverInvite,
      'expiresAt': message.expiresAt?.toIso8601String(),
    });

    var c = content;
    var enc = 0;
    String? spk;
    if (ecdhSecret != null && senderPublicKey != null) {
      c = E2eCrypto.encrypt(ecdhSecret, content);
      enc = 2;
      spk = senderPublicKey;
    } else if (toPhone.isNotEmpty) {
      c = E2eCrypto.encrypt(E2eCrypto.keyFor(fromPhone, toPhone), content);
      enc = 1;
    }
    return {
      'id': message.id,
      'from': fromPhone,
      'c': c,
      'enc': enc,
      if (spk != null) 'spk': spk,
      'ts': message.time.toIso8601String(),
    };
  }

  /// The minimum a member needs to be shown and reachable in someone else's
  /// copy of the group. Deliberately not the full profile — a group shouldn't
  /// leak a member's about text, score or links to everyone else in it.
  static Map<String, dynamic> _memberSummary(AppUser u) => {
        'id': u.id,
        'name': u.name,
        'phone': u.phone,
        'avatarColor': u.avatarColor,
      };

  /// Rebuilds the member list from the `groupMembers` blob of a payload.
  static List<AppUser> membersFromJson(Object? raw) {
    if (raw is! List) return const [];
    final out = <AppUser>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final id = m['id'] as String?;
      if (id == null || id.isEmpty) continue;
      final phone = (m['phone'] as String?) ?? '';
      final name = (m['name'] as String?)?.trim();
      out.add(AppUser(
        id: id,
        name: name != null && name.isNotEmpty ? name : phone,
        avatarColor: (m['avatarColor'] as String?) ?? '#7A5CFF',
        about: '',
        phone: phone,
      ));
    }
    return out;
  }

  /// Creates the local copy of a group we've just been let into, from the
  /// group fields carried in an incoming payload's sealed blob.
  static Chat _createGroupChat(
    ChatStore target, {
    required String groupId,
    required Map<String, dynamic> content,
  }) {
    final name = (content['groupName'] as String?)?.trim() ?? '';
    final members = membersFromJson(content['groupMembers']);
    final chat = Chat(
      id: groupId,
      contact: AppUser(
        id: groupId,
        name: name.isNotEmpty ? name : 'Group',
        avatarColor: '#4DB6AC',
        about: 'Group • ${members.length} members',
        isGroup: true,
      ),
      messages: const [],
      members: members,
    );
    target.upsert(chat);
    return chat;
  }

  /// Applies an incoming broadcast payload to [store]: finds or creates the
  /// local conversation with the sender and appends the message. Ignores
  /// messages from [myPhone] and duplicates by id. Returns true when a new
  /// message was added.
  static bool applyIncoming(
    Map<String, dynamic> payload, {
    required String myPhone,
    ChatStore? store,
  }) {
    final from = payload['from'] as String?;
    if (from == null || digits(from) == digits(myPhone)) return false;

    final target = store ?? ChatStore.instance;
    final id = payload['id'] as String? ?? 'relay_${payload['ts']}';

    // Something the user deleted here stays deleted, even if the mailbox
    // row outlived its delivery and replays the envelope.
    if (target.isMessageDeleted(id)) return false;

    // Privacy: blocked senders are always ignored.
    final knownChat = target.chatWithContact(from);
    if (AppState.isBlocked(from)) return false;

    // Decrypt the sealed content blob into the real fields. Falls back to the
    // legacy top-level layout for any message still on the old wire format.
    final content = _decodeContent(payload, from: from, myPhone: myPhone);

    // A group message carries its conversation id inside the sealed blob, so
    // it lands in the shared group thread rather than a 1:1 chat with whoever
    // happened to send it.
    final groupId = (content['groupId'] as String?)?.trim() ?? '';
    final knownGroup = groupId.isEmpty ? null : target.chatById(groupId);

    // "Only my contacts can message me": a message from someone you have no
    // chat with is dropped rather than starting a conversation. Being in a
    // group you already have counts as known, so members you haven't messaged
    // one-to-one still reach you there.
    final isKnown = knownChat != null || knownGroup != null;
    if (!isKnown && AppState.messagesFromContactsOnly.value) return false;

    // Respect the "allow voicemail" preference before touching the store.
    if (content['isVoicemail'] == true && !AppState.allowVoicemail.value) {
      return false;
    }

    // Spam & bots filter: drop keyword-matched messages, and links from
    // strangers, before they ever reach the chat store.
    final incomingText = (content['text'] as String?) ?? '';
    if (incomingText.isNotEmpty &&
        AppState.looksLikeSpam(incomingText, isKnownContact: isKnown)) {
      return false;
    }

    // Profile fields the sender chose to share (empty when withheld by their
    // privacy settings).
    final sharedColor = (content['fromAvatarColor'] as String?)?.trim() ?? '';
    final sharedAbout = (content['fromAbout'] as String?)?.trim() ?? '';
    final sharedEmoji = (content['fromEmoji'] as String?)?.trim() ?? '';
    final sharedPronouns = (content['fromPronouns'] as String?)?.trim() ?? '';
    final sharedLink = (content['fromLink'] as String?)?.trim() ?? '';
    final sharedVerified = content['fromVerified'] == true;
    final sharedScore = (content['fromScore'] as num?)?.toInt() ?? 0;

    final senderName = (content['fromName'] as String?)?.trim() ?? '';

    final Chat chat;
    if (groupId.isNotEmpty) {
      // Group thread: create it on first contact (this is how you find out
      // you've been added), then keep its name and roster following whatever
      // the sender's copy says.
      chat = knownGroup ??
          _createGroupChat(target, groupId: groupId, content: content);
      target.updateGroup(
        groupId,
        name: (content['groupName'] as String?)?.trim(),
        members: membersFromJson(content['groupMembers']),
      );
    } else if (knownChat == null) {
      final contact = AppUser(
        id: from,
        name: senderName.isNotEmpty ? senderName : from,
        avatarColor: sharedColor.isNotEmpty ? sharedColor : '#7A5CFF',
        about: sharedAbout.isNotEmpty ? sharedAbout : 'Available',
        phone: from,
        username: (content['fromUsername'] as String?) ?? '',
        verified: sharedVerified,
        score: sharedScore,
        emoji: sharedEmoji,
        pronouns: sharedPronouns,
        link: sharedLink,
      );
      chat = Chat(id: 'chat_$from', contact: contact, messages: const []);
      target.upsert(chat);
    } else {
      chat = knownChat;
      // Keep an existing contact's avatar / about / verified / score in sync
      // when the sender shares fresh values.
      target.updateContactProfile(
        from,
        avatarColor: sharedColor.isNotEmpty ? sharedColor : null,
        about: sharedAbout.isNotEmpty ? sharedAbout : null,
        verified: sharedVerified,
        score: sharedScore,
        emoji: sharedEmoji.isNotEmpty ? sharedEmoji : null,
        pronouns: sharedPronouns.isNotEmpty ? sharedPronouns : null,
        link: sharedLink.isNotEmpty ? sharedLink : null,
      );
    }

    final existing = target.chatById(chat.id);
    if (existing != null && existing.messages.any((m) => m.id == id)) {
      return false;
    }

    final replyJson = content['replyTo'];
    target.addMessage(
      chat.id,
      Message(
        id: id,
        text: (content['text'] as String?) ?? '',
        time: DateTime.tryParse(payload['ts'] as String? ?? '')?.toLocal() ??
            DateTime.now(),
        isMe: false,
        status: MessageStatus.delivered,
        // Only groups need the "who said this" label above the bubble.
        senderName: groupId.isEmpty ? '' : senderName,
        isImage: content['isImage'] as bool? ?? false,
        imageSeed: content['imageSeed'] as int? ?? 0,
        imageUrl: content['imageUrl'] as String?,
        isVoice: content['isVoice'] as bool? ?? false,
        voiceSeconds: content['voiceSeconds'] as int? ?? 0,
        isVoicemail: content['isVoicemail'] as bool? ?? false,
        forwarded: content['forwarded'] as bool? ?? false,
        replyTo: replyJson is Map
            ? ReplyInfo.fromJson(Map<String, dynamic>.from(replyJson))
            : null,
        isLocation: content['isLocation'] as bool? ?? false,
        locationLat: (content['locationLat'] as num?)?.toDouble(),
        locationLng: (content['locationLng'] as num?)?.toDouble(),
        locationLabel: content['locationLabel'] as String?,
        isContact: content['isContact'] as bool? ?? false,
        contactName: content['contactName'] as String?,
        contactPhone: content['contactPhone'] as String?,
        isPayment: content['isPayment'] as bool? ?? false,
        paymentAmountCents: content['paymentAmountCents'] as int? ?? 0,
        paymentCurrency: content['paymentCurrency'] as String? ?? 'cad',
        paymentStatus: content['paymentStatus'] as String? ?? '',
        isPoll: content['isPoll'] as bool? ?? false,
        pollQuestion: content['pollQuestion'] as String? ?? '',
        pollOptions:
            (content['pollOptions'] as List?)?.cast<String>() ?? const [],
        pollVotes: (content['pollVotes'] as List?)
                ?.map((e) => (e as num).toInt())
                .toList() ??
            const [],
        serverInvite: content['serverInvite'] as String? ?? '',
        expiresAt: content['expiresAt'] == null
            ? null
            : DateTime.tryParse(content['expiresAt'] as String),
      ),
    );
    // Converge the streak with the sender's live count (they only broadcast a
    // non-zero value while it's alive), so both devices show the same number.
    final sharedStreak = (content['fromStreak'] as num?)?.toInt() ?? 0;
    if (sharedStreak > 0 && !chat.contact.isGroup) {
      StreakStore.instance.reconcile(
        chat.id,
        sharedStreak,
        at: DateTime.tryParse(payload['ts'] as String? ?? '')?.toLocal() ??
            DateTime.now(),
      );
    }
    return true;
  }

  /// Applies a remote message-scoped event (edit, delete, reaction, poll vote,
  /// view-once opened, payment status) to the chat that actually holds the
  /// message — routed by message id, so an event for a group message lands in
  /// the group rather than the sender's 1:1 thread. Returns true when a chat
  /// was found and mutated.
  static bool applyMessageEvent(
    String event,
    Map<String, dynamic> payload, {
    required String myPhone,
    ChatStore? store,
  }) {
    final from = payload['from'] as String?;
    final id = payload['id'] as String?;
    if (from == null || id == null || digits(from) == digits(myPhone)) {
      return false;
    }
    final target = store ?? ChatStore.instance;
    final chat = target.chatWithMessage(id, senderId: from);
    if (chat == null) return false;
    switch (event) {
      case 'edit':
        target.editMessage(chat.id, id, (payload['text'] as String?) ?? '');
        return true;
      case 'delete':
        target.deleteMessage(chat.id, id, forEveryone: true);
        return true;
      case 'reaction':
        final emoji = payload['emoji'] as String?;
        if (emoji == null) return false;
        target.setReactionState(
            chat.id, id, emoji, payload['add'] as bool? ?? true);
        return true;
      case 'poll':
        target.applyRemotePollVote(
          chat.id,
          id,
          (payload['add'] as num?)?.toInt() ?? -1,
          (payload['remove'] as num?)?.toInt() ?? -1,
        );
        return true;
      case 'vopen':
        target.markViewOnceOpened(chat.id, id);
        return true;
      case 'payst':
        final status = payload['status'] as String?;
        if (status == null) return false;
        target.setPaymentStatus(chat.id, id, status);
        return true;
    }
    return false;
  }

  /// Applies a delivery/read receipt. When the receipt names the message it
  /// acknowledges, the chat is found through it — so a group member's receipt
  /// advances the ticks in the group, not in your 1:1 thread with them. A
  /// legacy receipt without an id falls back to the sender's own chat.
  static bool applyReceipt(
    Map<String, dynamic> payload, {
    required String myPhone,
    ChatStore? store,
  }) {
    final from = payload['from'] as String?;
    if (from == null || digits(from) == digits(myPhone)) return false;
    final target = store ?? ChatStore.instance;
    final id = payload['id'] as String?;
    final chat = id != null
        ? target.chatWithMessage(id, senderId: from)
        : target.chatWithContact(from);
    if (chat == null) return false;
    final status = payload['kind'] == 'read'
        ? MessageStatus.read
        : MessageStatus.delivered;
    target.setOutgoingStatus(chat.id, status);
    return true;
  }

  /// Recovers the decrypted content map from a relay payload. New payloads seal
  /// everything into `c`; legacy payloads carried the fields at the top level,
  /// so we read those directly when `c` is absent.
  static Map<String, dynamic> _decodeContent(
    Map<String, dynamic> payload, {
    required String from,
    required String myPhone,
  }) {
    final blob = payload['c'] as String?;
    if (blob == null) {
      // Legacy format: fields ride in the clear at the top level.
      return {
        'text': (payload['text'] as String?) ?? '',
        'fromName': payload['fromName'],
        'fromUsername': payload['fromUsername'],
        'isImage': payload['isImage'],
        'imageSeed': payload['imageSeed'],
        'imageUrl': payload['imageUrl'],
        'isVoice': payload['isVoice'],
        'voiceSeconds': payload['voiceSeconds'],
      };
    }

    var json = blob;
    // enc may arrive as int or bool depending on JSON transport.
    final encRaw = payload['enc'];
    if (encRaw == 2 || encRaw == '2') {
      // ECDH path: derive the shared secret from the sender's public key.
      final spk = payload['spk'] as String?;
      final secret =
          spk == null ? null : SecureKeyExchange.instance.sharedSecretWith(spk);
      if (secret != null) {
        json = E2eCrypto.decrypt(secret, blob) ?? blob;
        SecureKeyExchange.instance.rememberPeer(from, spk!);
      }
    } else if (encRaw == 1 || encRaw == true) {
      json = E2eCrypto.decrypt(E2eCrypto.keyFor(from, myPhone), blob) ?? blob;
    }

    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Undecryptable (missing key) — surface a placeholder rather than crash.
    }
    return {'text': json};
  }

  /// Initializes the realtime client when a relay is configured.
  Future<void> init() async {
    if (!RelayConfig.isEnabled || _initialized) return;
    await Supabase.initialize(
      url: RelayConfig.supabaseUrl,
      publishableKey: RelayConfig.supabaseAnonKey,
    );
    _initialized = true;
  }

  /// Subscribes to the signed-in user's inbox so incoming messages arrive even
  /// from someone they haven't chatted with before.
  // --- Offline mailbox ----------------------------------------------------

  /// The store-and-forward table: sealed envelopes held until the recipient
  /// drains them. Same E2E ciphertext as the live broadcast — the server can
  /// read nothing. Rows die on delivery, or after [mailboxTtl] unclaimed.
  static const mailboxTable = 'mailbox';
  static const mailboxTtl = Duration(days: 14);

  Map<String, String> get _restHeaders => {
        'apikey': RelayConfig.supabaseAnonKey,
        'Authorization': 'Bearer ${RelayConfig.supabaseAnonKey}',
        'Content-Type': 'application/json',
      };

  /// Queues one sealed envelope for an offline recipient, tagged with the
  /// broadcast [event] it mirrors. Fire-and-forget: a missing table (setup
  /// SQL not applied yet) just means live-only.
  Future<void> _mailboxPut(
      String contactPhone, Map<String, dynamic> payload,
      {String event = 'msg'}) async {
    try {
      await http
          .post(
            Uri.parse('${RelayConfig.supabaseUrl}/rest/v1/$mailboxTable'),
            headers: _restHeaders,
            body: jsonEncode({
              'inbox': digits(contactPhone),
              'payload': {'e': event, 'p': payload},
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  /// Pure: unwraps fetched mailbox rows into (event, payload) pairs. Typed
  /// rows carry {'e': event, 'p': payload}; anything unwrapped is a plain
  /// message from before events were queued. Junk rows drop out.
  static List<(String, Map<String, dynamic>)> mailboxEntries(
      List<dynamic> rows) {
    final out = <(String, Map<String, dynamic>)>[];
    for (final row in rows) {
      if (row is! Map) continue;
      var p = row['payload'];
      if (p is String) {
        try {
          p = jsonDecode(p);
        } catch (_) {
          continue;
        }
      }
      if (p is! Map) continue;
      final inner = p['p'];
      final event = p['e'];
      if (event is String && inner is Map) {
        out.add((event, Map<String, dynamic>.from(inner)));
      } else {
        out.add(('msg', Map<String, dynamic>.from(p)));
      }
    }
    return out;
  }

  /// Drains this device's offline mailbox: every queued envelope goes
  /// through the same path as a live broadcast (dedup makes replays safe),
  /// claimed rows are deleted, and anything past its TTL is swept.
  Future<void> fetchMailbox() async {
    if (!_initialized) return;
    final me = Session.instance.user.value?.phone;
    if (me == null) return;
    final inbox = digits(me);
    if (inbox.isEmpty) return;
    const base = '${RelayConfig.supabaseUrl}/rest/v1/$mailboxTable';
    try {
      final res = await http
          .get(
            Uri.parse('$base?inbox=eq.$inbox&select=id,payload'
                '&order=created_at.asc&limit=200'),
            headers: _restHeaders,
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 300) return; // table missing or unreachable
      final rows = jsonDecode(res.body);
      if (rows is! List) return;
      for (final (event, payload) in mailboxEntries(rows)) {
        try {
          switch (event) {
            case 'msg':
              _onInboxMessage(payload, myPhone: me);
            case 'receipt':
              applyReceipt(payload, myPhone: me);
            case 'edit' || 'delete' || 'reaction' || 'poll' || 'payst' ||
                  'vopen':
              applyMessageEvent(event, payload, myPhone: me);
            case 'gupd':
              applyGroupUpdate(payload, myPhone: me);
            case 'chmsg' || 'chjoin' || 'chupd' || 'fpost' || 'fdel' ||
                  'flike' || 'fvote' || 'chdel' || 'chedt' || 'chrxn' ||
                  'chpin':
              _applyCommunityEvent(event, payload, me);
          }
        } catch (_) {
          // A corrupt envelope must not wedge the queue — it gets deleted
          // with the rest below.
        }
      }
      final ids = [
        for (final row in rows)
          if (row is Map && row['id'] != null) '${row['id']}'
      ];
      if (ids.isNotEmpty) {
        await http
            .delete(Uri.parse('$base?id=in.(${ids.join(',')})'),
                headers: _restHeaders)
            .timeout(const Duration(seconds: 15));
      }
      // Sweep whatever nobody claimed within the TTL.
      final cutoff =
          DateTime.now().toUtc().subtract(mailboxTtl).toIso8601String();
      await http
          .delete(
              Uri.parse('$base?inbox=eq.$inbox&created_at=lt.$cutoff'),
              headers: _restHeaders)
          .timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  /// Applies one incoming chat message, whether it arrived live over the
  /// broadcast or was fetched from the offline mailbox: dedup + store, key
  /// caching, and the delivered receipt that advances the sender's ticks.
  void _onInboxMessage(Map<String, dynamic> map, {required String myPhone}) {
    final added = applyIncoming(map, myPhone: myPhone);
    final from = map['from'] as String?;
    if (from != null) {
      // Cache the sender's public key (rides on enc-2 messages) and
      // make sure they have ours, so replies upgrade to the ECDH path.
      final spk = map['spk'] as String?;
      if (spk != null) SecureKeyExchange.instance.rememberPeer(from, spk);
      _ensureKeyShared(from);
    }
    // Acknowledge delivery so the sender's ticks advance — naming
    // the message so a group ack lands on the group's ticks.
    if (added && from != null) {
      sendReceipt(from, 'delivered', messageId: map['id'] as String?);
    }
  }

  void start() {
    if (!_initialized || _inbox != null) return;
    final me = Session.instance.user.value?.phone;
    if (me == null) return;
    _inbox = _client
        .channel(inboxChannel(me))
        .onBroadcast(
          event: 'msg',
          callback: (payload) => _onInboxMessage(
              Map<String, dynamic>.from(payload),
              myPhone: me),
        )
        .onBroadcast(
          event: 'gupd',
          callback: (payload) {
            final map = Map<String, dynamic>.from(payload);
            applyGroupUpdate(map, myPhone: me);
            final from = map['from'] as String?;
            final spk = map['spk'] as String?;
            if (from != null && spk != null) {
              SecureKeyExchange.instance.rememberPeer(from, spk);
            }
          },
        )
        .onBroadcast(
          event: 'key',
          callback: (payload) {
            final from = payload['from'] as String?;
            final pub = payload['pub'] as String?;
            if (from == null || pub == null || digits(from) == digits(me)) {
              return;
            }
            SecureKeyExchange.instance.rememberPeer(from, pub);
            // Reply with our key once so both sides can derive the secret.
            _ensureKeyShared(from);
          },
        )
        .onBroadcast(
          event: 'typing',
          callback: (payload) {
            final from = payload['from'] as String?;
            if (from == null || digits(from) == digits(me)) return;
            typingFromDigits = digits(from);
            typingPing.value++;
          },
        )
        .onBroadcast(
          event: 'presence',
          callback: (payload) {
            final from = payload['from'] as String?;
            if (from == null || digits(from) == digits(me)) return;
            presenceFromDigits = digits(from);
            presencePing.value++;
          },
        )
        .onBroadcast(
          event: 'loc',
          callback: (payload) {
            final parsed = parseLocation(Map<String, dynamic>.from(payload));
            if (parsed == null || parsed.fromDigits == digits(me)) return;
            LiveLocationStore.instance
                .update(parsed.fromDigits, parsed.lat, parsed.lng);
          },
        )
        .onBroadcast(
          event: 'vopen',
          callback: (payload) => applyMessageEvent(
              'vopen', Map<String, dynamic>.from(payload), myPhone: me),
        )
        .onBroadcast(
          event: 'receipt',
          callback: (payload) =>
              applyReceipt(Map<String, dynamic>.from(payload), myPhone: me),
        )
        .onBroadcast(
          event: 'edit',
          callback: (payload) => applyMessageEvent(
              'edit', Map<String, dynamic>.from(payload), myPhone: me),
        )
        .onBroadcast(
          event: 'delete',
          callback: (payload) => applyMessageEvent(
              'delete', Map<String, dynamic>.from(payload), myPhone: me),
        )
        .onBroadcast(
          event: 'payst',
          callback: (payload) => applyMessageEvent(
              'payst', Map<String, dynamic>.from(payload), myPhone: me),
        )
        .onBroadcast(
          event: 'reaction',
          callback: (payload) => applyMessageEvent(
              'reaction', Map<String, dynamic>.from(payload), myPhone: me),
        )
        .onBroadcast(
          event: 'poll',
          callback: (payload) => applyMessageEvent(
              'poll', Map<String, dynamic>.from(payload), myPhone: me),
        )
        .onBroadcast(
          event: 'call',
          callback: (payload) {
            final p = Map<String, dynamic>.from(payload);
            final from = p['from'] as String?;
            final kind = p['kind'] as String?;
            final callId = p['callId'] as String?;
            if (from == null ||
                kind == null ||
                callId == null ||
                digits(from) == digits(me)) {
              return;
            }
            final call = CallService.instance;
            switch (kind) {
              case 'offer':
                final peer = AppUser(
                  id: from,
                  name: (p['fromName'] as String?)?.trim().isNotEmpty == true
                      ? p['fromName'] as String
                      : from,
                  avatarColor: '#7A5CFF',
                  about: 'Available',
                  phone: from,
                  username: (p['fromUsername'] as String?) ?? '',
                );
                final groupInfo = _openGroupInfo(from, p);
                if (groupInfo != null) {
                  final groupId = (groupInfo['id'] as String?) ?? '';
                  if (groupId.isEmpty) break;
                  call.onRemoteGroupOffer(
                    peer,
                    callId,
                    p['video'] == true,
                    group: AppUser(
                      id: groupId,
                      name: (groupInfo['name'] as String?) ?? 'Group',
                      avatarColor:
                          (groupInfo['color'] as String?) ?? '#4DB6AC',
                      isGroup: true,
                    ),
                    members: membersFromJson(groupInfo['members']),
                  );
                  break;
                }
                call.onRemoteOffer(peer, callId, p['video'] == true,
                    sdp: _openSdp(from, p));
                break;
              case 'joined':
                call.onRemoteJoined(from, callId);
                break;
              case 'left':
                call.onRemoteLeft(from, callId);
                break;
              case 'answer':
                call.onRemoteAnswer(callId, sdp: _openSdp(from, p));
                break;
              case 'ice':
                final ice = _openIce(from, p);
                if (ice != null) call.onRemoteIce(callId, ice);
                break;
              case 'decline':
                call.onRemoteDecline(callId);
                break;
              case 'end':
                call.onRemoteEnd(callId);
                break;
              case 'reaction':
                call.onRemoteReaction(callId, p['emoji'] as String?);
                break;
              case 'media':
                final m = p['media'];
                call.onRemoteMediaState(
                    callId, m is Map ? Map<String, dynamic>.from(m) : null);
                break;
            }
          },
        )
        .onBroadcast(
          event: 'file',
          callback: (payload) {
            final p = Map<String, dynamic>.from(payload);
            final from = p['from'] as String?;
            final kind = p['kind'] as String?;
            if (from == null || kind == null || digits(from) == digits(me)) {
              return;
            }
            final ft = FileTransfer.instance;
            switch (kind) {
              case 'offer':
                ft.onRemoteOffer(
                  from,
                  (p['fromName'] as String?) ?? from,
                  (p['transferId'] as String?) ?? '',
                  (p['fileName'] as String?) ?? 'file',
                  (p['size'] as num?)?.toInt() ?? 0,
                  _openSdp(from, p) ?? '',
                );
                break;
              case 'answer':
                ft.onRemoteAnswer(_openSdp(from, p) ?? '');
                break;
              case 'ice':
                final ice = _openIce(from, p);
                if (ice != null) ft.onRemoteIce(ice);
                break;
              case 'decline':
                ft.onRemoteDecline();
                break;
            }
          },
        )
        .subscribe();

    // The shared community bus. Everything server-scoped — channel messages,
    // joins, structure syncs, and feed posts — rides it sealed with each
    // server's own secret, so only members can read any of it. The bare
    // 'post' event below is the legacy plaintext feed path, kept only so
    // pre-secret servers and old builds still interoperate.
    _feedChannel = _client
        .channel('server_feed')
        .onBroadcast(
          event: 'post',
          callback: (payload) {
            final map = Map<String, dynamic>.from(payload);
            final from = map['from'] as String?;
            if (from == null || digits(from) == digits(me)) return;
            final raw = map['post'];
            if (raw is! Map) return;
            try {
              FeedStore.instance.addRemote(
                  FeedPost.fromJson(Map<String, dynamic>.from(raw)));
            } catch (_) {}
          },
        )
        .onBroadcast(
          event: 'chmsg',
          callback: (payload) => _applyCommunityEvent('chmsg',
              Map<String, dynamic>.from(payload), me),
        )
        .onBroadcast(
          event: 'chdel',
          callback: (payload) => _applyCommunityEvent('chdel',
              Map<String, dynamic>.from(payload), me),
        )
        .onBroadcast(
          event: 'chedt',
          callback: (payload) => _applyCommunityEvent('chedt',
              Map<String, dynamic>.from(payload), me),
        )
        .onBroadcast(
          event: 'chrxn',
          callback: (payload) => _applyCommunityEvent('chrxn',
              Map<String, dynamic>.from(payload), me),
        )
        .onBroadcast(
          event: 'chpin',
          callback: (payload) => _applyCommunityEvent('chpin',
              Map<String, dynamic>.from(payload), me),
        )
        .onBroadcast(
          event: 'chjoin',
          callback: (payload) => _applyCommunityEvent('chjoin',
              Map<String, dynamic>.from(payload), me),
        )
        .onBroadcast(
          event: 'chupd',
          callback: (payload) => _applyCommunityEvent('chupd',
              Map<String, dynamic>.from(payload), me),
        )
        .onBroadcast(
          event: 'vpres',
          callback: (payload) => _applyCommunityEvent('vpres',
              Map<String, dynamic>.from(payload), me),
        )
        .onBroadcast(
          event: 'chtyp',
          callback: (payload) => _applyCommunityEvent('chtyp',
              Map<String, dynamic>.from(payload), me),
        )
        .onBroadcast(
          event: 'fpost',
          callback: (payload) => _applyCommunityEvent('fpost',
              Map<String, dynamic>.from(payload), me),
        )
        .onBroadcast(
          event: 'fdel',
          callback: (payload) => _applyCommunityEvent('fdel',
              Map<String, dynamic>.from(payload), me),
        )
        .onBroadcast(
          event: 'flike',
          callback: (payload) => _applyCommunityEvent('flike',
              Map<String, dynamic>.from(payload), me),
        )
        .onBroadcast(
          event: 'fvote',
          callback: (payload) => _applyCommunityEvent('fvote',
              Map<String, dynamic>.from(payload), me),
        )
        .subscribe();
    // Catch up on whatever arrived while the app was closed.
    fetchMailbox();
  }

  /// Routes one sealed community event ([event] = chmsg/chjoin/chupd) into
  /// the store — shared by the live bus and the offline mailbox, so the
  /// dedup/merge semantics are identical either way.
  /// Feeds one sealed community event through the real routing, so a test can
  /// check what a *received* chdel/chedt/chrxn/chpin actually does to the
  /// store rather than trusting that the switch has a case for it.
  @visibleForTesting
  void debugApplyCommunityEvent(
          String event, Map<String, dynamic> payload, String me) =>
      _applyCommunityEvent(event, payload, me);

  void _applyCommunityEvent(
      String event, Map<String, dynamic> payload, String me) {
    _onCommunityEvent(payload, me, (cid, body) {
      switch (event) {
        case 'chmsg':
          final rawMsg = body['message'];
          if (rawMsg is! Map) return;
          final msg = Message.fromJson(Map<String, dynamic>.from(rawMsg));
          CommunityStore.instance.addRemoteChannelMessage(
            cid,
            body['channelId'] as String? ?? '',
            Message(
              id: msg.id,
              text: msg.text,
              time: msg.time,
              isMe: false,
              status: MessageStatus.delivered,
              senderName: body['senderName'] as String? ?? 'Member',
              isImage: msg.isImage,
              imageUrl: msg.imageUrl,
              replyTo: msg.replyTo,
              isPoll: msg.isPoll,
              pollQuestion: msg.pollQuestion,
              pollOptions: msg.pollOptions,
              pollVotes: msg.pollVotes,
            ),
          );
        case 'chdel':
          final id = body['id'];
          if (id is! String) return;
          CommunityStore.instance.deleteChannelMessage(
              cid, body['channelId'] as String? ?? '', id);
        case 'chedt':
          final id = body['id'];
          final text = body['text'];
          if (id is! String || text is! String) return;
          CommunityStore.instance.applyRemoteChannelEdit(
              cid, body['channelId'] as String? ?? '', id, text);
        case 'chrxn':
          final id = body['id'];
          final emoji = body['emoji'];
          if (id is! String || emoji is! String) return;
          CommunityStore.instance.setChannelReaction(
              cid, body['channelId'] as String? ?? '', id, emoji,
              add: body['add'] as bool? ?? true);
        case 'chpin':
          final id = body['id'];
          if (id is! String) return;
          CommunityStore.instance.setChannelMessagePinned(
              cid, body['channelId'] as String? ?? '', id,
              pinned: body['pinned'] as bool? ?? true);
        case 'chjoin':
          final rawMember = body['member'];
          if (rawMember is! Map) return;
          CommunityStore.instance.applyRemoteJoin(
              cid, Member.fromJson(Map<String, dynamic>.from(rawMember)));
        case 'chupd':
          final structure = body['structure'];
          if (structure is! Map) return;
          CommunityStore.instance.applyRemoteStructure(
              Map<String, dynamic>.from(structure),
              myDigits: digits(me));
        case 'chtyp':
          final channelId = body['channelId'];
          final fromDigits = digits(payload['from'] as String? ?? '');
          if (channelId is! String || fromDigits.isEmpty) return;
          ChannelTypingStore.instance.noteRemote(
            channelId: channelId,
            digits: fromDigits,
            name: body['name'] as String? ?? '',
          );
        case 'vpres':
          final channelId = body['channelId'];
          final fromDigits = digits(payload['from'] as String? ?? '');
          if (channelId is! String || fromDigits.isEmpty) return;
          VoicePresenceStore.instance.applyRemote(
            channelId: channelId,
            digits: fromDigits,
            name: body['name'] as String? ?? '',
            joined: body['joined'] as bool? ?? false,
            muted: body['muted'] as bool? ?? false,
            video: body['video'] as bool? ?? false,
            screen: body['screen'] as bool? ?? false,
          );
        case 'fpost':
          final rawPost = body['post'];
          if (rawPost is! Map) return;
          try {
            FeedStore.instance.addRemote(
                FeedPost.fromJson(Map<String, dynamic>.from(rawPost)));
          } catch (_) {}
        case 'fdel':
          final id = body['id'];
          if (id is String) FeedStore.instance.removeRemote(id);
        case 'flike':
          final id = body['id'];
          if (id is String) {
            FeedStore.instance.applyRemoteLike(
              id,
              liked: body['liked'] as bool? ?? true,
              likerName: body['name'] as String? ?? 'Someone',
              likerUsername: body['username'] as String? ?? '',
            );
          }
        case 'fvote':
          final id = body['id'];
          final option = body['option'];
          if (id is String && option is int) {
            FeedStore.instance.applyRemoteVote(
              id,
              option: option,
              previous: body['previous'] as int? ?? -1,
              voterUsername: body['username'] as String? ?? '',
            );
          }
      }
    });
  }

  /// Decodes a sealed community-bus event: looks the server up by id, opens
  /// the body with its secret, and hands the plaintext to [apply]. Events
  /// for servers this device isn't in (no id match → no secret) drop
  /// silently, as do our own echoes.
  void _onCommunityEvent(Map<String, dynamic> payload, String me,
      void Function(String cid, Map<String, dynamic> body) apply) {
    try {
      final from = payload['from'] as String?;
      if (from == null || digits(from) == digits(me)) return;
      final cid = payload['communityId'] as String?;
      final data = payload['data'] as String?;
      if (cid == null || data == null) return;
      final secret = CommunityStore.instance.byId(cid)?.secretBytes;
      if (secret == null) return;
      final plain = E2eCrypto.decrypt(secret, data);
      if (plain == null) return;
      final body = jsonDecode(plain);
      if (body is! Map) return;
      apply(cid, Map<String, dynamic>.from(body));
    } catch (_) {}
  }

  /// Seals a community-bus event ('chmsg' / 'chjoin' / 'chupd') with the
  /// server's secret, broadcasts it live, and fans the same envelope into
  /// every other member's offline mailbox so nobody misses server activity
  /// just for being away. No-op for servers without a secret (older builds).
  Future<void> _sendCommunityEvent(
      String event, String communityId, Map<String, dynamic> body) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final community = CommunityStore.instance.byId(communityId);
    final secret = community?.secretBytes;
    if (community == null || secret == null) return;
    final payload = {
      'from': me.phone,
      'communityId': communityId,
      'data': E2eCrypto.encrypt(secret, jsonEncode(body)),
    };
    final channel = _feedChannel ??
        _sendChannels.putIfAbsent(
            'server_feed', () => _client.channel('server_feed'));
    try {
      await channel.sendBroadcastMessage(event: event, payload: payload);
    } catch (_) {}
    final mine = digits(me.phone);
    for (final m in community.members) {
      final d = CommunityStore.digitsOfWireId(m.id);
      if (d == null || d == mine) continue;
      _mailboxPut(d, payload, event: event);
    }
  }

  /// Like [_sendCommunityEvent] but broadcast only — nothing is queued into
  /// anyone's mailbox. For presence that is exactly right: a "joined voice"
  /// replayed from a mailbox hours later would park a ghost in a channel
  /// nobody is actually in.
  Future<void> _broadcastCommunityEvent(
      String event, String communityId, Map<String, dynamic> body) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final community = CommunityStore.instance.byId(communityId);
    final secret = community?.secretBytes;
    if (community == null || secret == null) return;
    final channel = _feedChannel ??
        _sendChannels.putIfAbsent(
            'server_feed', () => _client.channel('server_feed'));
    try {
      await channel.sendBroadcastMessage(event: event, payload: {
        'from': me.phone,
        'communityId': communityId,
        'data': E2eCrypto.encrypt(secret, jsonEncode(body)),
      });
    } catch (_) {}
  }

  /// Announces that this device joined or left a voice channel.
  Future<void> sendVoicePresence(
    String communityId,
    String channelId, {
    required bool joined,
    required bool muted,
    required bool video,
    required bool screen,
  }) =>
      _broadcastCommunityEvent('vpres', communityId, {
        'channelId': channelId,
        'name': Session.instance.user.value?.name ?? '',
        'joined': joined,
        'muted': muted,
        'video': video,
        'screen': screen,
      });

  /// Tells the server someone is typing in a channel. Live only — a typing
  /// ping replayed from a mailbox would be nonsense.
  Future<void> sendChannelTyping(String communityId, String channelId) =>
      _broadcastCommunityEvent('chtyp', communityId, {
        'channelId': channelId,
        'name': Session.instance.user.value?.name ?? '',
      });

  /// Delivers a channel message to every other member of the server.
  Future<void> sendChannelMessage(String communityId, String channelId,
          Message message, {required String senderName}) =>
      _sendCommunityEvent('chmsg', communityId, {
        'channelId': channelId,
        'senderName': senderName,
        'message': message.toJson(),
      });

  /// Removes a channel message on every member's device.
  ///
  /// Without this, "Delete" deleted it here and nowhere else: the author saw
  /// it go and everyone else kept reading it. The local tombstone only stops
  /// a mailbox replay putting it back on *this* device.
  Future<void> sendChannelMessageDeleted(
          String communityId, String channelId, String messageId) =>
      _sendCommunityEvent('chdel', communityId, {
        'channelId': channelId,
        'id': messageId,
      });

  /// Rewrites a channel message on every member's device.
  Future<void> sendChannelMessageEdited(String communityId, String channelId,
          String messageId, String text) =>
      _sendCommunityEvent('chedt', communityId, {
        'channelId': channelId,
        'id': messageId,
        'text': text,
      });

  /// Adds or removes an emoji reaction for everyone. Carries which way it
  /// went rather than "toggle", so two devices cannot cancel each other out.
  Future<void> sendChannelReaction(
          String communityId, String channelId, String messageId, String emoji,
          {required bool add}) =>
      _sendCommunityEvent('chrxn', communityId, {
        'channelId': channelId,
        'id': messageId,
        'emoji': emoji,
        'add': add,
      });

  /// Moves the channel's pin banner for everyone.
  Future<void> sendChannelPin(
          String communityId, String channelId, String messageId,
          {required bool pinned}) =>
      _sendCommunityEvent('chpin', communityId, {
        'channelId': channelId,
        'id': messageId,
        'pinned': pinned,
      });

  /// Announces that this device's user joined the server.
  Future<void> sendServerJoin(String communityId, Member member) =>
      _sendCommunityEvent('chjoin', communityId, {'member': member.toJson()});

  /// Removes a feed post (or repost entry) on every member's device. Only
  /// sealed servers can do this; legacy ones delete locally alone.
  Future<void> sendFeedDelete(String communityId, String postId) =>
      _sendCommunityEvent('fdel', communityId, {'id': postId});

  /// Broadcasts a like/unlike, carrying who so the author's count moves and
  /// they can be notified. Sealed with the server key like all feed traffic.
  Future<void> sendFeedLike(String communityId, String postId,
          {required bool liked,
          required String likerName,
          required String likerUsername}) =>
      _sendCommunityEvent('flike', communityId, {
        'id': postId,
        'liked': liked,
        'name': likerName,
        'username': likerUsername,
      });

  /// A poll vote, so everyone in the server sees one shared tally. [previous]
  /// is the option the voter moved off (-1 for a first vote).
  Future<void> sendFeedVote(String communityId, String postId,
          {required int option,
          required int previous,
          required String voterUsername}) =>
      _sendCommunityEvent('fvote', communityId, {
        'id': postId,
        'option': option,
        'previous': previous,
        'username': voterUsername,
      });

  /// Broadcasts the server's current shape so members converge after any
  /// structural change — a new channel, a rename, a ban, a settings flip.
  Future<void> sendCommunityUpdate(String communityId) async {
    final me = Session.instance.user.value;
    if (me == null) return;
    final structure = CommunityStore.instance.exportStructure(
      communityId,
      myDigits: digits(me.phone),
      myName: AppState.profile.value.name,
    );
    if (structure == null) return;
    await _sendCommunityEvent(
        'chupd', communityId, {'structure': structure});
  }

  /// Delivers a feed post to the server's members. Servers with a secret
  /// get it sealed on the community bus — members-only, offline-queued like
  /// every other server event. Only a legacy server with no secret still
  /// uses the old plaintext broadcast (kept so old builds interoperate).
  Future<void> sendFeedPost(FeedPost post) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final community = CommunityStore.instance.byId(post.communityId);
    if (community != null && community.secretBytes != null) {
      await _sendCommunityEvent(
          'fpost', post.communityId, {'post': post.toJson()});
      return;
    }
    final channel = _feedChannel ??
        _sendChannels.putIfAbsent(
            'server_feed', () => _client.channel('server_feed'));
    try {
      await channel.sendBroadcastMessage(
        event: 'post',
        payload: {'from': me.phone, 'post': post.toJson()},
      );
    } catch (_) {}
  }

  /// Encrypts a call/file signaling string ([plaintext] — an SDP or a JSON ICE
  /// candidate) for [contactPhone], so the relay can't read the WebRTC
  /// handshake (which carries DTLS fingerprints and network candidates). Uses
  /// the ECDH shared secret when known, else the phone-derived key. Returns the
  /// ciphertext, the enc mode, and (for ECDH) our public key.
  ({String data, int enc, String? spk}) _sealSignal(
      String contactPhone, String plaintext) {
    final kx = SecureKeyExchange.instance;
    final peerPub = kx.peerKey(contactPhone);
    if (kx.isReady && peerPub != null) {
      final secret = kx.sharedSecretWith(peerPub);
      if (secret != null) {
        return (
          data: E2eCrypto.encrypt(secret, plaintext),
          enc: 2,
          spk: kx.myPublicKey
        );
      }
    }
    final me = Session.instance.user.value;
    if (me != null) {
      return (
        data: E2eCrypto.encrypt(E2eCrypto.keyFor(me.phone, contactPhone),
            plaintext),
        enc: 1,
        spk: null,
      );
    }
    return (data: plaintext, enc: 0, spk: null);
  }

  /// Reverses [_sealSignal] for a signal received from [from]. Returns the
  /// plaintext, or the input unchanged when it wasn't (or couldn't be) sealed.
  String? _openSignal(String from, String? data, Object? encRaw, String? spk) {
    if (data == null) return null;
    if (encRaw == 2 || encRaw == '2') {
      final secret =
          spk == null ? null : SecureKeyExchange.instance.sharedSecretWith(spk);
      if (secret != null) {
        if (spk != null) SecureKeyExchange.instance.rememberPeer(from, spk);
        return E2eCrypto.decrypt(secret, data) ?? data;
      }
      return data;
    }
    if (encRaw == 1 || encRaw == true) {
      final me = Session.instance.user.value;
      if (me != null) {
        return E2eCrypto.decrypt(E2eCrypto.keyFor(from, me.phone), data) ?? data;
      }
    }
    return data;
  }

  /// The active file-transfer id, so ICE candidates can be tagged with it.
  String? _currentFileId;
  set currentFileId(String? id) => _currentFileId = id;

  /// Sends a file-transfer signaling event to [contactPhone]'s inbox. The file
  /// bytes never go through here — only the WebRTC handshake (SDP/ICE) does.
  Future<void> sendFileSignal(
    String contactPhone, {
    required String kind,
    String? sdp,
    Map<String, dynamic>? ice,
    String? fileName,
    int? size,
    String? transferId,
  }) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final name = inboxChannel(contactPhone);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    // Encrypt the handshake so the relay never sees the SDP / ICE candidates.
    final sealed = _sealSignalPair(contactPhone, sdp: sdp, ice: ice);
    await channel.sendBroadcastMessage(
      event: 'file',
      payload: {
        'from': me.phone,
        'fromName': me.name,
        'kind': kind,
        'transferId': transferId ?? _currentFileId ?? '',
        ...sealed,
        if (fileName != null) 'fileName': fileName,
        if (size != null) 'size': size,
      },
    );
  }

  /// Seals an [sdp] and/or [ice] candidate for [contactPhone] into a payload
  /// fragment carrying the ciphertext plus the enc mode / sender key so the
  /// receiver can decrypt. Shared by call and file signaling.
  Map<String, dynamic> _sealSignalPair(
    String contactPhone, {
    String? sdp,
    Map<String, dynamic>? ice,
  }) {
    final out = <String, dynamic>{};
    if (sdp != null) {
      final s = _sealSignal(contactPhone, sdp);
      out['sdp'] = s.data;
      out['senc'] = s.enc;
      if (s.spk != null) out['sspk'] = s.spk;
    }
    if (ice != null) {
      final s = _sealSignal(contactPhone, jsonEncode(ice));
      out['ice'] = s.data;
      out['ienc'] = s.enc;
      if (s.spk != null) out['ispk'] = s.spk;
    }
    return out;
  }

  /// Recovers an SDP string from a sealed signaling [payload].
  String? _openSdp(String from, Map<String, dynamic> payload) =>
      _openSignal(from, payload['sdp'] as String?, payload['senc'],
          payload['sspk'] as String?);

  /// Recovers an ICE-candidate map from a sealed signaling [payload].
  Map<String, dynamic>? _openIce(String from, Map<String, dynamic> payload) {
    final raw = payload['ice'];
    if (raw == null) return null;
    // New sealed form: an encrypted JSON string. Legacy form: a raw Map.
    if (raw is Map) return Map<String, dynamic>.from(raw);
    final json = _openSignal(from, raw as String?, payload['ienc'],
        payload['ispk'] as String?);
    if (json == null) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  /// Sends a call-signaling event ('offer', 'answer', 'decline', 'end') to
  /// [contactPhone]'s inbox so their device rings / stays in sync. For WebRTC,
  /// 'offer'/'answer' carry the session-description [sdp].
  Future<void> sendCall(
    String contactPhone, {
    required String kind,
    required String callId,
    required bool video,
    String? sdp,
    String? emoji,
    Map<String, dynamic>? media,
    Map<String, dynamic>? group,
  }) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final name = inboxChannel(contactPhone);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    // Group-call metadata (which group, who's in it) is sealed like an SDP,
    // so the relay can't tell a group call from a one-to-one one.
    ({String data, int enc, String? spk})? sealedGroup;
    if (group != null) {
      sealedGroup = _sealSignal(contactPhone, jsonEncode(group));
    }
    await channel.sendBroadcastMessage(
      event: 'call',
      payload: {
        'from': me.phone,
        'fromName': me.name,
        'fromUsername': me.username,
        'kind': kind,
        'callId': callId,
        'video': video,
        if (emoji != null) 'emoji': emoji,
        if (media != null) 'media': media,
        if (sealedGroup != null) 'grp': sealedGroup.data,
        if (sealedGroup != null) 'genc': sealedGroup.enc,
        if (sealedGroup?.spk != null) 'gspk': sealedGroup!.spk,
        ..._sealSignalPair(contactPhone, sdp: sdp),
      },
    );
  }

  /// The group fields a call invitation carries: enough for the callee's
  /// device to show the group and ring the same roster, nothing more.
  static Map<String, dynamic> groupCallInfo(Chat group) => {
        'id': group.id,
        'name': group.contact.name,
        'color': group.contact.avatarColor,
        'members': group.members.map(_memberSummary).toList(),
      };

  /// Opens the sealed group blob of a call payload, or null for 1:1 calls.
  Map<String, dynamic>? _openGroupInfo(
      String from, Map<String, dynamic> payload) {
    final raw = _openSignal(
        from, payload['grp'] as String?, payload['genc'], payload['gspk'] as String?);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  /// Sends a WebRTC ICE candidate for [callId] to [contactPhone].
  Future<void> sendIce(
      String contactPhone, Map<String, dynamic> candidate) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final name = inboxChannel(contactPhone);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    await channel.sendBroadcastMessage(
      event: 'call',
      payload: {
        'from': me.phone,
        'kind': 'ice',
        'callId': _currentCallId ?? '',
        'video': false,
        ..._sealSignalPair(contactPhone, ice: candidate),
      },
    );
  }

  /// The active call id, so ICE candidates can be tagged with it.
  String? _currentCallId;
  set currentCallId(String? id) => _currentCallId = id;

  /// Broadcasts [event] to [contactPhone]'s inbox live AND queues the same
  /// payload in their offline mailbox, so edits, deletes, reactions, votes
  /// and receipts survive the peer being away exactly like messages do.
  Future<void> _sendInboxEvent(
      String contactPhone, String event, Map<String, dynamic> payload) async {
    final name = inboxChannel(contactPhone);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    await channel.sendBroadcastMessage(event: event, payload: payload);
    _mailboxPut(contactPhone, payload, event: event);
  }

  /// Broadcasts a reaction change on message [messageId] to [contactPhone].
  Future<void> sendReaction(
      String contactPhone, String messageId, String emoji, bool add) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    await _sendInboxEvent(contactPhone, 'reaction',
        {'from': me.phone, 'id': messageId, 'emoji': emoji, 'add': add});
  }

  /// Broadcasts a poll vote on [messageId] to [contactPhone]: increments
  /// [addOption] and decrements a prior [removeOption] (-1 for none).
  Future<void> sendPollVote(
      String contactPhone, String messageId, int addOption,
      int removeOption) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    await _sendInboxEvent(contactPhone, 'poll', {
      'from': me.phone,
      'id': messageId,
      'add': addOption,
      'remove': removeOption,
    });
  }

  /// Broadcasts a payment lifecycle change ('paid'/'failed') for the receipt
  /// [messageId] to [contactPhone], so their bubble flips from pending.
  Future<void> sendPaymentStatus(
      String contactPhone, String messageId, String status) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    await _sendInboxEvent(contactPhone, 'payst',
        {'from': me.phone, 'id': messageId, 'status': status});
  }

  /// Broadcasts an edit of message [messageId] to [contactPhone].
  Future<void> sendEdit(
      String contactPhone, String messageId, String newText) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    await _sendInboxEvent(contactPhone, 'edit',
        {'from': me.phone, 'id': messageId, 'text': newText});
  }

  /// Broadcasts a delete-for-everyone of message [messageId] to [contactPhone].
  Future<void> sendDelete(String contactPhone, String messageId) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    await _sendInboxEvent(
        contactPhone, 'delete', {'from': me.phone, 'id': messageId});
  }

  /// Tells [contactPhone] that their "view once" photo [messageId] was opened,
  /// so their copy flips to the "Opened" state.
  Future<void> sendViewOnceOpened(
      String contactPhone, String messageId) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    await _sendInboxEvent(
        contactPhone, 'vopen', {'from': me.phone, 'id': messageId});
  }

  /// Sends a delivery/read receipt ('delivered' or 'read') to [contactPhone].
  Future<void> sendReceipt(String contactPhone, String kind,
      {String? messageId}) async {
    if (!_initialized || digits(contactPhone).isEmpty) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    // Naming the acknowledged message routes the receipt to the right
    // conversation — essential once the same person shares a group with you.
    await _sendInboxEvent(contactPhone, 'receipt', {
      'from': me.phone,
      'kind': kind,
      if (messageId != null) 'id': messageId,
    });
  }

  /// Parses an incoming 'loc' payload into the sender's digits and position,
  /// or null when it's malformed. Pure, so it can be unit-tested.
  static ({String fromDigits, double lat, double lng})? parseLocation(
      Map<String, dynamic> payload) {
    final from = payload['from'] as String?;
    final lat = (payload['lat'] as num?)?.toDouble();
    final lng = (payload['lng'] as num?)?.toDouble();
    if (from == null || lat == null || lng == null) return null;
    return (fromDigits: digits(from), lat: lat, lng: lng);
  }

  /// Broadcasts your live position to [contactPhone]'s inbox for the Snap Map.
  Future<void> sendLocation(
      String contactPhone, double lat, double lng) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final name = inboxChannel(contactPhone);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    await channel.sendBroadcastMessage(
      event: 'loc',
      payload: {'from': me.phone, 'lat': lat, 'lng': lng},
    );
  }

  /// Sends a lightweight "typing" ping to [contactPhone]'s inbox.
  Future<void> sendTyping(String contactPhone) async =>
      _ping(contactPhone, 'typing');

  /// Sends an "online" presence ping to [contactPhone]'s inbox.
  Future<void> sendPresence(String contactPhone) async =>
      _ping(contactPhone, 'presence');

  Future<void> _ping(String contactPhone, String event) async {
    if (!_initialized || digits(contactPhone).isEmpty) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final name = inboxChannel(contactPhone);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    await channel.sendBroadcastMessage(event: event, payload: {'from': me.phone});
  }

  /// Broadcasts an outgoing [message] to [contactPhone]'s inbox over REST (the
  /// channel is never subscribed, so we can't see their other traffic). Uses
  /// the ECDH key when the peer's public key is known, otherwise falls back to
  /// the phone-derived key and kicks off a key exchange for next time.
  /// When [group] is set the message is addressed to that group thread on the
  /// recipient's device instead of a one-to-one chat with you.
  Future<void> send(String contactPhone, Message message, {Chat? group}) async {
    if (!_initialized) return;
    // A contact without a number (e.g. the note-to-self chat) has no inbox.
    if (digits(contactPhone).isEmpty) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    // Also nudge their device over APNs (no-op unless push is configured).
    final sender = me.name.isEmpty ? 'New message' : me.name;
    PushService.instance.notify(contactPhone,
        title: group == null ? sender : '$sender • ${group.contact.name}');

    final kx = SecureKeyExchange.instance;
    final peerPub = kx.peerKey(contactPhone);
    List<int>? ecdhSecret;
    String? senderPublicKey;
    if (kx.isReady && peerPub != null) {
      ecdhSecret = kx.sharedSecretWith(peerPub);
      senderPublicKey = kx.myPublicKey;
    } else {
      await _ensureKeyShared(contactPhone); // bootstrap for future messages
    }

    // Gate the profile fields by the sender's privacy audience for this
    // recipient. "My contacts" shares only with someone you already have a
    // chat with; "Nobody" withholds entirely (the field never leaves here).
    final myChat = ChatStore.instance.chatWithContact(contactPhone);
    final isContact = myChat != null;
    final avatarColor = gatedProfileField(
        AppState.profilePhotoAudience.value, me.avatarColor, isContact);
    final about =
        gatedProfileField(AppState.aboutAudience.value, me.about, isContact);
    final streak =
        myChat == null ? 0 : StreakStore.instance.streakFor(myChat.id);

    final name = inboxChannel(contactPhone);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    final payload = encode(
      message: message,
      fromPhone: me.phone,
      fromName: me.name,
      fromUsername: me.username,
      fromAvatarColor: avatarColor,
      fromAbout: about,
      fromEmoji: avatarColor.isEmpty ? '' : me.emoji,
      fromPronouns: about.isEmpty ? '' : me.pronouns,
      fromLink: about.isEmpty ? '' : me.link,
      fromVerified: me.verified,
      fromScore: ScoreStore.instance.points,
      fromStreak: streak,
      toPhone: contactPhone,
      groupId: group?.id ?? '',
      groupName: group?.contact.name ?? '',
      groupMembers: group?.members ?? const [],
      ecdhSecret: ecdhSecret,
      senderPublicKey: senderPublicKey,
    );
    await channel.sendBroadcastMessage(event: 'msg', payload: payload);
    // Also queue the sealed envelope so an offline recipient still gets it
    // the next time their app opens — the store-and-forward every messenger
    // relies on, holding only ciphertext the server can't read.
    _mailboxPut(contactPhone, payload);
    // And put it on the air, if the user turned the mesh on. Unconditionally
    // rather than only when offline: "am I online" is a question no device
    // answers reliably, and the recipient dedups by message id whichever way
    // it arrives — so trying both costs a duplicate that is already handled,
    // where guessing wrong costs the message.
    // Not awaited — a radio must not hold up the internet path — and its
    // errors are swallowed here rather than left as an unhandled async
    // failure, which in a messenger is a crash report for a message that got
    // through fine by the other route.
    unawaited(MeshService.instance
        .send(digits(contactPhone), payload, messageId: message.id)
        .catchError((_) => false));
  }

  /// Fans [message] out to every member of [group] with a real phone number.
  /// There is no group on the server — each member's device gets its own
  /// encrypted copy addressed to their inbox, so nothing central ever holds
  /// the conversation or the roster.
  Future<void> sendToGroup(Chat group, Message message) async {
    for (final phone in groupRecipients(group)) {
      await send(phone, message, group: group);
    }
  }

  /// The phone numbers a group message should be fanned out to: every member
  /// who has one, minus you, de-duplicated by digits.
  static List<String> groupRecipients(Chat group, {String? myPhone}) {
    final mine = digits(myPhone ?? Session.instance.user.value?.phone ?? '');
    final seen = <String>{};
    final out = <String>[];
    for (final member in group.members) {
      final d = digits(member.phone);
      if (d.isEmpty || d == mine || !seen.add(d)) continue;
      out.add(member.phone);
    }
    return out;
  }

  /// Pushes a group edit (new name or roster) to the other members so their
  /// copies follow without waiting for the next message. Someone added this
  /// way gets the group created on their device by the same code path an
  /// incoming group message uses.
  Future<void> sendGroupUpdate(Chat group, {List<String>? extraRecipients}) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final recipients = <String>{
      ...groupRecipients(group),
      ...?extraRecipients,
    }..removeWhere((p) => digits(p).isEmpty || digits(p) == digits(me.phone));
    for (final phone in recipients) {
      final kx = SecureKeyExchange.instance;
      final peerPub = kx.peerKey(phone);
      final blob = jsonEncode({
        'groupId': group.id,
        'groupName': group.contact.name,
        'groupAbout': group.contact.about,
        'groupMembers': group.members.map(_memberSummary).toList(),
      });
      var c = blob;
      var enc = 0;
      String? spk;
      if (kx.isReady && peerPub != null) {
        final secret = kx.sharedSecretWith(peerPub);
        if (secret != null) {
          c = E2eCrypto.encrypt(secret, blob);
          enc = 2;
          spk = kx.myPublicKey;
        }
      }
      if (enc == 0) {
        c = E2eCrypto.encrypt(E2eCrypto.keyFor(me.phone, phone), blob);
        enc = 1;
      }
      await _sendInboxEvent(phone, 'gupd', {
        'from': me.phone,
        'c': c,
        'enc': enc,
        if (spk != null) 'spk': spk,
      });
    }
  }

  /// Applies an incoming `gupd` payload: creates the group if this is the
  /// first we've heard of it, otherwise syncs its name and roster. Returns
  /// true when the local store changed.
  static bool applyGroupUpdate(
    Map<String, dynamic> payload, {
    required String myPhone,
    ChatStore? store,
  }) {
    final from = payload['from'] as String?;
    if (from == null || digits(from) == digits(myPhone)) return false;
    if (AppState.isBlocked(from)) return false;

    final target = store ?? ChatStore.instance;
    final content = _decodeContent(payload, from: from, myPhone: myPhone);
    final groupId = (content['groupId'] as String?)?.trim() ?? '';
    if (groupId.isEmpty) return false;

    final members = membersFromJson(content['groupMembers']);
    final known = target.chatById(groupId);
    if (known == null) {
      // Being added to a group you've never seen is only allowed from someone
      // you already talk to, unless you accept messages from anyone.
      final knownSender = target.chatWithContact(from) != null;
      if (!knownSender && AppState.messagesFromContactsOnly.value) return false;
      _createGroupChat(target, groupId: groupId, content: content);
      return true;
    }
    target.updateGroup(
      groupId,
      name: (content['groupName'] as String?)?.trim(),
      about: (content['groupAbout'] as String?)?.trim(),
      members: members,
    );
    return true;
  }

  /// Returns [value] when the [audience] allows sharing it with a recipient who
  /// [isContact] (or not), else an empty string meaning "withheld". This is the
  /// gate that keeps a "Nobody" profile field from ever leaving the device.
  static String gatedProfileField(
      PrivacyAudience audience, String value, bool isContact) {
    switch (audience) {
      case PrivacyAudience.everyone:
        return value;
      case PrivacyAudience.contacts:
        return isContact ? value : '';
      case PrivacyAudience.nobody:
        return '';
    }
  }

  /// Sends this device's public key to [contactPhone] once per session, so the
  /// two sides can derive an ECDH shared secret.
  Future<void> _ensureKeyShared(String contactPhone) async {
    if (!_initialized) return;
    final kx = SecureKeyExchange.instance;
    if (!kx.isReady) return;
    final key = digits(contactPhone);
    if (_sentKeyTo.contains(key)) return;
    _sentKeyTo.add(key);
    final name = inboxChannel(contactPhone);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    await channel.sendBroadcastMessage(
      event: 'key',
      payload: {'from': Session.instance.user.value?.phone, 'pub': kx.myPublicKey},
    );
  }

  /// Re-establishes the inbox subscription and re-announces presence to the
  /// people you have chats with. Backs pull-to-refresh: it gives the relay a
  /// nudge so a device that just came online re-syncs delivery and presence.
  Future<void> resync() async {
    if (!_initialized) return;
    start(); // idempotent — subscribes only if not already listening
    // Anything sent while this device was away is waiting in the mailbox.
    await fetchMailbox();
    for (final chat in ChatStore.instance.chats) {
      final phone = chat.contact.phone;
      if (phone.isNotEmpty) {
        await sendPresence(phone);
      }
    }
  }

  /// Tears down all subscriptions (on sign-out).
  Future<void> stop() async {
    final inbox = _inbox;
    _inbox = null;
    if (inbox != null) await _client.removeChannel(inbox);
    for (final channel in _sendChannels.values) {
      await _client.removeChannel(channel);
    }
    _sendChannels.clear();
    _sentKeyTo.clear();
  }
}
