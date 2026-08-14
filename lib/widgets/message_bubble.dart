import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/community.dart';
import '../models/message.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../state/community_store.dart';
import '../state/community_sub_store.dart';
import '../state/live_location_store.dart';
import '../state/live_share_store.dart';
import 'subscribe_sheet.dart' show tierForCents;
import '../payments/payment_amount_sheet.dart';
import '../payments/store_prices.dart';
import '../payments/store_purchases.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import 'app_dialogs.dart';
import 'chat_photo.dart';
import 'initials_avatar.dart';
import 'message_status_icon.dart';
import 'osm_map.dart';
import 'pass_billing_note.dart';
import 'bill_split_card.dart';
import '../models/link_preview.dart';
import '../models/listing_card.dart';
import 'link_preview_card.dart';
import 'listing_card_content.dart';
import 'meeting_widgets.dart';
import 'poll_widgets.dart';
import 'rich_message_text.dart';
import 'voice_note_bubble.dart';
import 'sticker_sheet.dart';

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

  /// Per-voter poll vote weight for a GROUP chat's admin — "Decision
  /// Voting". Null for a 1:1 chat (no admin concept) or when the caller
  /// hasn't resolved one yet; a poll then tallies every vote as 1, same as
  /// before this existed.
  final int Function(String voterDigits)? pollVoteWeight;

  /// Opens the list of who said they are coming to a meeting. Resolving a
  /// voter's digits to a name needs the chat's roster, which the bubble
  /// does not have — so the chat screen owns the sheet, as it does for
  /// "who reacted" and "who has seen this".
  final VoidCallback? onShowMeetingGuests;

  /// Opens the marketplace listing a shared card points at.
  final VoidCallback? onOpenListing;

  /// Plays a shared video in the app. Null leaves the card opening the link
  /// the ordinary way, which is what every unplayable link does anyway.
  final VoidCallback? onPlayVideo;

  /// Opens a form — to fill in, or to read what came back. Which of those it
  /// is belongs to the chat screen, not here: the bubble only knows there is
  /// a form and who sent it.
  final VoidCallback? onOpenForm;

  /// Tapping a call-record chip calls that person back.
  final VoidCallback? onCallBack;

  /// Tapping an incoming poke pokes back. Null on your own pokes.
  final VoidCallback? onPokeBack;

  /// Pays this device's share of a split bill. Null when there's nothing to
  /// pay (you're the creator, or already settled).
  final VoidCallback? onPayBillShare;

  /// The chat peer's phone digits, so a live-location bubble can read the live
  /// pin (theirs from [LiveLocationStore], yours from [LiveShareStore]).
  final String peerDigits;

  /// Stops your own live share (shown on your live-location bubble).
  final VoidCallback? onStopLive;

  /// Tapped on the reaction pill to see WHO reacted with each emoji.
  final VoidCallback? onReactionsTap;

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
    this.pollVoteWeight,
    this.onShowMeetingGuests,
    this.onOpenListing,
    this.onPlayVideo,
    this.onOpenForm,
    this.onCallBack,
    this.onPokeBack,
    this.onPayBillShare,
    this.peerDigits = '',
    this.onStopLive,
    this.onReactionsTap,
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
    if (custom != null) {
      final onCustom =
          custom.computeLuminance() > 0.5 ? ink : Colors.white;
      textColor = onCustom;
      metaColor = onCustom.withValues(alpha: 0.7);
    } else if (isMe) {
      textColor = isDark ? ink : Colors.white;
      metaColor = isDark ? Colors.black54 : Colors.white70;
    } else {
      textColor = isDark ? const Color(0xFFE7E9EA) : ink;
      metaColor = isDark ? Colors.white54 : Colors.black45;
    }
    // Read ticks are a distinct blue (WhatsApp/Messenger "seen"), the same on
    // every bubble — delivered stays grey (metaColor), so the two never blur.
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

    // A poke is a chip like a call record — nobody said anything, so a
    // speech bubble would be the wrong shape for it.
    if (message.isPoke) {
      return _PokeBubble(
        isMe: isMe,
        bubbleColor: bubbleColor,
        textColor: textColor,
        metaColor: metaColor,
        onLongPress: onLongPress,
        onPokeBack: isMe ? null : onPokeBack,
      );
    }

    // Any view-once message — a photo or a ghost text — renders as a sealed
    // bubble that never shows its content in the transcript.
    if (message.viewOnce) {
      return ViewOnceBubble(
        message: message,
        isMe: isMe,
        bubbleColor: bubbleColor,
        textColor: textColor,
        metaColor: metaColor,
        isDark: isDark,
        hasReactions: hasReactions,
        onLongPress: onLongPress,
        onDoubleTap: onDoubleTap,
        onDoubleTapDown: onDoubleTapDown,
        onTap: onTap,
        onReactionsTap: onReactionsTap,
      );
    }

    if (message.isSticker) {
      // A sticker has no bubble on purpose — the whole point of the form is
      // the thing itself, big and bare. Emoji stickers are drawn as type
      // (identical on both ends because they ARE the emoji); photo stickers
      // are the same sealed data URI a photo rides, drawn compact.
      final bytes = message.isImage && message.imageUrl != null
          ? stickerBytes(message.imageUrl!)
          : null;
      return Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onLongPress: onLongPress,
          onTap: onTap,
          onDoubleTap: onDoubleTap,
          onDoubleTapDown: onDoubleTapDown,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: EdgeInsets.only(
                    left: 12, right: 12, top: 4, bottom: hasReactions ? 18 : 4),
                child: Column(
                  crossAxisAlignment: isMe
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isMe && message.senderName.isNotEmpty)
                      _SenderLabel(name: message.senderName),
                    bytes != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: Image.memory(bytes,
                                width: 150, height: 150, fit: BoxFit.cover),
                          )
                        : Text(message.text,
                            style: const TextStyle(fontSize: 84)),
                  ],
                ),
              ),
              // A sticker has no bubble to reserve room inside, so this pill
              // sits in the extra bottom padding above rather than
              // overlapping the sticker itself.
              if (hasReactions)
                Positioned(
                  bottom: 0,
                  right: isMe ? 12 : null,
                  left: isMe ? null : 12,
                  child: _ReactionPill(
                    reactions: message.reactions,
                    isDark: isDark,
                    onTap: onReactionsTap,
                  ),
                ),
            ],
          ),
        ),
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
        onDoubleTap: onDoubleTap,
        onDoubleTapDown: onDoubleTapDown,
        onReactionsTap: onReactionsTap,
      );
    }

    if (message.isPayment) {
      return Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onLongPress: onLongPress,
          // A request is answered by tapping it, so the tap has to reach it.
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: PaymentBubble(
              amountCents: message.paymentAmountCents,
              currency: message.paymentCurrency,
              note: message.text,
              isMe: isMe,
              isRequest: message.isPaymentRequest,
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
                        textColor: textColor,
                        metaColor: metaColor,
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
                    if (message.isBillSplit)
                      BillSplitCard(
                        message: message,
                        myPhone: AppState.profile.value.phone,
                        onPayShare: onPayBillShare,
                      )
                    else if (message.isForm)
                      _FormContent(
                        message: message,
                        textColor: textColor,
                        metaColor: metaColor,
                        onOpen: onOpenForm,
                      )
                    // BEFORE the poll branch, and it has to stay there: a
                    // meeting message really is a poll underneath (that is
                    // how an RSVP travels) and would otherwise draw as one.
                    else if (message.isMeeting)
                      MeetingBubble(
                        message: message,
                        textColor: textColor,
                        metaColor: metaColor,
                        onRsvp: onPollVote == null
                            ? null
                            : (r) => onPollVote!(r.index),
                        onShowWho: onShowMeetingGuests,
                      )
                    else if (message.isPoll)
                      PollBubble(
                        message: message,
                        textColor: textColor,
                        metaColor: metaColor,
                        onVote: (i) => onPollVote?.call(i),
                        // Deliberately not passed to a meeting above: a
                        // group admin's vote can weigh two when the room is
                        // DECIDING something, and never when it is counting
                        // who is coming.
                        weightFor: pollVoteWeight,
                      )
                    else if (message.isVoice)
                      VoiceNoteBubble(
                        seconds: message.voiceSeconds,
                        audioUrl: message.audioUrl,
                        audioPath: message.audioPath,
                        audioKey: message.audioKey,
                        textColor: textColor,
                        metaColor: metaColor,
                      )
                    else if (message.isLiveLocation)
                      _LiveLocationContent(
                        message: message,
                        peerDigits: peerDigits,
                        textColor: textColor,
                        metaColor: metaColor,
                        onTap: onOpenLocation,
                        onStop: onStopLive,
                      )
                    else if (message.isLocation)
                      LocationContent(
                        message: message,
                        textColor: textColor,
                        metaColor: metaColor,
                        onTap: onOpenLocation,
                      )
                    else if (message.isContact)
                      ContactContent(
                        message: message,
                        textColor: textColor,
                        metaColor: metaColor,
                        onMessage: onOpenContact,
                      )
                    else if (message.isListingCard)
                      Builder(builder: (context) {
                        final card = ListingCard.decode(message.listingCard);
                        // A card that will not parse draws nothing rather
                        // than an empty box with a dead tap on it.
                        if (card == null) return const SizedBox.shrink();
                        return ListingCardContent(
                          card: card,
                          textColor: textColor,
                          metaColor: metaColor,
                          onOpen: onOpenListing,
                        );
                      })
                    else if (message.isServerInvite)
                      _ServerInviteContent(
                        message: message,
                        textColor: textColor,
                        metaColor: metaColor,
                      )
                    else ...[
                      // The subject, when the sender wrote one — its own
                      // line above the body, in the BUBBLE's own ink (see
                      // "A bubble's contents take the BUBBLE's colours"),
                      // never the app accent.
                      if (message.subject.isNotEmpty) ...[
                        Text(
                          message.subject,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 3),
                      ],
                      RichMessageText(
                        text: message.text,
                        textColor: textColor,
                        linkColor: isDark
                            ? const Color(0xFF53BDEB)
                            : const Color(0xFF027EB5),
                      ),
                      // UNDER the words, never instead of them: somebody
                      // typed a sentence around that link and it is the
                      // message.
                      if (message.hasLinkPreview)
                        Builder(builder: (context) {
                          final preview =
                              LinkPreview.decode(message.linkPreview);
                          if (preview == null) return const SizedBox.shrink();
                          return LinkPreviewCard(
                            preview: preview,
                            textColor: textColor,
                            metaColor: metaColor,
                            onPlay: preview.playable ? onPlayVideo : null,
                          );
                        }),
                    ],
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
                    onTap: onReactionsTap,
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
      case 'busy':
        // Two different bubbles share this event, and they mean opposite
        // things: the CALLER's own outgoing record (isMe) says the peer
        // was busy; the CALLEE's own incoming record says THIS device was
        // the one on another call. Same word, told from each side.
        return isMe ? '$kind · Busy' : 'Missed ${kind.toLowerCase()} · you were on a call';
      default:
        final s = message.callSeconds;
        if (s <= 0) return kind;
        final m = s ~/ 60;
        return '$kind · $m:${(s % 60).toString().padLeft(2, '0')}';
    }
  }

  @override
  Widget build(BuildContext context) {
    // 'busy' means opposite things on each side (see _label): only the
    // callee's own copy — the call THEY missed by being on another one —
    // reads as a missed call visually. The caller's own outgoing record
    // reads more like a decline than a red missed-call icon.
    final missed =
        message.callEvent == 'missed' || (message.callEvent == 'busy' && !isMe);
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

  // The palette itself, and the name→color mapping, now live in
  // InitialsAvatar (shared with a channel message's name label and its
  // avatar) — kept here as a thin delegate so this stays a one-line change
  // for every existing caller of colorFor.
  static Color colorFor(String name) => InitialsAvatar.colorFor(name);

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
  final Color textColor;
  final Color metaColor;
  final VoidCallback? onTap;

  const _ReplyQuote({
    required this.reply,
    required this.textColor,
    required this.metaColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // The wash and accent stripe are decorative, not text, and stay tied to
    // the app theme; the two labels are bubble CONTENT, so — like every other
    // bubble-inner widget — they take the bubble's own computed textColor/
    // metaColor (which already accounts for a custom bubble color) rather
    // than raw theme brightness. Getting this wrong is exactly the
    // VoiceNoteBubble bug: a custom bubble color chosen for the opposite
    // theme direction renders this text unreadable against it.
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
              color: textColor,
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
              color: metaColor,
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
/// A "view once" bubble — a photo or a ghost text, consumed on open.
///
/// Public rather than private to `message_bubble.dart` (unlike most bubble
/// pieces in this file) because a server channel message renders it too —
/// see `_ChannelBubble` in `lib/screens/communities.dart`, which has no
/// second copy of this widget and reaches for this one directly.
class ViewOnceBubble extends StatelessWidget {
  final Message message;
  final bool isMe;
  final Color bubbleColor;
  final Color textColor;
  final Color metaColor;
  final VoidCallback? onLongPress;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final GestureTapDownCallback? onDoubleTapDown;
  final bool isDark;
  final bool hasReactions;
  final VoidCallback? onReactionsTap;

  const ViewOnceBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.bubbleColor,
    required this.textColor,
    required this.metaColor,
    required this.isDark,
    required this.hasReactions,
    this.onLongPress,
    this.onTap,
    this.onDoubleTap,
    this.onDoubleTapDown,
    this.onReactionsTap,
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
        // Unlike onTap (opening the photo, which only makes sense before it's
        // spent), double-tap-to-like stays live even after — the timeline's
        // primary "like a photo" gesture had never been wired here at all, so
        // a view-once photo could not be liked before OR after opening.
        onDoubleTap: onDoubleTap,
        onDoubleTapDown: onDoubleTapDown,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              margin: EdgeInsets.only(
                  left: 8, right: 8, top: 3, bottom: hasReactions ? 17 : 3),
              padding: const EdgeInsets.fromLTRB(12, 10, 13, 10),
              decoration: BoxDecoration(
                color:
                    faded ? bubbleColor.withValues(alpha: 0.55) : bubbleColor,
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
                          fontStyle:
                              faded ? FontStyle.italic : FontStyle.normal,
                        ),
                      ),
                      if (!isMe && !spent)
                        Text(ghost ? 'Tap to view once' : 'Tap to view',
                            style:
                                TextStyle(color: metaColor, fontSize: 11.5)),
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
                    ),
                  ],
                ],
              ),
            ),
            // Liking a ghost/view-once message was wired for double-tap
            // (2026-08-13's earlier fix) but never drawn — the same missing
            // confirmation the photo/GIF bubble had.
            if (hasReactions)
              Positioned(
                bottom: 2,
                right: isMe ? 12 : null,
                left: isMe ? null : 12,
                child: _ReactionPill(
                  reactions: message.reactions,
                  isDark: isDark,
                  onTap: onReactionsTap,
                ),
              ),
          ],
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
  final VoidCallback? onDoubleTap;
  final GestureTapDownCallback? onDoubleTapDown;

  /// Tapped on the reaction pill to see who reacted. Threading this and
  /// [hasReactions] through was the missing half of double-tap-to-like on a
  /// photo/GIF bubble: the gesture was wired, but nothing ever DREW the
  /// pill, so a like was recorded and invisible — "can't like gifs" really
  /// meant "nothing shows it worked" (2026-08-13).
  final VoidCallback? onReactionsTap;

  const _ImageBubble({
    required this.message,
    required this.isMe,
    required this.isDark,
    required this.bubbleColor,
    required this.hasReactions,
    required this.onLongPress,
    required this.onTap,
    this.onDoubleTap,
    this.onDoubleTapDown,
    this.onReactionsTap,
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
        // Double-tap to like works on a GIF/photo too, not just text.
        onDoubleTap: onDoubleTap,
        onDoubleTapDown: onDoubleTapDown,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
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
            // The margin above reserves the room; this is what a like on a
            // photo/GIF bubble was missing — the gesture worked, nothing
            // ever drew the confirmation (2026-08-13).
            if (hasReactions)
              Positioned(
                bottom: 2,
                right: isMe ? 12 : null,
                left: isMe ? null : 12,
                child: _ReactionPill(
                  reactions: message.reactions,
                  isDark: isDark,
                  onTap: onReactionsTap,
                ),
              ),
          ],
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
                    // Over the photo's dark scrim: white for sent/delivered,
                    // blue (the default) once read.
                    MessageStatusIcon(
                        status: message.status,
                        size: 15,
                        color: Colors.white70),
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
///
/// Public: a server channel message renders it too (`_ChannelBubble` in
/// `communities.dart` reaches for this one directly, the same reason
/// `ViewOnceBubble` is public) — plain location only, never
/// `_LiveLocationContent`, which stays 1:1-only (a live share needs someone
/// to keep updating it, and a channel has no single "someone" to answer for
/// that the way a 1:1 peer does).
class LocationContent extends StatelessWidget {
  final Message message;
  final Color textColor;
  final Color metaColor;
  final VoidCallback? onTap;

  const LocationContent({
    super.key,
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

/// A LIVE-location card: a map that stays fresh while the share is running,
/// with the time left and — on your own share — a Stop button. The pin comes
/// from the live stores (theirs as positions arrive, yours as they go out),
/// so it moves without rebuilding the message.
class _LiveLocationContent extends StatelessWidget {
  final Message message;
  final String peerDigits;
  final Color textColor;
  final Color metaColor;
  final VoidCallback? onTap;
  final VoidCallback? onStop;

  const _LiveLocationContent({
    required this.message,
    required this.peerDigits,
    required this.textColor,
    required this.metaColor,
    this.onTap,
    this.onStop,
  });

  static String _left(Duration d) {
    if (d <= Duration.zero) return '';
    if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m left';
    if (d.inMinutes >= 1) return '${d.inMinutes}m left';
    return 'less than a minute left';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
          [LiveLocationStore.instance, LiveShareStore.instance]),
      builder: (context, _) {
        final mine = message.isMe;
        final now = DateTime.now();
        var lat = message.locationLat ?? 0;
        var lng = message.locationLng ?? 0;
        bool active;
        Duration remaining = Duration.zero;

        if (mine) {
          final share = LiveShareStore.instance.shareFor(peerDigits, now: now);
          active = share != null;
          if (share != null) {
            lat = share.lat;
            lng = share.lng;
            remaining = LiveShareStore.instance.remaining(peerDigits, now: now);
          }
        } else {
          final until = message.liveUntil;
          active = until != null && now.isBefore(until);
          final live = LiveLocationStore.instance.locationFor(peerDigits, now: now);
          if (live != null) {
            lat = live.lat;
            lng = live.lng;
          }
          if (until != null && until.isAfter(now)) {
            remaining = until.difference(now);
          }
        }

        final title = active
            ? (mine ? 'Sharing your live location' : 'Live location')
            : 'Live location ended';

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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (active) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                          color: Color(0xFF12B76A), shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(title,
                      style: TextStyle(
                          color: textColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 15)),
                ],
              ),
              Text(
                active
                    ? (remaining > Duration.zero
                        ? '${_left(remaining)}  ·  Open in Maps'
                        : 'Open in Maps')
                    : 'Open in Maps',
                style: TextStyle(color: metaColor, fontSize: 12),
              ),
              if (mine && active && onStop != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: TextButton.icon(
                    onPressed: onStop,
                    icon: const Icon(Icons.stop_circle_outlined, size: 16),
                    label: const Text('Stop sharing'),
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        foregroundColor: const Color(0xFFE5484D)),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A shared-contact card: avatar initial, name, number and a Message action.
/// A server-invite card: the server's look and name, and a Join button that
/// adds it (channels, roster, encryption secret) with one tap.
/// A paid server's monthly price in the buyer's own currency: the App Store's
/// real price for the membership product the price maps to (so a Canadian
/// buyer sees CAD and it matches the charge), falling back to a plain USD
/// figure where there is no store to ask.
String _paidServerMoney(int priceCents) => StorePrices.instance.money(
    priceCents,
    productId: StorePurchases.communitySubProductId(tierForCents(priceCents)));

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
      // The roster now has the server, but not its history — pull the
      // durable copy so old posts don't stay invisible to a new member.
      unawaited(RelayService.instance.fetchCommunityPosts());
      // Registers this device as a real, server-verified member
      // (docs/community_structure.sql) — silently no-ops if the owner's
      // device has never published this server there yet.
      unawaited(RelayService.instance.joinCommunityAuthoritative(
          community.id, secret: community.secret, myName: me.name));
      unawaited(RelayService.instance.fetchCommunityStructure(community.id));
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Joined "${community.name}"')),
    );
  }

  /// A paid server: buy (or renew) a month of membership, then join. Runs the
  /// consumable IAP through CommunitySubStore; test mode simulates it. A store
  /// failure joins nothing.
  Future<void> _subscribeAndJoin(
      BuildContext context, Map<String, dynamic> snapshot) async {
    final id = snapshot['id'] as String? ?? '';
    final cents = (snapshot['priceCents'] as num?)?.toInt() ?? 0;
    final name = snapshot['name'] as String? ?? 'this server';
    final pitch = (snapshot['subPitch'] as String? ?? '').trim();
    if (id.isEmpty || cents <= 0) return;
    final messenger = ScaffoldMessenger.of(context);
    final go = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.workspace_premium,
                  size: 36, color: Theme.of(sheetContext).colorScheme.primary),
              const SizedBox(height: 8),
              Text('Subscribe to $name',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700)),
              if (pitch.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(pitch,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Theme.of(sheetContext)
                            .colorScheme
                            .onSurfaceVariant)),
              ],
              const SizedBox(height: 8),
              const PassBillingNote(),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: () => Navigator.of(sheetContext).pop(true),
                child: Text(
                    'Subscribe · ${_paidServerMoney(cents)} for 30 days'),
              ),
            ],
          ),
        ),
      ),
    );
    if (go != true || !context.mounted) return;
    final result =
        await CommunitySubStore.instance.subscribe(id, tierForCents(cents));
    if (!context.mounted) return;
    if (!result.ok) {
      messenger.showSnackBar(const SnackBar(
          content: Text('That didn\'t go through — nothing was charged.')));
      return;
    }
    _join(context, snapshot);
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
    final paid = snapshot['paid'] as bool? ?? false;
    final priceCents = (snapshot['priceCents'] as num?)?.toInt() ?? 0;
    return ListenableBuilder(
      listenable:
          Listenable.merge([CommunityStore.instance, CommunitySubStore.instance]),
      builder: (context, _) {
        final serverId = snapshot['id'] as String? ?? '';
        final joined = CommunityStore.instance.byId(serverId) != null;
        // A paid server needs an active membership pass before the join opens.
        final needsPass = paid &&
            priceCents > 0 &&
            !message.isMe &&
            !CommunitySubStore.instance.active(serverId);
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
                      Text(
                          paid && priceCents > 0
                              ? 'Paid server · '
                                  '${_paidServerMoney(priceCents)} · 30 days'
                              : 'Server invite',
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
            else if (needsPass)
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _subscribeAndJoin(context, snapshot),
                child: Text(
                    'Subscribe · ${_paidServerMoney(priceCents)} for 30 days'),
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

/// A shared-contact card. Public for the same reason [LocationContent] is —
/// `_ChannelBubble` in `communities.dart` renders it directly rather than a
/// second copy.
class ContactContent extends StatelessWidget {
  final Message message;
  final Color textColor;
  final Color metaColor;
  final VoidCallback? onMessage;

  const ContactContent({
    super.key,
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

class _ReactionPill extends StatelessWidget {
  final List<String> reactions;
  final bool isDark;

  /// Tapped to see who reacted. Null when nothing lists them (nothing here to
  /// name, or a surface that doesn't offer it).
  final VoidCallback? onTap;

  const _ReactionPill(
      {required this.reactions, required this.isDark, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
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

/// A poke in the thread: a chip, not a speech bubble — nobody said
/// anything, somebody waved. Tapping an incoming one waves back.
class _PokeBubble extends StatelessWidget {
  final bool isMe;
  final Color bubbleColor;
  final Color textColor;
  final Color metaColor;
  final VoidCallback? onLongPress;
  final VoidCallback? onPokeBack;

  const _PokeBubble({
    required this.isMe,
    required this.bubbleColor,
    required this.textColor,
    required this.metaColor,
    required this.onLongPress,
    required this.onPokeBack,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        onTap: onPokeBack,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: bubbleColor.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: metaColor.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: const Text('👉', style: TextStyle(fontSize: 15)),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(isMe ? 'You poked them' : 'Poked you',
                      style: TextStyle(
                          color: textColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  if (onPokeBack != null)
                    Text('Tap to poke back',
                        style: TextStyle(color: metaColor, fontSize: 11.5)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
