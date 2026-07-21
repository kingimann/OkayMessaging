import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/chat.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../state/chat_store.dart';
import 'supabase_service.dart';

/// Loads real conversations/messages from Supabase into [ChatStore] and keeps
/// them live via a realtime subscription. Only used when a backend is
/// configured; in demo mode nothing here runs.
class SupabaseChatService {
  SupabaseChatService._();
  static final SupabaseChatService instance = SupabaseChatService._();

  SupabaseClient get _db => SupabaseService.instance.client;
  String? get _me => SupabaseService.instance.currentUserId;

  RealtimeChannel? _channel;
  bool _syncing = false;
  bool _resyncQueued = false;

  /// Called after sign-in: loads conversations and starts listening for new
  /// messages so the store updates in real time.
  Future<void> start() async {
    await sync();
    _subscribe();
  }

  /// Tears down the realtime subscription (on sign-out).
  Future<void> stop() async {
    final ch = _channel;
    _channel = null;
    if (ch != null) await _db.removeChannel(ch);
  }

  void _subscribe() {
    if (_channel != null) return;
    _channel = _db
        .channel('public:messages')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: (_) => sync(),
        )
        .subscribe();
  }

  /// Reloads every conversation the current user belongs to and pushes the
  /// result into [ChatStore]. Coalesces concurrent calls.
  Future<void> sync() async {
    final me = _me;
    if (me == null) return;
    if (_syncing) {
      _resyncQueued = true;
      return;
    }
    _syncing = true;
    try {
      final memberRows = await _db
          .from('conversation_members')
          .select('conversation_id')
          .eq('user_id', me);
      final ids = memberRows
          .map((r) => r['conversation_id'] as String)
          .toList(growable: false);
      if (ids.isEmpty) {
        ChatStore.instance.setChats(const []);
        return;
      }

      final rows = await _db
          .from('conversations')
          .select(
            'id, is_group, name, '
            'conversation_members(user_id, profiles(*)), '
            'messages(id, sender_id, body, is_image, image_url, created_at)',
          )
          .inFilter('id', ids);

      final chats = <Chat>[];
      for (final row in rows) {
        final chat = _chatFromRow(Map<String, dynamic>.from(row), me);
        if (chat != null) chats.add(chat);
      }
      ChatStore.instance.setChats(chats);
    } finally {
      _syncing = false;
      if (_resyncQueued) {
        _resyncQueued = false;
        await sync();
      }
    }
  }

  Chat? _chatFromRow(Map<String, dynamic> row, String me) {
    final isGroup = row['is_group'] as bool? ?? false;
    final members = (row['conversation_members'] as List? ?? const [])
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();

    AppUser contact;
    if (isGroup) {
      contact = AppUser(
        id: row['id'] as String,
        name: (row['name'] as String?) ?? 'Group',
        avatarColor: '#4DB6AC',
        about: 'Group • ${members.length} members',
        isGroup: true,
      );
    } else {
      final other = members.firstWhere(
        (m) => m['user_id'] != me,
        orElse: () => <String, dynamic>{},
      );
      final profile = other['profiles'];
      if (profile == null) return null;
      contact = _userFromProfile(Map<String, dynamic>.from(profile as Map));
    }

    final messages = (row['messages'] as List? ?? const [])
        .map((m) => _messageFromRow(Map<String, dynamic>.from(m as Map), me))
        .toList()
      ..sort((a, b) => a.time.compareTo(b.time));

    return Chat(
      id: row['id'] as String,
      contact: contact,
      messages: messages,
    );
  }

  Message _messageFromRow(Map<String, dynamic> row, String me) {
    return Message(
      id: row['id'] as String,
      text: (row['body'] as String?) ?? '',
      time: DateTime.parse(row['created_at'] as String).toLocal(),
      isMe: row['sender_id'] == me,
      status: MessageStatus.delivered,
      isImage: row['is_image'] as bool? ?? false,
      imageUrl: row['image_url'] as String?,
    );
  }

  AppUser _userFromProfile(Map<String, dynamic> p) {
    return AppUser(
      id: p['id'] as String,
      name: (p['name'] as String?) ?? 'Someone',
      avatarColor: (p['avatar_color'] as String?) ?? '#9E9E9E',
      about: (p['about'] as String?) ?? '',
      phone: (p['phone'] as String?) ?? '',
      isOnline: p['is_online'] as bool? ?? false,
    );
  }

  /// Sends a text message to a conversation. Realtime then refreshes the store.
  Future<void> sendText(String conversationId, String body) async {
    final me = _me;
    if (me == null) return;
    await _db.from('messages').insert({
      'conversation_id': conversationId,
      'sender_id': me,
      'body': body,
    });
    await sync();
  }

  /// Everyone else who has an account (available to start a chat with).
  Future<List<AppUser>> contacts() async {
    final me = _me;
    final rows = await _db.from('profiles').select('*');
    return rows
        .map((r) => _userFromProfile(Map<String, dynamic>.from(r)))
        .where((u) => u.id != me)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  /// Returns the existing 1:1 conversation with [otherUserId], creating one
  /// (and its two membership rows) if none exists yet.
  Future<String> startConversationWith(String otherUserId) async {
    final me = _me;
    if (me == null) throw StateError('Not signed in');

    final myRows = await _db
        .from('conversation_members')
        .select('conversation_id')
        .eq('user_id', me);
    final myIds =
        myRows.map((r) => r['conversation_id'] as String).toList(growable: false);

    if (myIds.isNotEmpty) {
      final shared = await _db
          .from('conversation_members')
          .select('conversation_id, conversations(is_group)')
          .eq('user_id', otherUserId)
          .inFilter('conversation_id', myIds);
      for (final r in shared) {
        final conv = r['conversations'];
        final isGroup =
            conv is Map && (conv['is_group'] as bool? ?? false);
        if (!isGroup) return r['conversation_id'] as String;
      }
    }

    final conv = await _db
        .from('conversations')
        .insert({'is_group': false})
        .select('id')
        .single();
    final convId = conv['id'] as String;
    await _db.from('conversation_members').insert([
      {'conversation_id': convId, 'user_id': me},
      {'conversation_id': convId, 'user_id': otherUserId},
    ]);
    await sync();
    return convId;
  }
}
