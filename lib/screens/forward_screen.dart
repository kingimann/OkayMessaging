import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../widgets/user_avatar.dart';

/// Lets the user pick one or more conversations to send [text] — or, when
/// [place] is set, a shared-location card — into.
class ForwardScreen extends StatefulWidget {
  final String text;

  /// When set, a location message for this place is sent instead of [text].
  final ({double lat, double lng, String label})? place;

  const ForwardScreen({super.key, required this.text, this.place});

  @override
  State<ForwardScreen> createState() => _ForwardScreenState();
}

class _ForwardScreenState extends State<ForwardScreen> {
  final Set<String> _selected = {};

  /// A real, number-identified peer (not a seeded demo contact or group), so
  /// the message can also be delivered over the relay.
  bool _isRealPeer(AppUser c) =>
      !c.isGroup && c.phone.isNotEmpty && c.id == c.phone;

  Message _buildMessage(String chatId, DateTime now) {
    final place = widget.place;
    if (place != null) {
      return Message(
        id: 'loc_${chatId}_${now.microsecondsSinceEpoch}',
        text: 'Shared location',
        time: now,
        isMe: true,
        status: MessageStatus.sent,
        isLocation: true,
        locationLat: place.lat,
        locationLng: place.lng,
        locationLabel: place.label,
      );
    }
    return Message(
      id: 'fwd_${chatId}_${now.microsecondsSinceEpoch}',
      text: widget.text,
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      forwarded: true,
    );
  }

  void _send() {
    final store = ChatStore.instance;
    final now = DateTime.now();
    for (final id in _selected) {
      final Chat? chat = store.chatById(id);
      if (chat == null) continue;
      final message = _buildMessage(id, now);
      store.addMessage(id, message);
      // Also deliver over the relay when this is a real, reachable contact.
      if (RelayConfig.isEnabled && _isRealPeer(chat.contact)) {
        RelayService.instance.send(chat.contact.phone, message);
      }
    }
    final count = _selected.length;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(widget.place != null
            ? 'Sent to $count chat${count == 1 ? '' : 's'}'
            : 'Forwarded to $count chat${count == 1 ? '' : 's'}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chats = ChatStore.instance.chats;
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected.isEmpty
            ? (widget.place != null ? 'Send to...' : 'Forward to...')
            : '${_selected.length} selected'),
      ),
      body: ListView.builder(
        itemCount: chats.length,
        itemBuilder: (context, index) {
          final chat = chats[index];
          final selected = _selected.contains(chat.id);
          return ListTile(
            leading: UserAvatar(user: chat.contact, radius: 24),
            title: Text(chat.contact.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            trailing: selected
                ? const Icon(Icons.check_circle, color: AppColors.tealGreenDark)
                : const Icon(Icons.circle_outlined, color: Colors.grey),
            onTap: () => setState(() {
              if (!_selected.remove(chat.id)) _selected.add(chat.id);
            }),
          );
        },
      ),
      floatingActionButton: _selected.isEmpty
          ? null
          : FloatingActionButton(
              backgroundColor: AppColors.tealGreenDark,
              onPressed: _send,
              child: const Icon(Icons.send, color: Colors.white),
            ),
    );
  }
}
