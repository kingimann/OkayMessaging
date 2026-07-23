import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../models/chat.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../payments/payment_amount_sheet.dart';
import '../payments/payment_service.dart';
import '../relay/relay_config.dart';
import '../state/score_store.dart';
import '../widgets/poll_widgets.dart';
import '../relay/relay_service.dart';
import '../state/chat_store.dart';
import '../state/file_transfer.dart';
import '../state/scheduler.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../utils/maps_link.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/emoji_data.dart';
import '../widgets/heart_burst.dart';
import '../widgets/message_bubble.dart';
import '../widgets/typing_indicator.dart';
import '../state/streak_store.dart';
import '../widgets/streak_chip.dart';
import '../widgets/user_avatar.dart';
import '../widgets/verified_badge.dart';
import '../state/call_service.dart';
import 'contact_info_screen.dart';
import 'forward_screen.dart';
import 'group_info_screen.dart';
import 'image_view_screen.dart';
import 'media_gallery_screen.dart';
import 'okay_pro_screen.dart';
import 'wallpaper_screen.dart';

/// The conversation screen for a single [Chat], backed by [ChatStore].
class ChatScreen extends StatefulWidget {
  final Chat chat;

  /// When set (e.g. opened from search), the chat scrolls to and briefly
  /// highlights this message after it opens.
  final String? initialMessageId;

  const ChatScreen({super.key, required this.chat, this.initialMessageId});

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

  /// Presence: whether the peer is currently online, plus timers to broadcast
  /// our own presence and to revert the peer to offline after a quiet period.
  bool _peerOnline = false;
  Timer? _presenceSend;
  Timer? _presenceRevert;

  /// The unread count when the chat was opened, and the id of the message the
  /// "unread messages" divider should sit above (captured before markRead).
  int _initialUnread = 0;
  String? _unreadAnchorId;

  /// Per-message keys (for scroll-to-message) and the id currently flashing
  /// after a reply-quote jump.
  final Map<String, GlobalKey> _messageKeys = {};
  String? _highlightedId;

  /// Deferred scroll-to-message when opened from search, and the timer that
  /// clears a jumped-to message's highlight.
  Timer? _jumpTimer;
  Timer? _highlightClear;

  String get _chatId => widget.chat.id;

  @override
  void initState() {
    super.initState();
    // Make sure a store entry exists (e.g. for a freshly started chat).
    _store.upsert(widget.chat);
    _captureUnreadAnchor();
    _scrollController.addListener(_onScroll);
    // When opened from search, jump to the matched message once it's laid out.
    if (widget.initialMessageId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _jumpTimer = Timer(const Duration(milliseconds: 250),
            () => _jumpToMessage(widget.initialMessageId!));
      });
    }
    if (RelayConfig.isEnabled) {
      RelayService.instance.typingPing.addListener(_onTypingPing);
      if (_isRealPeer(widget.chat.contact)) {
        _store.addListener(_maybeSendReadReceipt);
        RelayService.instance.presencePing.addListener(_onPresencePing);
        // Announce we're here now, then keep announcing while the chat is open
        // (unless the user has hidden their online status).
        _broadcastPresence();
        _presenceSend = Timer.periodic(
          const Duration(seconds: 15),
          (_) => _broadcastPresence(),
        );
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
    if (!AppState.sendReadReceipts.value) return;
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
    // Respect the privacy setting: don't leak "typing…" when it's off.
    if (!AppState.sendTypingIndicators.value) return;
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

  void _broadcastPresence() {
    if (!AppState.shareLastSeen.value) return;
    RelayService.instance.sendPresence(widget.chat.contact.phone);
  }

  /// Marks the peer online when their presence ping arrives, reverting to
  /// offline after a quiet period.
  void _onPresencePing() {
    if (RelayService.instance.presenceFromDigits !=
        RelayService.digits(widget.chat.contact.phone)) {
      return;
    }
    if (!mounted) return;
    if (!_peerOnline) setState(() => _peerOnline = true);
    _presenceRevert?.cancel();
    _presenceRevert = Timer(const Duration(seconds: 35), () {
      if (mounted) setState(() => _peerOnline = false);
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
      RelayService.instance.presencePing.removeListener(_onPresencePing);
      _store.removeListener(_maybeSendReadReceipt);
    }
    _typingClear?.cancel();
    _presenceSend?.cancel();
    _presenceRevert?.cancel();
    _jumpTimer?.cancel();
    _highlightClear?.cancel();
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

  /// Closes search and scrolls to the tapped result in the full conversation,
  /// flashing it — so you see the match in context.
  void _exitSearchToMessage(String messageId) {
    setState(() {
      _searching = false;
      _searchQuery = '';
      _searchController.clear();
    });
    _jumpTimer?.cancel();
    _jumpTimer = Timer(const Duration(milliseconds: 300),
        () => _jumpToMessage(messageId));
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

  /// Schedules the current [text] to auto-send later. Returns true if set.
  Future<bool> _scheduleMessage(String text) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Send on',
    );
    if (date == null || !mounted) return false;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
      helpText: 'Send at',
    );
    if (time == null || !mounted) return false;
    final when =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!when.isAfter(now)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a time in the future')),
      );
      return false;
    }
    Scheduler.instance.schedule(
      chatId: _chatId,
      contactPhone: widget.chat.contact.phone,
      text: text,
      time: when,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('Scheduled for ${DateFormatter.scheduleLabel(when)}')),
    );
    return true;
  }

  void _showScheduledSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListenableBuilder(
          listenable: Scheduler.instance,
          builder: (context, _) {
            final items = Scheduler.instance.pendingFor(_chatId);
            if (items.isEmpty) {
              Navigator.of(sheetContext).maybePop();
              return const SizedBox.shrink();
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Scheduled messages',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
                for (final s in items)
                  ListTile(
                    leading: const Icon(Icons.schedule),
                    title: Text(s.text,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(DateFormatter.scheduleLabel(s.time)),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Cancel',
                      onPressed: () => Scheduler.instance.cancel(s.id),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _handleSendImage() async {
    if (!await _confirmRecipient()) return;
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

  /// Picks a file and sends it peer-to-peer over a WebRTC data channel (the
  /// bytes never touch a server). Requires a real, online contact.
  Future<void> _handleSendDocument() async {
    if (!RelayConfig.isEnabled || !_isRealPeer(widget.chat.contact)) {
      _showComingSoon(context, 'Direct file sending (needs a real contact)');
      return;
    }
    if (!await _confirmRecipient()) return;
    final result = await FilePicker.pickFiles(withData: true);
    if (result == null || result.files.isEmpty || !mounted) return;
    final f = result.files.first;
    final bytes = f.bytes;
    if (bytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn\'t read that file')),
      );
      return;
    }
    // Record a local marker in the chat, then stream the bytes directly.
    _deliver(Message(
      id: 'file_${DateTime.now().microsecondsSinceEpoch}',
      text: '📎 ${f.name}',
      time: DateTime.now(),
      isMe: true,
      status: MessageStatus.sent,
    ));
    FileTransfer.instance.sendFile(
      widget.chat.contact.phone,
      widget.chat.contact.name,
      f.name,
      Uint8List.fromList(bytes),
    );
  }

  Future<void> _handleSendLocation() async {
    if (!await _confirmRecipient()) return;
    final now = DateTime.now();
    // No device GPS on web; share a representative current location. The card
    // is fully rendered and "Open in Maps" produces a real maps link.
    _deliver(Message(
      id: 'loc_${now.microsecondsSinceEpoch}',
      text: 'Shared location',
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      isLocation: true,
      locationLat: 37.7749,
      locationLng: -122.4194,
      locationLabel: 'My location',
    ));
  }

  /// Opens a picker of the people you chat with, and shares the chosen one as
  /// a contact card.
  void _pickContactToShare() {
    final contacts = _store.allChats
        .map((c) => c.contact)
        .where((c) => !c.isGroup && c.id != widget.chat.contact.id)
        .toList();
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Share contact',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final c in contacts)
                    ListTile(
                      leading: UserAvatar(user: c, radius: 20),
                      title: Text(c.name),
                      subtitle: c.phone.isNotEmpty ? Text(c.phone) : null,
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        _sendContactCard(c);
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendContactCard(AppUser contact) async {
    if (!await _confirmRecipient()) return;
    final now = DateTime.now();
    _deliver(Message(
      id: 'contact_${now.microsecondsSinceEpoch}',
      text: 'Contact: ${contact.name}',
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      isContact: true,
      contactName: contact.name,
      contactPhone: contact.phone,
    ));
  }

  /// Opens a shared-location message in the platform's maps app — Apple Maps
  /// on iPhone/Mac, Google Maps everywhere else — falling back to copying the
  /// link if nothing can handle it.
  Future<void> _openLocation(Message m) async {
    final isApple = defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    final uri = mapsUrl(
      lat: m.locationLat ?? 0,
      lng: m.locationLng ?? 0,
      label: m.locationLabel ?? '',
      apple: isApple,
    );
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!opened && mounted) {
      await Clipboard.setData(ClipboardData(text: uri.toString()));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Maps link copied to clipboard')),
        );
      }
    }
  }

  /// Opens (or starts) a chat with a shared contact card's person.
  void _openSharedContact(Message m) {
    final phone = m.contactPhone ?? '';
    final name = m.contactName ?? 'Contact';
    var chat = phone.isEmpty ? null : _store.chatWithContact(phone);
    if (chat == null) {
      final user = AppUser(
        id: phone.isEmpty ? name : phone,
        name: name,
        avatarColor: '#7A5CFF',
        about: 'Available',
        phone: phone,
      );
      chat = Chat(id: 'chat_${user.id}', contact: user, messages: const []);
      _store.upsert(chat);
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(chat: chat!)),
    );
  }

  /// Stores an outgoing [message] and either delivers it over the relay (to a
  /// real number-based peer) or triggers a simulated reply (demo contact).
  /// When this chat has the "confirm before sending" safeguard on, asks the
  /// user to confirm the recipient before anything is sent. Returns true when
  /// it's safe to proceed (either off, or the user confirmed).
  Future<bool> _confirmRecipient() async {
    final chat = _store.chatById(_chatId);
    if (chat == null || !chat.confirmBeforeSend) return true;
    final contact = chat.contact;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Send to the right chat?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            UserAvatar(user: contact, radius: 30),
            const SizedBox(height: 12),
            Text(
              contact.isGroup
                  ? 'This message will go to everyone in "${contact.name}".'
                  : 'This message will be sent to ${contact.name}.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

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
        onTap: _searching
            ? () => _exitSearchToMessage(m.id)
            : (m.isImage && !_selectionMode ? () => _openImage(m) : null),
        onDoubleTapDown:
            _selectionMode ? null : (d) => _lastDoubleTapPos = d.globalPosition,
        onDoubleTap: _selectionMode ? null : () => _quickReact(m),
        onReplyTap: m.replyTo?.messageId == null
            ? null
            : () => _jumpToMessage(m.replyTo!.messageId!),
        onOpenLocation:
            m.isLocation && !_selectionMode ? () => _openLocation(m) : null,
        onOpenContact:
            m.isContact && !_selectionMode ? () => _openSharedContact(m) : null,
        onPollVote:
            m.isPoll && !_selectionMode ? (i) => _handleVotePoll(m, i) : null,
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

      final Widget row;
      if (_selectionMode) {
        final selected = _selectedIds.contains(m.id);
        row = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _toggleSelect(m.id),
          onLongPress: () => _toggleSelect(m.id),
          child: Container(
            color: selected
                ? AppColors.tealGreenDark.withValues(alpha: 0.16)
                : null,
            child: keyed,
          ),
        );
      } else {
        row = Dismissible(
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
        );
      }
      // Keyed by message id so each message animates in exactly once and
      // never re-animates on later rebuilds (reactions, status, etc.).
      items.add(_MessageEntrance(key: ValueKey('anim_${m.id}'), child: row));
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
    _highlightClear?.cancel();
    _highlightClear = Timer(const Duration(milliseconds: 1200), () {
      if (mounted && _highlightedId == messageId) {
        setState(() => _highlightedId = null);
      }
    });
  }

  /// Pins [message], enforcing the free-tier pin limit. Non-Pro users who hit
  /// the cap are offered Okay Pro instead.
  void _tryPin(Message message) {
    final isPro = AppState.profile.value.verified;
    if (_store.canPinMore(_chatId, isPro: isPro)) {
      _store.pinMessage(_chatId, message.id);
      return;
    }
    showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Pin limit reached'),
        content: const Text(
          'Free accounts can pin up to ${ChatStore.freePinLimit} messages per '
          'chat. Upgrade to Okay Pro to pin as many as you like.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('See Okay Pro'),
          ),
        ],
      ),
    ).then((go) {
      if (go == true && mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const OkayProScreen()),
        );
      }
    });
  }

  /// A bottom sheet listing every pinned message, each with jump + unpin.
  void _showPinnedSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: _store,
        builder: (context, _) {
          final chat = _store.chatById(_chatId);
          final ids = chat?.pinnedMessageIds ?? const <String>[];
          final msgs = <Message>[];
          for (final id in ids.reversed) {
            final match = chat!.messages.where((m) => m.id == id);
            if (match.isNotEmpty) msgs.add(match.first);
          }
          if (msgs.isEmpty) {
            // Nothing left pinned — close the sheet.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (Navigator.of(sheetContext).canPop()) {
                Navigator.of(sheetContext).pop();
              }
            });
            return const SizedBox.shrink();
          }
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.push_pin, size: 18),
                      const SizedBox(width: 8),
                      Text('${msgs.length} pinned',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          _store.unpinAll(_chatId);
                          Navigator.of(sheetContext).pop();
                        },
                        child: const Text('Unpin all'),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: msgs.length,
                    itemBuilder: (context, i) {
                      final m = msgs[i];
                      return ListTile(
                        leading: const Icon(Icons.push_pin_outlined),
                        title: Text(
                          m.isVoice
                              ? 'Voice message'
                              : m.isImage
                                  ? 'Photo'
                                  : m.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Unpin',
                          onPressed: () => _store.unpinMessage(_chatId, m.id),
                        ),
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          _jumpToMessage(m.id);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showMessageActions(Message message) {
    // A deleted tombstone only offers removal from this device.
    if (message.isDeleted) {
      showModalBottomSheet<void>(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete for me'),
            onTap: () {
              _store.deleteMessage(_chatId, message.id);
              Navigator.of(sheetContext).pop();
            },
          ),
        ),
      );
      return;
    }
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
                    _react(message.id, emoji);
                    Navigator.of(sheetContext).pop();
                  },
                  onMore: () {
                    Navigator.of(sheetContext).pop();
                    _pickReactionEmoji(message.id);
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
                      _store.chatById(_chatId)?.isPinnedMessage(message.id) ??
                          false;
                  return ListTile(
                    leading:
                        Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
                    title: Text(pinned ? 'Unpin' : 'Pin'),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      if (pinned) {
                        _store.unpinMessage(_chatId, message.id);
                      } else {
                        _tryPin(message);
                      }
                    },
                  );
                }),
                if (message.isMe && !message.isImage && !message.isVoice)
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('Edit'),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _editMessage(message);
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
                    Navigator.of(sheetContext).pop();
                    _deleteMessage(message);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _editMessage(Message message) async {
    final controller = TextEditingController(text: message.text);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final text = result?.trim();
    if (text == null || text.isEmpty || text == message.text) return;
    _store.editMessage(_chatId, message.id, text);
    if (RelayConfig.isEnabled && _isRealPeer(widget.chat.contact)) {
      RelayService.instance.sendEdit(widget.chat.contact.phone, message.id, text);
    }
  }

  /// Deletes a message: for your own messages on a real-peer chat, offers to
  /// delete it for everyone (removing it on the other device too).
  Future<void> _deleteMessage(Message message) async {
    final canDeleteForEveryone = message.isMe &&
        RelayConfig.isEnabled &&
        _isRealPeer(widget.chat.contact);
    if (!canDeleteForEveryone) {
      _store.deleteMessage(_chatId, message.id);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete for me'),
              onTap: () {
                _store.deleteMessage(_chatId, message.id);
                Navigator.of(sheetContext).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.red),
              title: const Text('Delete for everyone',
                  style: TextStyle(color: Colors.red)),
              onTap: () {
                _store.deleteMessage(_chatId, message.id, forEveryone: true);
                RelayService.instance
                    .sendDelete(widget.chat.contact.phone, message.id);
                Navigator.of(sheetContext).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Toggles a reaction locally and mirrors it to a real peer over the relay.
  void _react(String messageId, String emoji) {
    _store.toggleReaction(_chatId, messageId, emoji);
    ScoreStore.instance.award(ScoreStore.pointsPerReaction);
    ScoreStore.instance.recordFlag('reacted');
    if (RelayConfig.isEnabled && _isRealPeer(widget.chat.contact)) {
      final present = _store
              .chatById(_chatId)
              ?.messages
              .firstWhere((m) => m.id == messageId)
              .reactions
              .contains(emoji) ??
          false;
      RelayService.instance
          .sendReaction(widget.chat.contact.phone, messageId, emoji, present);
    }
  }

  /// Opens the full emoji grid to react to [messageId] with any emoji.
  void _pickReactionEmoji(String messageId) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: 320,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(14),
                child: Text('React with…',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 7,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (final e in EmojiData.picker)
                      InkWell(
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          _react(messageId, e);
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Center(
                          child: Text(e, style: const TextStyle(fontSize: 26)),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Toggles a ❤️ reaction; when one is added, pops a heart at the tap point.
  void _quickReact(Message message) {
    _react(message.id, '❤️');
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
      case 'search':
        setState(() => _searching = true);
      case 'view':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => contact.isGroup
                ? GroupInfoScreen(group: contact, members: widget.chat.members, chatId: _chatId)
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
      case 'disappearing':
        _chooseDisappearing();
      case 'wallpaper':
        Navigator.of(context)
            .push(MaterialPageRoute(
                builder: (_) => WallpaperScreen(chatId: _chatId)))
            .then((_) {
          if (mounted) setState(() {}); // reflect the new per-chat wallpaper
        });
      case 'export':
        _exportChat();
      case 'clear':
        _confirmClearChat();
      case 'delete':
        _confirmDeleteChat();
    }
  }

  Future<void> _chooseDisappearing() async {
    const options = <String, int>{
      'Off': 0,
      '1 hour': 3600,
      '1 day': 86400,
      '1 week': 604800,
    };
    final current = _store.chatById(_chatId)?.disappearingSeconds ?? 0;
    final chosen = await showModalBottomSheet<int>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Row(children: [
                Icon(Icons.timer_outlined, size: 20),
                SizedBox(width: 10),
                Text('Disappearing messages',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ]),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                'New messages in this chat will be deleted from this device '
                'after the selected time.',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ),
            for (final entry in options.entries)
              ListTile(
                title: Text(entry.key),
                trailing: entry.value == current
                    ? Icon(Icons.check,
                        color: Theme.of(sheetContext).colorScheme.primary)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(entry.value),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    _store.setDisappearing(_chatId, chosen);
    setState(() {});
    final label =
        options.entries.firstWhere((e) => e.value == chosen).key;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(chosen == 0
          ? 'Disappearing messages off'
          : 'Disappearing messages: $label'),
    ));
  }

  void _exportChat() {
    final chat = _store.chatById(_chatId);
    if (chat == null) return;
    final me = AppState.profile.value.name;
    final buffer = StringBuffer('Chat with ${widget.chat.contact.name}\n\n');
    for (final m in chat.messages) {
      final who = m.isMe ? me : widget.chat.contact.name;
      final time = DateFormatter.messageTime(m.time);
      final body = m.isImage
          ? '[photo]'
          : m.isVoice
              ? '[voice message]'
              : m.text;
      buffer.writeln('[$time] $who: $body');
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Chat copied to clipboard')),
    );
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
    CallService.instance.startOutgoing(widget.chat.contact, video: video);
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

  /// Sends money to this chat's contact via Stripe Connect. Opens the amount
  /// sheet, creates a destination PaymentIntent, presents the native payment
  /// sheet, and on success drops a payment receipt into the conversation.
  Future<void> _handleSendMoney() async {
    final svc = PaymentService.instance;
    if (!svc.isConfigured) {
      _showComingSoon(context, 'Payments (add your Stripe key to enable)');
      return;
    }
    if (!svc.canSendOnThisDevice) {
      _showComingSoon(context, 'Sending money (use the mobile app)');
      return;
    }
    // Test mode simulates locally, so it works with any contact.
    if (!svc.testMode.value && !_isRealPeer(widget.chat.contact)) {
      _showComingSoon(context, 'Payments (needs a real contact)');
      return;
    }
    if (!await _confirmRecipient()) return;
    if (!mounted) return;
    final result = await showModalBottomSheet<({int cents, String note})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => PaymentAmountSheet(peerName: widget.chat.contact.name),
    );
    if (result == null || result.cents <= 0 || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final phone = widget.chat.contact.phone;
    final now = DateTime.now();
    final payId = 'pay_${now.microsecondsSinceEpoch}';

    // Drop an optimistic "pending" receipt right away and relay it, so the
    // recipient sees the payment as pending while it's confirmed.
    _deliver(Message(
      id: payId,
      text: result.note,
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      isPayment: true,
      paymentAmountCents: result.cents,
      paymentCurrency: 'cad',
      paymentStatus: 'pending',
    ));

    void settle(String status) {
      _store.setPaymentStatus(_chatId, payId, status);
      RelayService.instance.sendPaymentStatus(phone, payId, status);
    }

    try {
      final ok = await svc.sendMoney(
        toPhone: phone,
        amountCents: result.cents,
        note: result.note,
      );
      settle(ok ? 'paid' : 'failed'); // false = cancelled/declined in the sheet
    } on PaymentException catch (e) {
      settle('failed');
      messenger.showSnackBar(SnackBar(
        content: Text(e.code == 'receiver_not_onboarded'
            ? '${widget.chat.contact.name} hasn\'t set up payments yet'
            : 'Payment failed: ${e.code}'),
      ));
    } catch (_) {
      settle('failed');
      messenger.showSnackBar(
          const SnackBar(content: Text('Payment could not be completed')));
    }
  }

  /// Composes and sends a poll into the conversation.
  Future<void> _handleCreatePoll() async {
    final result =
        await showModalBottomSheet<({String question, List<String> options})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const PollComposerSheet(),
    );
    if (result == null || !mounted) return;
    final now = DateTime.now();
    _deliver(Message(
      id: 'poll_${now.microsecondsSinceEpoch}',
      text: '',
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      isPoll: true,
      pollQuestion: result.question,
      pollOptions: result.options,
      pollVotes: List<int>.filled(result.options.length, 0),
    ));
  }

  /// Records the local vote and syncs it to a real peer.
  void _handleVotePoll(Message message, int option) {
    final previous = _store.votePoll(_chatId, message.id, option);
    if (previous == option) return; // no change
    if (RelayConfig.isEnabled && _isRealPeer(widget.chat.contact)) {
      RelayService.instance
          .sendPollVote(widget.chat.contact.phone, message.id, option, previous);
    }
  }

  void _showAttachmentSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        final options = <(IconData, String, Color, VoidCallback)>[
          (Icons.insert_drive_file, 'Document', const Color(0xFF7F66FF),
              _handleSendDocument),
          (Icons.camera_alt, 'Camera', const Color(0xFFEF5DA8),
              _handleSendImage),
          (Icons.photo, 'Gallery', const Color(0xFFC861F9), _handleSendImage),
          (Icons.headphones, 'Audio', const Color(0xFFF97052),
              () => _showComingSoon(context, 'Audio')),
          (Icons.location_on, 'Location', const Color(0xFF1FA855),
              _handleSendLocation),
          (Icons.person, 'Contact', const Color(0xFF009DE2),
              _pickContactToShare),
          (Icons.attach_money, 'Payment', const Color(0xFF12B76A),
              _handleSendMoney),
          (Icons.poll_outlined, 'Poll', const Color(0xFF7F66FF),
              _handleCreatePoll),
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

    return ListenableBuilder(
      // Rebuild on wallpaper changes and on the Okay Pro custom bubble color,
      // so switching either updates the open conversation immediately.
      listenable:
          Listenable.merge([AppState.chatWallpaper, AppState.bubbleColor]),
      builder: (context, _) {
        final globalWallpaper = AppState.chatWallpaper.value;
        return Scaffold(
        // A per-chat wallpaper overrides the global default.
        backgroundColor: (_store.wallpaperFor(_chatId) ?? globalWallpaper) ??
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
                        hintText: 'Search this chat',
                        border: InputBorder.none,
                      ),
                      onChanged: (v) => setState(() => _searchQuery = v),
                    ),
                    actions: [
                      if (_searchQuery.trim().isNotEmpty)
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Text(
                              _visibleMessages.isEmpty
                                  ? 'No matches'
                                  : '${_visibleMessages.length} found',
                              style: TextStyle(
                                  color: Colors.grey.shade500, fontSize: 13),
                            ),
                          ),
                        ),
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
                              ? GroupInfoScreen(group: contact, members: widget.chat.members, chatId: _chatId)
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
                                      child: NameWithBadge(
                                        name: contact.name,
                                        verified: contact.verified,
                                        badgeSize: 16,
                                        style: const TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        trailing: () {
                                          final s = StreakStore.instance
                                              .streakFor(_chatId);
                                          return s > 0
                                              ? StreakChip(
                                                  count: s,
                                                  expiring: StreakStore.instance
                                                      .isExpiringSoon(_chatId),
                                                )
                                              : null;
                                        }(),
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
                                    if (_store
                                            .chatById(_chatId)
                                            ?.confirmBeforeSend ??
                                        false) ...[
                                      const SizedBox(width: 6),
                                      const Icon(
                                        Icons.verified_user,
                                        size: 15,
                                        color: AppColors.tealGreenDark,
                                      ),
                                    ],
                                  ],
                                ),
                                _isTyping
                                    ? const TypingIndicator(
                                        color: AppColors.tealGreenDark,
                                      )
                                    : Text(
                                        (contact.isOnline || _peerOnline)
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
                      if ((_store.chatById(_chatId)?.disappearingSeconds ?? 0) >
                          0)
                        IconButton(
                          icon: const Icon(Icons.timer_outlined),
                          tooltip: 'Disappearing messages on',
                          onPressed: _chooseDisappearing,
                        ),
                      IconButton(
                        icon: const Icon(Icons.call),
                        onPressed: () => _startCall(video: false),
                      ),
                      IconButton(
                        icon: const Icon(Icons.videocam),
                        onPressed: () => _startCall(video: true),
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
                                value: 'search', child: Text('Search')),
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
                                value: 'disappearing',
                                child: Text('Disappearing messages')),
                            const PopupMenuItem(
                                value: 'wallpaper', child: Text('Wallpaper')),
                            const PopupMenuItem(
                                value: 'export', child: Text('Export chat')),
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
                final count = chat.pinnedMessageIds.length;
                return _PinnedBanner(
                  message: matches.first,
                  count: count,
                  onTap: count > 1 ? _showPinnedSheet : null,
                  onUnpin: () => _store.unpinMessage(_chatId, pinnedId),
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
            ListenableBuilder(
              listenable: Scheduler.instance,
              builder: (context, _) {
                final count = Scheduler.instance.pendingFor(_chatId).length;
                if (count == 0) return const SizedBox.shrink();
                return Material(
                  color: AppColors.tealGreenDark.withValues(alpha: 0.12),
                  child: InkWell(
                    onTap: _showScheduledSheet,
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(
                        children: [
                          const Icon(Icons.schedule,
                              size: 18, color: AppColors.tealGreenDark),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              count == 1
                                  ? '1 message scheduled'
                                  : '$count messages scheduled',
                              style: const TextStyle(
                                color: AppColors.tealGreenDark,
                                fontWeight: FontWeight.w600,
                                fontSize: 13.5,
                              ),
                            ),
                          ),
                          const Icon(Icons.chevron_right,
                              size: 20, color: AppColors.tealGreenDark),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            if (!_selectionMode)
              ValueListenableBuilder<Set<String>>(
                valueListenable: AppState.blockedContacts,
                builder: (context, _, __) {
                  if (AppState.isBlocked(widget.chat.contact.phone)) {
                    return _BlockedBanner(
                      name: widget.chat.contact.name,
                      onUnblock: () => AppState.setBlocked(
                          widget.chat.contact.phone, false),
                    );
                  }
                  return ChatInputBar(
                    onSend: _handleSend,
                    onAttach: _showAttachmentSheet,
                    onSendVoice: _handleSendVoice,
                    onTyping: _onTyping,
                    onSchedule: _scheduleMessage,
                    replyTo: _replyTo,
                    onCancelReply: () => setState(() => _replyTo = null),
                    initialText: _store.draftFor(_chatId),
                    onChanged: (t) => _store.setDraft(_chatId, t),
                    confirmSend: _confirmRecipient,
                  );
                },
              ),
          ],
        ),
        );
      },
    );
  }

  void _showComingSoon(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$feature is not available in this demo')),
    );
  }
}

/// Shown in place of the composer when the contact is blocked.
class _BlockedBanner extends StatelessWidget {
  final String name;
  final VoidCallback onUnblock;

  const _BlockedBanner({required this.name, required this.onUnblock});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'You blocked $name',
              style: TextStyle(color: Colors.grey.shade600),
            ),
            TextButton(
              onPressed: onUnblock,
              child: const Text('Unblock to send a message'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReactionRow extends StatelessWidget {
  final ValueChanged<String> onSelected;
  final VoidCallback? onMore;

  const _ReactionRow({required this.onSelected, this.onMore});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
          if (onMore != null)
            InkWell(
              onTap: onMore,
              borderRadius: BorderRadius.circular(24),
              child: Container(
                padding: const EdgeInsets.all(6),
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor:
                      isDark ? Colors.white10 : Colors.grey.shade200,
                  child: Icon(Icons.add,
                      color: isDark ? Colors.white70 : Colors.black54),
                ),
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
  final int count;
  final VoidCallback? onTap;
  final VoidCallback onUnpin;

  const _PinnedBanner({
    required this.message,
    required this.count,
    required this.onUnpin,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: isDark ? AppColors.darkAppBar : Colors.white,
      child: InkWell(
        onTap: onTap,
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
                    Text(
                      count > 1 ? '$count pinned messages' : 'Pinned message',
                      style: const TextStyle(
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

/// Fades and gently slides a message into view once, when it first appears.
class _MessageEntrance extends StatefulWidget {
  final Widget child;

  const _MessageEntrance({super.key, required this.child});

  @override
  State<_MessageEntrance> createState() => _MessageEntranceState();
}

class _MessageEntranceState extends State<_MessageEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..forward();

  late final Animation<double> _curve =
      CurvedAnimation(parent: _controller, curve: Curves.easeOut);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curve,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(_curve),
        child: widget.child,
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
    // Near-white accent in dark mode so the label is readable on the soft
    // dark background (the mono ink is near-black and would vanish).
    final accent = isDark ? const Color(0xFFB9C1C9) : AppColors.tealGreenDark;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: (isDark ? Colors.white : AppColors.tealGreenDark)
              .withValues(alpha: isDark ? 0.10 : 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          (count == 1 ? '1 unread message' : '$count unread messages')
              .toUpperCase(),
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: accent,
          ),
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
