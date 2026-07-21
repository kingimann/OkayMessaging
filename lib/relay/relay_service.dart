import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../models/chat.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../state/chat_store.dart';
import '../state/session.dart';
import 'relay_config.dart';

/// Delivers messages between devices over an ephemeral Realtime **broadcast**
/// channel. Nothing is ever stored on a server: a message is passed live to
/// the other device, which saves its own local copy. Two people talk over a
/// shared per-pair channel; both must be online (delivery is live-only).
///
/// The message-mapping logic is static and pure so it can be unit-tested
/// without a live connection.
class RelayService {
  RelayService._();
  static final RelayService instance = RelayService._();

  bool _initialized = false;
  final Map<String, RealtimeChannel> _channels = {};

  SupabaseClient get _client => Supabase.instance.client;

  /// Only the digits of a phone number, for use in a channel name.
  static String digits(String phone) => phone.replaceAll(RegExp(r'\D'), '');

  /// A deterministic, order-independent channel id for the pair (a, b).
  static String channelFor(String a, String b) {
    final pair = [digits(a), digits(b)]..sort();
    return 'dm_${pair[0]}_${pair[1]}';
  }

  /// Builds the broadcast payload for an outgoing message.
  static Map<String, dynamic> encode({
    required Message message,
    required String fromPhone,
    required String fromName,
  }) {
    return {
      'id': message.id,
      'from': fromPhone,
      'fromName': fromName,
      'text': message.text,
      'ts': message.time.toIso8601String(),
      'isImage': message.isImage,
      'imageUrl': message.imageUrl,
    };
  }

  /// Applies an incoming broadcast payload to [store]: finds or creates the
  /// local conversation with the sender and appends the message. Ignores
  /// messages from [myPhone] (our own echo) and duplicates by id. Returns true
  /// when a new message was added.
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
        avatarColor: '#64B5F6',
        about: 'Available',
        phone: from,
      );
      chat = Chat(id: 'chat_$from', contact: contact, messages: const []);
      target.upsert(chat);
    }

    // Skip if we already have this message id in the conversation.
    final existing = target.chatById(chat.id);
    if (existing != null && existing.messages.any((m) => m.id == id)) {
      return false;
    }

    target.addMessage(
      chat.id,
      Message(
        id: id,
        text: (payload['text'] as String?) ?? '',
        time: DateTime.tryParse(payload['ts'] as String? ?? '')?.toLocal() ??
            DateTime.now(),
        isMe: false,
        status: MessageStatus.delivered,
        isImage: payload['isImage'] as bool? ?? false,
        imageUrl: payload['imageUrl'] as String?,
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

  String? get _myPhone => Session.instance.user.value?.phone;

  /// Subscribes to the channels for every existing phone conversation.
  void start() {
    if (!_initialized) return;
    for (final chat in ChatStore.instance.allChats) {
      final phone = chat.contact.phone;
      if (!chat.contact.isGroup && phone.isNotEmpty) {
        ensureConversation(phone);
      }
    }
  }

  /// Ensures we're subscribed to the shared channel with [contactPhone].
  RealtimeChannel? ensureConversation(String contactPhone) {
    if (!_initialized) return null;
    final me = _myPhone;
    if (me == null) return null;
    final name = channelFor(me, contactPhone);
    final existing = _channels[name];
    if (existing != null) return existing;

    final channel = _client.channel(name);
    channel
        .onBroadcast(
          event: 'msg',
          callback: (payload) => applyIncoming(
            Map<String, dynamic>.from(payload),
            myPhone: me,
          ),
        )
        .subscribe();
    _channels[name] = channel;
    return channel;
  }

  /// Broadcasts an outgoing [message] to [contactPhone]'s device.
  Future<void> send(String contactPhone, Message message) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final channel = ensureConversation(contactPhone);
    if (channel == null) return;
    await channel.sendBroadcastMessage(
      event: 'msg',
      payload: encode(
        message: message,
        fromPhone: me.phone,
        fromName: me.name,
      ),
    );
  }

  /// Tears down all subscriptions (on sign-out).
  Future<void> stop() async {
    for (final channel in _channels.values) {
      await _client.removeChannel(channel);
    }
    _channels.clear();
  }
}
