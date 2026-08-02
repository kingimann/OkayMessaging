import 'form_spec.dart';
/// Delivery state of an outgoing message, mirroring WhatsApp's tick system.
enum MessageStatus { sending, sent, delivered, read }

/// Lightweight reference to the message being replied to (quoted).
class ReplyInfo {
  final String senderName;
  final String text;
  final bool isMe;

  /// Id of the original message, so tapping the quote can jump to it.
  final String? messageId;

  const ReplyInfo({
    required this.senderName,
    required this.text,
    required this.isMe,
    this.messageId,
  });

  Map<String, dynamic> toJson() => {
        'senderName': senderName,
        'text': text,
        'isMe': isMe,
        'messageId': messageId,
      };

  factory ReplyInfo.fromJson(Map<String, dynamic> json) => ReplyInfo(
        senderName: json['senderName'] as String,
        text: json['text'] as String,
        isMe: json['isMe'] as bool,
        messageId: json['messageId'] as String?,
      );
}

/// A single chat message.
class Message {
  final String id;
  final String text;
  final DateTime time;

  /// True when the message was sent by the current (local) user.
  final bool isMe;
  final MessageStatus status;

  /// Display name of whoever sent this, shown above incoming bubbles in a
  /// group so members can tell each other apart. Empty in one-to-one chats.
  final String senderName;

  /// Emoji reactions attached to this message (e.g. ['👍', '❤️']).
  final List<String> reactions;

  /// The quoted message this one replies to, if any.
  final ReplyInfo? replyTo;

  /// True when this message was forwarded from another chat.
  final bool forwarded;

  /// The id of the message this one hangs under, when it was sent into a
  /// thread rather than into the room.
  ///
  /// Null for everything in the main transcript, which is the point: a thread
  /// exists so a long exchange between two people does not push a group's
  /// conversation off the screen. Messages carrying this are drawn only
  /// inside the thread, and the message they hang under says how many there
  /// are.
  ///
  /// Flat by design — a reply in a thread joins that thread rather than
  /// starting one of its own. Threads of threads are how a group ends up with
  /// somewhere else to lose a conversation.
  final String? threadRootId;

  /// True when the sender had protection on for the conversation this was
  /// sent in — so the receiving app hides Forward and Copy for it too.
  ///
  /// It travels with the message rather than being read from the local chat
  /// because the setting belongs to whoever wrote the words. Turning it off
  /// on your side does not unlock what somebody else sent you under it.
  ///
  /// A REQUEST THE OTHER APP HONOURS, and nothing stronger. A modified client
  /// can ignore it and a camera pointed at the screen never sees it. Saying
  /// otherwise would promise something no messenger can deliver.
  final bool protected;

  /// True for voice messages; [voiceSeconds] then holds the clip length.
  final bool isVoice;
  final int voiceSeconds;

  /// True when this voice message is a voicemail left after an unanswered
  /// call (a [isVoice] message surfaced separately in the Calls tab).
  final bool isVoicemail;

  /// True when this message is a file saved to the device (an Okay Drop
  /// video or document). The text still carries the human-readable line —
  /// an old build shows a sentence — but the flag is what lets the pinboard
  /// list files without guessing from prose.
  final bool isFile;
  final String fileName;

  /// True when this message has been edited after sending.
  final bool edited;

  /// The text this message had before its first edit, so the original can be
  /// viewed. Null when the message has never been edited.
  final String? originalText;

  /// True when this message was deleted for everyone — it stays in the thread
  /// as a "This message was deleted" tombstone instead of disappearing.
  final bool isDeleted;

  /// True for image messages; [imageSeed] picks a placeholder gradient when
  /// there is no real [imageUrl] (e.g. in the local demo).
  final bool isImage;
  final int imageSeed;

  /// A real image URL (from backend storage), when available.
  final String? imageUrl;

  /// True for a "view once" photo — it can be opened a single time, then it's
  /// consumed and shows an "Opened" tombstone (Snapchat / WhatsApp style).
  final bool viewOnce;

  /// Whether a [viewOnce] photo has already been opened (and thus spent).
  final bool viewOnceOpened;

  /// When set, the message is deleted from the device after this time
  /// (disappearing messages).
  final DateTime? expiresAt;

  /// True for a shared-location message; [locationLat]/[locationLng] hold the
  /// coordinates and [locationLabel] an optional place name.
  final bool isLocation;
  final double? locationLat;
  final double? locationLng;
  final String? locationLabel;

  /// True for a shared-contact card; [contactName]/[contactPhone] hold the
  /// shared person's details.
  final bool isContact;
  final String? contactName;
  final String? contactPhone;

  /// True for an in-chat payment; [paymentAmountCents] / [paymentCurrency] hold
  /// the amount and [text] carries an optional note. Money moves through Stripe
  /// Connect — this message is only the receipt shown in the conversation.
  final bool isPayment;
  final int paymentAmountCents;
  final String paymentCurrency;

  /// Lifecycle of an in-chat payment: 'pending' while it's being confirmed,
  /// 'paid' once it settles, or 'failed'. Empty for non-payment messages.
  final String paymentStatus;

  /// Call record shown in the conversation: '' for normal messages, else
  /// 'missed' (rang, never answered), 'declined', 'noanswer' (outgoing,
  /// nobody picked up) or 'ended' (a completed call — [callSeconds] long).
  final String callEvent;
  final bool callVideo;
  final int callSeconds;

  /// A server invite card: a JSON snapshot of the community being shared
  /// (name, channels, the encryption secret) that the recipient can join
  /// with one tap. Empty for normal messages.
  final String serverInvite;

  /// True for a poll; [pollQuestion] / [pollOptions] describe it, [pollVotes]
  /// holds the tally per option, and [pollMyVote] is this device's choice
  /// (-1 = not voted yet).
  final bool isPoll;

  /// A custom form: [formTitle] names it, [formFields] are the questions, and
  /// [formResponses] are the answers as they come back.
  ///
  /// The responses live on the message the same way poll votes do — the chat
  /// IS the store, so a form's answers are E2E encrypted, on the two devices
  /// that took part, and nowhere else.
  final bool isForm;
  final String formTitle;
  final List<FormFieldSpec> formFields;
  final List<FormResponse> formResponses;
  final String pollQuestion;
  final List<String> pollOptions;
  final List<int> pollVotes;
  final int pollMyVote;

  const Message({
    required this.id,
    required this.text,
    required this.time,
    required this.isMe,
    this.status = MessageStatus.read,
    this.senderName = '',
    this.reactions = const [],
    this.replyTo,
    this.forwarded = false,
    this.threadRootId,
    this.protected = false,
    this.isVoice = false,
    this.voiceSeconds = 0,
    this.isVoicemail = false,
    this.isFile = false,
    this.fileName = '',
    this.isImage = false,
    this.imageSeed = 0,
    this.imageUrl,
    this.viewOnce = false,
    this.viewOnceOpened = false,
    this.edited = false,
    this.originalText,
    this.isDeleted = false,
    this.expiresAt,
    this.isLocation = false,
    this.locationLat,
    this.locationLng,
    this.locationLabel,
    this.isContact = false,
    this.contactName,
    this.contactPhone,
    this.isPayment = false,
    this.paymentAmountCents = 0,
    this.paymentCurrency = 'cad',
    this.paymentStatus = '',
    this.serverInvite = '',
    this.isPoll = false,
    this.isForm = false,
    this.formTitle = '',
    this.formFields = const [],
    this.formResponses = const [],
    this.pollQuestion = '',
    this.pollOptions = const [],
    this.pollVotes = const [],
    this.pollMyVote = -1,
    this.callEvent = '',
    this.callVideo = false,
    this.callSeconds = 0,
  });

  /// Whether this message is a call record rather than content.
  bool get isCallEvent => callEvent.isNotEmpty;

  /// Whether this message carries a server invite card.
  bool get isServerInvite => serverInvite.isNotEmpty;

  /// Total votes cast across all poll options.
  int get pollTotalVotes => pollVotes.fold(0, (n, v) => n + v);

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'time': time.toIso8601String(),
        'isMe': isMe,
        'status': status.index,
        'senderName': senderName,
        'reactions': reactions,
        'replyTo': replyTo?.toJson(),
        'forwarded': forwarded,
        'threadRootId': threadRootId,
        'protected': protected,
        'isVoice': isVoice,
        'voiceSeconds': voiceSeconds,
        'isVoicemail': isVoicemail,
        if (isFile) 'isFile': true,
        if (isFile) 'fileName': fileName,
        'isImage': isImage,
        'imageSeed': imageSeed,
        'imageUrl': imageUrl,
        'viewOnce': viewOnce,
        'viewOnceOpened': viewOnceOpened,
        'edited': edited,
        'originalText': originalText,
        'isDeleted': isDeleted,
        'expiresAt': expiresAt?.toIso8601String(),
        'isLocation': isLocation,
        'locationLat': locationLat,
        'locationLng': locationLng,
        'locationLabel': locationLabel,
        'isContact': isContact,
        'contactName': contactName,
        'contactPhone': contactPhone,
        'isPayment': isPayment,
        'paymentAmountCents': paymentAmountCents,
        'paymentCurrency': paymentCurrency,
        'paymentStatus': paymentStatus,
        'serverInvite': serverInvite,
        'isPoll': isPoll,
        'isForm': isForm,
        'formTitle': formTitle,
        'formFields': [for (final f in formFields) f.toJson()],
        'formResponses': [for (final r in formResponses) r.toJson()],
        'pollQuestion': pollQuestion,
        'pollOptions': pollOptions,
        'pollVotes': pollVotes,
        'pollMyVote': pollMyVote,
        'callEvent': callEvent,
        'callVideo': callVideo,
        'callSeconds': callSeconds,
      };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String,
        text: json['text'] as String,
        time: DateTime.parse(json['time'] as String),
        isMe: json['isMe'] as bool,
        status: MessageStatus.values[json['status'] as int? ?? 3],
        senderName: json['senderName'] as String? ?? '',
        reactions: (json['reactions'] as List?)?.cast<String>() ?? const [],
        replyTo: json['replyTo'] == null
            ? null
            : ReplyInfo.fromJson(
                Map<String, dynamic>.from(json['replyTo'] as Map)),
        forwarded: json['forwarded'] as bool? ?? false,
        threadRootId: json['threadRootId'] as String?,
        protected: json['protected'] as bool? ?? false,
        isVoice: json['isVoice'] as bool? ?? false,
        voiceSeconds: json['voiceSeconds'] as int? ?? 0,
        isVoicemail: json['isVoicemail'] as bool? ?? false,
        isFile: json['isFile'] as bool? ?? false,
        fileName: json['fileName'] as String? ?? '',
        isImage: json['isImage'] as bool? ?? false,
        imageSeed: json['imageSeed'] as int? ?? 0,
        imageUrl: json['imageUrl'] as String?,
        viewOnce: json['viewOnce'] as bool? ?? false,
        viewOnceOpened: json['viewOnceOpened'] as bool? ?? false,
        edited: json['edited'] as bool? ?? false,
        originalText: json['originalText'] as String?,
        isDeleted: json['isDeleted'] as bool? ?? false,
        expiresAt: json['expiresAt'] == null
            ? null
            : DateTime.tryParse(json['expiresAt'] as String),
        isLocation: json['isLocation'] as bool? ?? false,
        locationLat: (json['locationLat'] as num?)?.toDouble(),
        locationLng: (json['locationLng'] as num?)?.toDouble(),
        locationLabel: json['locationLabel'] as String?,
        isContact: json['isContact'] as bool? ?? false,
        contactName: json['contactName'] as String?,
        contactPhone: json['contactPhone'] as String?,
        isPayment: json['isPayment'] as bool? ?? false,
        paymentAmountCents: json['paymentAmountCents'] as int? ?? 0,
        paymentCurrency: json['paymentCurrency'] as String? ?? 'cad',
        paymentStatus: json['paymentStatus'] as String? ?? '',
        serverInvite: json['serverInvite'] as String? ?? '',
        isPoll: json['isPoll'] as bool? ?? false,
        isForm: json['isForm'] as bool? ?? false,
        formTitle: json['formTitle'] as String? ?? '',
        formFields: [
          for (final f in (json['formFields'] as List?) ?? const [])
            FormFieldSpec.fromJson(Map<String, dynamic>.from(f as Map))
        ],
        formResponses: [
          for (final r in (json['formResponses'] as List?) ?? const [])
            FormResponse.fromJson(Map<String, dynamic>.from(r as Map))
        ],
        pollQuestion: json['pollQuestion'] as String? ?? '',
        pollOptions:
            (json['pollOptions'] as List?)?.cast<String>() ?? const [],
        pollVotes: (json['pollVotes'] as List?)
                ?.map((e) => (e as num).toInt())
                .toList() ??
            const [],
        pollMyVote: json['pollMyVote'] as int? ?? -1,
        callEvent: json['callEvent'] as String? ?? '',
        callVideo: json['callVideo'] as bool? ?? false,
        callSeconds: json['callSeconds'] as int? ?? 0,
      );

  Message copyWith({
    List<FormResponse>? formResponses,
    bool? protected,
    String? threadRootId,
    String? text,
    MessageStatus? status,
    List<String>? reactions,
    bool? edited,
    String? originalText,
    bool? isDeleted,
    bool? viewOnceOpened,
    DateTime? expiresAt,
    List<int>? pollVotes,
    int? pollMyVote,
    String? paymentStatus,
  }) {
    return Message(
      id: id,
      text: text ?? this.text,
      time: time,
      isMe: isMe,
      status: status ?? this.status,
      senderName: senderName,
      reactions: reactions ?? this.reactions,
      replyTo: replyTo,
      forwarded: forwarded,
      protected: protected ?? this.protected,
      formResponses: formResponses ?? this.formResponses,
      threadRootId: threadRootId ?? this.threadRootId,
      isVoice: isVoice,
      voiceSeconds: voiceSeconds,
      isVoicemail: isVoicemail,
      isFile: isFile,
      fileName: fileName,
      isImage: isImage,
      imageSeed: imageSeed,
      imageUrl: imageUrl,
      viewOnce: viewOnce,
      viewOnceOpened: viewOnceOpened ?? this.viewOnceOpened,
      edited: edited ?? this.edited,
      originalText: originalText ?? this.originalText,
      isDeleted: isDeleted ?? this.isDeleted,
      expiresAt: expiresAt ?? this.expiresAt,
      isLocation: isLocation,
      locationLat: locationLat,
      locationLng: locationLng,
      locationLabel: locationLabel,
      isContact: isContact,
      contactName: contactName,
      contactPhone: contactPhone,
      isPayment: isPayment,
      paymentAmountCents: paymentAmountCents,
      paymentCurrency: paymentCurrency,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      serverInvite: serverInvite,
      isPoll: isPoll,
      isForm: isForm,
      formTitle: formTitle,
      formFields: formFields,
      pollQuestion: pollQuestion,
      pollOptions: pollOptions,
      pollVotes: pollVotes ?? this.pollVotes,
      pollMyVote: pollMyVote ?? this.pollMyVote,
      callEvent: callEvent,
      callVideo: callVideo,
      callSeconds: callSeconds,
    );
  }

  /// Formats [paymentAmountCents] as a currency string, e.g. "$20.00".
  String get paymentDisplay {
    final symbol = paymentCurrency.toLowerCase() == 'usd' ? r'$' : r'$';
    return '$symbol${(paymentAmountCents / 100).toStringAsFixed(2)}';
  }
}
