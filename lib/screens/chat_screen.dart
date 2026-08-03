import '../state/smart_replies.dart';
import 'quick_replies_screen.dart';
import '../state/quick_replies.dart';
import '../state/session.dart';
import 'form_fill_screen.dart';
import 'form_builder_screen.dart';
import '../models/form_spec.dart';
import '../state/screenshot_watch.dart';
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../data/mock_data.dart';
import '../models/chat.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../payments/payment_amount_sheet.dart';
import '../payments/payment_service.dart';
import '../payments/storage_economics.dart';
import '../relay/relay_config.dart';
import '../state/score_store.dart';
import '../util/phone_format.dart';
import '../util/file_moderation.dart';
import '../util/photo_prep.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/poll_widgets.dart';
import '../relay/relay_service.dart';
import '../state/chat_store.dart';
import '../state/push_service.dart';
import '../state/file_transfer.dart';
import '../state/scheduler.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/emoji_data.dart';
import '../widgets/emoji_gif_sheet.dart';
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
import 'ghost_view_screen.dart';
import 'image_view_screen.dart';
import 'location_map_screen.dart';
import 'media_gallery_screen.dart';
import '../util/geocoding.dart';
import 'explore_map_screen.dart';
import '../state/identity_verification.dart';
import 'score_screen.dart';

/// The conversation screen for a single [Chat], backed by [ChatStore].
class ChatScreen extends StatefulWidget {
  final Chat chat;

  /// When set (e.g. opened from search), the chat scrolls to and briefly
  /// highlights this message after it opens.
  final String? initialMessageId;

  /// When set, this is a THREAD under that message rather than the room:
  /// the transcript is the root plus its replies, and anything sent joins
  /// them instead of the main conversation.
  ///
  /// The same screen rather than a new one, so a thread gets the composer,
  /// the attachments, reactions, editing and delivery exactly as the room
  /// has them — a second, thinner chat screen would drift from this one the
  /// first time either changed.
  final String? threadRootId;

  const ChatScreen({
    super.key,
    required this.chat,
    this.initialMessageId,
    this.threadRootId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ScrollController _scrollController = ScrollController();
  final ChatStore _store = ChatStore.instance;

  ReplyInfo? _replyTo;
  bool _isTyping = false;

  /// Who is typing, for the group indicator ('' in a 1:1 chat — the header
  /// already names the person).
  String _typingName = '';
  bool _showScrollToBottom = false;

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
    _store.addListener(_refreshSuggestions);
    _refreshSuggestions();
    // Registered here because dispose removes them — for a while it removed
    // listeners nothing had added, which silently switched off screenshot
    // announcements and the live blanking of protected chats.
    ScreenshotWatch.instance.taken.addListener(_onScreenshot);
    ScreenshotWatch.instance.capturing.addListener(_onCapturing);
    RelayService.instance.screenshotPing.addListener(_onRemoteScreenshot);
    RelayService.instance.recordingPing.addListener(_onRemoteRecording);
    RelayService.instance.ghostShotPing.addListener(_onRemoteGhostShot);
    // A push for the conversation you are reading should not draw a banner
    // over the message the app has already put on screen.
    PushService.instance.setOpenChat(widget.chat.contact.phone);
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
    if (!AppState.sendReadReceipts.value) return;
    final incoming =
        _store.chatById(_chatId)?.messages.where((m) => !m.isMe).toList();
    if (incoming == null || incoming.isEmpty) return;
    final lastId = incoming.last.id;
    if (lastId == _lastAckedIncomingId) return;
    final phones = _relayPhones();
    if (phones.isEmpty) return;
    _lastAckedIncomingId = lastId;
    for (final phone in phones) {
      RelayService.instance.sendReceipt(phone, 'read', messageId: lastId);
    }
  }

  /// Broadcasts that we're typing (throttled) to whoever this chat reaches.
  void _onTyping() {
    // Respect the privacy setting: don't leak "typing…" when it's off.
    if (!AppState.sendTypingIndicators.value) return;
    final now = DateTime.now();
    if (_lastTypingSent != null &&
        now.difference(_lastTypingSent!) < const Duration(seconds: 2)) {
      return;
    }
    final phones = _relayPhones();
    if (phones.isEmpty) return;
    _lastTypingSent = now;
    for (final phone in phones) {
      RelayService.instance.sendTyping(phone);
    }
  }

  /// Shows the typing indicator when someone in *this* chat is typing — the
  /// peer of a 1:1 conversation, or any member of a group (who gets named).
  void _onTypingPing() {
    final fromDigits = RelayService.instance.typingFromDigits;
    if (fromDigits == null) return;
    String name = '';
    if (widget.chat.contact.isGroup) {
      final members = _store.chatById(_chatId)?.members ?? const [];
      final match = members.where(
          (m) => RelayService.digits(m.phone) == fromDigits).toList();
      if (match.isEmpty) return;
      name = match.first.name.split(' ').first;
    } else if (fromDigits != RelayService.digits(widget.chat.contact.phone)) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _isTyping = true;
      _typingName = name;
    });
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
    PushService.instance.setOpenChat(null);
    _store.removeListener(_refreshSuggestions);
    ScreenshotWatch.instance.taken.removeListener(_onScreenshot);
    ScreenshotWatch.instance.capturing.removeListener(_onCapturing);
    RelayService.instance.screenshotPing.removeListener(_onRemoteScreenshot);
    RelayService.instance.recordingPing.removeListener(_onRemoteRecording);
    RelayService.instance.ghostShotPing.removeListener(_onRemoteGhostShot);
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

  /// Whether this screen is showing a thread rather than the room.
  bool get _inThread => widget.threadRootId != null;

  /// The transcript. In the room, everything that is not in a thread — a
  /// thread's whole purpose is that its replies are not here. In a thread,
  /// the message it hangs under followed by its replies.
  List<Message> get _messages {
    final all = _store.chatById(_chatId)?.messages ?? const <Message>[];
    final root = widget.threadRootId;
    if (root == null) {
      return [for (final m in all) if (m.threadRootId == null) m];
    }
    return [
      for (final m in all)
        if (m.id == root || m.threadRootId == root) m
    ];
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

  /// Replies the device suggested for the last message received.
  List<String> _suggested = const [];

  /// The message the current suggestions were generated for, so a rebuild
  /// that changes nothing does not ask the model again.
  String? _suggestedFor;

  /// Asks the on-device model for replies to whatever just arrived.
  ///
  /// Cheap to call: it returns immediately on the phones that cannot do this
  /// (most of them), when the last word was yours, and when the answer for
  /// this message is already on screen.
  Future<void> _refreshSuggestions() async {
    final chat = _store.chatById(_chatId);
    final messages = chat?.messages ?? const <Message>[];
    if (!SmartReplies.worthSuggesting(messages)) {
      if (_suggested.isNotEmpty && mounted) {
        setState(() {
          _suggested = const [];
          _suggestedFor = null;
        });
      }
      return;
    }
    final latest = messages.last.id;
    if (latest == _suggestedFor) return;
    _suggestedFor = latest;
    final replies = await SmartReplies.instance.suggest(
      messages: messages,
      contactName: widget.chat.contact.name,
    );
    if (!mounted) return;
    // Another message may have landed while the model was thinking; that
    // request's answer is the one to show.
    if (_suggestedFor != latest) return;
    setState(() => _suggested = replies);
  }

  /// First names that can be @mentioned in this chat — the group's members
  /// (excluding you). Empty for one-to-one chats.
  List<String> _mentionNames() {
    if (!widget.chat.contact.isGroup) return const [];
    final members = widget.chat.members.isNotEmpty
        ? widget.chat.members
        : MockData.contacts();
    final me = AppState.profile.value.id;
    return members
        .where((u) => u.id != me && !u.isGroup)
        .map((u) => u.name.split(' ').first)
        .toList();
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

  /// Picks a real photo from the device, shrinks it to fit the relay, and
  /// sends it inline — device to device, no bucket in the middle.
  Future<void> _handleSendImage({bool viewOnce = false}) async {
    String? dataUri;
    try {
      dataUri = await PhotoPrep.pickPhoto();
    } on FileRejected catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.reason)));
      }
      return;
    }
    if (dataUri == null) {
      // Either the user cancelled (say nothing) or the image was unusable.
      return;
    }
    if (!mounted || !await _confirmRecipient()) return;
    final now = DateTime.now();
    _deliver(Message(
      id: 'img_${now.microsecondsSinceEpoch}',
      text: '',
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      isImage: true,
      imageUrl: dataUri,
      imageSeed: now.microsecondsSinceEpoch % 6,
      viewOnce: viewOnce,
      replyTo: _replyTo,
    ));
    setState(() => _replyTo = null);
  }

  /// Sends a GIF picked from the composer. It rides as an image message with
  /// a real URL, so it animates in the bubble and travels over the relay like
  /// any other photo — the file itself stays on the GIF provider's CDN.
  Future<void> _handleSendGif(String url) async {
    if (!await _confirmRecipient()) return;
    final now = DateTime.now();
    _deliver(Message(
      id: 'gif_${now.microsecondsSinceEpoch}',
      text: '',
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      isImage: true,
      imageUrl: url,
      imageSeed: now.microsecondsSinceEpoch % 6,
      replyTo: _replyTo,
    ));
    setState(() => _replyTo = null);
  }

  void _handleSendVoice(int seconds,
      {String? audioUrl, String? audioPath, String? audioKey}) {
    // No audio, no message: the input bar only calls back with nothing when
    // capture or upload failed, and it has already said so.
    if (audioUrl == null && audioPath == null) return;
    final now = DateTime.now();
    _deliver(Message(
      id: 'voice_${now.microsecondsSinceEpoch}',
      text: '',
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      isVoice: true,
      voiceSeconds: seconds,
      audioUrl: audioUrl,
      audioPath: audioPath,
      audioKey: audioKey,
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
    // Moderate before anything leaves the device: executables, scripts, and
    // blocked content are refused with a reason.
    final verdict = FileModeration.inspectFile(Uint8List.fromList(bytes));
    if (!verdict.allowed) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(verdict.reason!)));
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
    // The SAME map as Maps, in picking mode — search as you type, nearby
    // categories, saved places, recents, and a name for what you picked.
    // This used to open a second, much poorer map that existed only here.
    final picked = await Navigator.of(context).push<GeoResult>(
      MaterialPageRoute(builder: (_) => const ExploreMapScreen(picking: true)),
    );
    if (picked == null || !mounted) return;
    if (!await _confirmRecipient()) return;
    final now = DateTime.now();
    final label = picked.name.trim();
    _deliver(Message(
      id: 'loc_${now.microsecondsSinceEpoch}',
      // The place's own name, not "Shared location". A dropped pin is reverse
      // geocoded on the way through, so even a point in a field arrives as a
      // street rather than as two numbers.
      text: label.isEmpty ? 'Shared location' : label,
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      isLocation: true,
      locationLat: picked.lat,
      locationLng: picked.lng,
      locationLabel: label.isEmpty ? 'Shared location' : label,
    ));
  }

  /// Opens a picker of the people you chat with, and shares the chosen one as
  /// a contact card.
  void _pickContactToShare() {
    // Everyone you could plausibly share: 1:1 chats and members of your
    // groups (people you know but may never have messaged directly), minus
    // yourself and this chat's own peer.
    final me = AppState.profile.value.id;
    final seen = <String>{};
    final contacts = <AppUser>[];
    void consider(AppUser u) {
      if (u.isGroup || u.phone.isEmpty) return;
      if (u.id == me || u.id == widget.chat.contact.id) return;
      if (seen.add(RelayService.digits(u.phone))) contacts.add(u);
    }

    for (final chat in _store.allChats) {
      consider(chat.contact);
      chat.members.forEach(consider);
    }
    contacts.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
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
            if (contacts.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
                child: Text(
                  'No one to share yet — contacts appear here once you have '
                  'other chats or groups.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.subtle(context)),
                ),
              )
            else
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

  /// Opens a shared-location message on a full-screen, interactive
  /// OpenStreetMap; from there the user can hand off to their maps app.
  void _openLocation(Message m) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LocationMapScreen(
          lat: m.locationLat ?? 0,
          lng: m.locationLng ?? 0,
          label: m.locationLabel ?? '',
        ),
      ),
    );
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
      builder: (dialogContext) => Dialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: UserAvatar(user: contact, radius: 30)),
              const SizedBox(height: 12),
              const Text(
                'Send to the right chat?',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                contact.isGroup
                    ? 'This message will go to everyone in "${contact.name}".'
                    : 'This message will be sent to ${contact.name}.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14, height: 1.4, color: AppColors.subtle(context)),
              ),
              const SizedBox(height: 18),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accentOn(dialogContext),
                  foregroundColor: AppColors.onAccent(dialogContext),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26)),
                ),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Send'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text('Cancel',
                    style: TextStyle(color: AppColors.subtle(context))),
              ),
            ],
          ),
        ),
      ),
    );
    return ok ?? false;
  }

  /// Whether [message] may leave this conversation by forward or copy.
  ///
  /// Two ways it may not: this chat is protected, or the message arrived
  /// carrying the sender's own protection. The second is the one that
  /// matters — turning your own setting off must not unlock what somebody
  /// else sent you under theirs.
  bool _mayLeaveChat(Message message) =>
      !_store.isProtected(_chatId) && !message.protected;

  /// The same question for a selection, which is only exportable if every
  /// message in it is.
  bool get _selectionMayLeave => _selectedMessages.every(_mayLeaveChat);

  /// Watches for a screenshot while this conversation is on screen, and only
  /// when it is protected.
  ///
  /// Attributed to whatever was actually being looked at: the notifier fires
  /// app-wide, so a screen that is not on top must ignore it or a screenshot
  /// of the chat list would be announced as a screenshot of a conversation.
  void _onScreenshot() {
    if (!mounted || !ModalRoute.of(context)!.isCurrent) return;
    if (!_store.isProtected(_chatId)) return;
    _store.noteScreenshot(_chatId, byMe: true);
    if (RelayConfig.isEnabled && _isRealPeer(widget.chat.contact)) {
      RelayService.instance.sendScreenshotNotice(widget.chat.contact.phone);
    }
  }

  /// What sits where the conversation was while the screen is being captured.
  Widget _capturedNotice(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.screenshot_monitor_outlined,
                  size: 54, color: AppColors.subtle(context)),
              const SizedBox(height: 18),
              const Text('Hidden while the screen is being captured',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text(
                'This chat is protected, and the screen is being recorded or '
                'mirrored. The conversation comes back on its own when that '
                'stops. The other person has been told.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14.5,
                    height: 1.45,
                    color: AppColors.subtle(context)),
              ),
            ],
          ),
        ),
      );

  /// A recording started or stopped. Announced ONCE per recording, on the
  /// edge rather than on every rebuild — a notice per frame would bury the
  /// conversation it is warning about.
  void _onCapturing() {
    if (!mounted) return;
    final on = ScreenshotWatch.instance.capturing.value;
    setState(() {});
    if (!on || !_store.isProtected(_chatId)) return;
    if (!ModalRoute.of(context)!.isCurrent) return;
    _store.noteScreenshot(_chatId, byMe: true, recording: true);
    if (RelayConfig.isEnabled && _isRealPeer(widget.chat.contact)) {
      RelayService.instance.sendRecordingNotice(widget.chat.contact.phone);
    }
  }

  /// The far end is recording this conversation.
  void _onRemoteRecording() {
    if (!mounted) return;
    final from = RelayService.instance.recordingFromDigits;
    if (from.isEmpty ||
        from != RelayService.digits(widget.chat.contact.phone)) {
      return;
    }
    _store.noteScreenshot(_chatId, byMe: false, recording: true);
  }

  /// The far end screenshotted this conversation.
  void _onRemoteScreenshot() {
    if (!mounted) return;
    final from = RelayService.instance.screenshotFromDigits;
    if (from.isEmpty ||
        from != RelayService.digits(widget.chat.contact.phone)) {
      return;
    }
    _store.noteScreenshot(_chatId, byMe: false);
  }

  /// The far end screenshotted a ghost message from this conversation while
  /// it was open on their screen.
  void _onRemoteGhostShot() {
    if (!mounted) return;
    final from = RelayService.instance.ghostShotFromDigits;
    if (from.isEmpty ||
        from != RelayService.digits(widget.chat.contact.phone)) {
      return;
    }
    _store.noteScreenshot(_chatId, byMe: false, ghost: true);
  }

  void _deliver(Message rawMessage) {
    // Stamped here rather than at each of the eight places a message is
    // built, so a send path added later carries the flag without anybody
    // remembering to add it. The setting belongs to whoever wrote the words,
    // which is why it is read from this chat and then travels.
    var message = rawMessage;
    if (_store.isProtected(_chatId)) {
      message = message.copyWith(protected: true);
    }
    // Same funnel, same reason: every send path lands here, so a thread reply
    // cannot escape into the room because one of them forgot.
    if (_inThread) {
      message = message.copyWith(threadRootId: widget.threadRootId);
    }
    _store.addMessage(_chatId, message);
    WidgetsBinding.instance.addPostFrameCallback((_) => _animateToBottom());
    if (!RelayConfig.isEnabled) return;
    if (widget.chat.contact.isGroup) {
      // Groups have no server side: the message is fanned out to each member's
      // inbox, encrypted separately for every one of them.
      final chat = _store.chatById(_chatId);
      if (chat != null) RelayService.instance.sendToGroup(chat, message);
    } else if (_isRealPeer(widget.chat.contact)) {
      RelayService.instance.send(widget.chat.contact.phone, message);
    }
    // No simulated replies: only real people answer here.
  }

  /// A real, number-identified peer (chat started with an actual phone number),
  /// as opposed to a seeded demo contact or a group.
  bool _isRealPeer(AppUser c) =>
      !c.isGroup && c.phone.isNotEmpty && c.id == c.phone;

  /// Every inbox an in-chat event (edit, reaction, receipt, …) goes to: the
  /// peer for a real 1:1 chat, every member for a group, nobody for demo
  /// chats or note-to-self. Events fan out exactly like the messages they
  /// are about.
  List<String> _relayPhones() {
    // No RelayConfig gate here: every RelayService send is already a no-op
    // without a configured relay, and gating the *decision* on it hid the
    // delete-for-everyone option in local/dev builds.
    final c = widget.chat.contact;
    if (c.isGroup) {
      final chat = _store.chatById(_chatId);
      return chat == null ? const [] : RelayService.groupRecipients(chat);
    }
    return _isRealPeer(c) ? [c.phone] : const [];
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

  Future<void> _deleteSelected() async {
    final selected = _selectedMessages;
    final allMine = selected.isNotEmpty && selected.every((m) => m.isMe);
    if (allMine && _relayPhones().isNotEmpty) {
      final forEveryone = await showModalBottomSheet<bool>(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete for me'),
                onTap: () => Navigator.of(sheetContext).pop(false),
              ),
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text('Delete for everyone',
                    style: TextStyle(color: Colors.red)),
                onTap: () => Navigator.of(sheetContext).pop(true),
              ),
            ],
          ),
        ),
      );
      if (forEveryone == null) return; // dismissed — keep the selection
      for (final m in selected) {
        _store.deleteMessage(_chatId, m.id, forEveryone: forEveryone);
        if (forEveryone) {
          for (final phone in _relayPhones()) {
            RelayService.instance.sendDelete(phone, m.id);
          }
        }
      }
      _exitSelection();
      return;
    }
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
            : (_canOpenImage(m) && !_selectionMode
                ? () => _openImage(m)
                : (_canOpenGhost(m) && !_selectionMode
                    ? () => _openGhost(m)
                    : null)),
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
        // The sender reads what came back; everybody else fills it in.
        onOpenForm: m.isForm && !_selectionMode
            ? () => m.isMe ? _openFormResponses(m) : _handleFillForm(m)
            : null,
        // A call record is the natural place to return the call from.
        onCallBack: m.isCallEvent &&
                !_selectionMode &&
                !widget.chat.contact.isGroup
            ? () => CallService.instance
                .startOutgoing(widget.chat.contact, video: m.callVideo)
            : null,
      );

      final key = _messageKeys.putIfAbsent(m.id, () => GlobalKey());
      final highlighted = _highlightedId == m.id;
      final keyed = Container(
        key: key,
        color: highlighted
            ? AppColors.accentOn(context).withValues(alpha: 0.18)
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
                ? AppColors.accentOn(context).withValues(alpha: 0.16)
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

      // The thread hanging under this message, if any. Only in the room —
      // inside a thread the root is the thing you are already reading, and a
      // line offering to open it would lead back to here.
      if (!_inThread && !_selectionMode) {
        final replies = _store.threadReplyCount(_chatId, m.id);
        if (replies > 0) {
          items.add(_ThreadLine(
            count: replies,
            isMe: m.isMe,
            onTap: () => _openThread(m),
          ));
        }
      }
    }
    return items;
  }

  /// Opens the thread hanging under [message] — the same screen, showing the
  /// root and its replies instead of the room.
  void _openThread(Message message) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(chat: widget.chat, threadRootId: message.id),
    ));
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

  /// Pins [message]. Pinning is unlimited and free for everyone.
  void _tryPin(Message message) {
    _store.pinMessage(_chatId, message.id);
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
                if (message.text.trim().isNotEmpty &&
                    _mayLeaveChat(message) &&
                    !QuickReplies.instance.isFull)
                  ListTile(
                    leading: const Icon(Icons.bolt_outlined),
                    title: const Text('Save as quick reply'),
                    onTap: () async {
                      Navigator.of(sheetContext).pop();
                      final saved =
                          await QuickReplies.instance.add(message.text);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(saved
                              ? 'Saved as a quick reply'
                              : 'That is already saved')));
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.reply),
                  title: const Text('Reply'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _startReply(message);
                  },
                ),
                // Groups only, and never from inside a thread: a thread of
                // threads is how a group gets a second place to lose a
                // conversation. In a 1:1 there is nothing to spare the room
                // from — the room is the two of you.
                if (widget.chat.contact.isGroup &&
                    !_inThread &&
                    message.threadRootId == null)
                  ListTile(
                    leading: const Icon(Icons.forum_outlined),
                    title: const Text('Reply in thread'),
                    subtitle: const Text('Keeps it out of the main group'),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _openThread(message);
                    },
                  ),
                // A photo forwards as a photo. It used to forward
                // `message.text`, which for a picture sent without a caption
                // is an empty bubble at the other end.
                if ((message.isImage || message.text.trim().isNotEmpty) &&
                    _mayLeaveChat(message))
                  ListTile(
                    leading: const Icon(Icons.shortcut),
                    title: const Text('Forward'),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ForwardScreen(
                              text: message.text,
                              imageUrl:
                                  message.isImage ? message.imageUrl : null),
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
                if (message.text.trim().isNotEmpty && _mayLeaveChat(message))
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
                if (message.isMe)
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('Message info'),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _showMessageInfo(message);
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
    final result = await showAppTextPrompt(
      context,
      icon: Icons.edit_outlined,
      title: 'Edit message',
      initial: message.text,
      maxLines: 4,
      capitalization: TextCapitalization.sentences,
    );
    final text = result?.trim();
    if (text == null || text.isEmpty || text == message.text) return;
    _store.editMessage(_chatId, message.id, text);
    for (final phone in _relayPhones()) {
      RelayService.instance.sendEdit(phone, message.id, text);
    }
  }

  /// Deletes a message: for your own messages on a real-peer chat, offers to
  /// delete it for everyone (removing it on the other device too).
  Future<void> _deleteMessage(Message message) async {
    // Your own message can be recalled anywhere it was actually delivered —
    // a real 1:1 peer or a group (the old real-peer check silently made
    // group deletes local-only, so the message lived on for everyone else).
    final canDeleteForEveryone =
        message.isMe && _relayPhones().isNotEmpty;
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
                for (final phone in _relayPhones()) {
                  RelayService.instance.sendDelete(phone, message.id);
                }
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
    final phones = _relayPhones();
    if (phones.isNotEmpty) {
      final present = _store
              .chatById(_chatId)
              ?.messages
              .firstWhere((m) => m.id == messageId)
              .reactions
              .contains(emoji) ??
          false;
      for (final phone in phones) {
        RelayService.instance
            .sendReaction(phone, messageId, emoji, present);
      }
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
                child: EmojiPane(
                  onPick: (e) {
                    Navigator.of(sheetContext).pop();
                    _react(messageId, e);
                  },
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

  /// Pull-to-refresh: rebuild the live subscription and drain the offline
  /// mailbox, so "is something stuck?" has an answer that is always safe to
  /// reach for. A no-op (with a beat of spinner) when the relay is off.
  Future<void> _refreshChat() async {
    if (!RelayConfig.isEnabled) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return;
    }
    await RelayService.instance.wake();
    await RelayService.instance.fetchMailbox();
  }

  void _startCall({required bool video}) {
    if (_isNoteToSelf) return; // nobody on the other end to ring
    if (widget.chat.contact.isGroup) {
      final chat = _store.chatById(_chatId) ?? widget.chat;
      CallService.instance.startGroupCall(chat, video: video);
      return;
    }
    CallService.instance.startOutgoing(widget.chat.contact, video: video);
  }

  /// A WhatsApp-style "Message info" dialog: when it was sent and how far it
  /// got (sent → delivered → read), plus edit details when applicable.
  void _showMessageInfo(Message message) {
    final statusLabel = switch (message.status) {
      MessageStatus.read => 'Read',
      MessageStatus.delivered => 'Delivered',
      MessageStatus.sent => 'Sent',
      _ => 'Pending',
    };
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Message info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow(Icons.schedule,
                'Sent ${DateFormatter.messageTime(message.time)}'),
            const SizedBox(height: 10),
            _infoRow(
              message.status == MessageStatus.read
                  ? Icons.done_all
                  : message.status == MessageStatus.delivered
                      ? Icons.done_all
                      : Icons.done,
              'Status: $statusLabel',
            ),
            if (message.edited) ...[
              const SizedBox(height: 10),
              _infoRow(Icons.edit_outlined, 'Edited'),
            ],
            if (message.viewOnce) ...[
              const SizedBox(height: 10),
              _infoRow(
                  Icons.timer_outlined,
                  message.viewOnceOpened
                      ? 'View once · opened'
                      : 'View once · not opened yet'),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String text) => Row(
        children: [
          Icon(icon, size: 18, color: AppColors.subtle(context)),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      );

  /// Whether tapping an image should open the viewer. A spent view-once photo
  /// is no longer openable by the recipient.
  bool _canOpenImage(Message m) {
    if (!m.isImage) return false;
    if (!m.viewOnce) return true;
    if (m.isMe) return true; // the sender can still review what they sent
    return !m.viewOnceOpened;
  }

  /// A ghost text opens like a view-once photo: the sender can re-read what
  /// they wrote; the recipient gets exactly one viewing.
  bool _canOpenGhost(Message m) {
    if (!m.viewOnce || m.isImage) return false;
    if (m.isMe) return true;
    return !m.viewOnceOpened;
  }

  Future<void> _openGhost(Message message) async {
    // Refused, not blanked-after: opening it during a recording would read
    // the message into the capture before the viewer could hide anything.
    if (!message.isMe && ScreenshotWatch.instance.capturing.value) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Ghost messages stay hidden while the screen is '
              'being recorded or mirrored.')));
      return;
    }
    final consume =
        message.viewOnce && !message.isMe && !message.viewOnceOpened;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GhostViewScreen(
          text: message.text,
          senderName: message.isMe ? 'You' : widget.chat.contact.name,
          onScreenshot: () {
            _store.noteScreenshot(_chatId, byMe: true, ghost: true);
            for (final phone in _relayPhones()) {
              RelayService.instance.sendGhostShotNotice(phone);
            }
          },
        ),
      ),
    );
    if (consume) {
      _store.markViewOnceOpened(_chatId, message.id);
      for (final phone in _relayPhones()) {
        RelayService.instance.sendViewOnceOpened(phone, message.id);
      }
    }
  }

  /// Composes a ghost message: typed in its own sheet rather than the
  /// composer, so the words never sit in a field that autocorrect, drafts or
  /// the send button treat as an ordinary message.
  Future<void> _composeGhost() async {
    final controller = TextEditingController();
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
            left: 20,
            right: 20,
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Ghost message',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              // The promise this feature can actually keep, said up front:
              // one view, hidden from recordings, screenshots announced —
              // never "cannot be screenshotted", which iOS does not offer.
              'Can be read once, then it\'s gone. It stays hidden while a '
              'screen recording is running, and screenshots can\'t be '
              'blocked — both of you see a note if one is taken.',
              style: TextStyle(
                  fontSize: 12.5, color: AppColors.subtle(sheetContext)),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 1,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Say it once…',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.of(sheetContext).pop(v),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () =>
                  Navigator.of(sheetContext).pop(controller.text),
              child: const Text('Send ghost message'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty) return;
    if (!mounted || !await _confirmRecipient()) return;
    final now = DateTime.now();
    _deliver(Message(
      id: 'ghost_${now.microsecondsSinceEpoch}',
      text: text.trim(),
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      viewOnce: true,
    ));
  }

  Future<void> _openImage(Message message) async {
    // The single viewing must not be spent into a recording — same rule as a
    // ghost text.
    if (message.viewOnce &&
        !message.isMe &&
        ScreenshotWatch.instance.capturing.value) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('View-once photos stay hidden while the screen is '
              'being recorded or mirrored.')));
      return;
    }
    // A received "view once" photo is consumed after this single viewing.
    final consume =
        message.viewOnce && !message.isMe && !message.viewOnceOpened;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImageViewScreen(
          message: message,
          senderName: widget.chat.contact.name,
        ),
      ),
    );
    if (consume) {
      _store.markViewOnceOpened(_chatId, message.id);
      for (final phone in _relayPhones()) {
        RelayService.instance.sendViewOnceOpened(phone, message.id);
      }
    }
  }

  /// Whether this conversation is the private notes chat. Nothing leaves it,
  /// so there is nobody to pay.
  bool get _isNoteToSelf => widget.chat.contact.id == 'self';

  /// The members of a group who could actually be paid: real, number-identified
  /// people, never yourself and never the group itself.
  List<AppUser> get _payableGroupMembers {
    final me = AppState.profile.value;
    return [
      for (final u in widget.chat.members)
        if (u.id != me.id && u.id != 'me' && u.id != 'self' && _isRealPeer(u))
          u
    ];
  }

  /// Asks which member of a group to pay, then makes them confirm it.
  ///
  /// A group has no single "the other person", so sending to the chat would
  /// have to guess — and guessing wrong here moves real money to the wrong
  /// person. Two deliberate steps: pick a name, then confirm that name.
  Future<AppUser?> _pickGroupRecipient() async {
    final members = _payableGroupMembers;
    if (members.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No one in this group has set up payments yet')));
      return null;
    }
    final picked = await showModalBottomSheet<AppUser>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text('Who are you paying?',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            for (final m in members)
              ListTile(
                leading: UserAvatar(user: m, radius: 20),
                title: Text(m.name),
                subtitle: Text(m.phone),
                onTap: () => Navigator.pop(sheetContext, m),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return null;

    // Naming them again, on their own, is the whole point — a mis-tap in a
    // list of names shouldn't be enough to move money.
    final ok = await showAppConfirmDialog(
      context,
      icon: Icons.person_outline,
      title: 'Pay ${picked.name}?',
      message: 'Money will go to ${picked.name} (${picked.phone}). '
          'Check this is the right person — a sent payment cannot be '
          'reversed from here.',
      confirmLabel: 'Yes, ${picked.name}',
      cancelLabel: 'Back',
    );
    if (!ok || !mounted) return null;
    return picked;
  }

  /// Sends money to a person via Stripe Connect. Opens the amount sheet,
  /// creates a direct PaymentIntent on their connected account, presents the
  /// native payment sheet, and on success drops a receipt into the
  /// conversation.
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
    // The same gate the Wallet screen is behind. Sending money from a chat is
    // the wallet's own capability reached another way, so guarding one screen
    // and not this would be guarding the door and leaving the window.
    if (!IdentityVerification.instance.allowsTrusted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Verify your ID to send money.'),
        action: SnackBarAction(
          label: 'Verify',
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const ScoreScreen())),
        ),
      ));
      return;
    }
    // Not even in test mode: there is no second party in your own notes, so
    // offering to pay them is nonsense however the payment is simulated.
    if (_isNoteToSelf) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('You can\'t send money to yourself')));
      return;
    }

    // A group is not a recipient. Resolve one person, deliberately.
    var recipient = widget.chat.contact;
    if (recipient.isGroup) {
      final picked = await _pickGroupRecipient();
      if (picked == null || !mounted) return;
      recipient = picked;
    }

    // Test mode simulates locally, so it works with any contact.
    if (!svc.testMode.value && !_isRealPeer(recipient)) {
      _showComingSoon(context, 'Payments (needs a real contact)');
      return;
    }
    if (!widget.chat.contact.isGroup && !await _confirmRecipient()) return;
    if (!mounted) return;
    final result = await showModalBottomSheet<({int cents, String note, bool acknowledged})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => PaymentAmountSheet(peerName: recipient.name),
    );
    if (result == null || result.cents <= 0 || !mounted) return;

    // A large amount gets one more look, naming both the person and the
    // number. The sheet's checkbox covers "I know this is final"; this covers
    // "I meant this many zeros", which is the other way a send goes wrong.
    if (result.cents >= PaymentEconomics.confirmTwiceAboveCents) {
      final sure = await showAppConfirmDialog(
        context,
        icon: Icons.warning_amber_rounded,
        title: 'Send \$${(result.cents / 100).toStringAsFixed(2)}?',
        message: '${recipient.name} will receive '
            '\$${(result.cents / 100).toStringAsFixed(2)}. '
            'This cannot be undone from here.',
        confirmLabel: 'Yes, send it',
        cancelLabel: 'Go back',
        destructive: true,
      );
      if (!sure || !mounted) return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final phone = recipient.phone;
    final now = DateTime.now();
    final payId = 'pay_${now.microsecondsSinceEpoch}';

    // Drop an optimistic "pending" receipt right away and relay it, so the
    // recipient sees the payment as pending while it's confirmed.
    _deliver(Message(
      id: payId,
      // In a group the receipt is visible to everyone, so it has to say who
      // was paid — otherwise it reads as a payment to the room.
      text: widget.chat.contact.isGroup
          ? (result.note.isEmpty
              ? 'To ${recipient.name}'
              : 'To ${recipient.name} — ${result.note}')
          : result.note,
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
        acknowledged: result.acknowledged,
      );
      // The sheet returning true means the card authorised, not that it was
      // charged: capture waits on the cardholder check. Saying "paid" here
      // would be a lie for a card that is about to be refused.
      if (!ok) {
        settle('failed');
        return;
      }
      settle('pending');
      final intentId = svc.lastPaymentIntentId;
      final outcome = intentId.isEmpty
          ? 'pending'
          : await svc.awaitSettlement(intentId);
      settle(switch (outcome) {
        'succeeded' || 'paid' => 'paid',
        'pending' => 'pending',
        _ => 'failed',
      });
      if (outcome.startsWith('blocked_') && mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text(outcome == 'blocked_prepaid'
              ? 'Prepaid cards can\'t be used to send money.'
              : 'That card has to be in your own name.'),
        ));
      }
    } on PaymentException catch (e) {
      settle('failed');
      messenger.showSnackBar(SnackBar(
        content: Text(switch (e.code) {
          'receiver_not_onboarded' =>
            '${widget.chat.contact.name} hasn\'t set up payments yet',
          // Say why, plainly. A silent failure here reads as a bug and
          // invites another attempt.
          'sender_banned' =>
            'Sending money is blocked on this account after a chargeback.',
          'identity_required' =>
            'Verify your identity before sending money — Settings → Get '
                'verified.',
          'recipient_not_accepting' =>
            '${recipient.name} isn\'t accepting payments.',
          'daily_limit_reached' =>
            'You\'ve reached your daily sending limit. Raise it in '
                'Wallet → Payment controls (a higher limit starts tomorrow).',
          'over_send_limit' =>
            'That\'s more than your limit for a single transfer. Change it '
                'in Wallet → Payment controls.',
          'payments_paused' =>
            'Your payments are paused. Turn that off in Wallet → Payment '
                'controls.',
          _ => 'Payment failed: ${e.code}',
        }),
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

  /// Puts a saved reply in the box — not into the chat.
  ///
  /// Inserted rather than sent, so a word can be changed first: a canned
  /// reply that sends itself is a message nobody read before it left. It
  /// appends to whatever is already typed rather than replacing it.
  Future<void> _handleQuickReply() async {
    final reply = await pickQuickReply(context);
    if (reply == null || !mounted) return;
    final existing = _store.draftFor(_chatId).trimRight();
    _store.setDraft(
        _chatId, existing.isEmpty ? reply : '$existing $reply');
  }

  /// Builds a form and sends it as a message.
  Future<void> _handleCreateForm() async {
    final result =
        await Navigator.of(context).push<(String, List<FormFieldSpec>)>(
      MaterialPageRoute(builder: (_) => const FormBuilderScreen()),
    );
    if (result == null || !mounted) return;
    final now = DateTime.now();
    _deliver(Message(
      id: 'form_${now.microsecondsSinceEpoch}',
      text: '',
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      isForm: true,
      formTitle: result.$1,
      formFields: result.$2,
    ));
  }

  /// Fills in somebody's form and sends the answers back.
  Future<void> _handleFillForm(Message message) async {
    final mine = Session.instance.user.value?.name ?? '';
    final previous = message.formResponses
        .where((r) => r.from == mine)
        .map((r) => r.answers)
        .toList();
    final answers = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => FormFillScreen(
          title: message.formTitle,
          fields: message.formFields,
          initial: previous.isEmpty ? const [] : previous.first,
        ),
      ),
    );
    if (answers == null || !mounted) return;
    // Recorded here too, so the sender sees their own answers in the same
    // list as everybody's rather than only the people who replied to them.
    _store.applyFormResponse(_chatId, message.id,
        FormResponse(from: mine, answers: answers, at: DateTime.now()));
    if (RelayConfig.isEnabled && _isRealPeer(widget.chat.contact)) {
      RelayService.instance
          .sendFormResponse(widget.chat.contact.phone, message.id, answers);
    }
  }

  /// Shows what came back.
  void _openFormResponses(Message message) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FormResponsesScreen(
        title: message.formTitle,
        fields: message.formFields,
        responses: message.formResponses,
      ),
    ));
  }

  /// Records the local vote and syncs it to everyone the chat reaches.
  void _handleVotePoll(Message message, int option) {
    final previous = _store.votePoll(_chatId, message.id, option);
    if (previous == option) return; // no change
    for (final phone in _relayPhones()) {
      RelayService.instance
          .sendPollVote(phone, message.id, option, previous);
    }
  }

  /// GIFs moved off the composer bar and into the attachment panel — the
  /// bar was drowning in buttons.
  Future<void> _pickGifAttachment() async {
    final picked = await showEmojiGifSheet(context, initialTab: 1);
    final url = picked?.gif?.url;
    if (url != null) _handleSendGif(url);
  }

  /// The composer's attachment options, shown inline above the keyboard.
  List<AttachmentOption> _attachmentOptions() => [
        AttachmentOption(
            icon: Icons.photo,
            label: 'Photos',
            color: const Color(0xFFC861F9),
            onTap: _handleSendImage),
        AttachmentOption(
            icon: Icons.gif_box_outlined,
            label: 'GIF',
            color: const Color(0xFFF97052),
            onTap: _pickGifAttachment),
        AttachmentOption(
            icon: Icons.timer_outlined,
            label: 'View once',
            color: const Color(0xFF0A84FF),
            onTap: () => _handleSendImage(viewOnce: true)),
        AttachmentOption(
            icon: Icons.blur_on,
            label: 'Ghost message',
            color: const Color(0xFF5E5CE6),
            onTap: _composeGhost),
        AttachmentOption(
            icon: Icons.insert_drive_file,
            label: 'Document',
            color: const Color(0xFF7F66FF),
            onTap: _handleSendDocument),
        AttachmentOption(
            icon: Icons.location_on,
            label: 'Location',
            color: const Color(0xFF1FA855),
            onTap: _handleSendLocation),
        AttachmentOption(
            icon: Icons.person,
            label: 'Contact',
            color: const Color(0xFF009DE2),
            onTap: _pickContactToShare),

        // Not offered in your own notes: there is no second party to pay.
        // Groups keep it — the option asks which member first.
        if (!_isNoteToSelf)
          AttachmentOption(
              icon: Icons.attach_money,
              label: 'Payment',
              color: const Color(0xFF12B76A),
              onTap: _handleSendMoney),
        AttachmentOption(
            icon: Icons.poll_outlined,
            label: 'Poll',
            color: const Color(0xFF7F66FF),
            onTap: _handleCreatePoll),
        AttachmentOption(
            icon: Icons.bolt_outlined,
            label: 'Quick reply',
            color: const Color(0xFFF79009),
            onTap: _handleQuickReply),
        AttachmentOption(
            icon: Icons.assignment_outlined,
            label: 'Form',
            color: const Color(0xFF2E90FA),
            onTap: _handleCreateForm),
      ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final contact = widget.chat.contact;

    return ListenableBuilder(
      // Rebuild on wallpaper and the Okay Pro custom bubble color, and on
      // the chat store — so mute / disappearing / pin toggled from the
      // contact-info screen refresh the header the moment you return.
      //
      // The streak store too: a streak advances, lapses, or gets agreed with
      // the peer (reconcile, straight off the relay) without the chat store
      // changing at all, and the header's flame has to follow it rather than
      // waiting for the next unrelated redraw.
      listenable: Listenable.merge([
        AppState.chatWallpaper,
        AppState.bubbleColor,
        _store,
        StreakStore.instance,
      ]),
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
                  if (_selectionMayLeave) ...[
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
                  ] else
                    // Absent rather than disabled: a greyed-out Forward is a
                    // button somebody taps twice before believing it.
                    IconButton(
                      icon: const Icon(Icons.lock_outline),
                      tooltip: 'Protected — this cannot be forwarded or copied',
                      onPressed: () => ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(
                              content: Text('This conversation is protected. '
                                  'Messages in it cannot be forwarded or '
                                  'copied.'))),
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
                                  color: AppColors.subtle(context), fontSize: 13),
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
                : _inThread
                    // A thread is a different room to be in, and the header
                    // has to say so — the same name and avatar as the group
                    // would leave somebody typing into a side conversation
                    // believing they were talking to everyone.
                    ? AppBar(
                        title: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Thread',
                                style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600)),
                            Text(
                              'Stays out of ${contact.name}',
                              style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.normal,
                                  color: AppColors.subtle(context)),
                            ),
                          ],
                        ),
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
                                        // Bare numbers print like a phone
                                        // would show them.
                                        name: formatPhoneForDisplay(
                                            contact.name),
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
                                      Icon(
                                        Icons.verified_user,
                                        size: 15,
                                        color: AppColors.accentOn(context),
                                      ),
                                    ],
                                  ],
                                ),
                                _isTyping
                                    ? Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (_typingName.isNotEmpty)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                  right: 4),
                                              child: Text(
                                                _typingName,
                                                style: TextStyle(
                                                  fontSize: 12.5,
                                                  color: AppColors.accentOn(
                                                      context),
                                                ),
                                              ),
                                            ),
                                          TypingIndicator(
                                            color: AppColors.accentOn(context),
                                          ),
                                        ],
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
                      // Your own notes have nobody on the other end to ring.
                      if (!_isNoteToSelf) ...[
                        IconButton(
                          icon: const Icon(Icons.call),
                          onPressed: () => _startCall(video: false),
                        ),
                        IconButton(
                          icon: const Icon(Icons.videocam),
                          onPressed: () => _startCall(video: true),
                        ),
                      ],
                      // The overflow menu is gone from this bar. Of the four
                      // things it held, two were already reachable — tapping
                      // the name opens Contact & chat settings, which is
                      // where "Media, links, and docs" lives — and "Send as
                      // text (SMS)" moved there too, being a thing you decide
                      // about a person rather than about this moment.
                      //
                      // Search stays here, as an icon. It is a MODE OF THIS
                      // SCREEN, not a setting: searching a conversation is
                      // something you do while reading it, and routing it
                      // through a settings screen would mean leaving the
                      // thing you are searching.
                      IconButton(
                        icon: const Icon(Icons.search),
                        tooltip: 'Search this chat',
                        onPressed: () => setState(() => _searching = true),
                      ),
                      // The pinboard is the other mode of this screen: the
                      // same conversation with the scrolling taken out —
                      // pins, links, photos, places and files in one place.
                      IconButton(
                        icon: const Icon(Icons.push_pin_outlined),
                        tooltip: 'Pinboard',
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => MediaGalleryScreen(
                              chatId: _chatId,
                              contactName: contact.name,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
        // A screenshot can only be announced after the fact. A recording is
        // still going, so the honest thing is to take the conversation off
        // the screen for as long as it lasts — announcing and carrying on
        // would be telling somebody their messages are being filmed while
        // filming them.
        body: _store.isProtected(_chatId) &&
                ScreenshotWatch.instance.capturing.value
            ? _capturedNotice(context)
            : Column(
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
                        return RefreshIndicator(
                          onRefresh: _refreshChat,
                          child: LayoutBuilder(
                            builder: (context, constraints) =>
                                SingleChildScrollView(
                              // Scrollable even when empty, or there is
                              // nothing to pull.
                              physics: const AlwaysScrollableScrollPhysics(),
                              child: SizedBox(
                                height: constraints.maxHeight,
                                child: const _EmptyConversation(),
                              ),
                            ),
                          ),
                        );
                      }
                      return RefreshIndicator(
                        onRefresh: _refreshChat,
                        child: ListView(
                          controller: _scrollController,
                          // Short transcripts don't fill the screen and would
                          // otherwise have no overscroll to pull against.
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          children: items,
                        ),
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
                        // Theme-aware: the light accent is invisible on the
                        // dark app-bar surface.
                        foregroundColor: isDark
                            ? Colors.white
                            : AppColors.accentOn(context),
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
                  color: AppColors.accentOn(context).withValues(alpha: 0.12),
                  child: InkWell(
                    onTap: _showScheduledSheet,
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(
                        children: [
                          Icon(Icons.schedule,
                              size: 18, color: AppColors.accentOn(context)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              count == 1
                                  ? '1 message scheduled'
                                  : '$count messages scheduled',
                              style: TextStyle(
                                color: AppColors.accentOn(context),
                                fontWeight: FontWeight.w600,
                                fontSize: 13.5,
                              ),
                            ),
                          ),
                          Icon(Icons.chevron_right,
                              size: 20, color: AppColors.accentOn(context)),
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
                    onSendGif: _handleSendGif,
                    attachments: _attachmentOptions(),
                    onSendVoice: _handleSendVoice,
                    onTyping: _onTyping,
                    onSchedule: _scheduleMessage,
                    replyTo: _replyTo,
                    onCancelReply: () => setState(() => _replyTo = null),
                    initialText: _store.draftFor(_chatId),
                    onChanged: (t) => _store.setDraft(_chatId, t),
                    confirmSend: _confirmRecipient,
                    mentionNames: _mentionNames(),
                    suggestedReplies: _suggested,
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
              style: TextStyle(color: AppColors.subtle(context)),
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
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: AppColors.accentOn(context), width: 4),
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
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accentOn(context),
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
    final accent = isDark ? const Color(0xFFB9C1C9) : AppColors.accentOn(context);
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: (isDark ? Colors.white : AppColors.accentOn(context))
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

/// The "N replies" line under a message that has a thread.
///
/// Deliberately quiet and deliberately not a bubble: it is a door into the
/// conversation, not part of it. Aligned with the message it belongs to so it
/// reads as attached to that one rather than floating between two.
class _ThreadLine extends StatelessWidget {
  const _ThreadLine({
    required this.count,
    required this.isMe,
    required this.onTap,
  });

  final int count;
  final bool isMe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentOn(context);
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(
            left: isMe ? 0 : 18, right: isMe ? 18 : 0, bottom: 6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.forum_outlined, size: 15, color: accent),
                const SizedBox(width: 6),
                Text(
                  count == 1 ? '1 reply' : '$count replies',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: accent),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
