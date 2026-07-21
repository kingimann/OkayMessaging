import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chat.dart';
import '../models/message.dart';
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/emoji_data.dart';
import '../widgets/message_bubble.dart';
import '../widgets/user_avatar.dart';
import 'contact_info_screen.dart';
import 'forward_screen.dart';
import 'group_info_screen.dart';

/// The conversation screen for a single [Chat], backed by [ChatStore].
class ChatScreen extends StatefulWidget {
  final Chat chat;

  const ChatScreen({super.key, required this.chat});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ScrollController _scrollController = ScrollController();
  final ChatStore _store = ChatStore.instance;

  ReplyInfo? _replyTo;
  bool _isTyping = false;
  bool _showScrollToBottom = false;
  int _autoReplyCounter = 0;

  String get _chatId => widget.chat.id;

  @override
  void initState() {
    super.initState();
    // Make sure a store entry exists (e.g. for a freshly started chat).
    _store.upsert(widget.chat);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _store.markRead(_chatId);
      _jumpToBottom();
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final distance =
        _scrollController.position.maxScrollExtent - _scrollController.offset;
    final show = distance > 320;
    if (show != _showScrollToBottom) {
      setState(() => _showScrollToBottom = show);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  List<Message> get _messages => _store.chatById(_chatId)?.messages ?? const [];

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
    _store.addMessage(
      _chatId,
      Message(
        id: 'local_${now.microsecondsSinceEpoch}',
        text: text,
        time: now,
        isMe: true,
        status: MessageStatus.sent,
        replyTo: _replyTo,
      ),
    );
    setState(() => _replyTo = null);
    WidgetsBinding.instance.addPostFrameCallback((_) => _animateToBottom());
    _scheduleAutoReply();
  }

  /// Simulates the other person typing then replying so the demo feels alive.
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

    setState(() => _isTyping = true);
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (!mounted) return;
      setState(() => _isTyping = false);

      // Mark my messages as read now that a reply has arrived.
      final updated = _messages
          .map((m) => m.isMe ? m.copyWith(status: MessageStatus.read) : m)
          .toList()
        ..add(Message(
          id: 'reply_${DateTime.now().microsecondsSinceEpoch}',
          text: reply,
          time: DateTime.now(),
          isMe: false,
        ));
      _store.replaceMessages(_chatId, updated);
      WidgetsBinding.instance.addPostFrameCallback((_) => _animateToBottom());
    });
  }

  void _startReply(Message message) {
    setState(() {
      _replyTo = ReplyInfo(
        senderName: widget.chat.contact.name,
        text: message.text,
        isMe: message.isMe,
      );
    });
  }

  List<Widget> _buildItems() {
    final items = <Widget>[];
    DateTime? lastDay;
    for (final m in _messages) {
      final day = DateTime(m.time.year, m.time.month, m.time.day);
      if (lastDay == null || day != lastDay) {
        items.add(_DayHeader(label: DateFormatter.messageDayHeader(m.time)));
        lastDay = day;
      }
      items.add(Dismissible(
        key: ValueKey('msg_${m.id}'),
        direction: DismissDirection.startToEnd,
        dismissThresholds: const {DismissDirection.startToEnd: 0.25},
        confirmDismiss: (_) async {
          _startReply(m);
          return false; // snap back; we only use the swipe to trigger reply
        },
        background: const Padding(
          padding: EdgeInsets.only(left: 24),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Icon(Icons.reply, color: Colors.grey),
          ),
        ),
        child: MessageBubble(
          message: m,
          starred: _store.isStarred(_chatId, m.id),
          onLongPress: () => _showMessageActions(m),
        ),
      ));
    }
    return items;
  }

  void _showMessageActions(Message message) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ReactionRow(
                  onSelected: (emoji) {
                    _store.toggleReaction(_chatId, message.id, emoji);
                    Navigator.of(sheetContext).pop();
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.reply),
                  title: const Text('Reply'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _startReply(message);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.shortcut),
                  title: const Text('Forward'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ForwardScreen(text: message.text),
                      ),
                    );
                  },
                ),
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
                  leading: Icon(_store.isStarred(_chatId, message.id)
                      ? Icons.star
                      : Icons.star_border),
                  title: Text(_store.isStarred(_chatId, message.id)
                      ? 'Unstar'
                      : 'Star'),
                  onTap: () {
                    _store.toggleStar(_chatId, message.id);
                    Navigator.of(sheetContext).pop();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title:
                      const Text('Delete', style: TextStyle(color: Colors.red)),
                  onTap: () {
                    _store.deleteMessage(_chatId, message.id);
                    Navigator.of(sheetContext).pop();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showAttachmentSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        const options = [
          (Icons.insert_drive_file, 'Document', Color(0xFF7F66FF)),
          (Icons.camera_alt, 'Camera', Color(0xFFEF5DA8)),
          (Icons.photo, 'Gallery', Color(0xFFC861F9)),
          (Icons.headphones, 'Audio', Color(0xFFF97052)),
          (Icons.location_on, 'Location', Color(0xFF1FA855)),
          (Icons.person, 'Contact', Color(0xFF009DE2)),
        ];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              mainAxisSpacing: 20,
              children: [
                for (final (icon, label, color) in options)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 28,
                        backgroundColor: color,
                        child: Icon(icon, color: Colors.white),
                      ),
                      const SizedBox(height: 6),
                      Text(label, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
              ],
            ),
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
              builder: (_) => contact.isGroup
                  ? GroupInfoScreen(group: contact)
                  : ContactInfoScreen(user: contact),
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
                      _isTyping
                          ? 'typing…'
                          : (contact.isOnline
                              ? 'online'
                              : 'last seen recently'),
                      style: TextStyle(
                        fontSize: 12.5,
                        color:
                            _isTyping ? AppColors.lightGreen : Colors.white70,
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
            child: Stack(
              children: [
                ListenableBuilder(
                  listenable: _store,
                  builder: (context, _) => ListView(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: _buildItems(),
                  ),
                ),
                if (_showScrollToBottom)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: FloatingActionButton.small(
                      heroTag: 'scrollToBottom',
                      backgroundColor:
                          isDark ? AppColors.darkAppBar : Colors.white,
                      foregroundColor: AppColors.tealGreenDark,
                      elevation: 2,
                      onPressed: _animateToBottom,
                      child: const Icon(Icons.keyboard_arrow_down),
                    ),
                  ),
              ],
            ),
          ),
          ChatInputBar(
            onSend: _handleSend,
            onAttach: _showAttachmentSheet,
            replyTo: _replyTo,
            onCancelReply: () => setState(() => _replyTo = null),
          ),
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

class _ReactionRow extends StatelessWidget {
  final ValueChanged<String> onSelected;

  const _ReactionRow({required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          for (final emoji in EmojiData.quickReactions)
            InkWell(
              onTap: () => onSelected(emoji),
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Text(emoji, style: const TextStyle(fontSize: 28)),
              ),
            ),
        ],
      ),
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
