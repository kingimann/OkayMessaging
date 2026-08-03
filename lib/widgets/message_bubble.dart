import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../app_state.dart';
import '../models/community.dart';
import '../models/message.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../state/community_store.dart';
import '../state/voice_media.dart';
import '../payments/payment_amount_sheet.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import 'app_dialogs.dart';
import 'chat_photo.dart';
import 'message_status_icon.dart';
import 'osm_map.dart';
import 'poll_widgets.dart';
import 'rich_message_text.dart';

/// A single chat bubble, aligned left for incoming and right for outgoing.
class MessageBubble extends StatelessWidget {
  final Message message;
  final VoidCallback? onLongPress;

  /// Tapped when this is an image bubble (opens the full-screen viewer).
  final VoidCallback? onTap;

  /// Double-tapped to quick-react with a heart (WhatsApp-style).
  final VoidCallback? onDoubleTap;

  /// Records where the double-tap landed, so a heart can burst there.
  final GestureTapDownCallback? onDoubleTapDown;

  /// Tapped on the quoted reply to jump to the original message.
  final VoidCallback? onReplyTap;
  final bool starred;

  /// Tapped on a shared-location card (opens it in maps).
  final VoidCallback? onOpenLocation;

  /// Tapped on the "Message" action of a shared-contact card.
  final VoidCallback? onOpenContact;

  /// Called with the chosen option index when the user votes on a poll.
  final ValueChanged<int>? onPollVote;

  /// Opens a form — to fill in, or to read what came back. Which of those it
  /// is belongs to the chat screen, not here: the bubble only knows there is
  /// a form and who sent it.
  final VoidCallback? onOpenForm;

  /// Tapping a call-record chip calls that person back.
  final VoidCallback? onCallBack;

  const MessageBubble({
    super.key,
    required this.message,
    this.onLongPress,
    this.onTap,
    this.onDoubleTap,
    this.onDoubleTapDown,
    this.onReplyTap,
    this.starred = false,
    this.onOpenLocation,
    this.onOpenContact,
    this.onPollVote,
    this.onOpenForm,
    this.onCallBack,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMe = message.isMe;

    // Outgoing bubbles are high-contrast (dark in light mode, light in dark
    // mode); incoming bubbles are a subtle grey. Text/meta/tick colors are
    // derived so they always contrast with the bubble they sit on.
    const ink = Color(0xFF0F1419);
    // Okay Pro members can pick a custom color for their own bubbles; it only
    // ever applies to outgoing (isMe) bubbles. When set, text/meta/tick colors
    // are derived from its luminance so they stay readable on any hue.
    final Color? custom = isMe ? AppState.bubbleColor.value : null;
    final bubbleColor = custom ??
        (isMe
            ? (isDark
                ? AppColors.outgoingBubbleDark
                : AppColors.outgoingBubbleLight)
            : (isDark
                ? AppColors.incomingBubbleDark
                : AppColors.incomingBubbleLight));

    final Color textColor;
    final Color metaColor;
    final Color readTickColor;
    if (custom != null) {
      final onCustom =
          custom.computeLuminance() > 0.5 ? ink : Colors.white;
      textColor = onCustom;
      metaColor = onCustom.withValues(alpha: 0.7);
      readTickColor = onCustom;
    } else if (isMe) {
      textColor = isDark ? ink : Colors.white;
      metaColor = isDark ? Colors.black54 : Colors.white70;
      readTickColor = isDark ? ink : Colors.white;
    } else {
      textColor = isDark ? const Color(0xFFE7E9EA) : ink;
      metaColor = isDark ? Colors.white54 : Colors.black45;
      readTickColor = metaColor;
    }
    final hasReactions = message.reactions.isNotEmpty;

    if (message.isDeleted) {
      return Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onLongPress: onLongPress,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: bubbleColor.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: metaColor.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.do_not_disturb_alt, size: 15, color: metaColor),
                const SizedBox(width: 6),
                Text(
                  isMe ? 'You deleted this message' : 'This message was deleted',
                  style: TextStyle(
                    color: textColor.withValues(alpha: 0.7),
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  DateFormatter.messageTime(message.time),
                  style: TextStyle(color: metaColor, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (message.isCallEvent) {
      return _CallEventBubble(
        message: message,
        isMe: isMe,
        bubbleColor: bubbleColor,
        textColor: textColor,
        metaColor: metaColor,
        onLongPress: onLongPress,
        onCallBack: onCallBack,
      );
    }

    // Any view-once message — a photo or a ghost text — renders as a sealed
    // bubble that never shows its content in the transcript.
    if (message.viewOnce) {
      return _ViewOnceBubble(
        message: message,
        isMe: isMe,
        bubbleColor: bubbleColor,
        textColor: textColor,
        metaColor: metaColor,
        onLongPress: onLongPress,
        onTap: onTap,
      );
    }

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

    if (message.isPayment) {
      return Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: PaymentBubble(
              amountCents: message.paymentAmountCents,
              note: message.text,
              isMe: isMe,
              status: message.paymentStatus,
            ),
          ),
        ),
      );
    }

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        onDoubleTap: onDoubleTap,
        onDoubleTapDown: onDoubleTapDown,
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
                padding: const EdgeInsets.fromLTRB(13, 8, 13, 7),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: const BorderRadius.all(Radius.circular(20)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isMe && message.senderName.isNotEmpty)
                      _SenderLabel(name: message.senderName),
                    if (message.replyTo != null)
                      _ReplyQuote(
                        reply: message.replyTo!,
                        isDark: isDark,
                        onTap: onReplyTap,
                      ),
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
                    if (message.isForm)
                      _FormContent(
                        message: message,
                        textColor: textColor,
                        metaColor: metaColor,
                        onOpen: onOpenForm,
                      )
                    else if (message.isPoll)
                      PollBubble(
                        message: message,
                        textColor: textColor,
                        metaColor: metaColor,
                        onVote: (i) => onPollVote?.call(i),
                      )
                    else if (message.isVoice)
                      _VoiceContent(
                        seconds: message.voiceSeconds,
                        audioUrl: message.audioUrl,
                        audioPath: message.audioPath,
                        audioKey: message.audioKey,
                        textColor: textColor,
                        metaColor: metaColor,
                      )
                    else if (message.isLocation)
                      _LocationContent(
                        message: message,
                        textColor: textColor,
                        metaColor: metaColor,
                        onTap: onOpenLocation,
                      )
                    else if (message.isContact)
                      _ContactContent(
                        message: message,
                        textColor: textColor,
                        metaColor: metaColor,
                        onMessage: onOpenContact,
                      )
                    else if (message.isServerInvite)
                      _ServerInviteContent(
                        message: message,
                        textColor: textColor,
                        metaColor: metaColor,
                      )
                    else
                      RichMessageText(
                        text: message.text,
                        textColor: textColor,
                        linkColor: isDark
                            ? const Color(0xFF53BDEB)
                            : const Color(0xFF027EB5),
                      ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (starred) ...[
                          Icon(Icons.star, size: 13, color: metaColor),
                          const SizedBox(width: 3),
                        ],
                        if (message.edited) ...[
                          GestureDetector(
                            onTap: message.originalText == null
                                ? null
                                : () =>
                                    _showOriginal(context, message.originalText!),
                            child: Text(
                              'edited',
                              style: TextStyle(
                                color: metaColor,
                                fontSize: 11,
                                fontStyle: FontStyle.italic,
                                decoration: message.originalText == null
                                    ? null
                                    : TextDecoration.underline,
                                decorationColor: metaColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          DateFormatter.messageTime(message.time),
                          style: TextStyle(color: metaColor, fontSize: 11),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: 4),
                          MessageStatusIcon(
                            status: message.status,
                            size: 15,
                            color: metaColor,
                            readColor: readTickColor,
                          ),
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

/// Shows the pre-edit text of an edited message.
void _showOriginal(BuildContext context, String original) {
  showAppConfirmDialog(
    context,
    icon: Icons.history_edu_outlined,
    title: 'Original message',
    message: original.isEmpty ? '(empty)' : original,
    confirmLabel: 'Close',
    cancelLabel: null,
  );
}

/// A call record in the thread: "Missed voice call", "Voice call · 4:32" —
/// a compact chip rather than a speech bubble, since nobody said anything.
class _CallEventBubble extends StatelessWidget {
  final Message message;
  final bool isMe;
  final Color bubbleColor;
  final Color textColor;
  final Color metaColor;
  final VoidCallback? onLongPress;
  final VoidCallback? onCallBack;

  const _CallEventBubble({
    required this.message,
    required this.isMe,
    required this.bubbleColor,
    required this.textColor,
    required this.metaColor,
    required this.onLongPress,
    this.onCallBack,
  });

  String get _label {
    final kind = message.callVideo ? 'Video call' : 'Voice call';
    switch (message.callEvent) {
      case 'missed':
        return 'Missed ${kind.toLowerCase()}';
      case 'declined':
        return '$kind declined';
      case 'noanswer':
        return 'No answer';
      default:
        final s = message.callSeconds;
        if (s <= 0) return kind;
        final m = s ~/ 60;
        return '$kind · $m:${(s % 60).toString().padLeft(2, '0')}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final missed = message.callEvent == 'missed';
    final iconColor = missed ? Colors.redAccent : metaColor;
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        onTap: onCallBack,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: bubbleColor.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: iconColor.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      message.callVideo
                          ? (missed ? Icons.missed_video_call : Icons.videocam)
                          : (missed
                              ? Icons.phone_missed
                              : (isMe ? Icons.call_made : Icons.call_received)),
                      size: 16,
                      color: iconColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _label,
                    style: TextStyle(
                      color: missed ? Colors.redAccent : textColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    DateFormatter.messageTime(message.time),
                    style: TextStyle(color: metaColor, fontSize: 11),
                  ),
                ],
              ),
              if (onCallBack != null)
                Padding(
                  padding: const EdgeInsets.only(left: 36, top: 2),
                  child: Text(
                    'Tap to call back',
                    style: TextStyle(color: metaColor, fontSize: 11.5),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The sender's name above an incoming group bubble. Each member keeps a
/// stable colour (derived from their name) so a thread is easy to follow.
class _SenderLabel extends StatelessWidget {
  final String name;
  const _SenderLabel({required this.name});

  static const _palette = [
    Color(0xFF1F8AC0),
    Color(0xFFC0392B),
    Color(0xFF7D3C98),
    Color(0xFF117864),
    Color(0xFFB9770E),
    Color(0xFF2E4053),
  ];

  static Color colorFor(String name) =>
      _palette[name.hashCode.abs() % _palette.length];

  @override
  Widget build(BuildContext context) {
    final base = colorFor(name);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Text(
        name,
        style: TextStyle(
          color: isDark ? Color.lerp(base, Colors.white, 0.45) : base,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ReplyQuote extends StatelessWidget {
  final ReplyInfo reply;
  final bool isDark;
  final VoidCallback? onTap;

  const _ReplyQuote({required this.reply, required this.isDark, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(4),
        border: Border(
          left: BorderSide(color: AppColors.accentOn(context), width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            reply.isMe ? 'You' : reply.senderName,
            style: TextStyle(
              color: AppColors.accentOn(context),
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
      ),
    );
  }
}

/// A "view once" photo bubble: a compact chip that opens the photo a single
/// time for the recipient, then shows an "Opened" state (Snapchat style).
class _ViewOnceBubble extends StatelessWidget {
  final Message message;
  final bool isMe;
  final Color bubbleColor;
  final Color textColor;
  final Color metaColor;
  final VoidCallback? onLongPress;
  final VoidCallback? onTap;

  const _ViewOnceBubble({
    required this.message,
    required this.isMe,
    required this.bubbleColor,
    required this.textColor,
    required this.metaColor,
    this.onLongPress,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Recipient's copy is "spent" once opened; the sender always sees a
    // static label describing what they sent. A ghost text says what it is
    // in its own words — never any of the words inside it.
    final ghost = !message.isImage;
    final spent = message.viewOnceOpened && !isMe;
    final label = isMe
        ? (message.viewOnceOpened
            ? 'Opened'
            : (ghost ? 'Ghost message' : 'Photo · View once'))
        : (spent ? 'Opened' : (ghost ? 'Ghost message' : 'View once'));
    final icon = ghost
        ? Icons.blur_on
        : (spent ? Icons.timer_off_outlined : Icons.timer_outlined);
    final faded = spent || (isMe && message.viewOnceOpened);
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        onTap: spent ? null : onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          padding: const EdgeInsets.fromLTRB(12, 10, 13, 10),
          decoration: BoxDecoration(
            color: faded ? bubbleColor.withValues(alpha: 0.55) : bubbleColor,
            borderRadius: const BorderRadius.all(Radius.circular(20)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: textColor),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      fontStyle: faded ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
                  if (!isMe && !spent)
                    Text(ghost ? 'Tap to view once' : 'Tap to view',
                        style: TextStyle(color: metaColor, fontSize: 11.5)),
                ],
              ),
              const SizedBox(width: 10),
              Text(
                DateFormatter.messageTime(message.time),
                style: TextStyle(color: metaColor, fontSize: 11),
              ),
              if (isMe) ...[
                const SizedBox(width: 4),
                MessageStatusIcon(
                  status: message.status,
                  size: 15,
                  color: metaColor,
                  readColor: textColor,
                ),
              ],
            ],
          ),
        ),
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

  static Widget _gradientTile(List<Color> colors) {
    return Container(
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
    );
  }

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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isMe && message.senderName.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(7, 4, 7, 0),
                  child: _SenderLabel(name: message.senderName),
                ),
              _photo(colors),
            ],
          ),
        ),
      ),
    );
  }

  /// The photo itself, with the time (and ticks, when outgoing) laid over it.
  Widget _photo(List<Color> colors) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(13),
      child: Stack(
        children: [
          Hero(
            tag: 'photo_${message.id}',
            child: SizedBox(
              width: 220,
              height: 260,
              child: message.imageUrl != null
                  ? ChatPhoto(
                      url: message.imageUrl!,
                      width: 220,
                      height: 260,
                      errorBuilder: (_) => _gradientTile(colors),
                    )
                  : _gradientTile(colors),
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
                    style: const TextStyle(color: Colors.white, fontSize: 11),
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
    );
  }
}

/// A shared-location card: a stylised mini-map with a pin, the place label /
/// coordinates, and an "Open in Maps" affordance.
class _LocationContent extends StatelessWidget {
  final Message message;
  final Color textColor;
  final Color metaColor;
  final VoidCallback? onTap;

  const _LocationContent({
    required this.message,
    required this.textColor,
    required this.metaColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final lat = message.locationLat ?? 0;
    final lng = message.locationLng ?? 0;
    final label = message.locationLabel?.isNotEmpty == true
        ? message.locationLabel!
        : 'Shared location';
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: MiniMapPreview(lat: lat, lng: lng),
          ),
          const SizedBox(height: 6),
          Text(label,
              style: TextStyle(
                  color: textColor, fontWeight: FontWeight.w600, fontSize: 15)),
          Text(
            '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}  ·  Open in Maps',
            style: TextStyle(color: metaColor, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// A shared-contact card: avatar initial, name, number and a Message action.
/// A server-invite card: the server's look and name, and a Join button that
/// adds it (channels, roster, encryption secret) with one tap.
class _ServerInviteContent extends StatelessWidget {
  final Message message;
  final Color textColor;
  final Color metaColor;

  const _ServerInviteContent({
    required this.message,
    required this.textColor,
    required this.metaColor,
  });

  Map<String, dynamic>? get _snapshot {
    try {
      final decoded = jsonDecode(message.serverInvite);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  void _join(BuildContext context, Map<String, dynamic> snapshot) {
    final me = AppState.profile.value;
    final digits = me.phone.replaceAll(RegExp(r'\D'), '');
    final community = CommunityStore.instance
        .joinFromInvite(snapshot, myDigits: digits, myName: me.name);
    if (community == null) return;
    // Tell the other members someone new is in.
    if (RelayConfig.isEnabled) {
      RelayService.instance.sendServerJoin(
        community.id,
        Member(
            id: CommunityStore.wireId(digits),
            name: me.name.isEmpty ? 'Member' : me.name,
            online: true),
      );
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Joined "${community.name}"')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (snapshot == null) {
      return Text('Server invite', style: TextStyle(color: textColor));
    }
    final name = snapshot['name'] as String? ?? 'A server';
    final icon = snapshot['icon'] as String? ?? '';
    final colorHex = snapshot['color'] as String? ?? '#7A5CFF';
    final color = Color(
        int.parse(colorHex.replaceFirst('#', 'ff'), radix: 16));
    return ListenableBuilder(
      listenable: CommunityStore.instance,
      builder: (context, _) {
        final joined =
            CommunityStore.instance.byId(snapshot['id'] as String? ?? '') !=
                null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: color,
                  child: Text(
                      icon.isNotEmpty
                          ? icon
                          : (name.isEmpty ? '?' : name[0].toUpperCase()),
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Server invite',
                          style:
                              TextStyle(fontSize: 11.5, color: metaColor)),
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: textColor,
                              fontWeight: FontWeight.w700,
                              fontSize: 15)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (message.isMe && !joined)
              Text('Invite sent',
                  style: TextStyle(fontSize: 12, color: metaColor))
            else if (joined)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle, size: 16, color: metaColor),
                  const SizedBox(width: 5),
                  Text('Joined', style: TextStyle(color: metaColor)),
                ],
              )
            else
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _join(context, snapshot),
                child: const Text('Join server'),
              ),
          ],
        );
      },
    );
  }
}

class _ContactContent extends StatelessWidget {
  final Message message;
  final Color textColor;
  final Color metaColor;
  final VoidCallback? onMessage;

  const _ContactContent({
    required this.message,
    required this.textColor,
    required this.metaColor,
    this.onMessage,
  });

  @override
  Widget build(BuildContext context) {
    final name = message.contactName ?? 'Contact';
    final phone = message.contactPhone ?? '';
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return SizedBox(
      width: 220,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: metaColor.withValues(alpha: 0.25),
                child: Text(initial,
                    style: TextStyle(
                        color: textColor, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name,
                        style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.w600,
                            fontSize: 15),
                        overflow: TextOverflow.ellipsis),
                    if (phone.isNotEmpty)
                      Text(phone,
                          style: TextStyle(color: metaColor, fontSize: 12.5)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Divider(height: 1, color: metaColor.withValues(alpha: 0.25)),
          TextButton(
            onPressed: onMessage,
            style: TextButton.styleFrom(
              foregroundColor: textColor,
              padding: const EdgeInsets.symmetric(vertical: 4),
              minimumSize: const Size(0, 32),
            ),
            child: const Text('Message'),
          ),
        ],
      ),
    );
  }
}

/// A voice-message row: a play/pause toggle, a static waveform, and the
/// clip length. Playback is simulated (no real audio in this UI demo).
class _VoiceContent extends StatefulWidget {
  final int seconds;

  /// A short note's inline clip; null for a long (bucket-backed) one.
  final String? audioUrl;

  /// A long note's sealed object in the voice-notes bucket, and the key that
  /// unseals it; both null for an inline note.
  final String? audioPath;
  final String? audioKey;
  final Color textColor;
  final Color metaColor;

  const _VoiceContent({
    required this.seconds,
    required this.audioUrl,
    required this.audioPath,
    required this.audioKey,
    required this.textColor,
    required this.metaColor,
  });

  @override
  State<_VoiceContent> createState() => _VoiceContentState();
}

class _VoiceContentState extends State<_VoiceContent> {
  // One player per bubble, made only when there is real audio to play.
  AudioPlayer? _player;
  bool _playing = false;
  bool _loading = false; // fetching a long note from the bucket
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;
  final List<StreamSubscription<dynamic>> _subs = [];

  /// A long note's bytes, fetched and unsealed from the bucket once and kept
  /// so a replay doesn't download again.
  Uint8List? _fetched;

  /// Native platforms play the clip from a temp file (written once per
  /// bubble); web plays the bytes directly.
  String? _tempPath;

  // A fixed pseudo-waveform so bubbles look varied but stable.
  static const _heights = [
    6.0, 12.0, 18.0, 10.0, 22.0, 14.0, 8.0, 20.0, 16.0, 11.0,
    24.0, 9.0, 15.0, 19.0, 7.0, 13.0, 21.0, 10.0, 17.0, 12.0,
  ];

  /// Whether there is a clip to play at all — inline, or a bucket note we can
  /// fetch. Old voice messages carried only a duration, so their bubble says
  /// so rather than pretending to play.
  bool get _inline => (widget.audioUrl ?? '').isNotEmpty;
  bool get _bucketed =>
      (widget.audioPath ?? '').isNotEmpty && (widget.audioKey ?? '').isNotEmpty;
  bool get _playable => _inline || _bucketed;

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    final temp = _tempPath;
    if (temp != null) {
      File(temp).delete().catchError((_) => File(temp));
    }
    super.dispose();
  }

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final p = AudioPlayer();
    _subs.add(p.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s == PlayerState.playing);
    }));
    _subs.add(p.onDurationChanged.listen((d) {
      if (mounted) setState(() => _total = d);
    }));
    _subs.add(p.onPositionChanged.listen((d) {
      if (mounted) setState(() => _position = d);
    }));
    _subs.add(p.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _position = Duration.zero);
    }));
    _player = p;
    return p;
  }

  Future<void> _toggle() async {
    if (!_playable || _loading) return;
    final p = _ensurePlayer();
    if (_playing) {
      await p.pause();
      return;
    }
    // A long note is fetched and unsealed from the bucket once, then cached.
    Uint8List? bytes;
    if (_inline) {
      final comma = widget.audioUrl!.indexOf(',');
      bytes = Uint8List.fromList(
          base64Decode(widget.audioUrl!.substring(comma + 1)));
    } else {
      bytes = _fetched;
      if (bytes == null) {
        setState(() => _loading = true);
        bytes =
            await VoiceMedia.instance.download(widget.audioPath!, widget.audioKey!);
        _fetched = bytes;
        if (mounted) setState(() => _loading = false);
        if (bytes == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Couldn\'t load that voice note.')));
          }
          return;
        }
      }
    }
    if (_position >= _total && _total > Duration.zero) {
      await p.seek(Duration.zero);
    }
    try {
      await p.play(await _sourceFor(bytes));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Couldn\'t play that voice note.')));
      }
    }
  }

  /// Where the player reads the clip from. BytesSource only exists on web
  /// and Android — audioplayers' iOS side answers `setSourceBytes is not
  /// currently implemented` — so native platforms write the decoded clip to
  /// a temp file once and play from that.
  Future<Source> _sourceFor(Uint8List bytes) async {
    if (kIsWeb) return BytesSource(bytes, mimeType: 'audio/mp4');
    var path = _tempPath;
    if (path == null) {
      final dir = await getTemporaryDirectory();
      path = '${dir.path}/vn_play_'
          '${DateTime.now().microsecondsSinceEpoch}.m4a';
      await File(path).writeAsBytes(bytes, flush: true);
      _tempPath = path;
    }
    return DeviceFileSource(path, mimeType: 'audio/mp4');
  }

  /// The elapsed/total counter — real once playing, the recorded length at
  /// rest so the bubble still says how long the note is.
  String get _label {
    final shown = _playing || _position > Duration.zero
        ? _position.inSeconds
        : widget.seconds;
    final m = shown ~/ 60;
    final s = shown % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// 0..1 through the clip, for lighting the waveform as it plays.
  double get _progress {
    final total = _total.inMilliseconds;
    if (total <= 0) return 0;
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentOn(context);
    return SizedBox(
      width: 210,
      child: Row(
        children: [
          GestureDetector(
            onTap: _playable ? _toggle : null,
            child: _loading
                ? SizedBox(
                    width: 26,
                    height: 26,
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: accent),
                    ),
                  )
                : Icon(
                    !_playable
                        ? Icons.mic_off_outlined
                        : (_playing ? Icons.pause : Icons.play_arrow),
                    color: _playable ? accent : widget.metaColor,
                    size: 30,
                  ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: !_playable
                // An old note with no clip: say it plainly instead of a
                // waveform that does nothing.
                ? Text('Can\'t be played',
                    style: TextStyle(color: widget.metaColor, fontSize: 12.5))
                : SizedBox(
                    height: 26,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        for (var i = 0; i < _heights.length; i++)
                          Expanded(
                            child: Container(
                              margin:
                                  const EdgeInsets.symmetric(horizontal: 0.5),
                              height: _heights[i],
                              decoration: BoxDecoration(
                                // The bars up to the play head take the accent;
                                // the rest stay muted.
                                color: (i / _heights.length) <= _progress
                                    ? accent
                                    : widget.metaColor,
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

/// A form inside a bubble: what it is called, how many questions, and the one
/// button that matters — which differs by who is looking.
///
/// The sender sees how many people answered, because that is the thing they
/// are waiting for. Everybody else sees an invitation to answer, or that they
/// already did.
class _FormContent extends StatelessWidget {
  const _FormContent({
    required this.message,
    required this.textColor,
    required this.metaColor,
    required this.onOpen,
  });

  final Message message;
  final Color textColor;
  final Color metaColor;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final count = message.formResponses.length;
    final questions = message.formFields.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.assignment_outlined, size: 17, color: textColor),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                message.formTitle.isEmpty ? 'Form' : message.formTitle,
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: textColor),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          questions == 1 ? '1 question' : '$questions questions',
          style: TextStyle(fontSize: 12.5, color: metaColor),
        ),
        const SizedBox(height: 8),
        SizedBox(
          // The same fixed width a poll bubble uses: double.infinity here
          // stretched every form bubble to the transcript's maximum width,
          // however small the form.
          width: 250,
          child: FilledButton.tonal(
            onPressed: onOpen,
            child: Text(message.isMe
                ? (count == 0
                    ? 'No responses yet'
                    : count == 1
                        ? 'View 1 response'
                        : 'View $count responses')
                : 'Fill in this form'),
          ),
        ),
      ],
    );
  }
}
