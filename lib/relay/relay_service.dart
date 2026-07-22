import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../models/chat.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../state/chat_store.dart';
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

  /// Digits of whoever most recently sent a "typing" ping; the counter bumps
  /// on every ping so listeners always fire (even for the same sender).
  String? typingFromDigits;
  final ValueNotifier<int> typingPing = ValueNotifier<int>(0);

  SupabaseClient get _client => Supabase.instance.client;

  /// Only the digits of a phone number, for use in a channel name.
  static String digits(String phone) => phone.replaceAll(RegExp(r'\D'), '');

  /// The inbox channel a user listens on / is reached at.
  static String inboxChannel(String phone) => 'inbox_${digits(phone)}';

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
        avatarColor: '#64B5F6',
        about: 'Available',
        phone: from,
      );
      chat = Chat(id: 'chat_$from', contact: contact, messages: const []);
      target.upsert(chat);
    }

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
          callback: (payload) => applyIncoming(
            Map<String, dynamic>.from(payload),
            myPhone: me,
          ),
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
        .subscribe();
  }

  /// Sends a lightweight "typing" ping to [contactPhone]'s inbox.
  Future<void> sendTyping(String contactPhone) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final name = inboxChannel(contactPhone);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    await channel
        .sendBroadcastMessage(event: 'typing', payload: {'from': me.phone});
  }

  /// Broadcasts an outgoing [message] to [contactPhone]'s inbox over REST (the
  /// channel is never subscribed, so we can't see their other traffic).
  Future<void> send(String contactPhone, Message message) async {
    if (!_initialized) return;
    final me = Session.instance.user.value;
    if (me == null) return;
    final name = inboxChannel(contactPhone);
    final channel =
        _sendChannels.putIfAbsent(name, () => _client.channel(name));
    await channel.sendBroadcastMessage(
      event: 'msg',
      payload: encode(message: message, fromPhone: me.phone, fromName: me.name),
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
  }
}
