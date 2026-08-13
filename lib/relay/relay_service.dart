import 'dart:async';
import '../models/bill_split.dart';
import '../models/form_spec.dart';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;

import '../crypto/sealed_sender.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../app_state.dart';
import '../crypto/e2e.dart';
import '../mesh/mesh_packet.dart';
import '../payments/lightning.dart';
import '../mesh/mesh_service.dart';
import '../crypto/double_ratchet.dart';
import '../crypto/encryption_label.dart';
import '../crypto/key_exchange.dart';
import '../crypto/notification_preview.dart';
import '../crypto/sender_key.dart';
import '../models/chat.dart';
import '../models/community.dart';
import '../models/message.dart';
import '../models/status_update.dart';
import '../models/user.dart';
import '../state/call_service.dart';
import '../state/chat_store.dart';
import '../state/community_store.dart';
import '../state/preview_key_store.dart';
import '../state/push_service.dart';
import '../state/feed_store.dart';
import '../state/status_store.dart';
import '../state/file_transfer.dart';
import '../state/live_location_store.dart';
import '../state/score_store.dart';
import '../state/session.dart';
import '../state/channel_typing_store.dart';
import '../state/streak_store.dart';
import '../state/voice_presence_store.dart';
import '../state/room_media.dart';
import '../state/group_presence_store.dart';
import '../state/server_directory_store.dart';
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

  /// The GROUP the last typing ping was for, or '' for a 1:1. A group ping
  /// carries the group id so it lights only that group — without it, a member
  /// typing in a group also lit the 1:1 chat/tile with that same person, which
  /// is the "typing shows in the wrong chat" bug.
  String typingGroupId = '';
  final ValueNotifier<int> typingPing = ValueNotifier<int>(0);
  Timer? _typingExpire;

  /// Records a live typing ping — and expires it. A ping is a moment, not a
  /// state: the chat list drew 'typing…' straight off the last ping and
  /// nothing ever unset it, so one keystroke read as typing for the rest of
  /// the session (the chat screen had its own 3-second timer; the list had
  /// none). A real typer re-pings every 2 seconds, so 4 keeps them lit.
  @visibleForTesting
  void noteTypingPing(String fromDigits, {String groupId = ''}) {
    typingFromDigits = fromDigits;
    typingGroupId = groupId;
    typingPing.value++;
    _typingExpire?.cancel();
    _typingExpire = Timer(const Duration(seconds: 4), () {
      typingFromDigits = null;
      typingGroupId = '';
      typingPing.value++;
    });
  }

  /// Same pattern for "online" presence pings. [presenceWhere] is what the
  /// last ping said about where the sender is: 'chat' means looking at the
  /// conversation with you (the only thing the original ping could mean, so
  /// it is also the default a ping from an older build decodes to), 'app'
  /// means the app is open somewhere else — the answer-pong below.
  String? presenceFromDigits;
  String presenceWhere = 'chat';
  final ValueNotifier<int> presencePing = ValueNotifier<int>(0);

  /// The 1:1 conversation on screen right now (digits, '' when none), kept
  /// by ChatScreen. The presence answer needs it: someone already in the
  /// peer's chat is pinging 'chat' every few seconds, and an 'app' pong on
  /// top would demote their own header from "in this chat" to "online".
  String openChatDigits = '';

  /// Rate limit for presence answers, per peer — an answer to every ping
  /// would double the presence traffic for nothing.
  final Map<String, DateTime> _lastPresenceAnswer = {};

  /// Tests stand in for "is the app foregrounded" — the binding's lifecycle
  /// state is null in a test and never resumed.
  @visibleForTesting
  static bool Function()? debugForegroundOverride;

  static bool _foregrounded() =>
      debugForegroundOverride?.call() ??
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// Answers a peer who just opened the conversation with this account
  /// ('chat' ping) with an 'app' pong, so their header can say "online"
  /// rather than nothing — but only when that is true and safe to say:
  /// the app is actually foregrounded, this account shares its last-seen,
  /// the peer is an accepted contact (no request, no block), and this
  /// device is not already in their chat saying something stronger.
  @visibleForTesting
  void maybeAnswerPresence(String fromDigits) {
    if (!_foregrounded()) return;
    if (!AppState.shareLastSeen.value) return;
    if (openChatDigits == fromDigits) return;
    final chat = ChatStore.instance.allChats
        .where(
            (c) => !c.contact.isGroup && digits(c.contact.phone) == fromDigits)
        .firstOrNull;
    if (chat == null || chat.isRequest) return;
    if (AppState.isBlocked(chat.contact.phone)) return;
    final last = _lastPresenceAnswer[fromDigits];
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(seconds: 10)) {
      return;
    }
    _lastPresenceAnswer[fromDigits] = now;
    sendPresence(chat.contact.phone, where: 'app');
  }

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
  ///  * enc 3 — the Signal Double Ratchet ([DoubleRatchet]): a fresh AES key
  ///    per message, deleted on use, with the ratchet header riding as `rh`.
  ///    Used whenever a session exists or this side may start one.
  ///  * enc 2 — AES-256-GCM keyed by an ECDH shared secret ([ecdhSecret]); the
  ///    sender's public key rides along as `spk` so the recipient can derive
  ///    the same secret. The floor once keys are exchanged, and what the
  ///    responder side sends until the initiator's first ratchet message.
  ///  * enc 1 — AES-256-GCM keyed by the phone-number-derived secret (the
  ///    fallback until the ECDH handshake completes).
  ///  * enc 0 — plaintext JSON (no recipient key available yet).
  static Map<String, dynamic> encode({
    required Message message,
    required String fromPhone,
    required String fromName,
    String fromUsername = '',
    String fromAvatarColor = '',
    String fromAvatarColor2 = '',
    String fromBannerColor = '',
    String fromLocation = '',
    bool fromBusiness = false,
    String fromBusinessCategory = '',
    String fromBusinessHours = '',
    bool fromSubscribable = false,
    int fromSubscriptionTier = 0,
    String fromSubscriptionPitch = '',
    String fromSubscriptionTiers = '',
    String fromLightningAddress = '',
    String fromAbout = '',
    String fromEmoji = '',
    String fromAvatarSeed = '',
    String fromPronouns = '',
    String fromLink = '',
    bool fromVerified = false,
    int fromScore = 0,
    int fromStreak = 0,
    String toPhone = '',
    String groupId = '',
    String groupName = '',
    List<AppUser> groupMembers = const [],
    DoubleRatchet? ratchet,
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
      'fromAvatarColor2': fromAvatarColor2,
      'fromBannerColor': fromBannerColor,
      'fromLocation': fromLocation,
      'fromBusiness': fromBusiness,
      'fromBusinessCategory': fromBusinessCategory,
      'fromBusinessHours': fromBusinessHours,
      'fromSubscribable': fromSubscribable,
      'fromSubscriptionTier': fromSubscriptionTier,
      'fromSubscriptionPitch': fromSubscriptionPitch,
      'fromSubscriptionTiers': fromSubscriptionTiers,
      'fromLightningAddress': fromLightningAddress,
      'fromAbout': fromAbout,
      'fromEmoji': fromEmoji,
      'fromAvatarSeed': fromAvatarSeed,
      'fromPronouns': fromPronouns,
      'fromLink': fromLink,
      'fromVerified': fromVerified,
      'fromScore': fromScore,
      'fromStreak': fromStreak,
      'isImage': message.isImage,
      'imageSeed': message.imageSeed,
      'imageUrl': message.imageUrl,
      // Without this on the wire, "view once" was a promise the sending
      // device made to itself: the far end decoded an ordinary message.
      'viewOnce': message.viewOnce,
      'isVoice': message.isVoice,
      'voiceSeconds': message.voiceSeconds,
      if (message.audioUrl != null) 'audioUrl': message.audioUrl,
      // A long note lives in the bucket; the path AND its per-note key ride
      // inside this sealed blob, so the bucket only ever holds ciphertext.
      if (message.audioPath != null) 'audioPath': message.audioPath,
      if (message.audioKey != null) 'audioKey': message.audioKey,
      'isVoicemail': message.isVoicemail,
      'forwarded': message.forwarded,
      'protected': message.protected,
      // How the far end learns a brand-new conversation is marketplace
      // traffic and files it accordingly — see the newborn-chat branch in
      // _onInboxMessage.
      if (message.marketplace) 'marketplace': true,
      if (message.isPoke) 'isPoke': true,
      'threadRootId': message.threadRootId,
      'isForm': message.isForm,
      'formTitle': message.formTitle,
      'formFields': [for (final f in message.formFields) f.toJson()],
      'replyTo': message.replyTo?.toJson(),
      'isLocation': message.isLocation,
      'locationLat': message.locationLat,
      'locationLng': message.locationLng,
      'locationLabel': message.locationLabel,
      if (message.isLiveLocation) 'isLiveLocation': true,
      if (message.liveUntil != null)
        'liveUntil': message.liveUntil!.toIso8601String(),
      'isContact': message.isContact,
      'contactName': message.contactName,
      'contactPhone': message.contactPhone,
      if (message.isSticker) 'isSticker': true,
      'isPayment': message.isPayment,
      'paymentAmountCents': message.paymentAmountCents,
      'paymentCurrency': message.paymentCurrency,
      'isPaymentRequest': message.isPaymentRequest,
      'paymentStatus': message.paymentStatus,
      'isPoll': message.isPoll,
      'pollQuestion': message.pollQuestion,
      'pollOptions': message.pollOptions,
      'pollVotes': message.pollVotes,
      if (message.billSplit != null) 'billSplit': message.billSplit!.toJson(),
      if (message.serverInvite.isNotEmpty) 'serverInvite': message.serverInvite,
      'expiresAt': message.expiresAt?.toIso8601String(),
    });

    final sealed = sealContent(fromPhone, toPhone, content, ratchet: ratchet);
    return {
      'id': message.id,
      'from': fromPhone,
      ...sealed,
      'ts': message.time.toIso8601String(),
      // The sealed-sender advertisement: this build can OPEN envelopes that
      // hide who they are from. Advertised on legacy traffic first, relied
      // on only after the peer has said it back — a sealed envelope sent to
      // a build that cannot open it is a lost message, worse than metadata.
      'sv': 1,
    };
  }

  /// Seals [plaintext] for [toPhone] into the `{c, enc, spk?, rh?}` fragment
  /// every pairwise payload carries — message content, group updates and call
  /// signaling all go through this one ladder, so the encryption a surface
  /// gets is never an accident of which method built its payload.
  ///
  /// The ladder, strongest first: the Double Ratchet (enc 3) whenever the
  /// peer's identity key is in hand and this side may drive a session, then
  /// static ECDH (enc 2), then the phone-derived key (enc 1), then plaintext
  /// (enc 0) only when there is no recipient to key to at all.
  static Map<String, dynamic> sealContent(
      String fromPhone, String toPhone, String plaintext,
      {DoubleRatchet? ratchet}) {
    final kx = SecureKeyExchange.instance;
    final peerPub = kx.peerKey(toPhone);
    final haveKey = kx.isReady && peerPub != null;
    // The ratchet declines internally (null) when this side may not start a
    // session; the static rungs below are the floor it never drops beneath.
    final r = haveKey ? (ratchet ?? DoubleRatchet.instance) : null;
    final sealed = r?.encrypt(fromPhone, toPhone, plaintext);
    if (sealed != null) {
      return {
        'c': sealed.blob,
        'enc': 3,
        // The identity key still rides along: it bootstraps the responder's
        // half and keeps rememberPeer current.
        if (kx.myPublicKey != null) 'spk': kx.myPublicKey,
        'rh': sealed.header,
      };
    }
    if (haveKey) {
      final secret = kx.sharedSecretWith(peerPub);
      if (secret != null) {
        return {
          'c': E2eCrypto.encrypt(secret, plaintext),
          'enc': 2,
          if (kx.myPublicKey != null) 'spk': kx.myPublicKey,
        };
      }
    }
    if (toPhone.isNotEmpty) {
      return {
        'c': E2eCrypto.encrypt(E2eCrypto.keyFor(fromPhone, toPhone), plaintext),
        'enc': 1,
        // The floor rung is exactly what a freshly re-minted identity sends
        // from — it has nobody's keys yet — and it was the ONE rung that
        // did not announce the sender's key. Without this, the first
        // message after a re-identity taught the peer nothing, their stale
        // session survived it, and their reply sealed to a ghost.
        if (kx.isReady && kx.myPublicKey != null) 'spk': kx.myPublicKey,
      };
    }
    return {'c': plaintext, 'enc': 0};
  }

  /// Reverses [sealContent]: recovers the plaintext from a `{c, enc, spk?,
  /// rh?}` fragment sent by [from], or null when the key is missing (wrong
  /// session, replay, or a header wound past the skip bound). Every pairwise
  /// decode — message, group update, call signal — funnels through here.
  static String? openContent(
      String from, String myPhone, Map<String, dynamic> f,
      {DoubleRatchet? ratchet}) {
    final blob = f['c'] as String?;
    if (blob == null) return null;
    final encRaw = f['enc'];
    if (encRaw == 3 || encRaw == '3') {
      // Remember the identity key FIRST: a changed key means the old session
      // is a session with the wrong person, and the responder bootstrap
      // needs the current key in place.
      final r = ratchet ?? DoubleRatchet.instance;
      final spk = f['spk'] as String?;
      if (spk != null && SecureKeyExchange.instance.rememberPeer(from, spk)) {
        r.resetPeer(from);
      }
      final rh = f['rh'];
      if (rh is Map) {
        return r.decrypt(myPhone, from, Map<String, dynamic>.from(rh), blob);
      }
      return null;
    }
    if (encRaw == 2 || encRaw == '2') {
      final spk = f['spk'] as String?;
      final secret =
          spk == null ? null : SecureKeyExchange.instance.sharedSecretWith(spk);
      if (secret == null) return null;
      if (SecureKeyExchange.instance.rememberPeer(from, spk!)) {
        (ratchet ?? DoubleRatchet.instance).resetPeer(from);
      }
      return E2eCrypto.decrypt(secret, blob);
    }
    if (encRaw == 1 || encRaw == true) {
      // Same rule as the sealed rungs: a CHANGED key means every session
      // with the old identity is a session with a ghost.
      final spk = f['spk'] as String?;
      if (spk != null && SecureKeyExchange.instance.rememberPeer(from, spk)) {
        (ratchet ?? DoubleRatchet.instance).resetPeer(from);
      }
      return E2eCrypto.decrypt(E2eCrypto.keyFor(from, myPhone), blob);
    }
    return blob; // enc 0: never sealed.
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

    // The sealed-sender handshake's other half: the peer's build says it
    // can open sealed envelopes, and from here on ours sends them some.
    if (payload['sv'] == 1) {
      SecureKeyExchange.instance.rememberSealedCapable(from);
    }

    final target = store ?? ChatStore.instance;
    final id = payload['id'] as String? ?? 'relay_${payload['ts']}';

    // Something the user deleted here stays deleted, even if the mailbox
    // row outlived its delivery and replays the envelope.
    if (target.isMessageDeleted(id)) return false;

    // A message already held is dropped HERE, before decryption — not just
    // at the add-to-chat step below. The mailbox redelivers envelopes the
    // broadcast already delivered, and an enc-3 replay reaching the ratchet
    // cannot decrypt (its key was deleted on use) but used to advance the
    // chain on its way to failing — one replay and every genuine message
    // after it rendered as "Couldn't unlock". Decrypt is transactional now
    // too; this keeps replays from even knocking. The sender must match as
    // well as the id: ids are only unique per sender, so someone else's
    // message under the same id is not a replay of this one.
    final dupChat = target.chatWithMessage(id, senderId: from);
    if (dupChat != null) {
      final dup = dupChat.messages.firstWhere((m) => m.id == id);
      final sameSender = dupChat.contact.isGroup
          ? digits(dup.senderPhone) == digits(from)
          : digits(dupChat.contact.phone) == digits(from);
      if (sameSender) return false;
    }

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
    final sharedColor2 = (content['fromAvatarColor2'] as String?)?.trim() ?? '';
    final sharedBanner = (content['fromBannerColor'] as String?)?.trim() ?? '';
    final sharedLocation = (content['fromLocation'] as String?)?.trim() ?? '';
    final sharedAbout = (content['fromAbout'] as String?)?.trim() ?? '';
    final sharedEmoji = (content['fromEmoji'] as String?)?.trim() ?? '';
    final sharedAvatarSeed =
        (content['fromAvatarSeed'] as String?)?.trim() ?? '';
    final sharedPronouns = (content['fromPronouns'] as String?)?.trim() ?? '';
    final sharedLink = (content['fromLink'] as String?)?.trim() ?? '';
    final sharedVerified = content['fromVerified'] == true;
    final sharedScore = (content['fromScore'] as num?)?.toInt() ?? 0;
    final sharedBusiness = content['fromBusiness'] == true;
    final sharedBusinessCategory =
        (content['fromBusinessCategory'] as String?)?.trim() ?? '';
    final sharedBusinessHours =
        (content['fromBusinessHours'] as String?)?.trim() ?? '';
    final sharedSubscribable = content['fromSubscribable'] == true;
    final sharedSubscriptionTier =
        (content['fromSubscriptionTier'] as num?)?.toInt() ?? 0;
    final sharedSubscriptionPitch =
        (content['fromSubscriptionPitch'] as String?)?.trim() ?? '';
    // JSON, so never trimmed of meaning — take it as-is.
    final sharedSubscriptionTiers =
        (content['fromSubscriptionTiers'] as String?) ?? '';
    // Re-parsed rather than trusted: it arrived from another device and is
    // about to become a URL. Anything that is not an address reads as none.
    final sharedLightning = LightningAddress.isValid(
            (content['fromLightningAddress'] as String?) ?? '')
        ? ((content['fromLightningAddress'] as String?) ?? '')
            .trim()
            .toLowerCase()
        : '';

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
        avatarSeed: sharedAvatarSeed,
        pronouns: sharedPronouns,
        link: sharedLink,
        avatarColor2: sharedColor2,
        bannerColor: sharedBanner,
        location: sharedLocation,
        isBusiness: sharedBusiness,
        businessCategory: sharedBusinessCategory,
        businessHours: sharedBusinessHours,
        subscribable: sharedSubscribable,
        subscriptionTier: sharedSubscriptionTier,
        subscriptionPitch: sharedSubscriptionPitch,
        subscriptionTiersJson: sharedSubscriptionTiers,
        lightningAddress: sharedLightning,
      );
      // Born a request: a stranger's first message lands in Message requests,
      // not the chat list, and earns no receipts until it is accepted.
      // Sharing a group with them counts as knowing them.
      //
      // Born marketplace when the first message says so: a buyer's opener
      // files the new conversation in the marketplace section rather than
      // among friends. Only at birth — an existing chat is never reclassified
      // by a flagged message, because that would move a friend's chat the
      // moment they bought something.
      chat = Chat(
          id: 'chat_$from',
          contact: contact,
          messages: const [],
          marketplace: content['marketplace'] == true,
          isRequest: !target.allChats.any((c) =>
              c.contact.isGroup &&
              c.members.any((m) => digits(m.phone) == digits(from))));
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
        avatarSeed: sharedAvatarSeed.isNotEmpty ? sharedAvatarSeed : null,
        pronouns: sharedPronouns.isNotEmpty ? sharedPronouns : null,
        link: sharedLink.isNotEmpty ? sharedLink : null,
        avatarColor2: sharedColor2.isNotEmpty ? sharedColor2 : null,
        bannerColor: sharedBanner.isNotEmpty ? sharedBanner : null,
        location: sharedLocation.isNotEmpty ? sharedLocation : null,
        // Applied as sent, not non-empty-wins: a business that stops being
        // one has to be able to say so, same as the verified flag.
        business: sharedBusiness,
        businessCategory: sharedBusinessCategory,
        businessHours: sharedBusinessHours,
        subscribable: sharedSubscribable,
        subscriptionTier: sharedSubscriptionTier,
        subscriptionPitch: sharedSubscriptionPitch,
        subscriptionTiersJson: sharedSubscriptionTiers,
        lightningAddress: sharedLightning,
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
        // Only groups need the "who said this" label above the bubble — and
        // the digits under the label, so their message can be sparked. A 1:1
        // carries neither: the chat's contact IS the sender.
        senderName: groupId.isEmpty ? '' : senderName,
        senderPhone: groupId.isEmpty ? '' : digits(from),
        isImage: content['isImage'] as bool? ?? false,
        imageSeed: content['imageSeed'] as int? ?? 0,
        imageUrl: content['imageUrl'] as String?,
        viewOnce: content['viewOnce'] as bool? ?? false,
        isVoice: content['isVoice'] as bool? ?? false,
        voiceSeconds: content['voiceSeconds'] as int? ?? 0,
        audioUrl: content['audioUrl'] as String?,
        audioPath: content['audioPath'] as String?,
        audioKey: content['audioKey'] as String?,
        isVoicemail: content['isVoicemail'] as bool? ?? false,
        forwarded: content['forwarded'] as bool? ?? false,
        protected: content['protected'] as bool? ?? false,
        marketplace: content['marketplace'] as bool? ?? false,
        isPoke: content['isPoke'] as bool? ?? false,
        threadRootId: content['threadRootId'] as String?,
        isForm: content['isForm'] as bool? ?? false,
        formTitle: content['formTitle'] as String? ?? '',
        formFields: [
          for (final f in (content['formFields'] as List?) ?? const [])
            FormFieldSpec.fromJson(Map<String, dynamic>.from(f as Map))
        ],
        replyTo: replyJson is Map
            ? ReplyInfo.fromJson(Map<String, dynamic>.from(replyJson))
            : null,
        isLocation: content['isLocation'] as bool? ?? false,
        locationLat: (content['locationLat'] as num?)?.toDouble(),
        locationLng: (content['locationLng'] as num?)?.toDouble(),
        locationLabel: content['locationLabel'] as String?,
        isLiveLocation: content['isLiveLocation'] as bool? ?? false,
        liveUntil: content['liveUntil'] == null
            ? null
            : DateTime.tryParse(content['liveUntil'] as String),
        isContact: content['isContact'] as bool? ?? false,
        contactName: content['contactName'] as String?,
        contactPhone: content['contactPhone'] as String?,
        isSticker: content['isSticker'] as bool? ?? false,
        isPayment: content['isPayment'] as bool? ?? false,
        paymentAmountCents: content['paymentAmountCents'] as int? ?? 0,
        paymentCurrency: content['paymentCurrency'] as String? ?? 'cad',
        isPaymentRequest: content['isPaymentRequest'] as bool? ?? false,
        paymentStatus: content['paymentStatus'] as String? ?? '',
        isPoll: content['isPoll'] as bool? ?? false,
        pollQuestion: content['pollQuestion'] as String? ?? '',
        pollOptions:
            (content['pollOptions'] as List?)?.cast<String>() ?? const [],
        pollVotes: (content['pollVotes'] as List?)
                ?.map((e) => (e as num).toInt())
                .toList() ??
            const [],
        billSplit: content['billSplit'] == null
            ? null
            : BillSplit.fromJson(
                Map<String, dynamic>.from(content['billSplit'] as Map)),
        serverInvite: content['serverInvite'] as String? ?? '',
        expiresAt: content['expiresAt'] == null
            ? null
            : DateTime.tryParse(content['expiresAt'] as String),
        // Which key this actually arrived under. Read off the payload the
        // sender sealed, not guessed from the chat's current rung — the
        // ladder climbs, and a message does not get safer after the fact.
        enc: EncryptionLabel.codeOf(EncryptionLabel.fromWire(payload['enc'])),
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
    // The message could not be unlocked: start the repair. Rate-limited and
    // SAFE on false alarms — a peer whose cached key already matches ours
    // ignores the re-introduction entirely, so a replayed envelope cannot
    // hurt a healthy pairing.
    if (content['sealedToOldKey'] == true) {
      RelayService.instance.healPeer(from);
    }
    // An admin who added you to their server sends the invite flagged `added`;
    // that joins you straight away, the WhatsApp-group way. Only from a real,
    // ACCEPTED contact (a known, non-request 1:1 — never a stranger, a request,
    // or a group message), so nobody can force you into a server just by
    // messaging you. A plain shared invite (no flag) is untouched — still a
    // tap-to-join card.
    if (groupId.isEmpty &&
        knownChat != null &&
        !knownChat.isRequest &&
        RelayConfig.isEnabled) {
      RelayService.instance.maybeAutoJoinServer(
          content['serverInvite'] as String?,
          myPhone: myPhone);
    }
    return true;
  }

  /// Joins the server in an admin-add invite ([inviteJson], flagged `added`) on
  /// receipt, and announces the join so the roster and sender keys converge.
  /// No-ops for a plain invite (no flag), a server already joined, a PAID
  /// server (the paywall stands — the added person sees the Subscribe card),
  /// or a numberless account (no relay identity to join with).
  @visibleForTesting
  void maybeAutoJoinServer(String? inviteJson, {required String myPhone}) {
    if (inviteJson == null || inviteJson.isEmpty) return;
    try {
      final decoded = jsonDecode(inviteJson);
      if (decoded is! Map) return;
      final snapshot = Map<String, dynamic>.from(decoded);
      if (snapshot['added'] != true) return;
      if (snapshot['paid'] == true) return;
      final id = snapshot['id'] as String?;
      if (id == null || CommunityStore.instance.byId(id) != null) return;
      final myDigits = digits(myPhone);
      if (myDigits.isEmpty) return;
      final me = Session.instance.user.value;
      final myName =
          (me?.name.trim().isNotEmpty ?? false) ? me!.name : 'Member';
      final community = CommunityStore.instance
          .joinFromInvite(snapshot, myDigits: myDigits, myName: myName);
      if (community == null) return;
      sendServerJoin(
        community.id,
        Member(id: CommunityStore.wireId(myDigits), name: myName, online: true),
      );
      // Auto-join is silent by design — there's no screen to pull-to-refresh
      // from, so the durable backfill has to happen here or a message-added
      // member never sees anything posted before they joined.
      unawaited(fetchCommunityPosts());
      // Same reasoning, for the authoritative structure tables
      // (docs/community_structure.sql): this is the only chance a silently
      // auto-joined member gets to register itself before the next relay
      // start does it opportunistically.
      unawaited(joinCommunityAuthoritative(community.id,
          secret: community.secret, myName: myName));
      unawaited(fetchCommunityStructure(community.id));
    } catch (_) {}
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
        // The reactor's own phone rides the wire as `from` — record it so a
        // "reacted by" list can name them (in a group, this is how a member's
        // device learns WHO reacted).
        target.setReactionState(
            chat.id, id, emoji, payload['add'] as bool? ?? true,
            reactor: digits(from));
        return true;
      case 'form':
        final answers = payload['answers'];
        if (answers is! List) return false;
        target.applyFormResponse(
          chat.id,
          id,
          FormResponse(
            from: (payload['name'] as String?)?.trim().isNotEmpty == true
                ? payload['name'] as String
                : (payload['from'] as String? ?? ''),
            answers: [for (final a in answers) '$a'],
            at: DateTime.now(),
          ),
        );
        return true;
      case 'poll':
        target.applyRemotePollVote(
          chat.id,
          id,
          (payload['add'] as num?)?.toInt() ?? -1,
          (payload['remove'] as num?)?.toInt() ?? -1,
          voter: digits(from),
        );
        return true;
      case 'billpaid':
        final payer = payload['payer'] as String?;
        if (payer == null) return false;
        target.markBillSharePaid(chat.id, id, payer);
        return true;
      case 'vopen':
        target.markViewOnceOpened(chat.id, id);
        return true;
      case 'locstop':
        target.endIncomingLiveLocation(chat.id, id);
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
    // In a group the ticks say "someone"; this records WHO. Per-reader,
    // up to the message the receipt names — the same implied prefix.
    if (status == MessageStatus.read && chat.contact.isGroup && id != null) {
      target.noteSeenUpTo(chat.id, id, digits(from));
    }
    return true;
  }

  /// Recovers the decrypted content map from a relay payload. New payloads seal
  /// everything into `c`; legacy payloads carried the fields at the top level,
  /// so we read those directly when `c` is absent.
  static Map<String, dynamic> _decodeContent(
    Map<String, dynamic> payload, {
    required String from,
    required String myPhone,
    DoubleRatchet? ratchet,
  }) {
    final blob = payload['c'] as String?;
    if (blob == null) {
      // Legacy format: fields ride in the clear at the top level.
      return {
        'text': (payload['text'] as String?) ?? '',
        'fromName': payload['fromName'],
        'fromUsername': payload['fromUsername'],
        'marketplace': payload['marketplace'],
        'isPoke': payload['isPoke'],
        'isImage': payload['isImage'],
        'imageSeed': payload['imageSeed'],
        'imageUrl': payload['imageUrl'],
        'isVoice': payload['isVoice'],
        'voiceSeconds': payload['voiceSeconds'],
        'audioUrl': payload['audioUrl'],
      };
    }

    // The one pairwise un-ladder, shared with group updates and signaling.
    final json = openContent(from, myPhone, payload, ratchet: ratchet);
    if (json == null) {
      // A failed decrypt used to fall back to the RAW CIPHERTEXT, which the
      // chat then rendered — screens full of base64, which is exactly how
      // the bug was reported. Say what happened in words instead, and mark
      // the content so applyIncoming can start the key repair: the usual
      // cause is the far side sealing to an identity key this device no
      // longer holds (an account switch minted a fresh one, and their build
      // kept encrypting to the ghost).
      return {
        'text': '🔒 Couldn\'t unlock this message — it was sealed to a key '
            'this device no longer has. New messages will come through '
            'shortly; ask them to resend this one.',
        'sealedToOldKey': true,
      };
    }

    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Plaintext that isn't JSON (the oldest wire format): it IS the text.
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
  Future<void> _mailboxPut(String contactPhone, Map<String, dynamic> payload,
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

  /// Opens a sealed-sender envelope and routes what was inside through the
  /// same handling the legacy event would have gotten — live broadcast and
  /// mailbox replay both land here. An envelope that will not open is
  /// dropped silently: it is anonymous by design, so there is nobody to
  /// tell and nothing further to do.
  @visibleForTesting
  void applySealedEnvelope(Map<String, dynamic> envelope,
      {required String myPhone, ChatStore? store}) {
    final inner = SealedSender.unseal(envelope);
    if (inner == null) return;
    final event = inner['e'];
    final payload = inner['p'];
    if (event is! String || payload is! Map) return;
    applyInboxEvent(event, Map<String, dynamic>.from(payload),
        myPhone: myPhone, store: store);
  }

  /// One router for every 1:1 inbox event, however it arrived — named on
  /// the channel (legacy) or inside a sealed envelope. The cases mirror
  /// the live subscription and the mailbox switch exactly; a new event
  /// type added to either must be added here, or its sealed form is
  /// silently dropped (the test pins the roster).
  @visibleForTesting
  void applyInboxEvent(String event, Map<String, dynamic> payload,
      {required String myPhone, ChatStore? store}) {
    final me = myPhone;
    switch (event) {
      case 'msg':
        // The full live-message handling (key caching, delivery receipt)
        // when running for real; the bare apply when a test injects its
        // own store — same split the mailbox drain has always had.
        if (store != null) {
          applyIncoming(payload, myPhone: me, store: store);
        } else {
          _onInboxMessage(payload, myPhone: me);
        }
      case 'receipt':
        applyReceipt(payload, myPhone: me);
      case 'edit' ||
            'delete' ||
            'reaction' ||
            'poll' ||
            'billpaid' ||
            'payst' ||
            'form' ||
            'vopen' ||
            'locstop':
        applyMessageEvent(event, payload, myPhone: me);
      case 'gupd':
        applyGroupUpdate(payload, myPhone: me);
        final from = payload['from'] as String?;
        final spk = payload['spk'] as String?;
        if (from != null && spk != null) {
          SecureKeyExchange.instance.rememberPeer(from, spk);
        }
      case 'callmiss':
        _applyMissedCall(payload, myPhone: me);
      case 'call':
        _applyCallEvent(payload, me);
      case 'skdm':
        applySkdm(payload, myPhone: me);
      case 'skreq':
        applySkreq(payload, myPhone: me);
      case 'fbreq':
        applyFbreq(payload, myPhone: me);
      case 'key':
        applyKeyEvent(payload, myPhone: me);
      // The pings, mirrored from the live handlers — sealed pings arrive
      // as 'sealed' too, or typing and presence would re-draw the graph.
      case 'typing':
        final from = payload['from'] as String?;
        if (from == null || digits(from) == digits(me)) return;
        noteTypingPing(digits(from), groupId: payload['g'] as String? ?? '');
      case 'presence':
        final from = payload['from'] as String?;
        if (from == null || digits(from) == digits(me)) return;
        presenceFromDigits = digits(from);
        presenceWhere = payload['where'] as String? ?? 'chat';
        presencePing.value++;
        if (presenceWhere == 'chat') maybeAnswerPresence(digits(from));
      case 'gpres':
        // A member is currently viewing a group chat. Live-only; recorded per
        // group id, swept when it goes quiet (GroupPresenceStore).
        final from = payload['from'] as String?;
        final g = payload['g'] as String?;
        if (from == null || g == null || digits(from) == digits(me)) return;
        GroupPresenceStore.instance.applyRemote(g, digits(from));
      case 'shot':
        final from = payload['from'] as String?;
        if (from == null || digits(from) == digits(me)) return;
        screenshotFromDigits = digits(from);
        screenshotPing.value++;
      case 'cap':
        final from = payload['from'] as String?;
        if (from == null || digits(from) == digits(me)) return;
        recordingFromDigits = digits(from);
        recordingPing.value++;
      case 'gshot':
        final from = payload['from'] as String?;
        if (from == null || digits(from) == digits(me)) return;
        ghostShotFromDigits = digits(from);
        ghostShotPing.value++;
      case 'status':
        applyStatus(payload, myPhone: me);
      case 'prof':
        applyProfileUpdate(payload, myPhone: me, store: store);
    }
  }

  /// Applies a proactive profile refresh from [payload]'s sender to their
  /// existing 1:1 contact card — the same fields a message piggybacks, but
  /// pushed the moment the profile changed instead of waiting for the next
  /// message. Only touches a chat that already exists (a profile ping never
  /// starts a conversation), and mirrors the message receive path's rules:
  /// non-empty-wins for the free-text fields, applied-as-sent for the flags so
  /// a business or creator that switches OFF clears itself. Name is left alone,
  /// exactly as the message path leaves it — a contact never renames itself on
  /// your device.
  @visibleForTesting
  void applyProfileUpdate(Map<String, dynamic> payload,
      {required String myPhone, ChatStore? store}) {
    final from = payload['from'] as String?;
    if (from == null || digits(from) == digits(myPhone)) return;
    final target = store ?? ChatStore.instance;
    if (target.chatById('chat_$from') == null) return;
    String s(String k) => (payload[k] as String?)?.trim() ?? '';
    target.updateContactProfile(
      from,
      avatarColor:
          s('fromAvatarColor').isNotEmpty ? s('fromAvatarColor') : null,
      about: s('fromAbout').isNotEmpty ? s('fromAbout') : null,
      verified: payload['fromVerified'] == true,
      score: (payload['fromScore'] as num?)?.toInt() ?? 0,
      emoji: s('fromEmoji').isNotEmpty ? s('fromEmoji') : null,
      avatarSeed: s('fromAvatarSeed').isNotEmpty ? s('fromAvatarSeed') : null,
      pronouns: s('fromPronouns').isNotEmpty ? s('fromPronouns') : null,
      link: s('fromLink').isNotEmpty ? s('fromLink') : null,
      avatarColor2:
          s('fromAvatarColor2').isNotEmpty ? s('fromAvatarColor2') : null,
      bannerColor:
          s('fromBannerColor').isNotEmpty ? s('fromBannerColor') : null,
      location: s('fromLocation').isNotEmpty ? s('fromLocation') : null,
      business: payload['fromBusiness'] == true,
      businessCategory: s('fromBusinessCategory'),
      businessHours: s('fromBusinessHours'),
      subscribable: payload['fromSubscribable'] == true,
      subscriptionTier: (payload['fromSubscriptionTier'] as num?)?.toInt() ?? 0,
      subscriptionPitch: s('fromSubscriptionPitch'),
      subscriptionTiersJson:
          (payload['fromSubscriptionTiers'] as String?) ?? '',
      lightningAddress: LightningAddress.isValid(s('fromLightningAddress'))
          ? s('fromLightningAddress').toLowerCase()
          : '',
    );
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
            case 'sealed':
              applySealedEnvelope(payload, myPhone: me);
            case 'msg':
              _onInboxMessage(payload, myPhone: me);
            case 'receipt':
              applyReceipt(payload, myPhone: me);
            case 'edit' ||
                  'delete' ||
                  'reaction' ||
                  'poll' ||
                  'billpaid' ||
                  'payst' ||
                  'form' ||
                  'vopen':
              applyMessageEvent(event, payload, myPhone: me);
            case 'gupd':
              applyGroupUpdate(payload, myPhone: me);
            case 'callmiss':
              _applyMissedCall(payload, myPhone: me);
            case 'call':
              _applyCallEvent(payload, me);
            case 'skdm':
              applySkdm(payload, myPhone: me);
            case 'skreq':
              applySkreq(payload, myPhone: me);
            case 'fbreq':
              applyFbreq(payload, myPhone: me);
            case 'key':
              applyKeyEvent(payload, myPhone: me);
            case 'chmsg' ||
                  'chack' ||
                  'chjoin' ||
                  'chleave' ||
                  'chupd' ||
                  'fpost' ||
                  'fdel' ||
                  'flike' ||
                  'fview' ||
                  'fspark' ||
                  'fvote' ||
                  'chdel' ||
                  'chedt' ||
                  'chrxn' ||
                  'chpin' ||
                  'frpost' ||
                  'frcom' ||
                  'frvote' ||
                  'frdel' ||
                  'frcdel' ||
                  'fredt' ||
                  'frcedt' ||
                  'frpin' ||
                  'frlock':
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
          .delete(Uri.parse('$base?inbox=eq.$inbox&created_at=lt.$cutoff'),
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
      // Cache the sender's public key (rides on every sealed rung) and
      // make sure they have ours, so replies upgrade to the ECDH path. The
      // return value matters: a CHANGED key buries the stale session and
      // re-offers ours, or the very next reply seals to the ghost.
      final spk = map['spk'] as String?;
      if (spk != null && SecureKeyExchange.instance.rememberPeer(from, spk)) {
        DoubleRatchet.instance.resetPeer(from);
        _sentKeyTo.remove(digits(from));
        // Their identity key moved, so the secret the old preview key came
        // from is gone. Drop it before deriving the new one, or the
        // extension keeps a stale entry in a SHARED keychain and fails every
        // future open with total confidence.
        PreviewKeyStore.instance.forget(digits(from));
      }
      if (spk != null) {
        // The Notification Service Extension cannot derive this itself — it
        // has no ratchet and no identity key — so the app leaves it where a
        // shared keychain group makes it readable. Done HERE because this is
        // the one place a peer's public key is learned, live or from the
        // mailbox; anywhere else would be a second path to forget.
        PreviewKeyStore.instance.remember(digits(from), spk);
      }
      _ensureKeyShared(from);
    }
    // Acknowledge delivery so the sender's ticks advance — naming
    // the message so a group ack lands on the group's ticks.
    if (added && from != null) {
      sendReceipt(from, 'delivered', messageId: map['id'] as String?);
    }
  }

  /// Recovers the payload a sender actually broadcast from what
  /// realtime_client hands a subscription callback — the whole wire envelope
  /// `{event: …, payload: {…}, type: broadcast}`, NOT the payload that was
  /// sent. Every live handler below read `payload['from']` off the envelope,
  /// got null, and dropped the event — so nothing was ever applied live and
  /// delivery quietly degraded to the offline-mailbox sweeps (which is why
  /// messages only appeared after a refresh, and typing/presence/ringing —
  /// live-only, no mailbox — never appeared at all). Proven against the live
  /// project with tool/probe_realtime.dart. Tolerates an already-unwrapped
  /// map (no app payload carries a map under 'payload'), so a future client
  /// that starts delivering the inner payload can't re-break this.
  static Map<String, dynamic> unwrapBroadcast(Map<String, dynamic> raw) {
    final inner = raw['payload'];
    if (inner is Map) return Map<String, dynamic>.from(inner);
    return raw;
  }

  void start() {
    if (!_initialized || _inbox != null) return;
    final me = Session.instance.user.value?.phone;
    if (me == null) return;
    _inbox = _client
        .channel(inboxChannel(me))
        .onBroadcast(
          event: 'msg',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _onInboxMessage(Map<String, dynamic>.from(payload), myPhone: me);
          },
        )
        .onBroadcast(
          // Sealed sender: any 1:1 event, wearing an envelope only this
          // device's identity key can open — the wire no longer says who
          // it is from, or even what KIND of event it is.
          event: 'sealed',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            applySealedEnvelope(Map<String, dynamic>.from(payload),
                myPhone: me);
          },
        )
        .onBroadcast(
          event: 'gupd',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
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
          event: 'skdm',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            applySkdm(Map<String, dynamic>.from(payload), myPhone: me);
          },
        )
        .onBroadcast(
          event: 'skreq',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            applySkreq(Map<String, dynamic>.from(payload), myPhone: me);
          },
        )
        .onBroadcast(
          event: 'fbreq',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            applyFbreq(Map<String, dynamic>.from(payload), myPhone: me);
          },
        )
        .onBroadcast(
          event: 'key',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            applyKeyEvent(Map<String, dynamic>.from(payload), myPhone: me);
          },
        )
        .onBroadcast(
          event: 'cap',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            final from = payload['from'] as String?;
            if (from == null || digits(from) == digits(me)) return;
            recordingFromDigits = digits(from);
            recordingPing.value++;
          },
        )
        .onBroadcast(
          event: 'shot',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            final from = payload['from'] as String?;
            if (from == null || digits(from) == digits(me)) return;
            screenshotFromDigits = digits(from);
            screenshotPing.value++;
          },
        )
        .onBroadcast(
          event: 'gshot',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            final from = payload['from'] as String?;
            if (from == null || digits(from) == digits(me)) return;
            ghostShotFromDigits = digits(from);
            ghostShotPing.value++;
          },
        )
        .onBroadcast(
          event: 'typing',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            final from = payload['from'] as String?;
            if (from == null || digits(from) == digits(me)) return;
            noteTypingPing(digits(from),
                groupId: payload['g'] as String? ?? '');
          },
        )
        .onBroadcast(
          event: 'presence',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            final from = payload['from'] as String?;
            if (from == null || digits(from) == digits(me)) return;
            presenceFromDigits = digits(from);
            // 'chat' is what a ping from an older build means too: those
            // builds only ever ping from inside the conversation.
            presenceWhere = payload['where'] as String? ?? 'chat';
            presencePing.value++;
            // They just opened (or are sitting in) the chat with this
            // account — answer with "the app is open here" so their header
            // can say online instead of guessing.
            if (presenceWhere == 'chat') maybeAnswerPresence(digits(from));
          },
        )
        .onBroadcast(
          event: 'loc',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            final parsed = parseLocation(Map<String, dynamic>.from(payload));
            if (parsed == null || parsed.fromDigits == digits(me)) return;
            LiveLocationStore.instance
                .update(parsed.fromDigits, parsed.lat, parsed.lng);
          },
        )
        .onBroadcast(
          // A friend's story, live. (Sealed ones arrive as 'sealed' and route
          // through applyInboxEvent's 'status' case; this is the legacy path.)
          event: 'status',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            applyStatus(Map<String, dynamic>.from(payload), myPhone: me);
          },
        )
        .onBroadcast(
          event: 'vopen',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            applyMessageEvent('vopen', Map<String, dynamic>.from(payload),
                myPhone: me);
          },
        )
        .onBroadcast(
          event: 'callmiss',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyMissedCall(Map<String, dynamic>.from(payload), myPhone: me);
          },
        )
        .onBroadcast(
          event: 'receipt',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            applyReceipt(Map<String, dynamic>.from(payload), myPhone: me);
          },
        )
        .onBroadcast(
          event: 'edit',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            applyMessageEvent('edit', Map<String, dynamic>.from(payload),
                myPhone: me);
          },
        )
        .onBroadcast(
          event: 'delete',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            applyMessageEvent('delete', Map<String, dynamic>.from(payload),
                myPhone: me);
          },
        )
        .onBroadcast(
          event: 'payst',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            applyMessageEvent('payst', Map<String, dynamic>.from(payload),
                myPhone: me);
          },
        )
        .onBroadcast(
          event: 'reaction',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            applyMessageEvent('reaction', Map<String, dynamic>.from(payload),
                myPhone: me);
          },
        )
        .onBroadcast(
          event: 'poll',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            applyMessageEvent('poll', Map<String, dynamic>.from(payload),
                myPhone: me);
          },
        )
        .onBroadcast(
          event: 'billpaid',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            applyMessageEvent('billpaid', Map<String, dynamic>.from(payload),
                myPhone: me);
          },
        )
        .onBroadcast(
          event: 'call',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCallEvent(Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'vrtc',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyRoomSignal(Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'file',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
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
    var channel = _client
        .channel('server_feed')
        .onBroadcast(
          event: 'post',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            final map = Map<String, dynamic>.from(payload);
            final from = map['from'] as String?;
            if (from == null || digits(from) == digits(me)) return;
            final raw = map['post'];
            if (raw is! Map) return;
            try {
              FeedStore.instance
                  .addRemote(FeedPost.fromJson(Map<String, dynamic>.from(raw)));
            } catch (_) {}
          },
        )
        .onBroadcast(
          event: 'chmsg',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'chmsg', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'chdel',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'chdel', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'chedt',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'chedt', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'chrxn',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'chrxn', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'chpin',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'chpin', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'chack',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'chack', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'chjoin',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'chjoin', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'chupd',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'chupd', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'vpres',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'vpres', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'vpreq',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'vpreq', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'vkick',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'vkick', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'fbcat',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'fbcat', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'chtyp',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'chtyp', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'fpost',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'fpost', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'fdel',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'fdel', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'flike',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'flike', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'fview',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'fview', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'fspark',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'fspark', Map<String, dynamic>.from(payload), me);
          },
        )
        .onBroadcast(
          event: 'fvote',
          callback: (rawEnvelope) {
            final payload = unwrapBroadcast(rawEnvelope);
            _applyCommunityEvent(
                'fvote', Map<String, dynamic>.from(payload), me);
          },
        );
    // Forum activity, registered off the shared list so a new event cannot
    // be sent and never heard.
    for (final event in forumEvents) {
      channel = channel.onBroadcast(
        event: event,
        callback: (rawEnvelope) {
          final payload = unwrapBroadcast(rawEnvelope);
          _applyCommunityEvent(event, Map<String, dynamic>.from(payload), me);
        },
      );
    }
    _feedChannel = channel;
    channel.subscribe((status, [error]) {
      // Tracked here rather than read off the channel: the channel's own
      // state getters are package-internal, and the callback is told about
      // every transition anyway — including the errored/closed ones the
      // watchdog below exists to catch.
      _inboxLive = status == RealtimeSubscribeStatus.subscribed;
    });
    // Catch up on whatever arrived while the app was closed — the mailbox
    // for directed envelopes, the durable store for server posts.
    fetchMailbox();
    unawaited(fetchCommunityPosts());
    // The global marketplace: every seller's listings, from any server or none,
    // so a brand-new account in no servers still opens to a full marketplace.
    unawaited(fetchMarketListings());
    // And every listing's reviews, so a review reaches its seller (and every
    // other browser) even without either device being online at the same time.
    unawaited(fetchMarketReviews());
    // The Discover directory: every public server, so a fresh account can find
    // and join one without an invite.
    unawaited(fetchServerDirectory());
    // Server-authoritative structure (docs/community_structure.sql): owned
    // servers republish, joined servers opportunistically re-register, every
    // known community's structure is pulled fresh. See _syncCommunityStructure.
    unawaited(_syncCommunityStructure());
    // Same shape for 1:1/group chats (docs/chat_structure.sql).
    unawaited(_syncChatStructure());
    // The socket dies silently mid-foreground too (network blips, carrier
    // NAT timeouts) and "sometimes works" is what that looks like. Check
    // the join every half minute and rebuild the moment it is gone, instead
    // of waiting for the next backgrounding to notice. A rebuild that
    // cannot join yet simply tries again on the next tick.
    _socketWatch?.cancel();
    _socketWatch = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_inbox != null && !_inboxLive) wake();
    });
  }

  Timer? _socketWatch;
  bool _inboxLive = false;

  /// Routes one sealed community event ([event] = chmsg/chjoin/chupd) into
  /// the store — shared by the live bus and the offline mailbox, so the
  /// dedup/merge semantics are identical either way.
  /// Applies a sealed server event that arrived over Bluetooth rather than the
  /// internet.
  ///
  /// The SAME routing, deliberately. `_onCommunityEvent` looks the server up
  /// by id and decrypts with its secret, so a phone that is not a member gets
  /// nothing out of it and no separate membership check is needed — the key it
  /// does not hold is the check. The event name rides in the payload here,
  /// because a broadcast has no per-event channel to arrive on.
  void applyCommunityFromMesh(Map<String, dynamic> payload, String me) {
    final event = payload['e'];
    if (event is! String) return;
    _applyCommunityEvent(event, payload, me);
  }

  /// Feeds one sealed community event through the real routing, so a test can
  /// check what a *received* chdel/chedt/chrxn/chpin actually does to the
  /// store rather than trusting that the switch has a case for it.
  @visibleForTesting
  void debugApplyCommunityEvent(
          String event, Map<String, dynamic> payload, String me) =>
      _applyCommunityEvent(event, payload, me);

  void _applyCommunityEvent(
      String event, Map<String, dynamic> payload, String me) {
    _onCommunityEvent(payload, me, (cid, body, enc) {
      switch (event) {
        case 'chmsg':
          final rawMsg = body['message'];
          if (rawMsg is! Map) return;
          final msg = Message.fromJson(Map<String, dynamic>.from(rawMsg));
          final msgChannelId = body['channelId'] as String? ?? '';
          final added = CommunityStore.instance.addRemoteChannelMessage(
            cid,
            msgChannelId,
            Message(
              id: msg.id,
              text: msg.text,
              time: msg.time,
              isMe: false,
              status: MessageStatus.delivered,
              senderName: body['senderName'] as String? ?? 'Member',
              // The envelope's sender, kept on the message so a channel
              // message can be sparked — the same digits the sender-key
              // chain and signature were just checked against.
              senderPhone: digits(payload['from'] as String? ?? ''),
              isImage: msg.isImage,
              imageUrl: msg.imageUrl,
              replyTo: msg.replyTo,
              isPoll: msg.isPoll,
              pollQuestion: msg.pollQuestion,
              pollOptions: msg.pollOptions,
              pollVotes: msg.pollVotes,
              // What actually opened it here — never `msg.enc`, which is the
              // sender's own bookkeeping and rode in with their payload.
              enc: EncryptionLabel.codeOf(enc),
            ),
          );
          // Acknowledge delivery, the same way _onInboxMessage does for a
          // 1:1/group message — but only when this device genuinely just
          // added it. The mailbox replays an already-drained message on
          // every relaunch until it expires, and re-acking a replay would
          // teach the sender nothing while never actually going quiet.
          if (added) {
            unawaited(sendChannelAck(cid, msgChannelId, 'delivered', msg.id));
          }
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
              add: body['add'] as bool? ?? true,
              reactor: digits(payload['from'] as String? ?? ''));
        case 'chpin':
          final id = body['id'];
          if (id is! String) return;
          CommunityStore.instance.setChannelMessagePinned(
              cid, body['channelId'] as String? ?? '', id,
              pinned: body['pinned'] as bool? ?? true);
        case 'chack':
          final channelId = body['channelId'];
          final id = body['id'];
          final kind = body['kind'];
          if (channelId is! String || id is! String) return;
          final status =
              kind == 'read' ? MessageStatus.read : MessageStatus.delivered;
          CommunityStore.instance
              .setChannelOutgoingStatus(cid, channelId, status);
          // Only a read ack records WHO — a delivered ack is the coarse
          // ticks-only signal, the same split ChatStore.applyReceipt draws
          // for a group.
          if (status == MessageStatus.read) {
            CommunityStore.instance.noteChannelSeenUpTo(
                cid, channelId, id, digits(payload['from'] as String? ?? ''));
          }
        case 'chjoin':
          final rawMember = body['member'];
          if (rawMember is! Map) return;
          final joined = Member.fromJson(Map<String, dynamic>.from(rawMember));
          CommunityStore.instance.applyRemoteJoin(cid, joined);
          // The joiner's own sendServerJoin already hands EXISTING members
          // its key, so they can read the joiner's future messages — but
          // nothing made that trip the other way. _sealCommunity only
          // auto-distributes on this device's FIRST-EVER send for this
          // community; an established member who already posted before
          // today never re-triggers it, so a brand-new joiner got that
          // member's key ONLY by accident — after failing to decrypt one of
          // their live messages and sending skreq, which drops that first
          // message and needs the member to post something NEW while the
          // joiner is still around. A server where the existing members
          // simply hadn't posted since the join left the joiner staring at
          // an empty channel with no failed decrypt to ever trigger a
          // repair. Handing our key to the joiner directly, the moment we
          // see them join, closes that gap — reported as "servers aren't
          // working ... text channels don't show any messages" (2026-08-13).
          final joinedDigits = CommunityStore.digitsOfWireId(joined.id);
          if (joinedDigits != null && SenderKeyStore.instance.hasOwn(cid)) {
            final community = CommunityStore.instance.byId(cid);
            if (community != null) {
              _distributeSkdm(community, toDigits: joinedDigits);
            }
          }
        case 'chleave':
          // The leaver is the event's SENDER, never a name in the body —
          // the signature binds `from`, and a body field would let one
          // member evict another.
          // Same `from` the signature was verified against a few frames up
          // in _onCommunityEvent — not a body field anyone could set.
          CommunityStore.instance
              .applyRemoteLeave(cid, digits(payload['from'] as String? ?? ''));
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
        case 'vpreq':
          // "Who's here?" — opening a voice channel used to learn about
          // whoever was already in it purely by luck: only from their NEXT
          // periodic heartbeat (up to 20s away), never on demand. A device
          // already in this server's voice re-announces itself the instant
          // it hears the request, the same announce a heartbeat sends.
          if (VoicePresenceStore.instance.myCommunityId == cid) {
            VoicePresenceStore.instance.announceNow();
          }
        case 'vkick':
          // A moderator force-disconnected someone from voice
          // (docs/community_voice.sql's DELETE policy is the real
          // enforcement; this is the best-effort live nudge so the target
          // hangs up immediately instead of lingering until something
          // notices their row is gone — nothing currently polls for that).
          // Not independently permission-checked here: even a forged vkick
          // can only make the RECEIVER hang up their OWN call, the same
          // as tapping Leave themself, so there is nothing to protect
          // against beyond the annoyance of a bogus disconnect.
          final channelId = body['channelId'];
          final target = digits(body['target'] as String? ?? '');
          if (channelId is! String || target.isEmpty) return;
          if (target == digits(me) &&
              VoicePresenceStore.instance.myChannelId == channelId) {
            unawaited(RoomMedia.instance.leaveRoom());
            VoicePresenceStore.instance.leave();
          }
        case 'fbcat':
          applyFbcat(cid, body, myPhone: me);
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
        case 'fview':
          final id = body['id'];
          if (id is String) {
            FeedStore.instance.applyRemoteView(
              id,
              viewerUsername: body['username'] as String? ?? '',
            );
          }
        case 'fspark':
          final id = body['id'];
          final zid = body['sid'];
          if (id is String && zid is String) {
            FeedStore.instance.applyRemoteSpark(
              id,
              sparkId: zid,
              cents: (body['cents'] as num?)?.toInt() ?? 0,
              sparkerName: body['name'] as String? ?? 'Someone',
              sparkerUsername: body['username'] as String? ?? '',
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
        case 'frpost':
          final channelId = body['channelId'];
          final raw = body['post'];
          if (channelId is! String || raw is! Map) return;
          try {
            CommunityStore.instance.applyRemoteForumPost(cid, channelId,
                ForumPost.fromJson(Map<String, dynamic>.from(raw)));
          } catch (_) {}
        case 'frcom':
          final channelId = body['channelId'];
          final postId = body['postId'];
          final raw = body['comment'];
          if (channelId is! String || postId is! String || raw is! Map) {
            return;
          }
          try {
            CommunityStore.instance.applyRemoteForumComment(cid, channelId,
                postId, ForumComment.fromJson(Map<String, dynamic>.from(raw)));
          } catch (_) {}
        case 'frvote':
          final channelId = body['channelId'];
          final postId = body['postId'];
          if (channelId is! String || postId is! String) return;
          CommunityStore.instance.applyRemoteForumVote(cid, channelId, postId,
              commentId: body['commentId'] as String?,
              delta: (body['delta'] as num?)?.toInt() ?? 0);
        case 'frdel':
          final channelId = body['channelId'];
          final postId = body['postId'];
          if (channelId is! String || postId is! String) return;
          CommunityStore.instance
              .applyRemoteForumPostDelete(cid, channelId, postId);
        case 'frcdel':
          final channelId = body['channelId'];
          final postId = body['postId'];
          final commentId = body['commentId'];
          if (channelId is! String ||
              postId is! String ||
              commentId is! String) {
            return;
          }
          CommunityStore.instance
              .applyRemoteForumCommentDelete(cid, channelId, postId, commentId);
        case 'fredt':
          final channelId = body['channelId'];
          final postId = body['postId'];
          final title = body['title'];
          if (channelId is! String || postId is! String || title is! String) {
            return;
          }
          CommunityStore.instance.applyRemoteForumPostEdit(
              cid, channelId, postId, title, body['body'] as String? ?? '',
              tag: body['tag'] as String?, gifUrl: body['gifUrl'] as String?);
        case 'frcedt':
          final channelId = body['channelId'];
          final postId = body['postId'];
          final commentId = body['commentId'];
          final text = body['body'];
          if (channelId is! String ||
              postId is! String ||
              commentId is! String ||
              text is! String) {
            return;
          }
          CommunityStore.instance.applyRemoteForumCommentEdit(
              cid, channelId, postId, commentId, text);
        case 'frpin':
          final channelId = body['channelId'];
          final postId = body['postId'];
          if (channelId is! String || postId is! String) return;
          CommunityStore.instance.applyRemoteForumFlag(cid, channelId, postId,
              pinned: body['pinned'] as bool? ?? false);
        case 'frlock':
          final channelId = body['channelId'];
          final postId = body['postId'];
          if (channelId is! String || postId is! String) return;
          CommunityStore.instance.applyRemoteForumFlag(cid, channelId, postId,
              locked: body['locked'] as bool? ?? false);
      }
    });
  }

  /// Decodes a sealed community-bus event: looks the server up by id, opens
  /// the body with its secret, and hands the plaintext to [apply], along with
  /// WHICH key opened it — the sender-key chain or the legacy shared secret.
  /// Those are different promises, so a channel message records the one it
  /// really arrived under rather than the one this build would have used.
  /// Events for servers this device isn't in (no id match → no secret) drop
  /// silently, as do our own echoes.
  void _onCommunityEvent(
      Map<String, dynamic> payload,
      String me,
      void Function(String cid, Map<String, dynamic> body, EncryptionKind enc)
          apply) {
    try {
      final from = payload['from'] as String?;
      if (from == null || digits(from) == digits(me)) return;
      final cid = payload['communityId'] as String?;
      if (cid == null) return;
      if (CommunityStore.instance.byId(cid)?.secretBytes == null) return;

      String? plain;
      final skc = payload['skc'] as String?;
      if (skc != null) {
        // Sender-key path: forward-secret per-sender chain. If we don't hold
        // this sender's chain yet, their SKDM hasn't arrived — ask for it and
        // drop this one message rather than reading it a weaker way.
        final n = (payload['skn'] as num?)?.toInt() ?? 0;
        final sg = payload['sg'] as String? ?? '';
        final sender = digits(from);
        if (!SenderKeyStore.instance.canRead(cid, sender)) {
          _requestSkdm(cid, sender);
          return;
        }
        plain = SenderKeyStore.instance.open(cid, sender, n, skc, sg);
        if (plain == null) {
          // Held the chain but couldn't open: a gap past the bound / a
          // rotation we missed (re-request resyncs), OR a signature that did
          // not verify (a forgery — the resync is harmless, the message
          // stays dropped).
          _requestSkdm(cid, sender);
          return;
        }
      } else {
        // Legacy shared-secret path, for servers/senders on older builds.
        final data = payload['data'] as String?;
        final secret = CommunityStore.instance.byId(cid)?.secretBytes;
        if (data == null || secret == null) return;
        plain = E2eCrypto.decrypt(secret, data);
      }
      if (plain == null) return;
      final body = jsonDecode(plain);
      if (body is! Map) return;
      apply(
        cid,
        Map<String, dynamic>.from(body),
        skc != null ? EncryptionKind.senderKey : EncryptionKind.serverSecret,
      );
    } catch (_) {}
  }

  /// Seals a community-bus event ('chmsg' / 'chjoin' / 'chupd') with the
  /// server's secret, broadcasts it live, and fans the same envelope into
  /// every other member's offline mailbox so nobody misses server activity
  /// just for being away. No-op for servers without a secret (older builds).
  ///
  /// Returns WHICH key sealed it, or null when nothing was sent — the caller
  /// records that on the message, and "nothing went out" must never read as
  /// "encrypted".
  Future<EncryptionKind?> _sendCommunityEvent(
      String event, String communityId, Map<String, dynamic> body,
      {bool viaSecret = false}) async {
    if (!_initialized) return null;
    final me = Session.instance.user.value;
    if (me == null) return null;
    final community = CommunityStore.instance.byId(communityId);
    final secret = community?.secretBytes;
    if (community == null || secret == null) return null;
    // BOOTSTRAP EVENTS ride the shared secret, not a sender key. A brand-new
    // member's very first event (their `chjoin`) can't be sealed with a sender
    // key the recipients don't hold yet — they'd drop it and never re-read it,
    // so the owner would never register the join or backfill the feed. The
    // shared secret every member already holds is the one key guaranteed to be
    // readable at that moment; the payload is only membership metadata, no more
    // exposed than the roster itself. Content still rides sender keys.
    final sealed = viaSecret
        ? {'data': E2eCrypto.encrypt(secret, jsonEncode(body))}
        : _sealCommunity(community, jsonEncode(body));
    final payload = {
      'from': me.phone,
      'communityId': communityId,
      ...sealed,
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
    // And on the air, if the mesh is on. The event name has to travel inside
    // the payload: a Bluetooth broadcast has no per-event channel to arrive
    // on, where the Supabase bus subscribes to one name per event.
    // RANDOM, not a counter. A router dedups by this id, so two phones that
    // both number their first event "chmsg_c1_0" would each silently drop the
    // other's — a bug that only shows up with two devices in a room, which is
    // the hardest place to find one.
    unawaited(MeshService.instance.sendCommunity({...payload, 'e': event},
        eventId: MeshPacket.randomId()).catchError((_) => false));
    return viaSecret ? EncryptionKind.serverSecret : EncryptionKind.senderKey;
  }

  /// Hands one NEW member the feed history of a server they just joined —
  /// the live listings and recent posts, sealed like any feed event and
  /// queued straight into their mailbox (they were not a member when the
  /// originals fanned out, so no copy of them exists anywhere they can
  /// reach). Called on the owner's device only; every member sees the join,
  /// and all of them re-sending the same posts would stampede one mailbox.
  /// Receiving is the ordinary 'fpost' path, whose id/rev dedup makes any
  /// overlap harmless.
  Future<void> backfillFeedTo(String communityId, String joinerWireId,
      {bool authoredOnly = false}) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final community = CommunityStore.instance.byId(communityId);
    if (community == null || community.secretBytes == null) return;
    final d = CommunityStore.digitsOfWireId(joinerWireId);
    if (d == null || d == digits(me.phone)) return;
    // Hand the joiner our sender key FIRST, so the posts we're about to send —
    // sealed with that key — are readable the moment they arrive. Without this
    // they'd drop every fpost, skreq us, and only see the feed after a second
    // round trip (or not at all, if we post nothing new).
    _distributeSkdm(community, toDigits: d);
    final myDigits = digits(me.phone);
    for (final post in FeedStore.instance.backfillFor(communityId)) {
      // A catch-up answer carries only what THIS device wrote — every
      // author re-sending their own is complete without n-fold duplicates.
      if (authoredOnly &&
          digits(post.authorPhone) != myDigits &&
          post.authorUsername != 'you') {
        continue;
      }
      final payload = {
        'from': me.phone,
        'communityId': communityId,
        ..._sealCommunity(community, jsonEncode({'post': post.toJson()})),
      };
      await _mailboxPut(d, payload, event: 'fpost');
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
        ..._sealCommunity(community, jsonEncode(body)),
      });
    } catch (_) {}
  }

  /// Seals a community body under this device's Signal sender key for the
  /// server — a forward-secret per-sender chain, so a member who leaves (and
  /// the shared server secret they walk off with) reads nothing sent after
  /// the next rotation. On the FIRST send to a server this device also mints
  /// and distributes its sender-key distribution message (SKDM) pairwise to
  /// every reachable member, over the ratchet, so their next receive can open
  /// this chain.
  ///
  /// The shared secret is no longer what protects content — it only gated
  /// membership before, and the SKDM (which rides the pairwise ratchet, not
  /// the shared secret) now carries that job. A receiver on an older build
  /// that does not understand `skc` will miss these, the same version cost
  /// the pairwise `enc 3` messages carry; it is a branch push, not a live
  /// fleet.
  Map<String, dynamic> _sealCommunity(Community community, String plaintext) {
    final sk = SenderKeyStore.instance;
    final firstSend = !sk.hasOwn(community.id);
    final sealed = sk.seal(community.id, plaintext);
    if (firstSend) _distributeSkdm(community);
    return {'skc': sealed.ct, 'skn': sealed.n, 'sg': sealed.sg};
  }

  /// Sends this device's current SKDM for [community] to each reachable
  /// member (or just [toDigits] when answering an skreq), pairwise-sealed so
  /// only that member can read the chain key. Members with no resolvable
  /// inbox (seeds, the local 'me') are skipped — they have no device to reach.
  void _distributeSkdm(Community community, {String? toDigits}) {
    final me = Session.instance.user.value;
    if (me == null) return;
    final skdm = SenderKeyStore.instance.mySkdm(community.id);
    final mine = digits(me.phone);
    final body = jsonEncode({
      'communityId': community.id,
      'ck': skdm.ck,
      'n': skdm.n,
      'sig': skdm.sig, // the signing public key, so receivers can verify
    });
    for (final m in community.members) {
      final d = CommunityStore.digitsOfWireId(m.id);
      if (d == null || d == mine) continue;
      if (toDigits != null && d != toDigits) continue;
      unawaited(_sendInboxEvent(d, 'skdm', {
        'from': me.phone,
        ...sealContent(me.phone, d, body),
      }));
    }
  }

  /// Rotates a server's sender-key epoch after a member left, then hands the
  /// fresh SKDM to everyone still in. Wired to CommunityStore.onMemberRemoved.
  void rotateServerKey(String communityId) {
    final community = CommunityStore.instance.byId(communityId);
    if (community == null) return;
    SenderKeyStore.instance.rotate(communityId);
    _distributeSkdm(community);
  }

  /// Applies an inbound SKDM from [from]: opens the pairwise seal, stores the
  /// sender's chain so their broadcasts can be read.
  void applySkdm(Map<String, dynamic> payload, {required String myPhone}) {
    final from = payload['from'] as String?;
    if (from == null || digits(from) == digits(myPhone)) return;
    final plain = openContent(from, myPhone, payload);
    if (plain == null) return;
    try {
      final body = jsonDecode(plain) as Map<String, dynamic>;
      final cid = body['communityId'] as String?;
      final ck = body['ck'] as String?;
      final n = (body['n'] as num?)?.toInt();
      final sig = body['sig'] as String?;
      if (cid == null || ck == null || n == null || sig == null) return;
      final fresh =
          SenderKeyStore.instance.acceptSkdm(cid, digits(from), ck, n, sig);
      // A chain we never had means everything this sender sealed before now
      // was dropped unread — the mailbox deletes what it cannot open, so a
      // listing posted while the pairing was broken simply never existed
      // here. Ask them to re-send the feed; id/rev dedup on the receiving
      // path makes any overlap harmless.
      if (fresh) _requestFeedBackfill(cid, digits(from));
    } catch (_) {}
  }

  /// Once per (server, sender) per run: the ask is answered with the whole
  /// feed, and a healthy pairing must not be able to stampede a mailbox.
  final Set<String> _backfillAsked = {};
  void _requestFeedBackfill(String communityId, String senderDigits) {
    final me = Session.instance.user.value;
    if (me == null) return;
    final key = '$communityId|$senderDigits';
    if (_backfillAsked.contains(key)) return;
    _backfillAsked.add(key);
    unawaited(_sendInboxEvent(senderDigits, 'fbreq', {
      'from': me.phone,
      'communityId': communityId,
    }));
  }

  /// Answers an fbreq: a member's copy of the server feed has holes (their
  /// first chain from us just arrived, so everything sealed before it was
  /// dropped) — re-send them the feed, membership-checked first.
  void applyFbreq(Map<String, dynamic> payload, {required String myPhone}) {
    final from = payload['from'] as String?;
    final cid = payload['communityId'] as String?;
    if (from == null || cid == null || digits(from) == digits(myPhone)) {
      return;
    }
    final community = CommunityStore.instance.byId(cid);
    if (community == null) return;
    final wire = CommunityStore.wireId(digits(from));
    if (!community.members.any((m) => m.id == wire)) return;
    unawaited(backfillFeedTo(cid, wire));
  }

  /// Pull-to-refresh's reach into every joined server: broadcasts a
  /// catch-up ask ('fbcat') on the community bus, and every member online
  /// answers with the posts THEY authored — each author re-sending their
  /// own is complete coverage without every member re-sending everything.
  /// This is the on-demand repair for "the marketplace shows no listings":
  /// broadcast has no history, the automatic backfills only fire on chain
  /// events, and a listing posted while everything else was misaligned
  /// otherwise stayed invisible with no way to ASK for it.
  Future<void> requestFeedCatchup() async {
    final me = Session.instance.user.value;
    if (me == null) return;
    // The durable store first — it answers even when nobody is online.
    unawaited(fetchCommunityPosts());
    // And the global marketplace, so a pull-to-refresh pulls in every seller's
    // listings, not just the ones in servers this device belongs to.
    unawaited(fetchMarketListings());
    // And every listing's reviews.
    unawaited(fetchMarketReviews());
    // And the Discover directory of public servers.
    unawaited(fetchServerDirectory());
    // And server-authoritative structure — same republish/register/fetch
    // pass relay start runs, so pulling to refresh also rebuilds a dead
    // realtime subscription's view of who's actually on a roster.
    unawaited(_syncCommunityStructure());
    unawaited(_syncChatStructure());
    for (final community in CommunityStore.instance.communities) {
      if (community.secretBytes == null) continue;
      await _broadcastCommunityEvent('fbcat', community.id, {
        'wire': CommunityStore.wireId(digits(me.phone)),
      });
    }
  }

  /// Answers an fbcat with the posts this device AUTHORED, rate-limited per
  /// asker — a refresh spammed in a loop must not stampede a mailbox.
  final Map<String, DateTime> _fbcatAnswered = {};
  void applyFbcat(String cid, Map<String, dynamic> body,
      {required String myPhone}) {
    final wire = body['wire'] as String?;
    if (wire == null) return;
    final d = CommunityStore.digitsOfWireId(wire);
    if (d == null || d == digits(myPhone)) return;
    final community = CommunityStore.instance.byId(cid);
    if (community == null || !community.members.any((m) => m.id == wire)) {
      return;
    }
    final key = '$cid|$d';
    final last = _fbcatAnswered[key];
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 5)) {
      return;
    }
    _fbcatAnswered[key] = DateTime.now();
    unawaited(backfillFeedTo(cid, wire, authoredOnly: true));
  }

  /// Answers an skreq: a member saw our sender-key traffic before our SKDM
  /// reached them, so re-send it to just them.
  void applySkreq(Map<String, dynamic> payload, {required String myPhone}) {
    final from = payload['from'] as String?;
    final cid = payload['communityId'] as String?;
    if (from == null || cid == null || digits(from) == digits(myPhone)) return;
    final community = CommunityStore.instance.byId(cid);
    if (community == null || !SenderKeyStore.instance.hasOwn(cid)) return;
    _distributeSkdm(community, toDigits: digits(from));
  }

  /// Asks [senderDigits] to (re)send their SKDM for [communityId] — closes the
  /// race where a broadcast outran its distribution message.
  void _requestSkdm(String communityId, String senderDigits) {
    final me = Session.instance.user.value;
    if (me == null) return;
    unawaited(_sendInboxEvent(senderDigits, 'skreq', {
      'from': me.phone,
      'communityId': communityId,
    }));
  }

  /// Voice-channel WebRTC signaling (offer/answer/ice/bye), pairwise and
  /// sealed like call signaling — the mesh is per-peer connections, so its
  /// SDP is a private conversation between two devices even though the room
  /// is many. LIVE ONLY, never queued: a room offer replayed from a mailbox
  /// after the sender left would open a connection to nobody.
  Future<void> sendRoomSignal(
    String contactPhone, {
    required String roomId,
    required String kind,
    String? sdp,
    Map<String, dynamic>? ice,
  }) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final name = inboxChannel(contactPhone);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    await channel.sendBroadcastMessage(event: 'vrtc', payload: {
      'from': me.phone,
      'roomId': roomId,
      'kind': kind,
      'ts': DateTime.now().millisecondsSinceEpoch,
      ..._sealSignalPair(contactPhone, sdp: sdp, ice: ice),
    });
  }

  /// Where an incoming room-signaling event goes — wired to RoomMedia at
  /// startup; left null in tests so nothing touches WebRTC.
  void Function(String fromDigits, String roomId, String kind,
      {String? sdp, Map<String, dynamic>? ice})? onRoomSignal;

  void _applyRoomSignal(Map<String, dynamic> p, String me) {
    final from = p['from'] as String?;
    final roomId = p['roomId'] as String?;
    final kind = p['kind'] as String?;
    if (from == null || roomId == null || kind == null) return;
    if (digits(from) == digits(me)) return;
    onRoomSignal?.call(digits(from), roomId, kind,
        sdp: _openSdp(from, p), ice: _openIce(from, p));
  }

  /// Asks every device already in one of this server's voice channels to
  /// re-announce itself right now, rather than waiting for its next
  /// heartbeat. Fired when a device OPENS a voice channel screen — reported
  /// as "servers aren't in sync ... can't see me in voice channel"
  /// (2026-08-13): joining announces immediately and should reach anyone
  /// with a live connection, but a device that opened the room BEFORE you
  /// joined, or whose subscription silently died and was rebuilt, had no
  /// way to catch up except waiting out someone else's next tick.
  Future<void> sendVoicePresenceRequest(String communityId) =>
      _broadcastCommunityEvent('vpreq', communityId, const {});

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

  /// Voice channel presence, Phase 2 of "central authority"
  /// (docs/community_voice.sql) — a durable, RLS-scoped ground truth over
  /// the same live vpres/vpreq broadcast above, which stays completely
  /// untouched and remains the low-latency path for anyone already watching
  /// a room. This table answers the one thing broadcast structurally can't:
  /// who is here for a device that just opened the room.
  static const communityVoicePresenceTable = 'community_voice_presence';

  /// Upserts (join, or any state change) or deletes (leave) this device's own
  /// row. Wired as a SECOND consequence of [VoicePresenceStore.onPresence] —
  /// the exact shape [publishCommunityStructure] took off
  /// `CommunityStore.onStructureChanged` in Phase 1 — so it rides the SAME
  /// 20-second heartbeat [VoicePresenceStore] already re-announces on, which
  /// is also what keeps `last_seen` fresh without a second timer: a
  /// force-quit stops the heartbeat, which stops `last_seen` advancing,
  /// which is what lets a reader's own [VoicePresenceStore.staleAfter]
  /// filter this row out with no server-side sweep at all.
  Future<void> publishVoicePresence(String communityId, String channelId,
      {required bool joined,
      required bool muted,
      required bool video,
      required bool screen}) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final myDigits = digits(me.phone);
    if (myDigits.isEmpty) return;
    try {
      if (!joined) {
        await _client
            .from(communityVoicePresenceTable)
            .delete()
            .eq('channel_id', channelId)
            .eq('member_phone', myDigits);
        return;
      }
      await _client.from(communityVoicePresenceTable).upsert({
        'channel_id': channelId,
        'member_phone': myDigits,
        'community_id': communityId,
        'member_name': me.name,
        'muted': muted,
        'video': video,
        'screen': screen,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'channel_id,member_phone');
    } catch (_) {
      // Table missing (setup SQL not run), the community not yet published
      // by its owner (the FK to community_servers has nothing to point at),
      // or offline — presence stays exactly as functional as it is today
      // over the live broadcast alone.
    }
  }

  /// The ground-truth read: pulls [channelId]'s current occupants and feeds
  /// them through [VoicePresenceStore.applyGroundTruth]. Called once when a
  /// voice channel screen opens, alongside the existing
  /// [sendVoicePresenceRequest] live ask — this answers instantly from
  /// whoever already has a row, the live ask answers a moment later from
  /// whoever is still connected right now; together they cover both a device
  /// that's foregrounded-but-quiet and one that's genuinely live.
  Future<void> fetchVoicePresence(String communityId, String channelId) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final myDigits = digits(me.phone);
    if (myDigits.isEmpty) return;
    try {
      final rows = await _client
          .from(communityVoicePresenceTable)
          .select()
          .eq('channel_id', channelId);
      VoicePresenceStore.instance.applyGroundTruth(
        channelId,
        [for (final r in rows) Map<String, dynamic>.from(r)],
        myDigits: myDigits,
      );
    } catch (_) {}
  }

  /// The roster-eviction half of a kick — force-disconnects [targetDigits]
  /// from [channelId]. The DELETE is the real enforcement
  /// (`community_voice_presence_delete`'s `can_moderate_community` check;
  /// a non-moderator's call here matches nothing under RLS and silently
  /// changes zero rows, same as every other moderation action in this app).
  /// The `vkick` broadcast alongside it is best-effort UX only: it does NOT
  /// need its own permission check, because even a forged one can only make
  /// the RECEIVING device hang up its OWN call — the same as if that person
  /// had tapped Leave themself — never anyone else's. Without it, the target
  /// would keep talking until something else noticed their row was gone,
  /// which nothing currently polls for.
  ///
  /// Does NOT tear down the target's actual WebRTC connection directly —
  /// that stays a client-driven hangup on the receiving end (see the
  /// `vkick` case in [_applyCommunityEvent]) — and does NOT ban them from
  /// the server; they can rejoin the room immediately if they choose to.
  Future<void> forceDisconnectVoice(
      String communityId, String channelId, String targetDigits) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    try {
      await _client
          .from(communityVoicePresenceTable)
          .delete()
          .eq('channel_id', channelId)
          .eq('member_phone', targetDigits);
    } catch (_) {}
    unawaited(_broadcastCommunityEvent('vkick', communityId, {
      'channelId': channelId,
      'target': targetDigits,
    }));
  }

  /// Tells the server someone is typing in a channel. Live only — a typing
  /// ping replayed from a mailbox would be nonsense.
  Future<void> sendChannelTyping(String communityId, String channelId) =>
      _broadcastCommunityEvent('chtyp', communityId, {
        'channelId': channelId,
        'name': Session.instance.user.value?.name ?? '',
      });

  /// Delivers a channel message to every other member of the server.
  Future<void> sendChannelMessage(
      String communityId, String channelId, Message message,
      {required String senderName}) async {
    final kind = await _sendCommunityEvent('chmsg', communityId, {
      'channelId': channelId,
      'senderName': senderName,
      'message': message.toJson(),
    });
    // Record what really sealed it — and nothing at all when the send did not
    // happen, so a message that only ever sat on this device does not claim a
    // key it never met.
    if (kind == null) return;
    CommunityStore.instance.noteChannelMessageEnc(
        communityId, channelId, message.id, EncryptionLabel.codeOf(kind));
  }

  /// Acknowledges a channel message — `kind` 'delivered' (this device
  /// received it) or 'read' (this device has now shown it, and everything
  /// before it, on screen). Rides the full `_sendCommunityEvent` path —
  /// sealed with the sender key, mailbox-fanned to every other member —
  /// rather than the live-only broadcast typing/presence use: an ack has to
  /// reach the ORIGINAL sender even when they are offline at the moment it
  /// is sent, or their ticks would only ever advance while they happen to be
  /// watching. Applied on the receiving end by `_applyCommunityEvent`'s
  /// 'chack' case, which upgrades the whole channel's outgoing status the
  /// same coarse "first responder" way `ChatStore.setOutgoingStatus` does
  /// for a group, and — for 'read' — records WHO via
  /// `CommunityStore.noteChannelSeenUpTo`.
  Future<void> sendChannelAck(String communityId, String channelId, String kind,
          String messageId) =>
      _sendCommunityEvent('chack', communityId, {
        'channelId': channelId,
        'kind': kind,
        'id': messageId,
      });

  /// Announces that this device's account is LEAVING the server, so every
  /// other member drops it from the roster — which fires
  /// `onMemberRemoved` and rotates the sender keys, so nothing sent after
  /// the departure is readable with the chain the leaver walked away with.
  ///
  /// Sent on the SIGNED sender-key path rather than the shared secret,
  /// unlike `chjoin`. A join says "add this member" and is checked against
  /// the invite; a leave says "remove that member", and on the shared-secret
  /// path `from` is unauthenticated — any member could forge a departure for
  /// anyone. The signature is what makes the claim the sender's own.
  ///
  /// Must be called BEFORE the local `deleteCommunity`: sealing and the
  /// mailbox fan-out both need the secret and the roster.
  Future<void> sendServerLeave(String communityId) =>
      _sendCommunityEvent('chleave', communityId, const {});

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
  ///
  /// Two things have to happen for a join to actually work, and both are here:
  ///   1. Hand every existing member THIS device's sender key (SKDM), so our
  ///      future posts are readable. _sealCommunity would do this on our first
  ///      sealed send, but the join itself rides the shared secret (below), so
  ///      we distribute explicitly rather than wait for a later post.
  ///   2. Announce the join under the SHARED SECRET (viaSecret), so the owner
  ///      can read it without already holding our sender key — otherwise the
  ///      chjoin is dropped and we're never added to the roster or backfilled.
  Future<void> sendServerJoin(String communityId, Member member) async {
    final community = CommunityStore.instance.byId(communityId);
    if (community != null && community.secretBytes != null) {
      _distributeSkdm(community);
    }
    await _sendCommunityEvent(
        'chjoin', communityId, {'member': member.toJson()},
        viaSecret: true);
  }

  /// Removes a feed post (or repost entry) on every member's device. Only
  /// sealed servers can do this; legacy ones delete locally alone.
  Future<void> sendFeedDelete(String communityId, String postId) {
    // The durable copy dies with the post — a deleted listing must not
    // come back on the next fetch.
    unawaited(_deleteCommunityPost(communityId, postId));
    // And its global marketplace row (a no-op for a non-listing post id) —
    // and the same for a review row (a no-op for a non-review post id).
    // addReview replaces a review by deleting the old one first, so this is
    // also what keeps a rewritten review from leaving a stale copy behind.
    unawaited(deleteMarketListing(postId));
    unawaited(deleteMarketReview(postId));
    return _sendCommunityEvent('fdel', communityId, {'id': postId});
  }

  /// Every forum event name that rides the community bus. One list, used by
  /// the live subscription, so adding an event cannot silently skip a leg.
  static const List<String> forumEvents = [
    'frpost', // new post
    'frcom', // new comment
    'frvote', // a vote, as a score delta
    'frdel', // post deleted (with its comments)
    'frcdel', // comment deleted (with its reply subtree)
    'fredt', // post edited
    'frcedt', // comment edited
    'frpin', // pinned / unpinned
    'frlock', // thread locked / unlocked
  ];

  /// Carries one forum action to every member over the sealed community bus,
  /// live and into offline mailboxes. Wired to CommunityStore.onForumEvent —
  /// the forum used to be per-device, so a delete only ever happened on the
  /// screen it was tapped on and everybody else kept the post forever.
  Future<void> sendForumEvent(
          String communityId, String event, Map<String, dynamic> body) =>
      forumEvents.contains(event)
          ? _sendCommunityEvent(event, communityId, body)
          : Future.value();

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

  /// Broadcasts that a member opened a post — a unique-viewer tally, the
  /// same replay-guarded shape a like rides. The username is the dedup key
  /// and nothing more; it is never shown as "who viewed".
  Future<void> sendFeedView(String communityId, String postId,
          {required String viewerUsername}) =>
      _sendCommunityEvent('fview', communityId, {
        'id': postId,
        'username': viewerUsername,
      });

  /// A spark — a real-money tip pinned to a post, à la Damus. The MONEY moved
  /// person-to-person over Stripe before this is sent; this event only moves
  /// the tally on everyone's copy of the post. [sparkId] keys replay
  /// idempotency (mailbox rows and reconnects re-deliver).
  Future<void> sendFeedSpark(String communityId, String postId,
          {required String sparkId,
          required int cents,
          required String name,
          required String username}) =>
      _sendCommunityEvent('fspark', communityId, {
        'id': postId,
        'sid': sparkId,
        'cents': cents,
        'name': name,
        'username': username,
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
    await _sendCommunityEvent('chupd', communityId, {'structure': structure});
  }

  /// The durable copy of a server's posts: sealed rows in
  /// `community_posts` (docs/community_posts.sql). The broadcast is the
  /// fast path and the mailbox the offline path — this is the one that
  /// SURVIVES, so a listing exists somewhere other than its author's
  /// phone. Sealed with the community SECRET, not a sender-key chain: a
  /// chain's keys die on use, and a stored listing must open for any
  /// member on any day. Chats are deliberately not here — message content
  /// never gets a durable server copy of any kind.
  static const communityPostsTable = 'community_posts';

  Future<void> _storeCommunityPost(Community community, FeedPost post) async {
    final secret = community.secretBytes;
    if (secret == null) return;
    try {
      final payload =
          E2eCrypto.encrypt(secret, jsonEncode({'post': post.toJson()}));
      await http
          .post(
            Uri.parse('${RelayConfig.supabaseUrl}/rest/v1/'
                '$communityPostsTable?on_conflict=community_id,post_id'),
            headers: {
              ..._restHeaders,
              'Prefer': 'resolution=merge-duplicates',
            },
            body: jsonEncode([
              {
                'community_id': post.communityId,
                'post_id': post.id,
                'payload': payload,
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              }
            ]),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Table missing (setup SQL not run) or offline — the broadcast and
      // mailbox already carried the post; durability simply waits.
    }
  }

  Future<void> _deleteCommunityPost(String communityId, String postId) async {
    try {
      await http
          .delete(
            Uri.parse('${RelayConfig.supabaseUrl}/rest/v1/'
                '$communityPostsTable'
                '?community_id=eq.${Uri.encodeComponent(communityId)}'
                '&post_id=eq.${Uri.encodeComponent(postId)}'),
            headers: _restHeaders,
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  /// Pulls every joined server's stored posts and feeds them through the
  /// normal arrival path — id/rev dedup and delete-tombstones make replays
  /// harmless. Called on relay start and from pull-to-refresh, so a fresh
  /// install or a member who missed the broadcast converges on open.
  Future<void> fetchCommunityPosts() async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    for (final community in CommunityStore.instance.communities) {
      final secret = community.secretBytes;
      if (secret == null) continue;
      try {
        final res = await http
            .get(
              Uri.parse('${RelayConfig.supabaseUrl}/rest/v1/'
                  '$communityPostsTable?select=payload'
                  '&community_id=eq.${Uri.encodeComponent(community.id)}'
                  '&order=updated_at.desc&limit=500'),
              headers: _restHeaders,
            )
            .timeout(const Duration(seconds: 15));
        if (res.statusCode >= 300) continue;
        final rows = jsonDecode(res.body);
        if (rows is! List) continue;
        for (final row in rows) {
          if (row is! Map) continue;
          final blob = row['payload'];
          if (blob is! String) continue;
          final plain = E2eCrypto.decrypt(secret, blob);
          if (plain == null) continue; // rotated secret / not ours
          try {
            final decoded = jsonDecode(plain);
            final rawPost = decoded is Map ? decoded['post'] : null;
            if (rawPost is! Map) continue;
            FeedStore.instance.addRemote(
                FeedPost.fromJson(Map<String, dynamic>.from(rawPost)));
          } catch (_) {}
        }
      } catch (_) {}
    }
  }

  /// The GLOBAL marketplace (docs/public_market.sql): a world-readable row per
  /// listing so ANY account — including one in no servers, or a member who
  /// joined a server after an item went up — can find it. Plaintext by the
  /// same rule as the public feed and forum: a listing is an advertisement,
  /// its audience is everyone, and a board whose audience is everyone has no
  /// key to seal under. The seller's PHONE is stripped before the row ever
  /// leaves the device; attribution and reach-out are by username, which is
  /// already how the marketplace resolves a seller to message or pay them.
  static const marketListingsTable = 'market_listings';
  static const marketListingsView = 'market_listings_view';

  /// Publishes (or re-publishes, on edit/sold/price change) one listing — or
  /// one of a listing's photo parts — to the global table. Needs a session, so
  /// it no-ops for a numberless account; selling already requires a verified
  /// number anyway.
  Future<void> publishMarketListing(FeedPost post) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final phone = digits(me.phone);
    if (phone.isEmpty) return;
    // The phone never rides to a world-readable table — strip it from the copy
    // that goes up. On the way back in, FeedPost.fromJson simply reads '' for it.
    final payload = post.toJson()..remove('authorPhone');
    final username =
        post.authorUsername == 'you' ? me.username : post.authorUsername;
    try {
      await _client.from(marketListingsTable).upsert({
        'id': post.id,
        'author_phone': phone,
        'author_username': username,
        'payload': jsonEncode(payload),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'id');
    } catch (_) {
      // Table missing (setup SQL not run) or offline — the listing still lives
      // locally and, if it was posted to a server, in that server's sealed
      // copy; the global row simply waits for the next publish.
    }
  }

  /// Removes a listing's global row — a deleted listing must not come back on
  /// the next fetch. Harmless for a non-listing post id (no row to delete).
  Future<void> deleteMarketListing(String postId) async {
    if (!_initialized) return;
    try {
      await _client.from(marketListingsTable).delete().eq('id', postId);
    } catch (_) {}
  }

  /// Pulls the global marketplace and feeds every listing through the normal
  /// arrival path (id/rev dedup makes replays harmless). Called on relay start
  /// and pull-to-refresh, so a brand-new account opens straight to a full
  /// marketplace and a returning one converges.
  Future<void> fetchMarketListings() async {
    if (!_initialized) return;
    try {
      final rows = await _client
          .from(marketListingsView)
          .select('payload')
          .order('updated_at', ascending: false)
          .limit(300);
      for (final row in rows) {
        final blob = row['payload'];
        if (blob is! String) continue;
        try {
          final decoded = jsonDecode(blob);
          if (decoded is Map) {
            FeedStore.instance.addRemote(
                FeedPost.fromJson(Map<String, dynamic>.from(decoded)));
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// The GLOBAL marketplace's reviews (docs/market_reviews.sql) — the exact
  /// same table shape as [marketListingsTable], for the exact same reason: a
  /// review is a public opinion on a public listing, with nothing to seal it
  /// under. Fixes the bug where a review on a global (communityId: '')
  /// listing had no branch in [sendFeedPost]'s dispatch and simply vanished
  /// after being written locally — nobody else, least of all the seller, ever
  /// saw it or was told about it.
  static const marketReviewsTable = 'market_reviews';
  static const marketReviewsView = 'market_reviews_view';

  /// Publishes (or re-publishes) one review to the global table. Needs a
  /// session, so it no-ops for a numberless account — same floor as posting a
  /// listing.
  Future<void> publishMarketReview(FeedPost post) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final phone = digits(me.phone);
    if (phone.isEmpty) return;
    final listingId = post.parentId;
    if (listingId == null || listingId.isEmpty) return;
    // The phone never rides to a world-readable table — same as a listing.
    final payload = post.toJson()..remove('authorPhone');
    final username =
        post.authorUsername == 'you' ? me.username : post.authorUsername;
    try {
      await _client.from(marketReviewsTable).upsert({
        'id': post.id,
        'listing_id': listingId,
        'author_phone': phone,
        'author_username': username,
        'payload': jsonEncode(payload),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'id');
    } catch (_) {
      // Table missing (setup SQL not run) or offline — the review still
      // lives locally; the global row simply waits for the next publish.
    }
  }

  /// Removes a review's global row. Harmless for a non-review post id.
  Future<void> deleteMarketReview(String postId) async {
    if (!_initialized) return;
    try {
      await _client.from(marketReviewsTable).delete().eq('id', postId);
    } catch (_) {}
  }

  /// Pulls every review in the global marketplace and feeds it through the
  /// normal arrival path (id dedup makes replays harmless; the existing
  /// delete-cascade in [FeedStore.addRemote] drops a review whose listing is
  /// already gone). Called alongside [fetchMarketListings] — relay start and
  /// pull-to-refresh — so a listing's reviews show up for everyone browsing
  /// it, not just the device that wrote them.
  Future<void> fetchMarketReviews() async {
    if (!_initialized) return;
    try {
      final rows = await _client
          .from(marketReviewsView)
          .select('payload')
          .order('updated_at', ascending: false)
          .limit(500);
      for (final row in rows) {
        final blob = row['payload'];
        if (blob is! String) continue;
        try {
          final decoded = jsonDecode(blob);
          if (decoded is Map) {
            FeedStore.instance.addRemote(
                FeedPost.fromJson(Map<String, dynamic>.from(decoded)));
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// The Discover directory (docs/public_servers.sql): a world-readable table of
  /// PUBLIC servers anyone can find and join without an invite. A private
  /// server is simply never listed here. The row carries the full invite
  /// snapshot (secret included) — a public server's key is world-readable by
  /// design — with the owner's phone stripped, read back through a phone-free
  /// view.
  static const serverDirectoryTable = 'server_directory';
  static const serverDirectoryView = 'server_directory_view';

  /// Publishes (or removes) a server's Discover row to match its current state:
  /// a listed, non-paid server upserts its snapshot + member count; anything
  /// else (private, paid, or gone) deletes the row. Needs a session, so it
  /// no-ops for a numberless account (which has no relay identity to own a row).
  Future<void> publishServerDirectory(String communityId) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final phone = digits(me.phone);
    if (phone.isEmpty) return;
    final community = CommunityStore.instance.byId(communityId);
    // Not listed, gone, or paid → make sure no row lingers.
    if (community == null || !community.listed || community.paid) {
      try {
        await _client.from(serverDirectoryTable).delete().eq('id', communityId);
      } catch (_) {}
      return;
    }
    final invite = CommunityStore.instance.exportInvite(
      communityId,
      myDigits: phone,
      myName: AppState.profile.value.name,
    );
    if (invite == null) return;
    try {
      await _client.from(serverDirectoryTable).upsert({
        'id': community.id,
        'owner_phone': phone,
        'name': community.name,
        'description': community.description,
        'member_count': community.members.length,
        'payload': jsonEncode(invite),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'id');
    } catch (_) {
      // Table missing (setup SQL not run) or offline — the server stays public
      // locally and the row waits for the next publish.
    }
  }

  /// Pulls the Discover directory into [ServerDirectoryStore], so a browser sees
  /// the current set of public servers. Called on relay start and when the
  /// Discover screen refreshes. Reads the phone-free view with the anon key, so
  /// even a name-only account can browse.
  Future<void> fetchServerDirectory() async {
    if (!_initialized) return;
    try {
      final rows = await _client
          .from(serverDirectoryView)
          .select('id, name, description, member_count, payload')
          .order('updated_at', ascending: false)
          .limit(300);
      final servers = <DiscoverServer>[];
      for (final row in rows) {
        final blob = row['payload'];
        if (blob is! String) continue;
        Map<String, dynamic> invite;
        try {
          final decoded = jsonDecode(blob);
          if (decoded is! Map) continue;
          invite = Map<String, dynamic>.from(decoded);
        } catch (_) {
          continue;
        }
        servers.add(DiscoverServer(
          id: (row['id'] as String?) ?? (invite['id'] as String? ?? ''),
          name: (row['name'] as String?)?.trim().isNotEmpty == true
              ? row['name'] as String
              : (invite['name'] as String? ?? 'Server'),
          description: (row['description'] as String?) ??
              (invite['description'] as String? ?? ''),
          memberCount: (row['member_count'] as num?)?.toInt() ??
              (invite['members'] as List?)?.length ??
              0,
          invite: invite,
        ));
      }
      ServerDirectoryStore.instance.setAll(servers);
    } catch (_) {}
  }

  /// Server-authoritative community structure (docs/community_structure.sql):
  /// a durable, RLS-scoped copy of a server's identity, channel list, roster,
  /// and custom roles, layered as a cache-coherence backstop over the existing
  /// peer-broadcast/mailbox/mesh protocol — see that file's header for the
  /// full rationale. None of the tables below carry message CONTENT; that
  /// stays exactly as sealed and peer-relayed as it always has.
  static const communityServersTable = 'community_servers';
  static const communityMembersTable = 'community_members';
  static const communityChannelsTable = 'community_channels';
  static const communityRolesTable = 'community_roles';
  static const communityBansTable = 'community_bans';

  /// Server-authoritative chat structure (docs/chat_structure.sql), Phase 3
  /// of "central authority" — the same backstop for 1:1 and group chats. No
  /// message content here either; see that file's header for the full
  /// rationale, including why a 1:1's phone_a/phone_b exist at all.
  static const directChatsTable = 'direct_chats';
  static const chatMembersTable = 'chat_members';

  /// sha256(secret) hex — the ONLY form of a server's content-decryption key
  /// that ever reaches the server. Matches AccountService.phoneHashHex's own
  /// client-side-hash pattern (package:crypto), just over a different input.
  static String _secretHash(String secret) =>
      sha256.convert(utf8.encode(secret)).toString();

  /// Publishes (or re-publishes, on any structural change) a server's full
  /// authoritative structure — its own row, channels, custom roles, roster,
  /// and bans. OWNER-ONLY: this is the one device whose writes the RLS
  /// policies actually allow to reshape community_channels/_roles/_members
  /// wholesale (see can_manage_community in docs/community_structure.sql),
  /// and it is also the device whose local Community is the real source of
  /// truth for a legacy (still-local-only) server. A non-owner member never
  /// calls this — see [joinCommunityAuthoritative] for how it registers
  /// itself instead. Needs a session and a minted secret; no-ops for a
  /// numberless account or a server predating secrets (nothing safe to hash).
  Future<void> publishCommunityStructure(String communityId) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final myDigits = digits(me.phone);
    if (myDigits.isEmpty) return;
    final community = CommunityStore.instance.byId(communityId);
    if (community == null || community.members.isEmpty) return;
    final ownerId = community.members.first.id;
    final ownerDigits =
        ownerId == 'me' ? myDigits : CommunityStore.digitsOfWireId(ownerId);
    if (ownerDigits != myDigits) return;
    if (community.secret.isEmpty) return;
    final secretHash = _secretHash(community.secret);
    try {
      await _client.from(communityServersTable).upsert({
        'id': community.id,
        'owner_phone': myDigits,
        'secret_hash': secretHash,
        'name': community.name,
        'color': community.color,
        'color2': community.color2,
        'icon': community.icon,
        'description': community.description,
        'slow_mode_seconds': community.slowModeSeconds,
        'members_can_create_channels': community.membersCanCreateChannels,
        'members_can_post': community.membersCanPost,
        'members_can_message': community.membersCanMessage,
        'invite_policy': community.invitePolicy,
        'banned_words': community.bannedWords,
        'paid': community.paid,
        'price_cents': community.priceCents,
        'sub_pitch': community.subPitch,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'id');

      // Channels and roles: straightforward id-keyed reconciliation. Upsert
      // every local row, then delete whatever the server still has for this
      // community that isn't in the local set any more (a deleted channel/role).
      await _reconcileById(
        table: communityChannelsTable,
        communityId: communityId,
        rows: [
          for (final c in community.channels)
            {
              'id': c.id,
              'community_id': communityId,
              'name': c.name,
              'type': c.toJson()['type'],
              'category': c.category,
              'topic': c.topic,
              'position': community.channels.indexOf(c),
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            },
        ],
      );
      await _reconcileById(
        table: communityRolesTable,
        communityId: communityId,
        rows: [
          for (final r in community.roles)
            {
              'id': r.id,
              'community_id': communityId,
              'name': r.name,
              'color': r.color,
              'tier': r.tier.name,
              'badge': r.badge,
            },
        ],
      );

      // Members: everyone but the owner (index 0) — the owner's own row is
      // seeded once by the community_servers_seed_owner trigger and the
      // members insert/update policies deliberately refuse role='owner' from
      // the client, so re-upserting it here would fail RLS. The owner's phone
      // is kept in the "don't delete" set even though it's never re-upserted.
      final keepPhones = <String>{myDigits};
      final memberRows = <Map<String, dynamic>>[];
      for (final m in community.members.skip(1)) {
        final d = CommunityStore.digitsOfWireId(m.id);
        if (d == null) {
          continue; // a local-only/demo id has no real identity to publish
        }
        keepPhones.add(d);
        memberRows.add({
          'community_id': communityId,
          'member_phone': d,
          'role': m.role.name,
          'role_id': m.roleId,
        });
      }
      await _reconcileByPhone(
        table: communityMembersTable,
        communityId: communityId,
        rows: memberRows,
        keepPhones: keepPhones,
      );

      // Bans: same phone-keyed reconciliation, no owner carve-out needed —
      // the app already refuses to let the owner be banned.
      final banPhones = <String>{};
      final banRows = <Map<String, dynamic>>[];
      for (final m in community.bannedMembers) {
        final d = CommunityStore.digitsOfWireId(m.id);
        if (d == null) continue;
        banPhones.add(d);
        banRows.add({
          'community_id': communityId,
          'member_phone': d,
          'member_name': m.name,
        });
      }
      await _reconcileByPhone(
        table: communityBansTable,
        communityId: communityId,
        rows: banRows,
        keepPhones: banPhones,
      );
    } catch (_) {
      // Table missing (setup SQL not run) or offline — the server stays
      // exactly as functional as it is today over the gossip protocol; the
      // authoritative copy simply waits for the next publish.
    }
  }

  /// Upserts [rows] (each carrying an 'id') into [table] for [communityId],
  /// then deletes whatever [table] still has for that community that isn't
  /// among [rows]' ids any more — the "rebuild deletes by omission" pattern
  /// CommunityStore.applyAuthoritativeStructure relies on when reading it
  /// back. A no-op call (empty [rows]) still runs the delete pass, which is
  /// correct: a server with zero custom roles left should end up with zero
  /// rows here too.
  Future<void> _reconcileById({
    required String table,
    required String communityId,
    required List<Map<String, dynamic>> rows,
  }) async {
    if (rows.isNotEmpty) {
      await _client.from(table).upsert(rows, onConflict: 'id');
    }
    final ids = rows.map((r) => r['id'] as String).toSet();
    final existing =
        await _client.from(table).select('id').eq('community_id', communityId);
    final stale = [
      for (final row in existing)
        if (!ids.contains(row['id'] as String?)) row['id'] as String,
    ];
    if (stale.isNotEmpty) {
      await _client.from(table).delete().inFilter('id', stale);
    }
  }

  /// Same reconciliation shape as [_reconcileById], for a table keyed by
  /// ([idColumn], member_phone) instead of a single id column. [idColumn]
  /// defaults to 'community_id' (every original call site); chat_members
  /// (docs/chat_structure.sql) is keyed by 'chat_id' instead, so it passes
  /// that explicitly rather than this file growing a second near-identical
  /// helper. [keepPhones] is the full set of phones that should survive even
  /// when [rows] itself is a subset of them (publishCommunityStructure's
  /// owner carve-out: the owner's phone is never re-upserted here, but must
  /// never be deleted either — publishChatStructure carries the same shape).
  Future<void> _reconcileByPhone({
    required String table,
    required String communityId,
    required List<Map<String, dynamic>> rows,
    required Set<String> keepPhones,
    String idColumn = 'community_id',
  }) async {
    if (rows.isNotEmpty) {
      await _client
          .from(table)
          .upsert(rows, onConflict: '$idColumn,member_phone');
    }
    final existing = await _client
        .from(table)
        .select('member_phone')
        .eq(idColumn, communityId);
    final stale = [
      for (final row in existing)
        if (!keepPhones.contains(row['member_phone'] as String?))
          row['member_phone'] as String,
    ];
    if (stale.isNotEmpty) {
      await _client
          .from(table)
          .delete()
          .eq(idColumn, communityId)
          .inFilter('member_phone', stale);
    }
  }

  /// Registers this device as a real, server-verified member of [communityId]
  /// — called opportunistically for every community already joined locally
  /// (on relay start) and right after the existing local join/invite flow.
  /// The RPC (community_join, docs/community_structure.sql) silently no-ops
  /// on a wrong hash, a per-server ban, a platform-wide lockout, or an unpaid
  /// pass on a paid server — never distinguishing which to a caller who might
  /// be probing. ON CONFLICT DO NOTHING server-side makes repeat calls (the
  /// opportunistic re-register on every start) harmless.
  Future<void> joinCommunityAuthoritative(String communityId,
      {required String secret, required String myName}) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null || secret.isEmpty) return;
    try {
      await _client.rpc('community_join', params: {
        'cid': communityId,
        'secret_hash': _secretHash(secret),
        'my_name': myName,
      });
    } catch (_) {}
  }

  /// Pulls the authoritative structure for [communityId] and reconciles this
  /// device's local copy against it (CommunityStore.applyAuthoritativeStructure).
  /// All five reads happen before anything is applied — a partial failure
  /// (one table not migrated yet, a network blip mid-read) leaves the local
  /// copy exactly as it was rather than applying a half-empty picture that
  /// would read as "everyone but you left" or "every role got deleted".
  Future<void> fetchCommunityStructure(String communityId) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final myDigits = digits(me.phone);
    if (myDigits.isEmpty) return;
    try {
      final server = await _client
          .from(communityServersTable)
          .select()
          .eq('id', communityId)
          .maybeSingle();
      if (server == null) return; // no authoritative row yet — nothing to apply
      final channels = await _client
          .from(communityChannelsTable)
          .select()
          .eq('community_id', communityId);
      final roles = await _client
          .from(communityRolesTable)
          .select()
          .eq('community_id', communityId);
      // Ordered oldest-joined-first so the owner (seeded first, by the
      // community_servers_seed_owner trigger, before anyone else can join)
      // sorts to the front — CommunityStore.applyAuthoritativeStructure also
      // re-sorts explicitly rather than trusting this order alone.
      final members = await _client
          .from(communityMembersTable)
          .select()
          .eq('community_id', communityId)
          .order('joined_at');
      final bans = await _client
          .from(communityBansTable)
          .select()
          .eq('community_id', communityId);
      CommunityStore.instance.applyAuthoritativeStructure(
        communityId: communityId,
        server: Map<String, dynamic>.from(server),
        channels: [for (final r in channels) Map<String, dynamic>.from(r)],
        roles: [for (final r in roles) Map<String, dynamic>.from(r)],
        members: [for (final r in members) Map<String, dynamic>.from(r)],
        bans: [for (final r in bans) Map<String, dynamic>.from(r)],
        myDigits: myDigits,
      );
    } catch (_) {}
  }

  /// Server-authoritative structure sync, run once per relay start: a device
  /// republishes every server it owns (so a legacy, still-local-only server
  /// gets authoritative rows the moment its owner reopens the app — see the
  /// migration note in docs/community_structure.sql) and opportunistically
  /// re-registers itself in every server it is already locally a member of.
  /// A community whose owner never opens the app again simply never gets a
  /// row here and keeps working exactly as it does today, forever.
  Future<void> _syncCommunityStructure() async {
    final me = Session.instance.user.value;
    if (me == null) return;
    final myDigits = digits(me.phone);
    if (myDigits.isEmpty) return;
    for (final community in CommunityStore.instance.communities) {
      if (community.secret.isEmpty) continue;
      final ownerId =
          community.members.isEmpty ? '' : community.members.first.id;
      final amOwner =
          ownerId == 'me' || CommunityStore.digitsOfWireId(ownerId) == myDigits;
      if (amOwner) {
        unawaited(publishCommunityStructure(community.id));
      } else {
        unawaited(joinCommunityAuthoritative(community.id,
            secret: community.secret, myName: AppState.profile.value.name));
      }
      unawaited(fetchCommunityStructure(community.id));
    }
  }

  /// Delivers a feed post to the server's members. Servers with a secret
  /// get it sealed on the community bus — members-only, offline-queued like
  /// every other server event. Only a legacy server with no secret still
  /// uses the old plaintext broadcast (kept so old builds interoperate).
  ///
  /// A listing (and each of its photo parts) is marketplace-only: it goes to
  /// the GLOBAL marketplace table and NOWHERE else — never sealed to a server
  /// feed. Every account finds it through the marketplace; servers don't carry
  /// listings. Ordinary (non-listing) posts still seal to their community.
  Future<void> sendFeedPost(FeedPost post) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    // A listing or one of its photo parts: publish to the global marketplace
    // and stop — it is not shared with any server.
    if (post.isListing || post.mediaPart > 0) {
      unawaited(publishMarketListing(post));
      return;
    }
    // A review of a listing: same rule, its own global table. This is the
    // fix — a review used to inherit its listing's communityId ('' for the
    // now-normal global listing) and fall through every branch below with
    // nowhere to go, so it never reached anyone but the reviewer's device.
    if (post.isReview) {
      unawaited(publishMarketReview(post));
      return;
    }
    final community = CommunityStore.instance.byId(post.communityId);
    if (community != null && community.secretBytes != null) {
      await _sendCommunityEvent(
          'fpost', post.communityId, {'post': post.toJson()});
      // The durable copy, alongside the live one.
      unawaited(_storeCommunityPost(community, post));
      return;
    }
    // A listing posted to NO server (the global-only path) has no bus to ride
    // and no members to broadcast to — the marketplace publish above is its
    // whole delivery. Only a real, secret-less legacy server still uses the
    // old plaintext broadcast.
    if (post.communityId.isEmpty) return;
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
  /// Seals a signaling string ([plaintext] — an SDP, ICE candidate, or group
  /// blob) into a `{c, enc, spk?, rh?}` fragment, on the SAME per-peer
  /// ratchet session chat uses: the call handshake (DTLS fingerprints, the
  /// candidate IPs) gets the same forward secrecy the messages do. (The call
  /// MEDIA is separately DTLS-SRTP encrypted by WebRTC — a layer below this.)
  Map<String, dynamic> _sealSignal(String contactPhone, String plaintext) {
    final me = Session.instance.user.value;
    return sealContent(me?.phone ?? '', contactPhone, plaintext);
  }

  /// Reverses a signaling seal for a signal received from [from]. Returns the
  /// plaintext, or null when it cannot be opened (missing key, replay).
  String? _openSignal(String from, Map<String, dynamic> fragment) {
    final me = Session.instance.user.value;
    if (fragment['c'] == null || me == null) return null;
    return openContent(from, me.phone, fragment);
  }

  /// Packs a signaling seal under a payload's per-slot keys — `sdp/senc/sspk/
  /// srh`, `ice/i…`, `grp/g…` — so one payload can carry more than one sealed
  /// blob without their fields colliding.
  Map<String, dynamic> _packSignal(
      String contactPhone, String dataKey, String letter, String plaintext) {
    final f = _sealSignal(contactPhone, plaintext);
    return {
      dataKey: f['c'],
      '${letter}enc': f['enc'],
      if (f['spk'] != null) '${letter}spk': f['spk'],
      if (f['rh'] != null) '${letter}rh': f['rh'],
    };
  }

  /// Reverses [_packSignal] for one slot.
  String? _unpackSignal(String from, Map<String, dynamic> payload,
      String dataKey, String letter) {
    final data = payload[dataKey];
    if (data is! String) return null;
    return _openSignal(from, {
      'c': data,
      'enc': payload['${letter}enc'],
      if (payload['${letter}spk'] != null) 'spk': payload['${letter}spk'],
      if (payload['${letter}rh'] != null) 'rh': payload['${letter}rh'],
    });
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
      out.addAll(_packSignal(contactPhone, 'sdp', 's', sdp));
    }
    if (ice != null) {
      out.addAll(_packSignal(contactPhone, 'ice', 'i', jsonEncode(ice)));
    }
    return out;
  }

  /// Applies one call-signaling payload, live or from the mailbox. The
  /// mailbox path exists for the VoIP wake: the offer went out while this
  /// app was CLOSED, the push rang CallKit, and the queued copy is how the
  /// woken app learns what it is answering. Stale offers are refused by
  /// timestamp — replaying a ring from an hour ago would be a ghost call.
  void _applyCallEvent(Map<String, dynamic> p, String me) {
    final from = p['from'] as String?;
    final kind = p['kind'] as String?;
    final callId = p['callId'] as String?;
    if (from == null ||
        kind == null ||
        callId == null ||
        digits(from) == digits(me)) {
      return;
    }
    if (kind == 'offer') {
      final ts = p['ts'];
      if (ts is int && DateTime.now().millisecondsSinceEpoch - ts > 90 * 1000) {
        return; // the caller gave up long ago
      }
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
              avatarColor: (groupInfo['color'] as String?) ?? '#4DB6AC',
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
  }

  /// Recovers an SDP string from a sealed signaling [payload].
  String? _openSdp(String from, Map<String, dynamic> payload) =>
      _unpackSignal(from, payload, 'sdp', 's');

  /// Recovers an ICE-candidate map from a sealed signaling [payload].
  Map<String, dynamic>? _openIce(String from, Map<String, dynamic> payload) {
    final raw = payload['ice'];
    if (raw == null) return null;
    // New sealed form: an encrypted JSON string. Legacy form: a raw Map.
    if (raw is Map) return Map<String, dynamic>.from(raw);
    final json = _unpackSignal(from, payload, 'ice', 'i');
    if (json == null) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  /// Server-authoritative call presence (docs/call_presence.sql), Phase 4 of
  /// "central authority" — the same backstop as Phase 1-3, for live calls.
  /// No message/signaling content here; see that file's header for the full
  /// rationale, including the honest limit around a guessable call_id.
  static const callRostersTable = 'call_rosters';

  /// Registers this device on [callId]'s durable roster. [dialPhones] is the
  /// REAL dial list (who was actually rung) and should be passed non-empty
  /// only by whoever is founding the call (the RLS bootstrap branch checks
  /// this — see docs/call_presence.sql); everyone joining an already-founded
  /// call passes an empty list, since only the founder's row is ever allowed
  /// to carry the real one. No-ops for a numberless account (no session) or
  /// offline (silently — the call itself is unaffected either way, since
  /// signaling and media never touch this table).
  Future<void> publishCallPresence(
    String callId, {
    required bool video,
    List<String> dialPhones = const [],
  }) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final myDigits = digits(me.phone);
    if (myDigits.isEmpty) return;
    try {
      await _client.from(callRostersTable).upsert({
        'call_id': callId,
        'member_phone': myDigits,
        if (dialPhones.isNotEmpty) 'initiator_phone': myDigits,
        if (dialPhones.isNotEmpty)
          'dial_phones': [
            for (final p in dialPhones)
              if (digits(p).isNotEmpty) digits(p)
          ],
        'member_name': me.name,
        'video': video,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'call_id,member_phone');
    } catch (_) {}
  }

  /// Reads [callId]'s durable roster and feeds it straight to
  /// [RoomMedia.updateCallPeers] — the SAME externally-fed-peer-set
  /// mechanism the live `onRemoteJoined`/`onRemoteLeft` signaling already
  /// drives, so no new RoomMedia API was needed. Wired conservatively (see
  /// CLAUDE.md): live signaling is the primary, reliable source for a call
  /// already in progress; this exists for the device that reconnects mid
  /// group-call and missed the join/leave events during the gap.
  Future<void> fetchCallPresence(String callId) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final myDigits = digits(me.phone);
    try {
      final rows =
          await _client.from(callRostersTable).select().eq('call_id', callId);
      final peers = <String>{
        for (final r in rows)
          if ((r['member_phone'] as String? ?? '') != myDigits)
            r['member_phone'] as String,
      };
      RoomMedia.instance.updateCallPeers(callId, peers);
    } catch (_) {}
  }

  /// Removes this device's own row from [callId]'s roster — the client-side
  /// half of cleanup (the other half is docs/call_presence.sql's scheduled
  /// pg_cron sweep, which catches what a force-quit or dropped connection
  /// never runs this for). Never fails loudly: a call that has already ended
  /// locally should not surface a network error to the person leaving it.
  Future<void> leaveCallRoster(String callId) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final myDigits = digits(me.phone);
    if (myDigits.isEmpty) return;
    try {
      await _client
          .from(callRostersTable)
          .delete()
          .eq('call_id', callId)
          .eq('member_phone', myDigits);
    } catch (_) {}
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
    bool queue = true,
  }) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final name = inboxChannel(contactPhone);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    // Group-call metadata (which group, who's in it) is sealed like an SDP,
    // so the relay can't tell a group call from a one-to-one one.
    final payload = {
      'from': me.phone,
      'fromName': me.name,
      'fromUsername': me.username,
      'kind': kind,
      'callId': callId,
      'video': video,
      'ts': DateTime.now().millisecondsSinceEpoch,
      if (emoji != null) 'emoji': emoji,
      if (media != null) 'media': media,
      if (group != null)
        ..._packSignal(contactPhone, 'grp', 'g', jsonEncode(group)),
      ..._sealSignalPair(contactPhone, sdp: sdp),
    };
    // Who calls whom is metadata like who messages whom — sealed the same.
    final callSealed = sealedEnvelopeFor(contactPhone, 'call', payload);
    await channel.sendBroadcastMessage(
        event: callSealed == null ? 'call' : 'sealed',
        payload: callSealed ?? payload);
    // The handshake also queues for a CLOSED app: a VoIP push rings CallKit
    // with no app running, and the mailbox is how the woken app learns what
    // it is answering. Stale offers die by the ts guard on the way back in;
    // presence-flavoured kinds (joined/reaction/media) stay live-only —
    // replayed hours later they would be nonsense. [queue] false is for
    // MID-CALL renegotiation (camera on, screen share): the peer is on the
    // call and therefore online, and a queued copy replaying on the next
    // mailbox sweep would shove a stale SDP into a live connection.
    if (queue && const {'offer', 'answer', 'end', 'decline'}.contains(kind)) {
      _mailboxPut(contactPhone, callSealed ?? payload,
          event: callSealed == null ? 'call' : 'sealed');
    }
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
    final raw = _unpackSignal(from, payload, 'grp', 'g');
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  /// Queues a "missed call" notice to [contactPhone]: broadcast for an app
  /// that is open, mailbox for one that isn't — because the live call offer
  /// is deliberately never queued (ringing someone hours late is nonsense),
  /// this notice is what makes the missed call exist on their side at all.
  Future<void> sendMissedCall(String contactPhone,
      {required String callId, required bool video}) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    await _sendInboxEvent(contactPhone, 'callmiss', {
      'from': me.phone,
      'fromName': me.name,
      'fromUsername': me.username,
      'callId': callId,
      'video': video,
    });
  }

  /// Applies a 'callmiss' notice, live or from the mailbox: files the missed
  /// call in the log and the conversation. Blocked callers are dropped the
  /// same way their ring would have been.
  void _applyMissedCall(Map<String, dynamic> p, {required String myPhone}) {
    final from = p['from'] as String?;
    if (from == null || digits(from) == digits(myPhone)) return;
    if (AppState.isBlocked(from)) return;
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
    CallService.instance.onRemoteMissed(
        peer, (p['callId'] as String?) ?? '', p['video'] == true);
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
    final payload = {
      'from': me.phone,
      'kind': 'ice',
      'callId': _currentCallId ?? '',
      'video': false,
      ..._sealSignalPair(contactPhone, ice: candidate),
    };
    final iceSealed = sealedEnvelopeFor(contactPhone, 'call', payload);
    await channel.sendBroadcastMessage(
        event: iceSealed == null ? 'call' : 'sealed',
        payload: iceSealed ?? payload);
    // Queued too: a callee waking from a VoIP push missed every live
    // candidate, and candidates are only ever signaled once. Stale ones are
    // harmless — a dead call's id matches nothing.
    _mailboxPut(contactPhone, iceSealed ?? payload,
        event: iceSealed == null ? 'call' : 'sealed');
  }

  /// The active call id, so ICE candidates can be tagged with it.
  String? _currentCallId;
  set currentCallId(String? id) => _currentCallId = id;

  /// Sealed-sender wrap for one recipient: the whole legacy (event,
  /// payload) pair moves inside an envelope only their identity key can
  /// open, so the wire and the mailbox stop saying who it is from. Null —
  /// meaning "send legacy" — until the peer has advertised it can open
  /// these AND we hold their key; anything else would lose the message.
  Map<String, dynamic>? sealedEnvelopeFor(
      String contactPhone, String event, Map<String, dynamic> payload) {
    final kx = SecureKeyExchange.instance;
    if (!kx.sealedCapable(contactPhone)) return null;
    final pub = kx.peerKey(contactPhone);
    if (pub == null) return null;
    return SealedSender.seal(pub, {'e': event, 'p': payload});
  }

  /// Broadcasts [event] to [contactPhone]'s inbox live AND queues the same
  /// payload in their offline mailbox, so edits, deletes, reactions, votes
  /// and receipts survive the peer being away exactly like messages do.
  /// Sealed when the peer can open sealed — one funnel, so no event type
  /// leaks the sender by being forgotten.
  Future<void> _sendInboxEvent(
      String contactPhone, String event, Map<String, dynamic> payload) async {
    final name = inboxChannel(contactPhone);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    final sealed = sealedEnvelopeFor(contactPhone, event, payload);
    if (sealed != null) {
      await channel.sendBroadcastMessage(event: 'sealed', payload: sealed);
      _mailboxPut(contactPhone, sealed, event: 'sealed');
      return;
    }
    await channel.sendBroadcastMessage(event: event, payload: payload);
    _mailboxPut(contactPhone, payload, event: event);
  }

  /// Broadcasts a reaction change on message [messageId] to [contactPhone].
  Future<void> sendReaction(
      String contactPhone, String messageId, String emoji, bool add) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    // A reaction deserves a buzz like a message does — only when ADDING;
    // taking one back should not light anyone's phone up. The recipient's
    // private-notifications setting still reduces it to "New message"
    // server-side, like every push.
    if (add) {
      PushService.instance.notify(contactPhone,
          title: me.name.isEmpty ? 'New reaction' : me.name,
          body: 'Reacted $emoji to your message');
    }
    await _sendInboxEvent(contactPhone, 'reaction',
        {'from': me.phone, 'id': messageId, 'emoji': emoji, 'add': add});
  }

  /// Broadcasts a poll vote on [messageId] to [contactPhone]: increments
  /// [addOption] and decrements a prior [removeOption] (-1 for none).
  /// Sends one person's answers back to whoever sent the form.
  ///
  /// Answers only — the form itself is already on their device, and echoing
  /// the questions back would put the same content through the relay twice.
  Future<void> sendFormResponse(
      String contactPhone, String messageId, List<String> answers) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    await _sendInboxEvent(contactPhone, 'form', {
      'from': me.phone,
      'id': messageId,
      'name': me.name,
      'answers': answers,
    });
  }

  Future<void> sendPollVote(String contactPhone, String messageId,
      int addOption, int removeOption) async {
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

  /// Tells [contactPhone] that [payerPhone] has paid their share of the split
  /// bill [messageId], so the bill card flips that person to paid everywhere.
  Future<void> sendBillPaid(
      String contactPhone, String messageId, String payerPhone) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    await _sendInboxEvent(contactPhone, 'billpaid', {
      'from': me.phone,
      'id': messageId,
      'payer': payerPhone,
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
  Future<void> sendViewOnceOpened(String contactPhone, String messageId) async {
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

  /// Tells [contactPhone] that the live-location share drawn from message
  /// [messageId] has ended, sealed and mailboxed like any other
  /// message-scoped event (`_sendInboxEvent`) — so it reaches them even if
  /// they're briefly offline right now, rather than only ever reading the
  /// original scheduled end time. See `ChatStore.endIncomingLiveLocation`.
  Future<void> sendLiveLocationStop(
      String contactPhone, String messageId) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    await _sendInboxEvent(
        contactPhone, 'locstop', {'from': me.phone, 'id': messageId});
  }

  /// Broadcasts your live position to [contactPhone]'s inbox for the Snap Map.
  Future<void> sendLocation(String contactPhone, double lat, double lng) async {
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

  /// Broadcasts one of my stories to my friends (1:1 contacts). Rides the
  /// sealed inbox-event rails, so it delivers live AND through the offline
  /// mailbox — a friend who was away still gets it while it's within its
  /// 24-hour window. The story text is E2E-sealed to each recipient like any
  /// other content.
  Future<void> sendStatus(StatusUpdate update) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final payload = <String, dynamic>{
      'from': me.phone,
      'id': update.id,
      'name': me.name,
      'ac': update.avatarColor,
      'text': update.text,
      'bg': update.bgColor,
      't': update.time.toIso8601String(),
    };
    final seen = <String>{};
    for (final chat in ChatStore.instance.chats) {
      final u = chat.contact;
      if (u.isGroup) continue;
      final d = digits(u.phone);
      if (d.isEmpty || d == digits(me.phone) || !seen.add(d)) continue;
      unawaited(_sendInboxEvent(u.phone, 'status', payload));
    }
  }

  /// Folds a story that arrived from a friend into the [StatusStore], dropping
  /// my own echo and anything already past the 24-hour active window.
  void applyStatus(Map<String, dynamic> payload, {required String myPhone}) {
    final from = payload['from'] as String?;
    if (from == null || digits(from) == digits(myPhone)) return;
    final text = (payload['text'] as String? ?? '').trim();
    if (text.isEmpty) return;
    final time =
        DateTime.tryParse(payload['t'] as String? ?? '') ?? DateTime.now();
    if (DateTime.now().difference(time).inHours >= 24) return;
    StatusStore.instance.addRemote(StatusUpdate(
      id: (payload['id'] as String?) ??
          'st_${digits(from)}_${time.microsecondsSinceEpoch}',
      authorId: digits(from),
      authorName: (payload['name'] as String? ?? '').trim(),
      avatarColor: payload['ac'] as String? ?? '#7A5CFF',
      text: text,
      bgColor: payload['bg'] as String? ?? '#7A5CFF',
      time: time,
    ));
  }

  /// Sends a lightweight "typing" ping to [contactPhone]'s inbox. [groupId] is
  /// set when the typing is happening in a group, so the recipient lights that
  /// group and not the 1:1 chat with the sender.
  Future<void> sendTyping(String contactPhone, {String groupId = ''}) async =>
      _ping(contactPhone, 'typing',
          extra: groupId.isEmpty ? const {} : {'g': groupId});

  /// Tells [contactPhone] that a screenshot was just taken of the
  /// conversation with them.
  ///
  /// Carries nothing but who: no image, no message id, nothing about what was
  /// on the screen. The point is that the other person finds out, which is
  /// the only thing any app can do about a screenshot.
  Future<void> sendScreenshotNotice(String contactPhone) async =>
      _ping(contactPhone, 'shot');

  /// Tells [contactPhone] that the conversation with them is being recorded
  /// or mirrored. Its own event rather than a flag on 'shot', because
  /// announcing a recording as a screenshot would be a wrong sentence.
  Future<void> sendRecordingNotice(String contactPhone) async =>
      _ping(contactPhone, 'cap');

  /// Tells [contactPhone] that their ghost message, open on screen right
  /// then, was screenshotted. Its own event for the same reason as 'cap':
  /// "they screenshotted the chat" and "they kept the message you sent to
  /// be read once" are different sentences.
  Future<void> sendGhostShotNotice(String contactPhone) async =>
      _ping(contactPhone, 'gshot');

  /// Tests observe outgoing presence here — the real send needs a live
  /// relay client, which the suite never has.
  @visibleForTesting
  static void Function(String contactPhone, String where)?
      debugPresenceSendOverride;

  /// Sends a presence ping to [contactPhone]'s inbox. [where] is 'chat'
  /// (looking at the conversation with them — what ChatScreen sends) or
  /// 'app' (open somewhere else — the answer-pong). Older builds ignore the
  /// field and read either as "online", which both honestly are.
  Future<void> sendPresence(String contactPhone, {String where = 'chat'}) {
    final observe = debugPresenceSendOverride;
    if (observe != null) {
      observe(contactPhone, where);
      return Future.value();
    }
    return _ping(contactPhone, 'presence', extra: {'where': where});
  }

  /// Tells the other members of [group] that this device is looking at the
  /// group chat NOW — a live "who's here" ping fanned out to the roster,
  /// carrying only the group id (the reader resolves names from its own
  /// roster). Same live-only shape as [sendPresence]; not mailboxed.
  Future<void> sendGroupPresence(Chat group) async {
    for (final phone in groupRecipients(group)) {
      await _ping(phone, 'gpres', extra: {'g': group.id});
    }
  }

  /// Bumped when the far end says they screenshotted the conversation;
  /// [screenshotFromDigits] is whose. Same shape as the typing ping, because
  /// it is the same kind of thing: a fact about a conversation with no
  /// message behind it.
  final ValueNotifier<int> screenshotPing = ValueNotifier<int>(0);
  String screenshotFromDigits = '';

  /// The same, for a screen recording rather than a single screenshot.
  final ValueNotifier<int> recordingPing = ValueNotifier<int>(0);
  String recordingFromDigits = '';

  /// The same, for a screenshot of a ghost message specifically.
  final ValueNotifier<int> ghostShotPing = ValueNotifier<int>(0);
  String ghostShotFromDigits = '';

  Future<void> _ping(String contactPhone, String event,
      {Map<String, dynamic> extra = const {}}) async {
    if (!_initialized || digits(contactPhone).isEmpty) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final name = inboxChannel(contactPhone);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    final payload = {'from': me.phone, ...extra};
    // Pings seal too, or typing and presence would keep drawing the very
    // graph the sealed messages hide — the event NAME on the channel is
    // metadata all by itself.
    final sealed = sealedEnvelopeFor(contactPhone, event, payload);
    if (sealed != null) {
      await channel.sendBroadcastMessage(event: 'sealed', payload: sealed);
      return;
    }
    await channel.sendBroadcastMessage(event: event, payload: payload);
  }

  /// Pushes the signed-in user's current profile to every 1:1 contact NOW,
  /// instead of waiting for it to piggyback on the next message. Call it right
  /// after a profile edit or a verification change — otherwise a new avatar,
  /// bio or badge only appears on the other side whenever you next happen to
  /// message them, which reads as "the chat takes a while to update".
  ///
  /// Same gated fields the message path shares, and sent ONLY sealed: a peer
  /// we can seal to is a peer on a current build that has the 'prof' handler,
  /// so a peer we can't seal to would drop it anyway — and sealing keeps a
  /// profile broadcast from doing what the message path is careful not to do,
  /// which is put these fields on the wire in the clear. Those peers still get
  /// the update the old way, on the next message. Fire-and-forget; a no-op
  /// before the relay is initialized (tests, restore).
  Future<void> broadcastProfile() async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    // Every recipient here is already a contact (we hold a chat with them), so
    // the "my contacts" audience shares; "nobody" still withholds.
    final avatarColor = gatedProfileField(
        AppState.profilePhotoAudience.value, me.avatarColor, true);
    final about =
        gatedProfileField(AppState.aboutAudience.value, me.about, true);
    final inner = <String, dynamic>{
      'from': me.phone,
      'fromName': me.name,
      'fromUsername': me.username,
      'fromAvatarColor': avatarColor,
      'fromAvatarColor2': avatarColor.isEmpty ? '' : me.avatarColor2,
      'fromBannerColor': avatarColor.isEmpty ? '' : me.bannerColor,
      'fromLocation': about.isEmpty ? '' : me.location,
      'fromAbout': about,
      'fromEmoji': avatarColor.isEmpty ? '' : me.emoji,
      'fromAvatarSeed': avatarColor.isEmpty ? '' : me.avatarSeed,
      'fromPronouns': about.isEmpty ? '' : me.pronouns,
      'fromLink': about.isEmpty ? '' : me.link,
      'fromVerified': me.verified,
      'fromScore': AppState.shareScore.value ? ScoreStore.instance.points : 0,
      'fromBusiness': me.isBusiness,
      'fromBusinessCategory': me.isBusiness ? me.businessCategory : '',
      'fromBusinessHours': me.isBusiness ? me.businessHours : '',
      'fromSubscribable': me.subscribable,
      'fromSubscriptionTier': me.subscribable ? me.subscriptionTier : 0,
      'fromSubscriptionPitch': me.subscribable ? me.subscriptionPitch : '',
      'fromSubscriptionTiers': me.subscribable ? me.subscriptionTiersJson : '',
      'fromLightningAddress': me.lightningAddress,
    };
    for (final chat in ChatStore.instance.allChats) {
      if (chat.contact.isGroup) continue;
      final phone = chat.contact.phone;
      if (digits(phone).isEmpty) continue;
      final sealed = sealedEnvelopeFor(phone, 'prof', inner);
      if (sealed == null) continue; // older peer — the next message carries it
      final name = inboxChannel(phone);
      final channel =
          _sendChannels.putIfAbsent(name, () => _client.channel(name));
      await channel.sendBroadcastMessage(event: 'sealed', payload: sealed);
      _mailboxPut(phone, sealed, event: 'sealed');
    }
  }

  /// Broadcasts an outgoing [message] to [contactPhone]'s inbox over REST (the
  /// channel is never subscribed, so we can't see their other traffic). Uses
  /// the ECDH key when the peer's public key is known, otherwise falls back to
  /// the phone-derived key and kicks off a key exchange for next time.
  /// The push preview for [message], sealed to [contactPhone], or '' when
  /// there is nothing to seal or no key to seal it with.
  ///
  /// The key comes from the static ECDH secret both devices already share, so
  /// there is no new exchange and nothing to go stale — but it does mean a
  /// peer whose identity key this device has never seen gets no preview, and
  /// that is the correct outcome: the alternative is sending the words in the
  /// clear to a device that cannot open a sealed one.
  ///
  /// Only the TEXT is previewed. A photo or a voice note already has an
  /// honest content-free label ("📷 Photo"), and a caption is the one part of
  /// a media message that could carry something the sender assumed was
  /// private in a different way.
  String _sealedPreviewFor(String contactPhone, Message message) {
    if (message.typeLabel.isNotEmpty) return '';
    final text = message.text.trim();
    if (text.isEmpty) return '';
    final peerPub = SecureKeyExchange.instance.peerKey(contactPhone);
    if (peerPub == null) return '';
    final secret = SecureKeyExchange.instance.sharedSecretWith(peerPub);
    if (secret == null) return '';
    try {
      return NotificationPreview.seal(NotificationPreview.keyFor(secret), text);
    } catch (_) {
      // A preview is a nicety; a send is not. Never let sealing one stop a
      // message from going out.
      return '';
    }
  }

  /// When [group] is set the message is addressed to that group thread on the
  /// recipient's device instead of a one-to-one chat with you.
  Future<void> send(String contactPhone, Message message, {Chat? group}) async {
    if (!_initialized) return;
    // A contact without a number (e.g. the note-to-self chat) has no inbox.
    if (digits(contactPhone).isEmpty) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    // Also nudge their device over APNs (no-op unless push is configured).
    // The title names the sender (accepted Apple-side metadata); the body says
    // WHAT kind of message arrived — "📷 Photo", "🎤 Voice message" — so the
    // banner isn't a flat "New message". It is NEVER the message text: that is
    // the one place it would be trivially easy to hand Apple the plaintext, and
    // a test pins that the notify call reads nothing off the message. So the
    // label is a content-free TYPE only; a plain text message carries no body
    // and shows just the sender (the in-app Alerts list, on-device, has the
    // real words). typeLabel is hoisted into a local so the notify args stay
    // clean of `message.`.
    final sender = me.name.isEmpty ? 'New message' : me.name;
    final typeLabel = message.typeLabel;
    final pushBody = typeLabel.isEmpty ? null : typeLabel;
    // ...and the words themselves, SEALED, so the recipient's Notification
    // Service Extension can put them on the banner while the relay and Apple
    // carry bytes they cannot read. The two above are the fallback and stay
    // exactly as content-free as before: a recipient on an older build has
    // no extension, so what it shows must still be safe on its own.
    PushService.instance.notify(contactPhone,
        title: group == null ? sender : '$sender • ${group.contact.name}',
        body: pushBody,
        preview: _sealedPreviewFor(contactPhone, message));

    final kx = SecureKeyExchange.instance;
    final peerPub = kx.peerKey(contactPhone);
    if (peerPub == null || !kx.isReady) {
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
      fromAvatarColor2: avatarColor.isEmpty ? '' : me.avatarColor2,
      fromBannerColor: avatarColor.isEmpty ? '' : me.bannerColor,
      fromLocation: about.isEmpty ? '' : me.location,
      // Ungated on purpose: marking the account a business IS the decision
      // to announce it — a storefront that hides from strangers isn't one.
      fromBusiness: me.isBusiness,
      fromBusinessCategory: me.isBusiness ? me.businessCategory : '',
      fromBusinessHours: me.isBusiness ? me.businessHours : '',
      // Ungated like the business flag: offering a subscription IS the
      // decision to announce it. Tier/pitch clear when it's off, so a
      // former creator stops advertising a price at the receiver.
      fromSubscribable: me.subscribable,
      fromSubscriptionTier: me.subscribable ? me.subscriptionTier : 0,
      fromSubscriptionPitch: me.subscribable ? me.subscriptionPitch : '',
      fromSubscriptionTiers: me.subscribable ? me.subscriptionTiersJson : '',
      // Ungated too: entering a tip address IS publishing it, and sent even
      // when empty so taking it down clears it on every contact card.
      fromLightningAddress: me.lightningAddress,
      fromAbout: about,
      fromEmoji: avatarColor.isEmpty ? '' : me.emoji,
      fromAvatarSeed: avatarColor.isEmpty ? '' : me.avatarSeed,
      fromPronouns: about.isEmpty ? '' : me.pronouns,
      fromLink: about.isEmpty ? '' : me.link,
      fromVerified: me.verified,
      // Withheld rather than zeroed at the far end: a field that never
      // leaves is a field nobody has to be trusted with.
      fromScore: AppState.shareScore.value ? ScoreStore.instance.points : 0,
      fromStreak: AppState.shareStreak.value ? streak : 0,
      toPhone: contactPhone,
      groupId: group?.id ?? '',
      groupName: group?.contact.name ?? '',
      groupMembers: group?.members ?? const [],
      // sealContent inside encode picks the ratchet / ECDH / static ladder
      // off the key exchange itself; the default DoubleRatchet.instance is
      // what it reaches for.
    );
    // Record which rung the ladder actually landed on, so the Message info
    // dialog reports the key this message really went out under rather than
    // the one the chat happens to be on when somebody opens the dialog. The
    // store lowers only: a group send calls this once per member, and the
    // weakest delivery is the honest answer for the message as a whole.
    ChatStore.instance.noteMessageEnc(
      group?.id ?? myChat?.id ?? '',
      message.id,
      EncryptionLabel.codeOf(EncryptionLabel.fromWire(payload['enc'])),
    );
    // Sealed sender when the peer can open it: the wire and the mailbox
    // row stop saying who the message is from. The legacy shape otherwise
    // — it carries the sv advertisement that upgrades the pair.
    final sealedEnvelope = sealedEnvelopeFor(contactPhone, 'msg', payload);
    if (sealedEnvelope != null) {
      await channel.sendBroadcastMessage(
          event: 'sealed', payload: sealedEnvelope);
      _mailboxPut(contactPhone, sealedEnvelope, event: 'sealed');
    } else {
      await channel.sendBroadcastMessage(event: 'msg', payload: payload);
      // Also queue the sealed envelope so an offline recipient still gets
      // it the next time their app opens — the store-and-forward every
      // messenger relies on, holding only ciphertext the server can't read.
      _mailboxPut(contactPhone, payload);
    }
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

  /// Publishes a GROUP's full authoritative structure — its own row and
  /// its whole roster. Called from [sendGroupUpdate], the one funnel every
  /// structural change (create, rename, add member, remove member) already
  /// goes through, so there is nowhere new to remember to wire this in. A
  /// group's id ('group_${epochMicroseconds}') is exactly as guessable as a
  /// Community.id — see docs/chat_structure.sql's header — so the OWNER is
  /// the only device that ever republishes the whole roster wholesale; a
  /// non-owner member's own add/remove writes still reach the table (they
  /// have chat_members insert privilege too), this function just isn't how
  /// they do it. No-ops for a 1:1 (nothing to publish beyond existence,
  /// handled separately by [publishDirectChatExistence]) or a numberless
  /// account (no session to publish under).
  Future<void> publishChatStructure(Chat group) async {
    if (!_initialized || !group.contact.isGroup) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final myDigits = digits(me.phone);
    if (myDigits.isEmpty || group.members.isEmpty) return;
    final ownerDigits = digits(group.members.first.phone);
    if (ownerDigits != myDigits) return;
    try {
      await _client.from(directChatsTable).upsert({
        'id': group.id,
        'is_group': true,
        'owner_phone': myDigits,
        'name': group.contact.name,
        'avatar_color': group.contact.avatarColor,
        'about': group.contact.about,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'id');

      final keepPhones = <String>{myDigits};
      final memberRows = <Map<String, dynamic>>[];
      for (final m in group.members.skip(1)) {
        final d = digits(m.phone);
        if (d.isEmpty) continue; // no real identity to publish
        keepPhones.add(d);
        memberRows.add({'chat_id': group.id, 'member_phone': d});
      }
      await _reconcileByPhone(
        table: chatMembersTable,
        communityId: group.id,
        idColumn: 'chat_id',
        rows: memberRows,
        keepPhones: keepPhones,
      );
    } catch (_) {
      // Table missing (setup SQL not run) or offline — the chat stays
      // exactly as functional as it is today over gossip; the authoritative
      // copy simply waits for the next publish.
    }
  }

  /// Registers a 1:1's existence — called ONCE, the first time either side
  /// sends a message in it (see ChatScreen._deliver's `_publishedDm` guard).
  /// Unlike a group there is nothing to update afterward: name/avatar/about
  /// are deliberately never populated for a 1:1 (docs/chat_structure.sql's
  /// header explains why), and is_group/owner_phone/phone_a/phone_b are
  /// immutable by design — so this is insert-once, `on conflict do nothing`,
  /// never an upsert. [peerDigits] is ordered against [myDigits] before
  /// writing so both sides of the pair independently compute the identical
  /// (phone_a, phone_b) pair regardless of who publishes first.
  Future<void> publishDirectChatExistence(
      String chatId, String peerDigits) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final myDigits = digits(me.phone);
    final peer = digits(peerDigits);
    if (myDigits.isEmpty || peer.isEmpty || myDigits == peer) return;
    final a = myDigits.compareTo(peer) <= 0 ? myDigits : peer;
    final b = myDigits.compareTo(peer) <= 0 ? peer : myDigits;
    try {
      await _client.from(directChatsTable).upsert({
        'id': chatId,
        'is_group': false,
        'phone_a': a,
        'phone_b': b,
      }, onConflict: 'id', ignoreDuplicates: true);
      await _client.from(chatMembersTable).upsert(
        {'chat_id': chatId, 'member_phone': myDigits},
        onConflict: 'chat_id,member_phone',
      );
    } catch (_) {}
  }

  /// Pulls the authoritative structure for [chatId] and reconciles this
  /// device's local copy against it (ChatStore.applyAuthoritativeChatStructure).
  Future<void> fetchChatStructure(String chatId) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    try {
      final chat = await _client
          .from(directChatsTable)
          .select()
          .eq('id', chatId)
          .maybeSingle();
      if (chat == null) return; // no authoritative row yet — nothing to apply
      final members =
          await _client.from(chatMembersTable).select().eq('chat_id', chatId);
      ChatStore.instance.applyAuthoritativeChatStructure(
        chatId: chatId,
        chat: Map<String, dynamic>.from(chat),
        members: [for (final r in members) Map<String, dynamic>.from(r)],
      );
    } catch (_) {}
  }

  /// Server-authoritative chat structure sync, run once per relay start: a
  /// device republishes every GROUP it owns (so a legacy, still-local-only
  /// group gets authoritative rows the moment its owner reopens the app) and
  /// fetches the current structure for every group and 1:1 it already has
  /// locally. A 1:1 with no authoritative row yet simply isn't republished
  /// here — its existence is published once, from the first message sent in
  /// it (see [publishDirectChatExistence]), not on every relay start.
  Future<void> _syncChatStructure() async {
    final me = Session.instance.user.value;
    if (me == null) return;
    final myDigits = digits(me.phone);
    if (myDigits.isEmpty) return;
    for (final chat in ChatStore.instance.allChats) {
      if (chat.contact.isGroup) {
        final ownerDigits =
            chat.members.isEmpty ? '' : digits(chat.members.first.phone);
        if (ownerDigits == myDigits) unawaited(publishChatStructure(chat));
      }
      unawaited(fetchChatStructure(chat.id));
    }
  }

  /// Pushes a group edit (new name or roster) to the other members so their
  /// copies follow without waiting for the next message. Someone added this
  /// way gets the group created on their device by the same code path an
  /// incoming group message uses.
  Future<void> sendGroupUpdate(Chat group,
      {List<String>? extraRecipients}) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    // The one funnel every structural change (create, rename, add/remove a
    // member) already passes through — see [publishChatStructure]'s own doc
    // comment for why this is the whole wiring, not one of several sites.
    unawaited(publishChatStructure(group));
    final recipients = <String>{
      ...groupRecipients(group),
      ...?extraRecipients,
    }..removeWhere((p) => digits(p).isEmpty || digits(p) == digits(me.phone));
    final blob = jsonEncode({
      'groupId': group.id,
      'groupName': group.contact.name,
      'groupAbout': group.contact.about,
      'groupMembers': group.members.map(_memberSummary).toList(),
    });
    for (final phone in recipients) {
      // The same pairwise ladder messages ride — ratchet first, sealed once
      // per recipient. applyGroupUpdate decodes it through _decodeContent,
      // which already understands every rung.
      await _sendInboxEvent(phone, 'gupd', {
        'from': me.phone,
        ...sealContent(me.phone, phone, blob),
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

  /// Applies a peer's key (re)introduction, wherever it arrived — the live
  /// broadcast, or the mailbox when a heal was queued for a device that was
  /// closed at the time.
  void applyKeyEvent(Map<String, dynamic> payload, {required String myPhone}) {
    final from = payload['from'] as String?;
    final pub = payload['pub'] as String?;
    if (from == null || pub == null || digits(from) == digits(myPhone)) {
      return;
    }
    final changed = SecureKeyExchange.instance.rememberPeer(from, pub);
    // A CHANGED key buries the ratchet session: the old one belongs to an
    // identity that no longer exists, and holding it means sealing every
    // future message to a ghost — which the far end renders as a screen
    // of base64. A HEAL buries it even when the key matches what is cached:
    // the far side just failed to open something this side sealed, and with
    // the same identity on both ends the only state left to blame is a
    // diverged session. That case used to be unfixable — the heal arrived,
    // matched, and did nothing, forever. Burial is rate-limited so a
    // replayed heal envelope cannot keep killing healthy new sessions.
    if (changed || (payload['heal'] == true && _healBuryAllowed(from))) {
      DoubleRatchet.instance.resetPeer(from);
      _sentKeyTo.remove(digits(from));
    }
    // Reply with our key once so both sides can derive the secret.
    _ensureKeyShared(from);
  }

  final Map<String, DateTime> _healBuried = {};
  bool _healBuryAllowed(String from) {
    final d = digits(from);
    final last = _healBuried[d];
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 2)) {
      return false;
    }
    _healBuried[d] = DateTime.now();
    return true;
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
      payload: {
        'from': Session.instance.user.value?.phone,
        'pub': kx.myPublicKey
      },
    );
  }

  /// Recovers live delivery after the app was suspended. iOS freezes the
  /// process in the background and the Realtime socket dies out from under
  /// the joined channels — and depending on how it died, the client can sit
  /// on a stale "joined" state until a heartbeat notices, long after the
  /// user is staring at the chat wondering why nothing arrives. Deterministic
  /// beats eventual here: tear the channels down, rejoin over a fresh
  /// socket, and drain the mailbox for everything sent while the socket was
  /// dead. Safe to call any time — it no-ops unless start() already ran.
  Future<void> wake() async {
    if (!_initialized || _inbox == null) return;
    final inbox = _inbox;
    final feed = _feedChannel;
    _inbox = null;
    _feedChannel = null;
    try {
      if (inbox != null) await _client.removeChannel(inbox);
      if (feed != null) await _client.removeChannel(feed);
    } catch (_) {}
    // The send channels never joined the socket (an unsubscribed channel
    // broadcasts over HTTP), so they survive the rebuild untouched.
    start(); // rebuilds both subscriptions and drains the mailbox
  }

  /// When something from [from] cannot be decrypted, re-introduce this
  /// device's CURRENT identity key, bypassing the once-per-run cache. The
  /// usual cause is their device sealing to a key this one no longer holds
  /// (an account switch minted a fresh identity); the moment their side
  /// sees the changed key it buries its stale session, and everything after
  /// arrives readable. Rate-limited per peer, and deliberately does nothing
  /// destructive here: a replayed envelope also fails to decrypt, and a
  /// healthy pairing must shrug this off.
  final Map<String, DateTime> _healAsked = {};
  final Map<String, int> _healAttempts = {};
  void healPeer(String from) {
    final d = digits(from);
    if (d.isEmpty) return;
    // Counted before every guard: the diagnosis matters even when the
    // network half cannot run, and a THIRD failure in one run means the
    // repair is being sent and not taking — which has exactly one cause a
    // heal can never fix, and it deserves to be said instead of leaving the
    // padlocks to read as random breakage.
    final attempts = (_healAttempts[d] ?? 0) + 1;
    _healAttempts[d] = attempts;
    if (attempts == 3) _noteUnhealablePeer(d);
    if (!_initialized) return;
    final last = _healAsked[d];
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 2)) {
      return;
    }
    _healAsked[d] = DateTime.now();
    final kx = SecureKeyExchange.instance;
    if (!kx.isReady) return;
    // The re-introduction, marked as a HEAL so the far side buries its
    // session even when the key it holds already matches — a plain announce
    // must never carry the flag, or every startup would kill healthy
    // sessions. Public material only: from-digits and a public key, both of
    // which the broadcast already carries in the clear.
    final payload = {
      'from': Session.instance.user.value?.phone,
      'pub': kx.myPublicKey,
      'heal': true,
    };
    _sentKeyTo.add(d);
    final name = inboxChannel(from);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    channel.sendBroadcastMessage(event: 'key', payload: payload);
    // The live broadcast only reaches an OPEN app — and the peer who sealed
    // to a ghost key almost certainly is not looking at theirs right now,
    // which is why the same failure came back hours apart instead of once.
    // Queue the re-introduction too, so their next launch applies it before
    // they send anything else.
    _mailboxPut(from, payload, event: 'key');
  }

  /// Said once per run, after the third failed unlock from the same person:
  /// the repair keeps being sent and keeps not taking. The one cause a heal
  /// cannot fix is the same number signed in somewhere else — a second
  /// phone, or a web tab — because each sign-in mints its own keys and the
  /// peer can only seal to one of them at a time.
  void _noteUnhealablePeer(String d) {
    final store = ChatStore.instance;
    Chat? chat;
    for (final c in store.allChats) {
      if (!c.contact.isGroup && digits(c.contact.phone) == d) {
        chat = c;
        break;
      }
    }
    if (chat == null) return;
    final noticeId = 'healnote_$d';
    if (chat.messages.any((m) => m.id == noticeId)) return;
    store.addMessage(
      chat.id,
      Message(
        id: noticeId,
        text: 'ℹ️ Messages here keep arriving sealed to a key this device '
            'doesn\'t hold, and the automatic repair hasn\'t taken. This '
            'usually means one of you is signed in on another phone or a '
            'web browser too — each sign-in has its own keys, so a message '
            'can only be unlocked where it was keyed. Sign out of the '
            'copies not in use, then ask them to resend.',
        time: DateTime.now(),
        isMe: false,
        status: MessageStatus.read,
      ),
    );
  }

  /// Re-establishes the inbox subscription and re-announces presence to the
  /// people you have chats with. Backs pull-to-refresh: it gives the relay a
  /// nudge so a device that just came online re-syncs delivery and presence.
  Future<void> resync() async {
    if (!_initialized) return;
    // Rebuild the live subscription rather than trusting it: the one time a
    // user pulls to refresh is exactly when it has silently died.
    await wake();
    start(); // first-run path: wake() no-ops before start() has ever run
    // Anything sent while this device was away is waiting in the mailbox.
    // (wake() started a drain already; the dedup + claimed-row delete make
    // the overlap safe, and this one can be awaited.)
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
    _socketWatch?.cancel();
    _socketWatch = null;
    final inbox = _inbox;
    _inbox = null;
    if (inbox != null) await _client.removeChannel(inbox);
    final feed = _feedChannel;
    _feedChannel = null;
    if (feed != null) await _client.removeChannel(feed);
    for (final channel in _sendChannels.values) {
      await _client.removeChannel(channel);
    }
    _sendChannels.clear();
    _sentKeyTo.clear();
  }
}
