import 'package:flutter/material.dart';

import '../models/message.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import 'message_status_icon.dart';

/// A single chat bubble, aligned left for incoming and right for outgoing.
class MessageBubble extends StatelessWidget {
  final Message message;
  final VoidCallback? onLongPress;

  /// Tapped when this is an image bubble (opens the full-screen viewer).
  final VoidCallback? onTap;

  /// Double-tapped to quick-react with a heart (WhatsApp-style).
  final VoidCallback? onDoubleTap;
  final bool starred;

  const MessageBubble({
    super.key,
    required this.message,
    this.onLongPress,
    this.onTap,
    this.onDoubleTap,
    this.starred = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMe = message.isMe;

    final bubbleColor = isMe
        ? (isDark
            ? AppColors.outgoingBubbleDark
            : AppColors.outgoingBubbleLight)
        : (isDark
            ? AppColors.incomingBubbleDark
            : AppColors.incomingBubbleLight);

    final textColor = isDark ? Colors.white : Colors.black87;
    final metaColor = isDark ? Colors.white60 : Colors.black45;
    final hasReactions = message.reactions.isNotEmpty;

    if (message.isImage) {
      return _ImageBubble(
        message: message,
        isMe: isMe,
        isDark: isDark,
        bubbleColor: bubbleColor,
        hasReactions: hasReactions,
        onLongPress: onLongPress,
        onTap: onTap,
      );
    }

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        onDoubleTap: onDoubleTap,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          margin: EdgeInsets.only(
            left: 8,
            right: 8,
            top: 2,
            bottom: hasReactions ? 16 : 2,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isMe ? 16 : 4),
                    bottomRight: Radius.circular(isMe ? 4 : 16),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 1,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (message.replyTo != null)
                      _ReplyQuote(reply: message.replyTo!, isDark: isDark),
                    if (message.forwarded)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.shortcut, size: 14, color: metaColor),
                            const SizedBox(width: 4),
                            Text(
                              'Forwarded',
                              style: TextStyle(
                                color: metaColor,
                                fontSize: 12.5,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (message.isVoice)
                      _VoiceContent(
                        seconds: message.voiceSeconds,
                        textColor: textColor,
                        metaColor: metaColor,
                      )
                    else
                      Text(
                        message.text,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 15.5,
                          height: 1.3,
                        ),
                      ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (starred) ...[
                          Icon(Icons.star, size: 13, color: metaColor),
                          const SizedBox(width: 3),
                        ],
                        Text(
                          DateFormatter.messageTime(message.time),
                          style: TextStyle(color: metaColor, fontSize: 11),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: 4),
                          MessageStatusIcon(status: message.status, size: 15),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (hasReactions)
                Positioned(
                  bottom: -14,
                  right: isMe ? 4 : null,
                  left: isMe ? null : 4,
                  child: _ReactionPill(
                    reactions: message.reactions,
                    isDark: isDark,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReplyQuote extends StatelessWidget {
  final ReplyInfo reply;
  final bool isDark;

  const _ReplyQuote({required this.reply, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(4),
        border: const Border(
          left: BorderSide(color: AppColors.tealGreenDark, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            reply.isMe ? 'You' : reply.senderName,
            style: const TextStyle(
              color: AppColors.tealGreenDark,
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            reply.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isDark ? Colors.white70 : Colors.black54,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// An image message: a rounded placeholder photo tile (a gradient stands in
/// for a real image) with the time/ticks overlaid on a scrim.
class _ImageBubble extends StatelessWidget {
  final Message message;
  final bool isMe;
  final bool isDark;
  final Color bubbleColor;
  final bool hasReactions;
  final VoidCallback? onLongPress;
  final VoidCallback? onTap;

  const _ImageBubble({
    required this.message,
    required this.isMe,
    required this.isDark,
    required this.bubbleColor,
    required this.hasReactions,
    required this.onLongPress,
    required this.onTap,
  });

  static const _gradients = [
    [Color(0xFF667EEA), Color(0xFF764BA2)],
    [Color(0xFFFF9A9E), Color(0xFFFAD0C4)],
    [Color(0xFF43CEA2), Color(0xFF185A9D)],
    [Color(0xFFF6D365), Color(0xFFFDA085)],
    [Color(0xFF30CFD0), Color(0xFF330867)],
    [Color(0xFFA8EDEA), Color(0xFFFED6E3)],
  ];

  @override
  Widget build(BuildContext context) {
    final colors = _gradients[message.imageSeed % _gradients.length];
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        onTap: onTap,
        child: Container(
          margin: EdgeInsets.only(
            left: 8,
            right: 8,
            top: 2,
            bottom: hasReactions ? 16 : 2,
          ),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(16),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: Stack(
              children: [
                Hero(
                  tag: 'photo_${message.id}',
                  child: Container(
                    width: 220,
                    height: 260,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: colors,
                      ),
                    ),
                    child: const Center(
                      child: Icon(Icons.image, color: Colors.white70, size: 48),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.45),
                        ],
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          DateFormatter.messageTime(message.time),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 11),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: 4),
                          MessageStatusIcon(status: message.status, size: 15),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A voice-message row: a play/pause toggle, a static waveform, and the
/// clip length. Playback is simulated (no real audio in this UI demo).
class _VoiceContent extends StatefulWidget {
  final int seconds;
  final Color textColor;
  final Color metaColor;

  const _VoiceContent({
    required this.seconds,
    required this.textColor,
    required this.metaColor,
  });

  @override
  State<_VoiceContent> createState() => _VoiceContentState();
}

class _VoiceContentState extends State<_VoiceContent> {
  bool _playing = false;

  // A fixed pseudo-waveform so bubbles look varied but stable.
  static const _heights = [
    6.0,
    12.0,
    18.0,
    10.0,
    22.0,
    14.0,
    8.0,
    20.0,
    16.0,
    11.0,
    24.0,
    9.0,
    15.0,
    19.0,
    7.0,
    13.0,
    21.0,
    10.0,
    17.0,
    12.0,
  ];

  String get _label {
    final m = widget.seconds ~/ 60;
    final s = widget.seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 210,
      child: Row(
        children: [
          GestureDetector(
            onTap: () => setState(() => _playing = !_playing),
            child: Icon(
              _playing ? Icons.pause : Icons.play_arrow,
              color: AppColors.tealGreenDark,
              size: 30,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SizedBox(
              height: 26,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  for (final h in _heights)
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 0.5),
                        height: h,
                        decoration: BoxDecoration(
                          color: widget.metaColor,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(_label, style: TextStyle(color: widget.metaColor, fontSize: 12)),
        ],
      ),
    );
  }
}

class _ReactionPill extends StatelessWidget {
  final List<String> reactions;
  final bool isDark;

  const _ReactionPill({required this.reactions, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkAppBar : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? Colors.black26 : Colors.black12,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 1,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Text(
        reactions.join(' '),
        style: const TextStyle(fontSize: 12.5),
      ),
    );
  }
}
