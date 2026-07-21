import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chat.dart';
import '../models/message.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/message_bubble.dart';
import '../widgets/user_avatar.dart';
import 'contact_info_screen.dart';

/// The conversation screen for a single [Chat].
class ChatScreen extends StatefulWidget {
  final Chat chat;

  const ChatScreen({super.key, required this.chat});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late List<Message> _messages;
  final ScrollController _scrollController = ScrollController();
  int _autoReplyCounter = 0;

  @override
  void initState() {
    super.initState();
    _messages = List<Message>.from(widget.chat.messages);
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  void _animateToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _handleSend(String text) {
    final now = DateTime.now();
    setState(() {
      _messages.add(Message(
        id: 'local_${now.microsecondsSinceEpoch}',
        text: text,
        time: now,
        isMe: true,
        status: MessageStatus.sent,
      ));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _animateToBottom());
    _scheduleAutoReply();
  }

  /// Simulates the other person replying so the demo feels alive.
  void _scheduleAutoReply() {
    _autoReplyCounter++;
    const replies = [
      'Got it 👍',
      'Sounds good!',
      'Haha nice 😄',
      'Let me check and get back to you.',
      'Okay 👌',
    ];
    final reply = replies[_autoReplyCounter % replies.length];

    Future.delayed(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() {
        // Mark my last message as read once a reply arrives.
        for (var i = _messages.length - 1; i >= 0; i--) {
          if (_messages[i].isMe) {
            final m = _messages[i];
            _messages[i] = Message(
              id: m.id,
              text: m.text,
              time: m.time,
              isMe: true,
              status: MessageStatus.read,
            );
            break;
          }
        }
        _messages.add(Message(
          id: 'reply_${DateTime.now().microsecondsSinceEpoch}',
          text: reply,
          time: DateTime.now(),
          isMe: false,
        ));
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _animateToBottom());
    });
  }

  /// Builds a flat list of widgets with day-separator headers inserted.
  List<Widget> _buildItems() {
    final items = <Widget>[];
    DateTime? lastDay;
    for (final m in _messages) {
      final day = DateTime(m.time.year, m.time.month, m.time.day);
      if (lastDay == null || day != lastDay) {
        items.add(_DayHeader(label: DateFormatter.messageDayHeader(m.time)));
        lastDay = day;
      }
      items.add(MessageBubble(
        message: m,
        onLongPress: () => _showMessageActions(m),
      ));
    }
    return items;
  }

  void _showMessageActions(Message message) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: message.text));
                  Navigator.of(sheetContext).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Message copied')),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply'),
                onTap: () => Navigator.of(sheetContext).pop(),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title:
                    const Text('Delete', style: TextStyle(color: Colors.red)),
                onTap: () {
                  setState(
                      () => _messages.removeWhere((m) => m.id == message.id));
                  Navigator.of(sheetContext).pop();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final contact = widget.chat.contact;

    return Scaffold(
      backgroundColor: isDark ? AppColors.chatBgDark : AppColors.chatBgLight,
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ContactInfoScreen(user: contact),
            ),
          ),
          child: Row(
            children: [
              UserAvatar(user: contact, radius: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      contact.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      contact.isOnline ? 'online' : 'last seen recently',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.videocam),
            onPressed: () => _showComingSoon(context, 'Video call'),
          ),
          IconButton(
            icon: const Icon(Icons.call),
            onPressed: () => _showComingSoon(context, 'Voice call'),
          ),
          PopupMenuButton<String>(
            onSelected: (_) {},
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'view', child: Text('View contact')),
              PopupMenuItem(
                  value: 'media', child: Text('Media, links, and docs')),
              PopupMenuItem(value: 'search', child: Text('Search')),
              PopupMenuItem(value: 'mute', child: Text('Mute notifications')),
              PopupMenuItem(value: 'wallpaper', child: Text('Wallpaper')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: _buildItems(),
            ),
          ),
          ChatInputBar(onSend: _handleSend),
        ],
      ),
    );
  }

  void _showComingSoon(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$feature is not available in this demo')),
    );
  }
}

class _DayHeader extends StatelessWidget {
  final String label;

  const _DayHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkAppBar : Colors.white,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            color: isDark ? Colors.white70 : Colors.black54,
          ),
        ),
      ),
    );
  }
}
