import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/chat.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/emoji_data.dart';
import '../widgets/heart_burst.dart';
import '../widgets/message_bubble.dart';
import '../widgets/typing_indicator.dart';
import '../widgets/user_avatar.dart';
import 'call_screen.dart';
import 'contact_info_screen.dart';
import 'forward_screen.dart';
import 'group_info_screen.dart';
import 'image_view_screen.dart';
import 'media_gallery_screen.dart';

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

  bool _searching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  final Set<String> _selectedIds = {};
  bool get _selectionMode => _selectedIds.isNotEmpty;

  /// Where the most recent double-tap landed, used to place the heart burst.
  Offset? _lastDoubleTapPos;

  /// Throttle for outgoing typing pings, and a timer to clear the incoming
  /// typing indicator after a pause.
  DateTime? _lastTypingSent;
  Timer? _typingClear;

  /// Id of the newest incoming message we've sent a read receipt for, so a
  /// receipt is sent once per new message (not on every store change).
  String? _lastAckedIncomingId;

  /// The unread count when the chat was opened, and the id of the message the
  /// "unread messages" divider should sit above (captured before markRead).
  int _initialUnread = 0;
  String? _unreadAnchorId;

  /// Per-message keys (for scroll-to-message) and the id currently flashing
  /// after a reply-quote jump.
  final Map<String, GlobalKey> _messageKeys = {};
  String? _highlightedId;

  String get _chatId => widget.chat.id;

  @override
  void initState() {
    super.initState();
    // Make sure a store entry exists (e.g. for a freshly started chat).
    _store.upsert(widget.chat);
    _captureUnreadAnchor();
    _scrollController.addListener(_onScroll);
    if (RelayConfig.isEnabled) {
      RelayService.instance.typingPing.addListener(_onTypingPing);
      if (_isRealPeer(widget.chat.contact)) {
        _store.addListener(_maybeSendReadReceipt);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _store.markRead(_chatId);
      _maybeSendReadReceipt();
      _jumpToBottom();
    });
  }

  /// Sends a 'read' receipt to a real peer when a new incoming message appears
  /// while this chat is open (once per message, so no receipt ping-pong).
  void _maybeSendReadReceipt() {
    if (!RelayConfig.isEnabled || !_isRealPeer(widget.chat.contact)) return;
    final incoming =
        _store.chatById(_chatId)?.messages.where((m) => !m.isMe).toList();
    if (incoming == null || incoming.isEmpty) return;
    final lastId = incoming.last.id;
    if (lastId == _lastAckedIncomingId) return;
    _lastAckedIncomingId = lastId;
    RelayService.instance.sendReceipt(widget.chat.contact.phone, 'read');
  }

  /// Broadcasts that we're typing (throttled) to a real peer.
  void _onTyping() {
    if (!RelayConfig.isEnabled || !_isRealPeer(widget.chat.contact)) return;
    final now = DateTime.now();
    if (_lastTypingSent != null &&
        now.difference(_lastTypingSent!) < const Duration(seconds: 2)) {
      return;
    }
    _lastTypingSent = now;
    RelayService.instance.sendTyping(widget.chat.contact.phone);
  }

  /// Shows the typing indicator when the peer of *this* chat is typing.
  void _onTypingPing() {
    if (RelayService.instance.typingFromDigits !=
        RelayService.digits(widget.chat.contact.phone)) {
      return;
    }
    if (!mounted) return;
    setState(() => _isTyping = true);
    _typingClear?.cancel();
    _typingClear = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _isTyping = false);
    });
  }

  /// Records where the "unread messages" divider goes: above the first of the
  /// last [unreadCount] incoming messages.
  void _captureUnreadAnchor() {
    final chat = _store.chatById(_chatId);
    final unread = chat?.unreadCount ?? 0;
    if (unread <= 0) return;
    final incoming = chat!.messages.where((m) => !m.isMe).toList();
    if (unread <= incoming.length) {
      _initialUnread = unread;
      _unreadAnchorId = incoming[incoming.length - unread].id;
    }
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
    if (RelayConfig.isEnabled) {
      RelayService.instance.typingPing.removeListener(_onTypingPing);
      _store.removeListener(_maybeSendReadReceipt);
    }
    _typingClear?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _exitSearch() {
    setState(() {
      _searching = false;
      _searchQuery = '';
      _searchController.clear();
    });
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
    _deliver(Message(
      id: 'local_${now.microsecondsSinceEpoch}',
      text: text,
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      replyTo: _replyTo,
    ));
    setState(() => _replyTo = null);
  }

  void _handleSendImage() {
    final now = DateTime.now();
    _deliver(Message(
      id: 'img_${now.microsecondsSinceEpoch}',
      text: '',
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      isImage: true,
      imageSeed: now.microsecondsSinceEpoch % 6,
      replyTo: _replyTo,
    ));
    setState(() => _replyTo = null);
  }

  void _handleSendVoice(int seconds) {
    final now = DateTime.now();
    _deliver(Message(
      id: 'voice_${now.microsecondsSinceEpoch}',
      text: '',
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      isVoice: true,
      voiceSeconds: seconds,
    ));
  }

  /// Stores an outgoing [message] and either delivers it over the relay (to a
  /// real number-based peer) or triggers a simulated reply (demo contact).
  void _deliver(Message message) {
    _store.addMessage(_chatId, message);
    WidgetsBinding.instance.addPostFrameCallback((_) => _animateToBottom());
    if (RelayConfig.isEnabled && _isRealPeer(widget.chat.contact)) {
      RelayService.instance.send(widget.chat.contact.phone, message);
    } else {
      _scheduleAutoReply();
    }
  }

  /// A real, number-identified peer (chat started with an actual phone number),
  /// as opposed to a seeded demo contact or a group.
  bool _isRealPeer(AppUser c) =>
      !c.isGroup && c.phone.isNotEmpty && c.id == c.phone;

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
        text: message.isImage
            ? '📷 Photo'
            : message.isVoice
                ? '🎤 Voice message'
                : message.text,
        isMe: message.isMe,
        messageId: message.id,
      );
    });
  }

  void _enterSelection(String id) => setState(() => _selectedIds
    ..clear()
    ..add(id));

  void _toggleSelect(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
    });
  }

  void _exitSelection() => setState(_selectedIds.clear);

  List<Message> get _selectedMessages =>
      _messages.where((m) => _selectedIds.contains(m.id)).toList();

  void _deleteSelected() {
    for (final id in _selectedIds) {
      _store.deleteMessage(_chatId, id);
    }
    _exitSelection();
  }

  void _starSelected() {
    for (final id in _selectedIds) {
      if (!_store.isStarred(_chatId, id)) _store.toggleStar(_chatId, id);
    }
    _exitSelection();
  }

  void _copySelected() {
    final text = _selectedMessages.map((m) => m.text).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    _exitSelection();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Messages copied')),
    );
  }

  void _forwardSelected() {
    final text = _selectedMessages.map((m) => m.text).join('\n');
    _exitSelection();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ForwardScreen(text: text)),
    );
  }

  List<Message> get _visibleMessages {
    final q = _searchQuery.trim().toLowerCase();
    if (!_searching || q.isEmpty) return _messages;
    return _messages.where((m) => m.text.toLowerCase().contains(q)).toList();
  }

  List<Widget> _buildItems() {
    final items = <Widget>[];
    DateTime? lastDay;
    for (final m in _visibleMessages) {
      final day = DateTime(m.time.year, m.time.month, m.time.day);
      if (lastDay == null || day != lastDay) {
        items.add(_DayHeader(label: DateFormatter.messageDayHeader(m.time)));
        lastDay = day;
      }
      if (!_searching && m.id == _unreadAnchorId) {
        items.add(_UnreadDivider(count: _initialUnread));
      }
      final bubble = MessageBubble(
        message: m,
        starred: _store.isStarred(_chatId, m.id),
        onLongPress: _selectionMode ? null : () => _showMessageActions(m),
        onTap: m.isImage && !_selectionMode ? () => _openImage(m) : null,
        onDoubleTapDown:
            _selectionMode ? null : (d) => _lastDoubleTapPos = d.globalPosition,
        onDoubleTap: _selectionMode ? null : () => _quickReact(m),
        onReplyTap: m.replyTo?.messageId == null
            ? null
            : () => _jumpToMessage(m.replyTo!.messageId!),
      );

      final key = _messageKeys.putIfAbsent(m.id, () => GlobalKey());
      final highlighted = _highlightedId == m.id;
      final keyed = Container(
        key: key,
        color: highlighted
            ? AppColors.tealGreenDark.withValues(alpha: 0.18)
            : null,
        child: bubble,
      );

      if (_selectionMode) {
        final selected = _selectedIds.contains(m.id);
        items.add(GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _toggleSelect(m.id),
          onLongPress: () => _toggleSelect(m.id),
          child: Container(
            color: selected
                ? AppColors.tealGreenDark.withValues(alpha: 0.16)
                : null,
            child: keyed,
          ),
        ));
      } else {
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
          child: keyed,
        ));
      }
    }
    return items;
  }

  /// Scrolls to the original [messageId] (the quoted message) and flashes it.
  void _jumpToMessage(String messageId) {
    final key = _messageKeys[messageId];
    final ctx = key?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      alignment: 0.3,
    );
    setState(() => _highlightedId = messageId);
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted && _highlightedId == messageId) {
        setState(() => _highlightedId = null);
      }
    });
  }

  void _showMessageActions(Message message) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
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
                  leading: const Icon(Icons.check_circle_outline),
                  title: const Text('Select'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _enterSelection(message.id);
                  },
                ),
                Builder(builder: (context) {
                  final pinned =
                      _store.chatById(_chatId)?.pinnedMessageId == message.id;
                  return ListTile(
                    leading:
                        Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
                    title: Text(pinned ? 'Unpin' : 'Pin'),
                    onTap: () {
                      if (pinned) {
                        _store.unpinMessage(_chatId);
                      } else {
                        _store.pinMessage(_chatId, message.id);
                      }
                      Navigator.of(sheetContext).pop();
                    },
                  );
                }),
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

  /// Toggles a ❤️ reaction; when one is added, pops a heart at the tap point.
  void _quickReact(Message message) {
    _store.toggleReaction(_chatId, message.id, '❤️');
    final added = _store
            .chatById(_chatId)
            ?.messages
            .firstWhere((m) => m.id == message.id)
            .reactions
            .contains('❤️') ??
        false;
    if (added && _lastDoubleTapPos != null) {
      _showHeartBurst(_lastDoubleTapPos!);
    }
  }

  void _showHeartBurst(Offset globalPosition) {
    final overlay = Overlay.of(context);
    final box = overlay.context.findRenderObject() as RenderBox?;
    final local = box?.globalToLocal(globalPosition) ?? globalPosition;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => HeartBurst(
        position: local,
        onDone: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }

  void _onMenuSelected(String value) {
    final contact = widget.chat.contact;
    switch (value) {
      case 'view':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => contact.isGroup
                ? GroupInfoScreen(group: contact, members: widget.chat.members)
                : ContactInfoScreen(user: contact, chatId: _chatId),
          ),
        );
      case 'media':
        _openMediaGallery();
      case 'pin':
        _store.togglePin(_chatId);
        final pinned = _store.chatById(_chatId)?.isPinned ?? false;
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(pinned ? 'Chat pinned' : 'Chat unpinned')),
        );
      case 'mute':
        _store.toggleMute(_chatId);
        final muted = _store.chatById(_chatId)?.isMuted ?? false;
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(muted ? 'Muted' : 'Unmuted')),
        );
      case 'wallpaper':
        _showComingSoon(context, 'Wallpaper');
      case 'clear':
        _confirmClearChat();
      case 'delete':
        _confirmDeleteChat();
    }
  }

  Future<void> _confirmClearChat() async {
    final ok = await _confirm(
      title: 'Clear this chat?',
      message: 'All messages in this conversation will be removed from this '
          'device. This cannot be undone.',
      action: 'Clear chat',
    );
    if (ok) _store.clearMessages(_chatId);
  }

  Future<void> _confirmDeleteChat() async {
    final ok = await _confirm(
      title: 'Delete this chat?',
      message: 'This conversation will be removed from this device. This '
          'cannot be undone.',
      action: 'Delete chat',
    );
    if (!ok || !mounted) return;
    _store.deleteChat(_chatId);
    Navigator.of(context).pop();
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _openMediaGallery() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MediaGalleryScreen(
          chatId: _chatId,
          contactName: widget.chat.contact.name,
        ),
      ),
    );
  }

  void _startCall({required bool video}) {
    if (widget.chat.contact.isGroup) {
      _showComingSoon(context, 'Group calls');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CallScreen(user: widget.chat.contact, video: video),
      ),
    );
  }

  void _openImage(Message message) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImageViewScreen(
          message: message,
          senderName: widget.chat.contact.name,
        ),
      ),
    );
  }

  void _showAttachmentSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        final options = <(IconData, String, Color, VoidCallback)>[
          (Icons.insert_drive_file, 'Document', const Color(0xFF7F66FF),
              () => _showComingSoon(context, 'Documents')),
          (Icons.camera_alt, 'Camera', const Color(0xFFEF5DA8),
              _handleSendImage),
          (Icons.photo, 'Gallery', const Color(0xFFC861F9), _handleSendImage),
          (Icons.headphones, 'Audio', const Color(0xFFF97052),
              () => _showComingSoon(context, 'Audio')),
          (Icons.location_on, 'Location', const Color(0xFF1FA855),
              () => _showComingSoon(context, 'Location')),
          (Icons.person, 'Contact', const Color(0xFF009DE2),
              () => _showComingSoon(context, 'Contacts')),
        ];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              mainAxisSpacing: 20,
              children: [
                for (final (icon, label, color, onTap) in options)
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      onTap();
                    },
                    child: Column(
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

    return ValueListenableBuilder<Color?>(
      valueListenable: AppState.chatWallpaper,
      builder: (context, wallpaper, _) => Scaffold(
        backgroundColor: wallpaper ??
            (isDark ? AppColors.chatBgDark : AppColors.chatBgLight),
        appBar: _selectionMode
            ? AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _exitSelection,
                ),
                title: Text('${_selectedIds.length}'),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.star_border),
                    tooltip: 'Star',
                    onPressed: _starSelected,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete',
                    onPressed: _deleteSelected,
                  ),
                  IconButton(
                    icon: const Icon(Icons.shortcut),
                    tooltip: 'Forward',
                    onPressed: _forwardSelected,
                  ),
                  if (_selectedIds.length == 1)
                    IconButton(
                      icon: const Icon(Icons.copy),
                      tooltip: 'Copy',
                      onPressed: _copySelected,
                    ),
                ],
              )
            : _searching
                ? AppBar(
                    leading: IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: _exitSearch,
                    ),
                    titleSpacing: 0,
                    title: TextField(
                      controller: _searchController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Search messages',
                        border: InputBorder.none,
                      ),
                      onChanged: (v) => setState(() => _searchQuery = v),
                    ),
                    actions: [
                      if (_searchQuery.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() {
                            _searchQuery = '';
                            _searchController.clear();
                          }),
                        ),
                    ],
                  )
                : AppBar(
                    titleSpacing: 0,
                    title: InkWell(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => contact.isGroup
                              ? GroupInfoScreen(group: contact, members: widget.chat.members)
                              : ContactInfoScreen(user: contact, chatId: _chatId),
                        ),
                      ),
                      child: Row(
                        children: [
                          UserAvatar(
                            user: contact,
                            radius: 18,
                            heroTag: 'chatHeaderAvatar',
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        contact.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    if (_store.chatById(_chatId)?.isMuted ??
                                        false) ...[
                                      const SizedBox(width: 6),
                                      Icon(
                                        Icons.volume_off,
                                        size: 16,
                                        color: isDark
                                            ? Colors.white54
                                            : Colors.black45,
                                      ),
                                    ],
                                  ],
                                ),
                                _isTyping
                                    ? const TypingIndicator(
                                        color: AppColors.tealGreenDark,
                                      )
                                    : Text(
                                        contact.isOnline
                                            ? 'online'
                                            : 'last seen recently',
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          color: isDark
                                              ? Colors.white70
                                              : Colors.black54,
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
                        icon: const Icon(Icons.search),
                        onPressed: () => setState(() => _searching = true),
                      ),
                      IconButton(
                        icon: const Icon(Icons.videocam),
                        onPressed: () => _startCall(video: true),
                      ),
                      IconButton(
                        icon: const Icon(Icons.call),
                        onPressed: () => _startCall(video: false),
                      ),
                      PopupMenuButton<String>(
                        onSelected: _onMenuSelected,
                        itemBuilder: (context) {
                          final pinned =
                              _store.chatById(_chatId)?.isPinned ?? false;
                          final muted =
                              _store.chatById(_chatId)?.isMuted ?? false;
                          return [
                            const PopupMenuItem(
                                value: 'view', child: Text('View contact')),
                            const PopupMenuItem(
                                value: 'media',
                                child: Text('Media, links, and docs')),
                            PopupMenuItem(
                                value: 'pin',
                                child:
                                    Text(pinned ? 'Unpin chat' : 'Pin chat')),
                            PopupMenuItem(
                                value: 'mute',
                                child: Text(muted
                                    ? 'Unmute notifications'
                                    : 'Mute notifications')),
                            const PopupMenuItem(
                                value: 'wallpaper', child: Text('Wallpaper')),
                            const PopupMenuItem(
                                value: 'clear', child: Text('Clear chat')),
                            const PopupMenuItem(
                                value: 'delete', child: Text('Delete chat')),
                          ];
                        },
                      ),
                    ],
                  ),
        body: Column(
          children: [
            ListenableBuilder(
              listenable: _store,
              builder: (context, _) {
                final chat = _store.chatById(_chatId);
                final pinnedId = chat?.pinnedMessageId;
                if (pinnedId == null) return const SizedBox.shrink();
                final matches = chat!.messages.where((m) => m.id == pinnedId);
                if (matches.isEmpty) return const SizedBox.shrink();
                return _PinnedBanner(
                  message: matches.first,
                  onUnpin: () => _store.unpinMessage(_chatId),
                );
              },
            ),
            Expanded(
              child: Stack(
                children: [
                  ListenableBuilder(
                    listenable: _store,
                    builder: (context, _) {
                      final items = _buildItems();
                      if (items.isEmpty && !_searching) {
                        return const _EmptyConversation();
                      }
                      return ListView(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        children: items,
                      );
                    },
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
            if (!_selectionMode)
              ChatInputBar(
                onSend: _handleSend,
                onAttach: _showAttachmentSheet,
                onSendVoice: _handleSendVoice,
                onTyping: _onTyping,
                replyTo: _replyTo,
                onCancelReply: () => setState(() => _replyTo = null),
              ),
          ],
        ),
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

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkAppBar : const Color(0xFFFEF6D9),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock, size: 16, color: Colors.amber.shade800),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Messages are end-to-end encrypted. Say hi 👋',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PinnedBanner extends StatelessWidget {
  final Message message;
  final VoidCallback onUnpin;

  const _PinnedBanner({required this.message, required this.onUnpin});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: isDark ? AppColors.darkAppBar : Colors.white,
      child: InkWell(
        onTap: () {},
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: const BoxDecoration(
            border: Border(
              left: BorderSide(color: AppColors.tealGreenDark, width: 4),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.push_pin, size: 16, color: Colors.grey),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Pinned message',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.tealGreenDark,
                      ),
                    ),
                    Text(
                      message.isVoice
                          ? 'Voice message'
                          : message.isImage
                              ? 'Photo'
                              : message.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: isDark ? Colors.white70 : Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                color: Colors.grey,
                onPressed: onUnpin,
                tooltip: 'Unpin',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A full-width "N unread messages" separator, shown above the first message
/// that was unread when the chat was opened.
class _UnreadDivider extends StatelessWidget {
  final int count;

  const _UnreadDivider({required this.count});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(vertical: 5),
      color: (isDark ? AppColors.darkAppBar : Colors.white)
          .withValues(alpha: 0.92),
      child: Text(
        count == 1 ? '1 unread message' : '$count unread messages',
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: AppColors.tealGreenDark,
        ),
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
