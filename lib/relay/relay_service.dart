import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../crypto/e2e.dart';
import '../crypto/key_exchange.dart';
import '../models/chat.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../state/call_service.dart';
import '../state/chat_store.dart';
import '../state/file_transfer.dart';
import '../state/session.dart';
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

  /// Builds the broadcast payload for an outgoing message. The text is end-to-
  /// end encrypted so the relay forwards ciphertext it cannot read:
  ///
  ///  * enc 2 — AES-256-GCM keyed by an ECDH shared secret ([ecdhSecret]); the
  ///    sender's public key rides along as `spk` so the recipient can derive
  ///    the same secret. This is the strong path, used once keys are exchanged.
  ///  * enc 1 — AES-256-GCM keyed by the phone-number-derived secret (the
  ///    fallback until the ECDH handshake completes).
  ///  * enc 0 — plaintext (no recipient / empty body).
  static Map<String, dynamic> encode({
    required Message message,
    required String fromPhone,
    required String fromName,
    String fromUsername = '',
    String toPhone = '',
    List<int>? ecdhSecret,
    String? senderPublicKey,
  }) {
    var text = message.text;
    var enc = 0;
    String? spk;
    if (text.isNotEmpty && ecdhSecret != null && senderPublicKey != null) {
      text = E2eCrypto.encrypt(ecdhSecret, message.text);
      enc = 2;
      spk = senderPublicKey;
    } else if (toPhone.isNotEmpty && text.isNotEmpty) {
      text = E2eCrypto.encrypt(E2eCrypto.keyFor(fromPhone, toPhone), message.text);
      enc = 1;
    }
    return {
      'id': message.id,
      'from': fromPhone,
      'fromName': fromName,
      'fromUsername': fromUsername,
      'text': text,
      'enc': enc,
      if (spk != null) 'spk': spk,
      'ts': message.time.toIso8601String(),
      'isImage': message.isImage,
      'imageSeed': message.imageSeed,
      'imageUrl': message.imageUrl,
      'isVoice': message.isVoice,
      'voiceSeconds': message.voiceSeconds,
    };
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

    var chat = target.chatWithContact(from);
    if (chat == null) {
      final contact = AppUser(
        id: from,
        name: (payload['fromName'] as String?)?.trim().isNotEmpty == true
            ? payload['fromName'] as String
            : from,
        avatarColor: '#7A5CFF',
        about: 'Available',
        phone: from,
        username: (payload['fromUsername'] as String?) ?? '',
      );
      chat = Chat(id: 'chat_$from', contact: contact, messages: const []);
      target.upsert(chat);
    }

    final existing = target.chatById(chat.id);
    if (existing != null && existing.messages.any((m) => m.id == id)) {
      return false;
    }

    var text = (payload['text'] as String?) ?? '';
    // enc may arrive as int or bool depending on JSON transport.
    final encRaw = payload['enc'];
    if (text.isNotEmpty) {
      if (encRaw == 2 || encRaw == '2') {
        // ECDH path: derive the shared secret from the sender's public key.
        final spk = payload['spk'] as String?;
        final secret = spk == null
            ? null
            : SecureKeyExchange.instance.sharedSecretWith(spk);
        if (secret != null) {
          text = E2eCrypto.decrypt(secret, text) ?? text;
          if (spk != null) SecureKeyExchange.instance.rememberPeer(from, spk);
        }
      } else if (encRaw == 1 || encRaw == true) {
        text = E2eCrypto.decrypt(E2eCrypto.keyFor(from, myPhone), text) ?? text;
      }
    }

    target.addMessage(
      chat.id,
      Message(
        id: id,
        text: text,
        time: DateTime.tryParse(payload['ts'] as String? ?? '')?.toLocal() ??
            DateTime.now(),
        isMe: false,
        status: MessageStatus.delivered,
        isImage: payload['isImage'] as bool? ?? false,
        imageSeed: payload['imageSeed'] as int? ?? 0,
        imageUrl: payload['imageUrl'] as String?,
        isVoice: payload['isVoice'] as bool? ?? false,
        voiceSeconds: payload['voiceSeconds'] as int? ?? 0,
      ),
    );
    return true;
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
  void start() {
    if (!_initialized || _inbox != null) return;
    final me = Session.instance.user.value?.phone;
    if (me == null) return;
    _inbox = _client
        .channel(inboxChannel(me))
        .onBroadcast(
          event: 'msg',
          callback: (payload) {
            final map = Map<String, dynamic>.from(payload);
            final added = applyIncoming(map, myPhone: me);
            final from = map['from'] as String?;
            if (from != null) {
              // Cache the sender's public key (rides on enc-2 messages) and
              // make sure they have ours, so replies upgrade to the ECDH path.
              final spk = map['spk'] as String?;
              if (spk != null) SecureKeyExchange.instance.rememberPeer(from, spk);
              _ensureKeyShared(from);
            }
            // Acknowledge delivery so the sender's ticks advance.
            if (added && from != null) sendReceipt(from, 'delivered');
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
          event: 'receipt',
          callback: (payload) {
            final from = payload['from'] as String?;
            if (from == null || digits(from) == digits(me)) return;
            final chat = ChatStore.instance.chatWithContact(from);
            if (chat == null) return;
            final status = payload['kind'] == 'read'
                ? MessageStatus.read
                : MessageStatus.delivered;
            ChatStore.instance.setOutgoingStatus(chat.id, status);
          },
        )
        .onBroadcast(
          event: 'edit',
          callback: (payload) {
            final from = payload['from'] as String?;
            final id = payload['id'] as String?;
            if (from == null || id == null || digits(from) == digits(me)) return;
            final chat = ChatStore.instance.chatWithContact(from);
            if (chat != null) {
              ChatStore.instance
                  .editMessage(chat.id, id, (payload['text'] as String?) ?? '');
            }
          },
        )
        .onBroadcast(
          event: 'delete',
          callback: (payload) {
            final from = payload['from'] as String?;
            final id = payload['id'] as String?;
            if (from == null || id == null || digits(from) == digits(me)) return;
            final chat = ChatStore.instance.chatWithContact(from);
            if (chat != null) ChatStore.instance.deleteMessage(chat.id, id);
          },
        )
        .onBroadcast(
          event: 'reaction',
          callback: (payload) {
            final from = payload['from'] as String?;
            final id = payload['id'] as String?;
            final emoji = payload['emoji'] as String?;
            if (from == null ||
                id == null ||
                emoji == null ||
                digits(from) == digits(me)) {
              return;
            }
            final chat = ChatStore.instance.chatWithContact(from);
            if (chat != null) {
              ChatStore.instance.setReactionState(
                  chat.id, id, emoji, payload['add'] as bool? ?? true);
            }
          },
        )
        .onBroadcast(
          event: 'call',
          callback: (payload) {
            final from = payload['from'] as String?;
            final kind = payload['kind'] as String?;
            final callId = payload['callId'] as String?;
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
                  name: (payload['fromName'] as String?)?.trim().isNotEmpty ==
                          true
                      ? payload['fromName'] as String
                      : from,
                  avatarColor: '#7A5CFF',
                  about: 'Available',
                  phone: from,
                  username: (payload['fromUsername'] as String?) ?? '',
                );
                call.onRemoteOffer(peer, callId, payload['video'] == true,
                    sdp: payload['sdp'] as String?);
                break;
              case 'answer':
                call.onRemoteAnswer(callId, sdp: payload['sdp'] as String?);
                break;
              case 'ice':
                final ice = payload['ice'];
                if (ice is Map) {
                  call.onRemoteIce(
                      callId, Map<String, dynamic>.from(ice));
                }
                break;
              case 'decline':
                call.onRemoteDecline(callId);
                break;
              case 'end':
                call.onRemoteEnd(callId);
                break;
            }
          },
        )
        .onBroadcast(
          event: 'file',
          callback: (payload) {
            final from = payload['from'] as String?;
            final kind = payload['kind'] as String?;
            if (from == null || kind == null || digits(from) == digits(me)) {
              return;
            }
            final ft = FileTransfer.instance;
            switch (kind) {
              case 'offer':
                ft.onRemoteOffer(
                  from,
                  (payload['fromName'] as String?) ?? from,
                  (payload['transferId'] as String?) ?? '',
                  (payload['fileName'] as String?) ?? 'file',
                  (payload['size'] as num?)?.toInt() ?? 0,
                  (payload['sdp'] as String?) ?? '',
                );
                break;
              case 'answer':
                ft.onRemoteAnswer((payload['sdp'] as String?) ?? '');
                break;
              case 'ice':
                final ice = payload['ice'];
                if (ice is Map) ft.onRemoteIce(Map<String, dynamic>.from(ice));
                break;
              case 'decline':
                ft.onRemoteDecline();
                break;
            }
          },
        )
        .subscribe();
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
    await channel.sendBroadcastMessage(
      event: 'file',
      payload: {
        'from': me.phone,
        'fromName': me.name,
        'kind': kind,
        'transferId': transferId ?? _currentFileId ?? '',
        if (sdp != null) 'sdp': sdp,
        if (ice != null) 'ice': ice,
        if (fileName != null) 'fileName': fileName,
        if (size != null) 'size': size,
      },
    );
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
  }) async {
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
        'fromName': me.name,
        'fromUsername': me.username,
        'kind': kind,
        'callId': callId,
        'video': video,
        if (sdp != null) 'sdp': sdp,
      },
    );
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
        'ice': candidate,
      },
    );
  }

  /// The active call id, so ICE candidates can be tagged with it.
  String? _currentCallId;
  set currentCallId(String? id) => _currentCallId = id;

  /// Broadcasts a reaction change on message [messageId] to [contactPhone].
  Future<void> sendReaction(
      String contactPhone, String messageId, String emoji, bool add) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final channel = _sendChannels.putIfAbsent(
        inboxChannel(contactPhone), () => _client.channel(inboxChannel(contactPhone)));
    await channel.sendBroadcastMessage(
      event: 'reaction',
      payload: {'from': me.phone, 'id': messageId, 'emoji': emoji, 'add': add},
    );
  }

  /// Broadcasts an edit of message [messageId] to [contactPhone].
  Future<void> sendEdit(
      String contactPhone, String messageId, String newText) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final channel = _sendChannels.putIfAbsent(
        inboxChannel(contactPhone), () => _client.channel(inboxChannel(contactPhone)));
    await channel.sendBroadcastMessage(
      event: 'edit',
      payload: {'from': me.phone, 'id': messageId, 'text': newText},
    );
  }

  /// Broadcasts a delete-for-everyone of message [messageId] to [contactPhone].
  Future<void> sendDelete(String contactPhone, String messageId) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final channel = _sendChannels.putIfAbsent(
        inboxChannel(contactPhone), () => _client.channel(inboxChannel(contactPhone)));
    await channel.sendBroadcastMessage(
      event: 'delete',
      payload: {'from': me.phone, 'id': messageId},
    );
  }

  /// Sends a delivery/read receipt ('delivered' or 'read') to [contactPhone].
  Future<void> sendReceipt(String contactPhone, String kind) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final name = inboxChannel(contactPhone);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    await channel.sendBroadcastMessage(
      event: 'receipt',
      payload: {'from': me.phone, 'kind': kind},
    );
  }

  /// Sends a lightweight "typing" ping to [contactPhone]'s inbox.
  Future<void> sendTyping(String contactPhone) async =>
      _ping(contactPhone, 'typing');

  /// Sends an "online" presence ping to [contactPhone]'s inbox.
  Future<void> sendPresence(String contactPhone) async =>
      _ping(contactPhone, 'presence');

  Future<void> _ping(String contactPhone, String event) async {
    if (!_initialized) return;
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
  Future<void> send(String contactPhone, Message message) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;

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

    final name = inboxChannel(contactPhone);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    await channel.sendBroadcastMessage(
      event: 'msg',
      payload: encode(
        message: message,
        fromPhone: me.phone,
        fromName: me.name,
        fromUsername: me.username,
        toPhone: contactPhone,
        ecdhSecret: ecdhSecret,
        senderPublicKey: senderPublicKey,
      ),
    );
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
