import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/message.dart';
import '../theme/app_theme.dart';
import 'emoji_data.dart';

/// The bottom input area: an optional reply preview, an optional emoji picker,
/// attachment icons, a text field and a send/mic button.
class ChatInputBar extends StatefulWidget {
  final ValueChanged<String> onSend;
  final VoidCallback? onAttach;

  /// Called with the recorded length in seconds when a voice message is sent.
  final ValueChanged<int>? onSendVoice;

  /// The message currently being replied to (shows a quote banner).
  final ReplyInfo? replyTo;
  final VoidCallback? onCancelReply;

  /// Called as the user types (used to broadcast a typing indicator).
  final VoidCallback? onTyping;

  /// Long-pressing send offers to schedule the current text; returns true when
  /// a message was scheduled (so the field is cleared).
  final Future<bool> Function(String text)? onSchedule;

  /// Text to pre-fill the composer with (a saved draft).
  final String initialText;

  /// Called as the composer text changes, so the draft can be saved.
  final ValueChanged<String>? onChanged;

  /// Optional guard run before a text or voice message is sent. When it
  /// resolves false, the send is cancelled and the composer text is kept.
  final Future<bool> Function()? confirmSend;

  const ChatInputBar({
    super.key,
    required this.onSend,
    this.onAttach,
    this.onSendVoice,
    this.replyTo,
    this.onCancelReply,
    this.onTyping,
    this.onSchedule,
    this.initialText = '',
    this.onChanged,
    this.confirmSend,
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);
  bool _hasText = false;
  bool _emojiOpen = false;

  bool _recording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;

  @override
  void initState() {
    super.initState();
    _hasText = _controller.text.trim().isNotEmpty;
    _controller.addListener(() {
      final has = _controller.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
      if (has) widget.onTyping?.call();
      widget.onChanged?.call(_controller.text);
    });
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _startRecording() {
    setState(() {
      _recording = true;
      _recordSeconds = 0;
      _emojiOpen = false;
    });
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _recordSeconds++);
    });
  }

  void _cancelRecording() {
    _recordTimer?.cancel();
    setState(() => _recording = false);
  }

  Future<void> _finishRecording() async {
    _recordTimer?.cancel();
    final seconds = _recordSeconds < 1 ? 1 : _recordSeconds;
    setState(() => _recording = false);
    if (widget.confirmSend != null && !await widget.confirmSend!()) return;
    widget.onSendVoice?.call(seconds);
  }

  String get _recordLabel {
    final m = _recordSeconds ~/ 60;
    final s = _recordSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    // Ask for confirmation first when the chat is guarded; keep the text if
    // the user backs out.
    if (widget.confirmSend != null && !await widget.confirmSend!()) return;
    widget.onSend(text);
    _controller.clear();
  }

  Future<void> _schedule() async {
    final text = _controller.text.trim();
    if (text.isEmpty || widget.onSchedule == null) return;
    final scheduled = await widget.onSchedule!(text);
    if (scheduled) _controller.clear();
  }

  void _insertEmoji(String emoji) {
    final sel = _controller.selection;
    final text = _controller.text;
    if (sel.isValid) {
      final newText = text.replaceRange(sel.start, sel.end, emoji);
      _controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: sel.start + emoji.length),
      );
    } else {
      _controller.text = text + emoji;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // The input pill needs to stand out from the (white) chat background, so
    // it uses a soft grey in light mode rather than blending into white.
    final fieldColor =
        isDark ? AppColors.darkAppBar : const Color(0xFFEFF1F3);

    return DecoratedBox(
      // A hairline separates the composer from the conversation above it.
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF2A2D31) : const Color(0xFFE8EAED),
            width: 0.6,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        // A little bottom breathing room so the bar isn't jammed against the
        // browser toolbar / gesture area on the web build.
        minimum: const EdgeInsets.only(bottom: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.replyTo != null && !_recording)
              _ReplyPreview(
                reply: widget.replyTo!,
                onCancel: widget.onCancelReply,
                isDark: isDark,
              ),
            _recording
                ? _buildRecordingBar(isDark, fieldColor)
                : _buildComposer(isDark, fieldColor),
            if (_emojiOpen && !_recording)
              _EmojiPicker(onSelected: _insertEmoji, isDark: isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildComposer(bool isDark, Color fieldColor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: fieldColor,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      _emojiOpen
                          ? Icons.keyboard
                          : Icons.emoji_emotions_outlined,
                    ),
                    color: Colors.grey,
                    onPressed: () => setState(() => _emojiOpen = !_emojiOpen),
                  ),
                  Expanded(
                    child: ValueListenableBuilder<bool>(
                      valueListenable: AppState.enterToSend,
                      builder: (context, enterToSend, _) => TextField(
                        controller: _controller,
                        minLines: 1,
                        maxLines: 5,
                        textCapitalization: TextCapitalization.sentences,
                        // When enter-to-send is on, the return key submits;
                        // otherwise it inserts a newline and the send button
                        // is used instead.
                        textInputAction: enterToSend
                            ? TextInputAction.send
                            : TextInputAction.newline,
                        onTap: () {
                          if (_emojiOpen) setState(() => _emojiOpen = false);
                        },
                        decoration: const InputDecoration(
                          hintText: 'Message',
                          border: InputBorder.none,
                        ),
                        onSubmitted: enterToSend ? (_) => _send() : null,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.attach_file),
                    color: Colors.grey,
                    onPressed: widget.onAttach,
                  ),
                  if (!_hasText)
                    IconButton(
                      icon: const Icon(Icons.camera_alt_outlined),
                      color: Colors.grey,
                      onPressed: widget.onAttach,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _hasText ? _send : _startRecording,
            onLongPress: _hasText ? _schedule : null,
            child: CircleAvatar(
              radius: 24,
              backgroundColor: AppColors.tealGreenDark,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: Icon(
                  _hasText ? Icons.send : Icons.mic,
                  key: ValueKey(_hasText),
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingBar(bool isDark, Color fieldColor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: fieldColor,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: _cancelRecording,
                    tooltip: 'Cancel',
                  ),
                  const Icon(Icons.fiber_manual_record,
                      color: Colors.red, size: 14),
                  const SizedBox(width: 8),
                  Text(_recordLabel,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  const Text('Recording…',
                      style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _finishRecording,
            child: const CircleAvatar(
              radius: 24,
              backgroundColor: AppColors.tealGreenDark,
              child: Icon(Icons.send, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReplyPreview extends StatelessWidget {
  final ReplyInfo reply;
  final VoidCallback? onCancel;
  final bool isDark;

  const _ReplyPreview({
    required this.reply,
    required this.onCancel,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkAppBar : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: const Border(
          left: BorderSide(color: AppColors.tealGreenDark, width: 4),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  reply.isMe ? 'You' : reply.senderName,
                  style: const TextStyle(
                    color: AppColors.tealGreenDark,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                Text(
                  reply.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isDark ? Colors.white70 : Colors.black54,
                    fontSize: 13.5,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            color: Colors.grey,
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

class _EmojiPicker extends StatelessWidget {
  final ValueChanged<String> onSelected;
  final bool isDark;

  const _EmojiPicker({required this.onSelected, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 220,
      color: isDark ? AppColors.chatBgDark : const Color(0xFFF0F0F0),
      child: GridView.count(
        crossAxisCount: 8,
        padding: const EdgeInsets.all(8),
        children: [
          for (final e in EmojiData.picker)
            InkWell(
              onTap: () => onSelected(e),
              borderRadius: BorderRadius.circular(8),
              child:
                  Center(child: Text(e, style: const TextStyle(fontSize: 24))),
            ),
        ],
      ),
    );
  }
}
