import 'package:flutter/material.dart';

import '../models/message.dart';
import '../theme/app_theme.dart';
import 'emoji_data.dart';

/// The bottom input area: an optional reply preview, an optional emoji picker,
/// attachment icons, a text field and a send/mic button.
class ChatInputBar extends StatefulWidget {
  final ValueChanged<String> onSend;
  final VoidCallback? onAttach;

  /// The message currently being replied to (shows a quote banner).
  final ReplyInfo? replyTo;
  final VoidCallback? onCancelReply;

  const ChatInputBar({
    super.key,
    required this.onSend,
    this.onAttach,
    this.replyTo,
    this.onCancelReply,
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  final TextEditingController _controller = TextEditingController();
  bool _hasText = false;
  bool _emojiOpen = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final has = _controller.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
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
    final fieldColor = isDark ? AppColors.darkAppBar : Colors.white;

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.replyTo != null)
            _ReplyPreview(
              reply: widget.replyTo!,
              onCancel: widget.onCancelReply,
              isDark: isDark,
            ),
          Padding(
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
                          onPressed: () =>
                              setState(() => _emojiOpen = !_emojiOpen),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            minLines: 1,
                            maxLines: 5,
                            textCapitalization: TextCapitalization.sentences,
                            onTap: () {
                              if (_emojiOpen) {
                                setState(() => _emojiOpen = false);
                              }
                            },
                            decoration: const InputDecoration(
                              hintText: 'Message',
                              border: InputBorder.none,
                            ),
                            onSubmitted: (_) => _send(),
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
                  onTap: _send,
                  child: CircleAvatar(
                    radius: 24,
                    backgroundColor: AppColors.tealGreenDark,
                    child: Icon(
                      _hasText ? Icons.send : Icons.mic,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_emojiOpen)
            _EmojiPicker(onSelected: _insertEmoji, isDark: isDark),
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
