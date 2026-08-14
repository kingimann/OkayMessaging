import '../crypto/encryption_label.dart';
import '../payments/money.dart';
import 'bill_split.dart';
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

/// How long after sending a message can still be UNSENT — taken back with
/// no trace on either side, as opposed to deleted (which leaves a "This
/// message was deleted" tombstone) or edited (which leaves an "edited" mark).
///
/// Five minutes is the window the owner asked for. It is long enough to
/// catch the wrong-chat and wrong-person mistakes unsend exists for, and
/// short enough that it cannot be used to quietly rewrite a conversation
/// somebody had days ago.
const Duration kUnsendWindow = Duration(minutes: 5);

/// A single chat message.
class Message {
  final String id;
  final String text;

  /// An optional one-line SUBJECT above the body, the way an email has one.
  /// Empty on nearly every message — it is only filled when the sender has
  /// turned the subject bar on (Settings -> Chats & appearance) and actually
  /// typed one. Rides the same sealed payload as the body.
  final String subject;
  final DateTime time;

  /// True when the message was sent by the current (local) user.
  final bool isMe;
  final MessageStatus status;

  /// Display name of whoever sent this, shown above incoming bubbles in a
  /// group so members can tell each other apart. Empty in one-to-one chats.
  final String senderName;

  /// Digits of whoever sent this, where the room itself doesn't say — group
  /// and channel messages, whose sender is otherwise only a display name.
  /// Empty in 1:1 chats (the chat's contact IS the sender) and on messages
  /// from builds before this field. What it exists for: sparking somebody's
  /// message needs an address for the money, and a name is not one.
  final String senderPhone;

  /// Emoji reactions attached to this message (e.g. ['👍', '❤️']). The set of
  /// emoji currently on the message; [reactionsBy] carries WHO put each one.
  final List<String> reactions;

  /// Who reacted with each emoji — emoji → the reactors' digits. Mirrors
  /// [seenBy]'s shape so a "reacted by" list can name people. The wire already
  /// carries the reactor (`from`), so this fills in over time; older reactions
  /// that predate it simply have no names to show, and [reactions] stays the
  /// source of truth for WHICH emoji are present.
  final Map<String, List<String>> reactionsBy;

  /// Group members (digits) whose read receipt has covered this message —
  /// a receipt names the newest message it acknowledges, and everything
  /// before it is implied, the same prefix the ticks already use. Only
  /// meaningful on OWN messages in a group; empty everywhere else.
  final List<String> seenBy;

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

  /// Sent from a chat that was born in the Marketplace. Stamped once in
  /// [ChatScreen]'s delivery funnel like [protected], and it exists for one
  /// reason: the FIRST message a buyer sends is how the seller's device
  /// learns the new conversation belongs in the marketplace section rather
  /// than among their friends. A label, never a lock.
  final bool marketplace;

  /// True for voice messages; [voiceSeconds] then holds the clip length.
  final bool isVoice;
  final int voiceSeconds;

  /// A SHORT recorded clip as a `data:audio/…;base64,…` URI — the actual
  /// sound, sealed into the message like a photo's [imageUrl] so it rides the
  /// same E2E path. Null on an old voice message that only carried a duration
  /// (bubble says "can't be played"), or on a LONG note, which is too big for
  /// the relay and lives in the bucket instead ([audioPath] / [audioKey]).
  final String? audioUrl;

  /// A LONG voice note's object in the `voice-notes` bucket, and the base64
  /// key that unseals it. The key rides here inside the E2E-sealed message, so
  /// the bucket only ever holds ciphertext — see [VoiceMedia]. Both null for
  /// an inline ([audioUrl]) note.
  final String? audioPath;
  final String? audioKey;

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

  /// True for a sticker: an emoji sticker carries the emoji in [text] and is
  /// drawn huge with no bubble; a photo sticker also sets [isImage] and rides
  /// the same sealed data-URI path a photo does, drawn compact and bare.
  final bool isSticker;

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

  /// True for a LIVE-location message — one that keeps updating while the
  /// sender is sharing. [liveUntil] is when the share is scheduled to end;
  /// [locationLat]/[locationLng] hold the latest position known when this was
  /// built (the live pin itself is read from the live-location stores, which
  /// stay fresh as positions arrive). A live message is also [isLocation], so
  /// every "is this a place?" check already covers it.
  final bool isLiveLocation;
  final DateTime? liveUntil;

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

  /// True when this payment message ASKS for money rather than moves it —
  /// no charge exists until the other side taps Pay. [paymentStatus] runs
  /// 'requested' → 'paid' / 'declined' instead of the send lifecycle.
  final bool isPaymentRequest;

  /// Lifecycle of an in-chat payment: 'pending' while it's being confirmed,
  /// 'paid' once it settles, or 'failed'. Empty for non-payment messages.
  final String paymentStatus;

  /// A poke: no words, just "hey". Rides as a real message on purpose —
  /// that is what buys store-and-forward for an offline phone, the push,
  /// and the unread badge, none of which a fire-and-forget ping gets.
  final bool isPoke;

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

  /// A marketplace listing shared into the chat: the JSON snapshot a
  /// [ListingCard] decodes from. Empty for every other message.
  ///
  /// Facebook's shape, and for Facebook's reason — a forwarded listing used
  /// to arrive as a paragraph somebody had to go and search for. The card
  /// carries the listing's ID, so it OPENS.
  final String listingCard;

  /// A link, as a card: the JSON a [LinkPreview] decodes from, built on the
  /// SENDER's device and carried inside this message. The recipient never
  /// fetches anything to draw it — see [LinkPreview] for why that is the
  /// whole point.
  final String linkPreview;

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

  /// Each voter's chosen option, keyed by their phone digits — the source of
  /// truth [pollVotes] is tallied from (mirrors [reactionsBy]'s emoji→reactor
  /// shape). Needed so a group poll can weight an admin's vote without losing
  /// the ability to move or undo a single voter's ballot: a flat per-option
  /// count alone can't tell WHOSE vote to reweight.
  final Map<String, int> pollVotesBy;

  /// A planned meeting: [meetingTitle] is what it is, [meetingAt] when, and
  /// [meetingPlace] optionally where. Who is coming is the poll underneath —
  /// see `lib/models/meeting.dart` for why an RSVP is a poll vote rather
  /// than a fourth kind of response event.
  ///
  /// [isMeeting] is checked BEFORE [isPoll] wherever a bubble or a label is
  /// chosen, because a meeting message carries both: it really is a poll
  /// with three fixed options, and it must not draw as one.
  final bool isMeeting;
  final String meetingTitle;
  final DateTime? meetingAt;
  final String meetingPlace;

  /// A split bill: the whole thing (title, total, each person's share and
  /// whether they've paid) rides on the message like a poll's votes, so it is
  /// E2E encrypted and lives only on the devices in the chat — never a server
  /// row. Null for every other message.
  final BillSplit? billSplit;

  /// Which key actually protected this message, as an [EncryptionLabel] code.
  ///
  /// Recorded rather than inferred at display time: the ladder a chat is on
  /// climbs as keys arrive, so asking "how is this chat encrypted now" would
  /// re-label yesterday's messages with today's answer. Defaults to
  /// [EncryptionLabel.codeUnknown] — a message that was never sent anywhere,
  /// or one stored before this field existed, says so rather than claiming a
  /// rung.
  final int enc;

  const Message({
    required this.id,
    required this.text,
    required this.time,
    required this.isMe,
    this.status = MessageStatus.read,
    this.senderName = '',
    this.senderPhone = '',
    this.reactions = const [],
    this.reactionsBy = const {},
    this.seenBy = const [],
    this.replyTo,
    this.forwarded = false,
    this.subject = '',
    this.threadRootId,
    this.protected = false,
    this.marketplace = false,
    this.isVoice = false,
    this.voiceSeconds = 0,
    this.audioUrl,
    this.audioPath,
    this.audioKey,
    this.isVoicemail = false,
    this.isFile = false,
    this.fileName = '',
    this.isSticker = false,
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
    this.isLiveLocation = false,
    this.liveUntil,
    this.isContact = false,
    this.contactName,
    this.contactPhone,
    this.isPayment = false,
    this.paymentAmountCents = 0,
    this.paymentCurrency = 'cad',
    this.isPaymentRequest = false,
    this.paymentStatus = '',
    this.serverInvite = '',
    this.listingCard = '',
    this.linkPreview = '',
    this.isPoll = false,
    this.isForm = false,
    this.formTitle = '',
    this.formFields = const [],
    this.formResponses = const [],
    this.pollQuestion = '',
    this.pollOptions = const [],
    this.pollVotes = const [],
    this.pollMyVote = -1,
    this.pollVotesBy = const {},
    this.isMeeting = false,
    this.meetingTitle = '',
    this.meetingAt,
    this.meetingPlace = '',
    this.billSplit,
    this.isPoke = false,
    this.callEvent = '',
    this.callVideo = false,
    this.callSeconds = 0,
    this.enc = EncryptionLabel.codeUnknown,
  });

  /// How this message was protected, in words — see [EncryptionLabel].
  EncryptionKind get encryptionKind => EncryptionLabel.fromCode(enc);

  /// Whether this message is a call record rather than content.
  bool get isCallEvent => callEvent.isNotEmpty;

  /// Whether this message carries a server invite card.
  bool get isServerInvite => serverInvite.isNotEmpty;

  /// Whether this message carries a marketplace listing card.
  bool get isListingCard => listingCard.isNotEmpty;

  /// Whether this message carries a link card. Never exclusive with text —
  /// the words stay, the card is drawn under them.
  bool get hasLinkPreview => linkPreview.isNotEmpty;

  /// Whether this message can still be taken back, [now] being the clock to
  /// measure against (injected so a test does not have to wait five minutes).
  ///
  /// Yours only, and never one already deleted — a tombstone has nothing left
  /// to unsend. Pure, so the window is one rule rather than a comparison
  /// written out at each place that offers the action.
  bool canUnsendAt(DateTime now) =>
      isMe && !isDeleted && now.difference(time) < kUnsendWindow;

  /// What is left of the window, floored at zero.
  Duration unsendLeftAt(DateTime now) {
    final left = kUnsendWindow - now.difference(time);
    return left.isNegative ? Duration.zero : left;
  }

  /// Total votes cast across all poll options.
  int get pollTotalVotes => pollVotes.fold(0, (n, v) => n + v);

  /// Whether this message carries a split bill.
  bool get isBillSplit => billSplit != null;

  /// A short, CONTENT-FREE description of what kind of message this is —
  /// "Photo", "Voice message", … — or '' for a plain text message. Used to
  /// label a notification by TYPE without leaking the message body: safe to
  /// send to the push broker, which the encrypted content never is.
  String get typeLabel {
    if (isPoke) return 'Poke 👋';
    if (isSticker) return 'Sticker';
    if (isVoice) return '🎤 Voice message';
    if (isFile) return '📎 File';
    if (isLiveLocation) return '📍 Live location';
    if (isLocation) return '📍 Location';
    if (isContact) return '👤 Contact';
    if (isPaymentRequest) return '💵 Payment request';
    if (isPayment) return '💵 Payment';
    if (isListingCard) return '\u{1F3F7} Listing';
    // Before the poll case: a meeting message is also a poll, and saying
    // "Poll" about one is the wrong word for the thing that arrived.
    if (isMeeting) return '📅 Meeting';
    if (isPoll) return '📊 Poll';
    if (isForm) return '📋 Form';
    if (isBillSplit) return '🧾 Bill split';
    if (viewOnce) return '📷 Photo'; // never "view-once" — that leaks intent
    if (isImage) return '📷 Photo';
    return '';
  }

  /// The best one-line label for an in-app notification / chat-list preview,
  /// where the device already holds the decrypted message so its own text is
  /// fair to show. Falls back to the type label, then a generic.
  String get previewLabel {
    if (viewOnce) return '📷 Photo';
    // The device already holds this decrypted, so naming the meeting is
    // fair here — [typeLabel], which the push broker sees, stays generic.
    if (isMeeting && meetingTitle.trim().isNotEmpty) {
      return '📅 ${meetingTitle.trim()}';
    }
    if (text.trim().isNotEmpty && !isPoke) return text;
    final t = typeLabel;
    return t.isEmpty ? 'New message' : t;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        if (subject.isNotEmpty) 'subject': subject,
        'time': time.toIso8601String(),
        'isMe': isMe,
        'status': status.index,
        'senderName': senderName,
        if (senderPhone.isNotEmpty) 'senderPhone': senderPhone,
        'reactions': reactions,
        if (reactionsBy.isNotEmpty) 'reactionsBy': reactionsBy,
        if (seenBy.isNotEmpty) 'seenBy': seenBy,
        'replyTo': replyTo?.toJson(),
        'forwarded': forwarded,
        'threadRootId': threadRootId,
        'protected': protected,
        if (marketplace) 'marketplace': true,
        'isVoice': isVoice,
        'voiceSeconds': voiceSeconds,
        if (audioUrl != null) 'audioUrl': audioUrl,
        if (audioPath != null) 'audioPath': audioPath,
        if (audioKey != null) 'audioKey': audioKey,
        'isVoicemail': isVoicemail,
        if (isFile) 'isFile': true,
        if (isFile) 'fileName': fileName,
        if (isSticker) 'isSticker': true,
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
        if (isLiveLocation) 'isLiveLocation': true,
        if (liveUntil != null) 'liveUntil': liveUntil!.toIso8601String(),
        'isContact': isContact,
        'contactName': contactName,
        'contactPhone': contactPhone,
        'isPayment': isPayment,
        'paymentAmountCents': paymentAmountCents,
        'paymentCurrency': paymentCurrency,
        'isPaymentRequest': isPaymentRequest,
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
        if (pollVotesBy.isNotEmpty) 'pollVotesBy': pollVotesBy,
        if (listingCard.isNotEmpty) 'listingCard': listingCard,
        if (linkPreview.isNotEmpty) 'linkPreview': linkPreview,
        if (isMeeting) 'isMeeting': true,
        if (meetingTitle.isNotEmpty) 'meetingTitle': meetingTitle,
        if (meetingAt != null) 'meetingAt': meetingAt!.toIso8601String(),
        if (meetingPlace.isNotEmpty) 'meetingPlace': meetingPlace,
        if (billSplit != null) 'billSplit': billSplit!.toJson(),
        if (isPoke) 'isPoke': true,
        'callEvent': callEvent,
        'callVideo': callVideo,
        'callSeconds': callSeconds,
        // Written only once there is something to record. This map is also
        // the channel-message wire shape, and a receiver builds its own
        // Message from what it actually opened — the sender's bookkeeping is
        // never read back as a claim about the recipient's copy.
        if (enc != EncryptionLabel.codeUnknown) 'enc': enc,
      };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String,
        text: json['text'] as String,
        subject: json['subject'] as String? ?? '',
        time: DateTime.parse(json['time'] as String),
        isMe: json['isMe'] as bool,
        status: MessageStatus.values[json['status'] as int? ?? 3],
        senderName: json['senderName'] as String? ?? '',
        senderPhone: json['senderPhone'] as String? ?? '',
        reactions: (json['reactions'] as List?)?.cast<String>() ?? const [],
        reactionsBy: (json['reactionsBy'] as Map?)?.map((k, v) =>
                MapEntry('$k', (v as List?)?.cast<String>() ?? const <String>[])) ??
            const {},
        seenBy: (json['seenBy'] as List?)?.cast<String>() ?? const [],
        replyTo: json['replyTo'] == null
            ? null
            : ReplyInfo.fromJson(
                Map<String, dynamic>.from(json['replyTo'] as Map)),
        forwarded: json['forwarded'] as bool? ?? false,
        threadRootId: json['threadRootId'] as String?,
        protected: json['protected'] as bool? ?? false,
        marketplace: json['marketplace'] as bool? ?? false,
        isVoice: json['isVoice'] as bool? ?? false,
        voiceSeconds: json['voiceSeconds'] as int? ?? 0,
        audioUrl: json['audioUrl'] as String?,
        audioPath: json['audioPath'] as String?,
        audioKey: json['audioKey'] as String?,
        isVoicemail: json['isVoicemail'] as bool? ?? false,
        isFile: json['isFile'] as bool? ?? false,
        fileName: json['fileName'] as String? ?? '',
        isSticker: json['isSticker'] as bool? ?? false,
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
        isLiveLocation: json['isLiveLocation'] as bool? ?? false,
        liveUntil: json['liveUntil'] == null
            ? null
            : DateTime.tryParse(json['liveUntil'] as String),
        isContact: json['isContact'] as bool? ?? false,
        contactName: json['contactName'] as String?,
        contactPhone: json['contactPhone'] as String?,
        isPayment: json['isPayment'] as bool? ?? false,
        paymentAmountCents: json['paymentAmountCents'] as int? ?? 0,
        paymentCurrency: json['paymentCurrency'] as String? ?? 'cad',
        isPaymentRequest: json['isPaymentRequest'] as bool? ?? false,
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
        pollVotesBy: (json['pollVotesBy'] as Map?)
                ?.map((k, v) => MapEntry('$k', (v as num).toInt())) ??
            const {},
        listingCard: json['listingCard'] as String? ?? '',
        linkPreview: json['linkPreview'] as String? ?? '',
        isMeeting: json['isMeeting'] as bool? ?? false,
        meetingTitle: json['meetingTitle'] as String? ?? '',
        meetingAt: json['meetingAt'] == null
            ? null
            : DateTime.tryParse(json['meetingAt'] as String),
        meetingPlace: json['meetingPlace'] as String? ?? '',
        billSplit: json['billSplit'] == null
            ? null
            : BillSplit.fromJson(
                Map<String, dynamic>.from(json['billSplit'] as Map)),
        isPoke: json['isPoke'] as bool? ?? false,
        callEvent: json['callEvent'] as String? ?? '',
        callVideo: json['callVideo'] as bool? ?? false,
        callSeconds: json['callSeconds'] as int? ?? 0,
        enc: (json['enc'] as num?)?.toInt() ?? EncryptionLabel.codeUnknown,
      );

  Message copyWith({
    List<FormResponse>? formResponses,
    bool? protected,
    bool? marketplace,
    String? threadRootId,
    String? text,
    String? subject,
    MessageStatus? status,
    List<String>? reactions,
    Map<String, List<String>>? reactionsBy,
    List<String>? seenBy,
    bool? edited,
    String? originalText,
    bool? isDeleted,
    bool? viewOnceOpened,
    DateTime? expiresAt,
    DateTime? liveUntil,
    List<int>? pollVotes,
    int? pollMyVote,
    Map<String, int>? pollVotesBy,
    String? paymentStatus,
    BillSplit? billSplit,
    int? enc,
  }) {
    return Message(
      id: id,
      text: text ?? this.text,
      subject: subject ?? this.subject,
      time: time,
      isMe: isMe,
      status: status ?? this.status,
      senderName: senderName,
      senderPhone: senderPhone,
      reactions: reactions ?? this.reactions,
      reactionsBy: reactionsBy ?? this.reactionsBy,
      seenBy: seenBy ?? this.seenBy,
      replyTo: replyTo,
      forwarded: forwarded,
      protected: protected ?? this.protected,
      marketplace: marketplace ?? this.marketplace,
      formResponses: formResponses ?? this.formResponses,
      threadRootId: threadRootId ?? this.threadRootId,
      isVoice: isVoice,
      voiceSeconds: voiceSeconds,
      audioUrl: audioUrl,
      audioPath: audioPath,
      audioKey: audioKey,
      isVoicemail: isVoicemail,
      isFile: isFile,
      fileName: fileName,
      isSticker: isSticker,
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
      isLiveLocation: isLiveLocation,
      liveUntil: liveUntil ?? this.liveUntil,
      isContact: isContact,
      contactName: contactName,
      contactPhone: contactPhone,
      isPayment: isPayment,
      paymentAmountCents: paymentAmountCents,
      paymentCurrency: paymentCurrency,
      isPaymentRequest: isPaymentRequest,
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
      pollVotesBy: pollVotesBy ?? this.pollVotesBy,
      listingCard: listingCard,
      linkPreview: linkPreview,
      // Carried, never overridden: what a meeting IS does not change once
      // it is sent — only who is coming does, and that is the poll above.
      isMeeting: isMeeting,
      meetingTitle: meetingTitle,
      meetingAt: meetingAt,
      meetingPlace: meetingPlace,
      billSplit: billSplit ?? this.billSplit,
      isPoke: isPoke,
      callEvent: callEvent,
      callVideo: callVideo,
      callSeconds: callSeconds,
      enc: enc ?? this.enc,
    );
  }

  /// Formats [paymentAmountCents] in the currency it was charged in, e.g.
  /// "CA$20.00".
  ///
  /// This used to pick the symbol with `currency == 'usd' ? r'$' : r'$'` —
  /// both arms identical, so the currency rode the whole way here and was
  /// then thrown away. Every transfer read as plain dollars.
  String get paymentDisplay =>
      Money.format(paymentAmountCents, paymentCurrency);
}
