import 'dart:async';
import '../models/form_spec.dart';
import 'chat_folders.dart';
import 'chat_lock.dart';
import 'message_sound_store.dart';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import '../crypto/encryption_label.dart';
import '../data/mock_data.dart';
import '../models/chat.dart';
import '../models/message.dart';
import '../models/user.dart';
import 'score_store.dart';
import 'streak_store.dart';
import '../util/phone_match.dart' show samePhoneNumber;

/// Single in-memory source of truth for conversations, so pin/mute/archive,
/// unread counts, sent messages, and reactions stay consistent across every
/// screen. Kept deliberately simple (a [ChangeNotifier]) for this demo.
class ChatStore extends ChangeNotifier {
  ChatStore._() {
    // Sample conversations exist only for development and tests. A real
    // (release) install starts with an empty chat list — no bot contacts.
    _chats = kReleaseMode ? [] : MockData.chats();
  }

  static final ChatStore instance = ChatStore._();

  late List<Chat> _chats;

  Timer? _sweeper;

  /// Starts a periodic sweep that deletes expired (disappearing) messages even
  /// while their chat isn't open. Safe to call once at startup.
  void startSweeper() {
    _sweeper ??=
        Timer.periodic(const Duration(seconds: 20), (_) => sweepExpired());
  }

  /// Ids of messages the user has starred.
  final Set<String> _starred = {};

  /// Unsent composer text per chat id (drafts), restored when you reopen a
  /// conversation.
  final Map<String, String> _drafts = {};

  /// Per-chat wallpaper color (ARGB int) overriding the global default.
  final Map<String, int> _wallpapers = {};

  /// Ids of messages the user deleted from this device. The offline mailbox
  /// only drops a row once its DELETE round-trips, so a failed delete (or a
  /// crash mid-drain) replays the same envelope on the next launch — and the
  /// "have I already got this?" check can't see a message that is gone.
  /// Without these, deleting a message or a whole conversation is undone the
  /// next time the queue drains.
  final Set<String> _deletedMessageIds = {};

  /// How many tombstones to keep. They only have to outlive the mailbox TTL
  /// (14 days), so this is generous; oldest go first.
  static const int _maxDeletedIds = 5000;

  /// Whether [messageId] was deleted here and must not be re-added.
  bool isMessageDeleted(String messageId) =>
      _deletedMessageIds.contains(messageId);

  void _tombstone(Iterable<String> ids) {
    _deletedMessageIds.addAll(ids);
    if (_deletedMessageIds.length > _maxDeletedIds) {
      final excess = _deletedMessageIds.length - _maxDeletedIds;
      _deletedMessageIds.removeAll(_deletedMessageIds.take(excess).toList());
    }
  }

  /// Invoked after every change so a persistence layer can save.
  void Function()? onChanged;

  @override
  void notifyListeners() {
    super.notifyListeners();
    onChanged?.call();
  }

  Map<String, dynamic> toJson() => {
        'chats': _chats.map((c) => c.toJson()).toList(),
        'starred': _starred.toList(),
        'drafts': Map<String, String>.of(_drafts),
        'wallpapers': Map<String, int>.of(_wallpapers),
        'deletedIds': _deletedMessageIds.toList(),
      };

  /// Replaces all state from a previously-saved [json] snapshot.
  void hydrate(Map<String, dynamic> json) {
    _chats = (json['chats'] as List)
        .map((c) => Chat.fromJson(Map<String, dynamic>.from(c as Map)))
        .toList();
    if (kReleaseMode) {
      // Purge sample conversations persisted by earlier builds: demo chats
      // use 'c_*' ids; real ones are created as 'chat_<number>'.
      _chats.removeWhere((c) => c.id.startsWith('c_'));
    }
    _starred
      ..clear()
      ..addAll((json['starred'] as List? ?? const []).map((e) => '$e'));
    _drafts
      ..clear()
      ..addAll((json['drafts'] as Map? ?? const {})
          .map((k, v) => MapEntry('$k', '$v')));
    _wallpapers
      ..clear()
      ..addAll((json['wallpapers'] as Map? ?? const {})
          .map((k, v) => MapEntry('$k', v as int)));
    _deletedMessageIds
      ..clear()
      ..addAll((json['deletedIds'] as List? ?? const []).map((e) => '$e'));
    notifyListeners();
  }

  /// The wallpaper override for [chatId], or null to use the global default.
  Color? wallpaperFor(String chatId) {
    final v = _wallpapers[chatId];
    return v == null ? null : Color(v);
  }

  /// Sets (or clears, with null) a per-chat wallpaper.
  void setWallpaper(String chatId, Color? color) {
    if (color == null) {
      _wallpapers.remove(chatId);
    } else {
      _wallpapers[chatId] = color.toARGB32();
    }
    notifyListeners();
  }

  /// The saved draft for [chatId] (empty when none).
  String draftFor(String chatId) => _drafts[chatId] ?? '';

  /// Saves (or clears, when empty) the composer draft for [chatId]. Notifies
  /// listeners only when the draft appears/disappears (so the chat-list
  /// indicator updates), otherwise just persists — no per-keystroke rebuild.
  void setDraft(String chatId, String text) {
    final trimmed = text.trim();
    final current = _drafts[chatId] ?? '';
    if (trimmed == current) return;
    final visibilityChanged = trimmed.isEmpty != current.isEmpty;
    if (trimmed.isEmpty) {
      _drafts.remove(chatId);
    } else {
      _drafts[chatId] = trimmed;
    }
    if (visibilityChanged) {
      notifyListeners();
    } else {
      onChanged?.call();
    }
  }

  /// Replaces all conversations wholesale (used by the backend sync to push
  /// server state into the store). Preserves the local starred set.
  void setChats(List<Chat> chats) {
    _chats = List.of(chats);
    notifyListeners();
  }

  /// Deletes every conversation from the device. Used by Settings →
  /// "Storage and data" → clear all chats.
  void clearAll() {
    _chats = [];
    _starred.clear();
    _drafts.clear();
    _wallpapers.clear();
    _deletedMessageIds.clear();
    notifyListeners();
  }

  /// Reloads the initial sample data. Intended for tests to isolate state
  /// between cases (the store is otherwise a long-lived singleton).
  @visibleForTesting
  void reset() {
    _chats = MockData.chats();
    _starred.clear();
    _drafts.clear();
    _wallpapers.clear();
    _deletedMessageIds.clear();
    _lastPokeAt.clear();
    notifyListeners();
  }

  int _indexOf(String id) => _chats.indexWhere((c) => c.id == id);

  Chat? chatById(String id) {
    final i = _indexOf(id);
    return i == -1 ? null : _chats[i];
  }

  List<Chat> _sorted(Iterable<Chat> chats) {
    final list = chats.toList();
    list.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      final at = a.lastMessage?.time ?? DateTime(0);
      final bt = b.lastMessage?.time ?? DateTime(0);
      return bt.compareTo(at);
    });
    return list;
  }

  /// Visible (non-archived, non-hidden) conversations, pinned first then
  /// most-recent.
  ///
  /// Hidden chats are filtered HERE rather than in the list that draws them,
  /// so a screen added later is private by default instead of private only if
  /// somebody remembered. The ones that must see everything ask for
  /// [allChats] by name, which reads as the deliberate choice it is.
  /// Marketplace conversations are filtered here for the same reason — they
  /// live in their own section ([marketplaceChats]) so buyer traffic cannot
  /// bury friends.
  List<Chat> get chats => _sorted(_chats.where((c) =>
      !c.isArchived && !c.isRequest && !c.marketplace && !_concealed(c.id)));

  /// The Marketplace section: conversations born from a listing. Archiving
  /// one still wins — it goes to Archived, not two places at once.
  List<Chat> get marketplaceChats => _sorted(_chats.where((c) =>
      c.marketplace && !c.isArchived && !c.isRequest && !_concealed(c.id)));

  /// Unread total for the Marketplace folder row, so a waiting buyer is
  /// news on the chat list even with the folder closed.
  int get marketplaceUnread => marketplaceChats.fold(
      0, (sum, c) => sum + c.unreadCount);

  /// Files a conversation in or out of the Marketplace section. Either
  /// side's own choice — moving a chat out is how a buyer becomes a friend.
  void setMarketplace(String id, bool marketplace) {
    final i = _indexOf(id);
    if (i != -1 && _chats[i].marketplace != marketplace) {
      _replace(i, _chats[i].copyWith(marketplace: marketplace));
    }
  }

  /// One poke per chat per half-minute. A poke's whole content is "hey", and
  /// ten of them in a row is not ten heys — it is somebody's phone buzzing
  /// in their pocket until they mute you. In memory only: the brake is
  /// against a burst, not against poking again after lunch.
  static const Duration pokeCooldown = Duration(seconds: 30);
  final Map<String, DateTime> _lastPokeAt = {};

  /// How long until this chat may poke again; [Duration.zero] means now.
  Duration pokeCooldownLeft(String chatId) {
    final last = _lastPokeAt[chatId];
    if (last == null) return Duration.zero;
    final left = pokeCooldown - DateTime.now().difference(last);
    return left.isNegative ? Duration.zero : left;
  }

  void notePoked(String chatId) => _lastPokeAt[chatId] = DateTime.now();

  /// Archived AND hidden is a real combination, and hiding wins: somebody who
  /// archived a chat and then hid it did not mean "unless you look here".
  List<Chat> get archivedChats => _sorted(
      _chats.where((c) => c.isArchived && !c.isRequest && !_concealed(c.id)));

  int get archivedCount => _chats
      .where((c) => c.isArchived && !c.isRequest && !_concealed(c.id))
      .length;

  /// First contacts from strangers, waiting to be accepted — kept off the
  /// chat list so an unknown number cannot put itself in front of you.
  List<Chat> get requests =>
      _sorted(_chats.where((c) => c.isRequest && !_concealed(c.id)));

  int get requestCount =>
      _chats.where((c) => c.isRequest && !_concealed(c.id)).length;

  /// Moves a request into the chat list. From here on receipts, typing and
  /// presence flow like any other conversation.
  void acceptRequest(String id) {
    final i = _indexOf(id);
    if (i != -1 && _chats[i].isRequest) {
      _replace(i, _chats[i].copyWith(isRequest: false));
    }
  }

  /// Every conversation regardless of archived state — including hidden ones.
  /// Delivery, dedup and the sweeper use this: a hidden chat still receives
  /// messages, it just is not on a list anywhere until its password is typed.
  List<Chat> get allChats => List.unmodifiable(_chats);

  /// Conversations that exist but are being kept out of every list, hidden
  /// and not yet opened this session.
  bool _concealed(String id) => ChatLock.instance.isConcealed(id);

  /// The conversations search may look inside.
  ///
  /// A locked chat's messages are exactly what its password protects, so
  /// search reading them would be a way round the lock that never asks for
  /// it. The rule lives here rather than in the search screen because the
  /// next thing to search over would otherwise have to remember it too.
  /// Requests stay out too: search is how chats are found to message, and a
  /// stranger should not be able to place themselves in its results.
  List<Chat> get searchableChats => _chats
      .where((c) => !c.isRequest && ChatLock.instance.isOpen(c.id))
      .toList();

  /// The conversation holding [messageId]: the 1:1 chat with [senderId] when
  /// it has the message, else whichever chat does — which is how an event for
  /// a group message finds the group instead of the sender's own thread.
  Chat? chatWithMessage(String messageId, {String? senderId}) {
    if (senderId != null) {
      final direct = chatWithContact(senderId);
      if (direct != null && direct.messages.any((m) => m.id == messageId)) {
        return direct;
      }
    }
    for (final chat in _chats) {
      if (chat.messages.any((m) => m.id == messageId)) return chat;
    }
    return null;
  }

  /// The existing conversation with [contactId], if one exists. Falls back
  /// to digit-normalized matching: a push (and the relay generally)
  /// addresses people by bare digits, while the chat was created from a
  /// formatted number — same digits, same person. An exact-id miss used to
  /// read as "no chat", which sent a notification tap off to the system's
  /// SMS handler: our own alert opening iMessage.
  Chat? chatWithContact(String contactId) {
    final i = _chats.indexWhere((c) => c.contact.id == contactId);
    if (i != -1) return _chats[i];
    final d = contactId.replaceAll(RegExp(r'\D'), '');
    if (d.length < 7) return null;
    final j = _chats.indexWhere((c) =>
        !c.contact.isGroup &&
        (c.contact.phone.replaceAll(RegExp(r'\D'), '') == d ||
            c.contact.id.replaceAll(RegExp(r'\D'), '') == d));
    return j == -1 ? null : _chats[j];
  }

  /// Whether [target] (a typed number, contact id, or account code) names
  /// the signed-in user's own number. Takes [myPhone] as a parameter rather
  /// than reading `Session` directly — this store is imported by
  /// `relay_service.dart`, which `session.dart` itself imports, so importing
  /// `session.dart` here would be a cycle.
  bool isOwnNumber(String target, {required String? myPhone}) {
    if (myPhone == null || myPhone.isEmpty || target.isEmpty) return false;
    return samePhoneNumber(target, myPhone);
  }

  /// The single "open (or create) a chat with somebody" funnel every
  /// chat-creation call site should go through, rather than each repeating
  /// its own lookup-or-construct. Redirects to [noteToSelfChat] when
  /// [contact] is the signed-in user's own number — a real-number self-chat
  /// LOOKS like it sends, but the message is silently dropped by the
  /// relay's own echo-suppression filter and never actually delivers.
  Chat startChatWith(
    AppUser contact, {
    required String? myPhone,
    required String myAvatarColor,
    bool marketplace = false,
  }) {
    if (isOwnNumber(contact.phone.isNotEmpty ? contact.phone : contact.id,
        myPhone: myPhone)) {
      return noteToSelfChat(myAvatarColor: myAvatarColor);
    }
    final existing = chatWithContact(contact.id);
    if (existing != null) {
      if (existing.isArchived) setArchived(existing.id, false);
      return existing;
    }
    final chat = Chat(
        id: 'chat_${contact.id}',
        contact: contact,
        messages: const [],
        marketplace: marketplace);
    upsert(chat);
    return chat;
  }

  /// Opens (or creates) the private "Note to self" chat: a phone-less
  /// pseudo-contact that never touches the relay, so it's the one place a
  /// real-number self-chat can safely be redirected to. A self-chat sent
  /// over the real relay path LOOKS like it sends, but the message is
  /// silently dropped by the relay's own echo-suppression filter and never
  /// actually delivers.
  Chat noteToSelfChat({required String myAvatarColor}) {
    final existing = chatWithContact('self');
    if (existing != null) return existing;
    final chat = Chat(
      id: 'chat_self',
      contact: AppUser(
        id: 'self',
        name: 'Note to self',
        avatarColor: myAvatarColor,
        about: 'Your private notes',
        phone: '',
        emoji: '📝',
      ),
      messages: const [],
    );
    upsert(chat);
    return chat;
  }

  void _replace(int index, Chat chat) {
    _chats[index] = chat;
    notifyListeners();
  }

  void togglePin(String id) {
    final i = _indexOf(id);
    if (i != -1) _replace(i, _chats[i].copyWith(isPinned: !_chats[i].isPinned));
  }

  void toggleMute(String id) {
    final i = _indexOf(id);
    if (i != -1) _replace(i, _chats[i].copyWith(isMuted: !_chats[i].isMuted));
  }

  void toggleFavorite(String id) {
    final i = _indexOf(id);
    if (i != -1) {
      _replace(i, _chats[i].copyWith(isFavorite: !_chats[i].isFavorite));
    }
  }

  /// Whether any non-archived chat is currently marked a favourite.
  bool get hasFavorites =>
      _chats.any((c) => c.isFavorite && !c.isArchived);

  /// Turns the "confirm before sending" safeguard on or off for a chat.
  /// Turns forward/copy protection and screenshot notices on or off for one
  /// conversation.
  void setProtectContent(String id, bool value) {
    final i = _indexOf(id);
    if (i != -1 && _chats[i].protectContent != value) {
      _replace(i, _chats[i].copyWith(protectContent: value));
    }
  }

  /// Whether [id] is protected — false for a chat that no longer exists, so
  /// callers can ask without a null check.
  bool isProtected(String id) => chatById(id)?.protectContent ?? false;

  void setConfirmBeforeSend(String id, bool value) {
    final i = _indexOf(id);
    if (i != -1 && _chats[i].confirmBeforeSend != value) {
      _replace(i, _chats[i].copyWith(confirmBeforeSend: value));
    }
  }

  void setArchived(String id, bool archived) {
    final i = _indexOf(id);
    if (i != -1) {
      // Un-pin when archiving so it doesn't jump to the top on restore.
      _replace(
        i,
        _chats[i].copyWith(
          isArchived: archived,
          isPinned: archived ? false : _chats[i].isPinned,
        ),
      );
    }
  }

  void markRead(String id) {
    final i = _indexOf(id);
    if (i != -1 && _chats[i].unreadCount != 0) {
      _replace(i, _chats[i].copyWith(unreadCount: 0));
    }
  }

  void markUnread(String id) {
    final i = _indexOf(id);
    if (i != -1 && _chats[i].unreadCount == 0) {
      _replace(i, _chats[i].copyWith(unreadCount: 1));
    }
  }

  /// Digits of peers whose key change has been said this run — once is a
  /// warning, every alternation of a two-device pairing would be noise.
  final Set<String> _keyChangeNoted = {};

  /// Posts Signal's warning into the 1:1 chat when a contact's identity key
  /// CHANGED: usually their reinstall or new phone, and once in a while the
  /// one event a safety-number comparison exists to catch. Said in the
  /// conversation, where the person deciding whether to keep talking is.
  void noteIdentityChange(String digits) {
    if (_keyChangeNoted.contains(digits)) return;
    String d(String phone) => phone.replaceAll(RegExp(r'\D'), '');
    Chat? chat;
    for (final c in allChats) {
      if (!c.contact.isGroup && d(c.contact.phone) == digits) {
        chat = c;
        break;
      }
    }
    // No conversation, nothing to warn in — and not marked as said, so the
    // warning still lands if a chat forms later and the key changes again.
    if (chat == null) return;
    _keyChangeNoted.add(digits);
    addMessage(
      chat.id,
      Message(
        id: 'keychg_${digits}_${DateTime.now().microsecondsSinceEpoch}',
        text: '🔒 ${chat.contact.name}\'s security code changed — usually a '
            'new phone, a reinstall, or a restored backup on their side. To '
            'be sure nobody is in the middle, compare security codes in '
            'contact info.',
        time: DateTime.now(),
        isMe: false,
        status: MessageStatus.read,
      ),
    );
  }

  void deleteChat(String id) {
    final i = _indexOf(id);
    if (i != -1) {
      _tombstone([for (final m in _chats[i].messages) m.id]);
      _chats.removeAt(i);
      // No folder tab may keep counting a conversation that is gone.
      ChatFolders.instance.forget(id);
      // Nor should its custom sound linger as an orphaned override.
      MessageSoundStore.instance.forget(id);
      notifyListeners();
    }
  }

  /// Ensures a conversation exists for [chat] (used when starting a new chat).
  void upsert(Chat chat) {
    final i = _indexOf(chat.id);
    if (i == -1) {
      _chats.add(chat);
      notifyListeners();
    }
  }

  /// Like [upsert] but returns the live chat — the existing one when it's
  /// already there, else the newly-added one.
  Chat upsertReturning(Chat chat) {
    final i = _indexOf(chat.id);
    if (i != -1) return _chats[i];
    _chats.add(chat);
    notifyListeners();
    return chat;
  }

  /// Refreshes the stored [name], [avatarColor], and/or [about] of the contact
  /// whose id matches [contactId] — used both when a peer shares updated
  /// profile info on an incoming message (subject to their privacy settings)
  /// and when you rename a contact locally. No-ops when nothing changes, so it
  /// won't churn the list needlessly.
  void updateContactProfile(String contactId,
      {String? name,
      String? avatarColor,
      String? about,
      bool? verified,
      int? score,
      String? emoji,
      String? avatarSeed,
      String? pronouns,
      String? link,
      String? avatarColor2,
      String? bannerColor,
      String? location,
      bool? business,
      String? businessCategory,
      String? businessHours,
      bool? subscribable,
      int? subscriptionTier,
      String? subscriptionPitch,
      String? subscriptionTiersJson,
      String? lightningAddress}) {
    final i = _chats.indexWhere((c) => c.contact.id == contactId);
    if (i == -1) return;
    final c = _chats[i].contact;
    final nextName = (name != null && name.trim().isNotEmpty) ? name.trim() : c.name;
    final nextColor =
        (avatarColor != null && avatarColor.isNotEmpty) ? avatarColor : c.avatarColor;
    final nextAbout =
        (about != null && about.isNotEmpty) ? about : c.about;
    final nextVerified = verified ?? c.verified;
    // Only ever raise a contact's known score (a stale, lower broadcast
    // shouldn't roll it back).
    final nextScore = (score != null && score > c.score) ? score : c.score;
    final nextEmoji = (emoji != null && emoji.isNotEmpty) ? emoji : c.emoji;
    final nextAvatarSeed =
        (avatarSeed != null && avatarSeed.isNotEmpty) ? avatarSeed : c.avatarSeed;
    final nextPronouns =
        (pronouns != null && pronouns.isNotEmpty) ? pronouns : c.pronouns;
    final nextLink = (link != null && link.isNotEmpty) ? link : c.link;
    final nextColor2 = (avatarColor2 != null && avatarColor2.isNotEmpty)
        ? avatarColor2
        : c.avatarColor2;
    final nextBanner = (bannerColor != null && bannerColor.isNotEmpty)
        ? bannerColor
        : c.bannerColor;
    final nextLocation =
        (location != null && location.isNotEmpty) ? location : c.location;
    // The business flag applies as sent — false has to be able to clear it
    // (and takes the category and hours with it), unlike the non-empty-wins
    // strings above.
    final nextBusiness = business ?? c.isBusiness;
    final nextBusinessCategory =
        !nextBusiness ? '' : (businessCategory ?? c.businessCategory);
    final nextBusinessHours =
        !nextBusiness ? '' : (businessHours ?? c.businessHours);
    // Subscription flag applies as sent, same as business: turning it off
    // clears the tier and pitch, so a creator who stops offering it doesn't
    // keep advertising a price on a contact card forever.
    final nextSubscribable = subscribable ?? c.subscribable;
    final nextSubTier =
        !nextSubscribable ? 0 : (subscriptionTier ?? c.subscriptionTier);
    final nextSubPitch =
        !nextSubscribable ? '' : (subscriptionPitch ?? c.subscriptionPitch);
    final nextSubTiers = !nextSubscribable
        ? ''
        : (subscriptionTiersJson ?? c.subscriptionTiersJson);
    // Applied AS SENT, like `verified` and the business flag: a creator who
    // takes their tip address down must have it disappear from every contact
    // card, which the never-zeroed rule the other strings follow would not do.
    final nextLightning = lightningAddress ?? c.lightningAddress;
    if (nextName == c.name &&
        nextColor == c.avatarColor &&
        nextAbout == c.about &&
        nextVerified == c.verified &&
        nextScore == c.score &&
        nextEmoji == c.emoji &&
        nextAvatarSeed == c.avatarSeed &&
        nextPronouns == c.pronouns &&
        nextLink == c.link &&
        nextColor2 == c.avatarColor2 &&
        nextBanner == c.bannerColor &&
        nextLocation == c.location &&
        nextBusiness == c.isBusiness &&
        nextBusinessCategory == c.businessCategory &&
        nextBusinessHours == c.businessHours &&
        nextSubscribable == c.subscribable &&
        nextSubTier == c.subscriptionTier &&
        nextSubPitch == c.subscriptionPitch &&
        nextSubTiers == c.subscriptionTiersJson &&
        nextLightning == c.lightningAddress) {
      return;
    }
    _replace(
      i,
      _chats[i].copyWith(
        contact: AppUser(
          id: c.id,
          name: nextName,
          avatarColor: nextColor,
          about: nextAbout,
          phone: c.phone,
          username: c.username,
          isOnline: c.isOnline,
          isGroup: c.isGroup,
          verified: nextVerified,
          score: nextScore,
          emoji: nextEmoji,
          avatarSeed: nextAvatarSeed,
          pronouns: nextPronouns,
          link: nextLink,
          avatarColor2: nextColor2,
          bannerColor: nextBanner,
          location: nextLocation,
          isBusiness: nextBusiness,
          businessCategory: nextBusinessCategory,
          businessHours: nextBusinessHours,
          subscribable: nextSubscribable,
          subscriptionTier: nextSubTier,
          subscriptionPitch: nextSubPitch,
          subscriptionTiersJson: nextSubTiers,
          lightningAddress: nextLightning,
        ),
      ),
    );
  }

  /// Everyone you hold a real one-to-one conversation with — i.e. the people
  /// who can be added to a group and actually receive its messages. Note to
  /// self and sample contacts are excluded; sorted by name.
  List<AppUser> reachableContacts() {
    final seen = <String>{};
    final out = <AppUser>[];
    for (final chat in _chats) {
      final c = chat.contact;
      if (c.isGroup || c.phone.isEmpty || !seen.add(c.id)) continue;
      out.add(c);
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// Applies a group edit — a new [name], [about] description, [avatarColor]
  /// or [members] list — to the group conversation [chatId]. Blank values are
  /// left untouched, and a no-op edit doesn't churn the list.
  void updateGroup(
    String chatId, {
    String? name,
    String? about,
    String? avatarColor,
    List<AppUser>? members,
  }) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    final chat = _chats[i];
    final g = chat.contact;
    final nextName =
        (name != null && name.trim().isNotEmpty) ? name.trim() : g.name;
    final nextAbout = about?.trim() ?? g.about;
    final nextColor = (avatarColor != null && avatarColor.isNotEmpty)
        ? avatarColor
        : g.avatarColor;
    final nextMembers = members ?? chat.members;
    final sameMembers = nextMembers.length == chat.members.length &&
        !nextMembers.any((m) => !chat.members.any((o) => o.id == m.id));
    if (nextName == g.name &&
        nextAbout == g.about &&
        nextColor == g.avatarColor &&
        sameMembers) {
      return;
    }
    _replace(
      i,
      chat.copyWith(
        contact: AppUser(
          id: g.id,
          name: nextName,
          avatarColor: nextColor,
          about: nextAbout,
          phone: g.phone,
          username: g.username,
          isGroup: true,
          emoji: g.emoji,
          avatarSeed: g.avatarSeed,
        ),
        members: nextMembers,
      ),
    );
  }

  /// Puts a line in [chatId] saying a screenshot was taken.
  ///
  /// A plain message rather than a new kind, so it persists, scrolls and
  /// exports like everything else — and so an old build reading a newer
  /// backup shows a sentence rather than an empty bubble. [byMe] decides
  /// which side it sits on and which way round it reads.
  void noteScreenshot(String chatId,
      {required bool byMe, bool recording = false, bool ghost = false}) {
    if (_indexOf(chatId) == -1) return;
    final now = DateTime.now();
    addMessage(
      chatId,
      Message(
        // Interpolated, not escaped: a literal '$' here once gave every
        // notice the same id, which broke everything keyed by it (pins,
        // reactions, delete) for all but the first.
        id: 'shot_${now.microsecondsSinceEpoch}',
        text: ghost
            ? (byMe
                ? 'You took a screenshot of a ghost message.'
                : 'They took a screenshot of a ghost message.')
            : recording
                ? (byMe
                    ? 'You started recording or mirroring this chat.'
                    : 'They started recording or mirroring this chat.')
                : (byMe
                    ? 'You took a screenshot of this chat.'
                    : 'They took a screenshot of this chat.'),
        time: now,
        isMe: byMe,
        // Never forwardable, whatever the chat's setting is now: the notice
        // is about this conversation and means nothing outside it.
        protected: true,
      ),
    );
  }

  /// The replies hanging under [rootId], oldest first.
  List<Message> threadReplies(String chatId, String rootId) => [
        for (final m in chatById(chatId)?.messages ?? const <Message>[])
          if (m.threadRootId == rootId) m
      ];

  /// How many replies [rootId] has, for the line under it in the transcript.
  int threadReplyCount(String chatId, String rootId) =>
      threadReplies(chatId, rootId).length;

  /// Records one person's answers on the form message [messageId].
  ///
  /// Last answer wins per person: somebody who fills a form twice meant to
  /// correct it, and two rows under one name is a worse answer than one.
  void applyFormResponse(
      String chatId, String messageId, FormResponse response) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    final chat = _chats[i];
    final messages = [
      for (final m in chat.messages)
        if (m.id != messageId || !m.isForm)
          m
        else
          m.copyWith(formResponses: [
            for (final r in m.formResponses)
              if (r.from != response.from) r,
            response,
          ])
    ];
    _replace(i, chat.copyWith(messages: messages));
  }

  void addMessage(String chatId, Message message) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    var msg = message;
    // Stamp an expiry when the chat has disappearing messages enabled.
    final ttl = _chats[i].disappearingSeconds;
    if (ttl > 0 && msg.expiresAt == null) {
      msg = msg.copyWith(
          expiresAt: msg.time.add(Duration(seconds: ttl)));
    }
    _replace(
      i,
      _chats[i].copyWith(
        messages: [..._chats[i].messages, msg],
        // Incoming activity lights the chat's unread badge (the open chat
        // screen clears it straight back via markRead).
        unreadCount:
            msg.isMe ? _chats[i].unreadCount : _chats[i].unreadCount + 1,
        // Replying IS accepting: stamped on the one funnel every outgoing
        // message passes through, so no send path can leave a conversation
        // half-request.
        isRequest: msg.isMe ? false : _chats[i].isRequest,
      ),
    );
    // Grow the Okay Score for real conversation activity.
    ScoreStore.instance.award(
        msg.isMe ? ScoreStore.pointsPerSend : ScoreStore.pointsPerReceive,
        source: 'message');
    // Track the day-by-day conversation streak (groups don't have streaks).
    if (!_chats[i].contact.isGroup) {
      StreakStore.instance
          .record(chatId, isMe: msg.isMe, at: msg.time);
    }
  }

  /// Sets (or clears, with 0) the disappearing-messages timer for a chat.
  void setDisappearing(String chatId, int seconds) {
    final i = _indexOf(chatId);
    if (i != -1) {
      _replace(i, _chats[i].copyWith(disappearingSeconds: seconds));
    }
  }

  /// Snapchat-style: called when a chat with [Chat.afterViewing] is left after
  /// being read — clears its messages from this device. A no-op for every
  /// other chat, so the chat screen can call it on leave unconditionally.
  void expireViewed(String chatId) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    if (_chats[i].disappearingSeconds != Chat.afterViewing) return;
    if (_chats[i].messages.isEmpty) return;
    _replace(i, _chats[i].copyWith(messages: const []));
  }

  /// Removes any messages whose expiry has passed. Returns the number deleted.
  /// [now] is injectable for tests.
  int sweepExpired([DateTime? now]) {
    final at = now ?? DateTime.now();
    var removed = 0;
    for (var i = 0; i < _chats.length; i++) {
      final msgs = _chats[i].messages;
      final kept = msgs
          .where((m) => m.expiresAt == null || m.expiresAt!.isAfter(at))
          .toList();
      if (kept.length != msgs.length) {
        removed += msgs.length - kept.length;
        _chats[i] = _chats[i].copyWith(messages: kept);
      }
    }
    if (removed > 0) notifyListeners();
    return removed;
  }

  void replaceMessages(String chatId, List<Message> messages) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    _replace(i, _chats[i].copyWith(messages: messages));
  }

  /// Updates the lifecycle status ('pending' → 'paid' / 'failed') of a payment
  /// message. No-ops if the message isn't found or already has that status.
  void setPaymentStatus(String chatId, String messageId, String status) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    var changed = false;
    final msgs = _chats[i].messages.map((m) {
      if (m.id == messageId && m.isPayment && m.paymentStatus != status) {
        changed = true;
        return m.copyWith(paymentStatus: status);
      }
      return m;
    }).toList();
    if (changed) _replace(i, _chats[i].copyWith(messages: msgs));
  }

  /// Records that [readerDigits] has read up to [messageId] in a group:
  /// that message and every OWN message before it gain the reader. A read
  /// receipt names the newest message it acknowledges and everything
  /// earlier is implied — the same prefix [setOutgoingStatus] already
  /// applies to the ticks; this is the per-person version of it.
  void noteSeenUpTo(String chatId, String messageId, String readerDigits) {
    final i = _indexOf(chatId);
    if (i == -1 || readerDigits.isEmpty) return;
    final msgs = _chats[i].messages;
    final upTo = msgs.indexWhere((m) => m.id == messageId);
    if (upTo == -1) return;
    var changed = false;
    final next = [
      for (var j = 0; j < msgs.length; j++)
        () {
          final m = msgs[j];
          if (j > upTo || !m.isMe || m.seenBy.contains(readerDigits)) {
            return m;
          }
          changed = true;
          return m.copyWith(seenBy: [...m.seenBy, readerDigits]);
        }()
    ];
    if (changed) _replace(i, _chats[i].copyWith(messages: next));
  }

  /// Upgrades the delivery status of the user's own (outgoing) messages in a
  /// chat to at least [status] — used to apply delivered/read receipts.
  void setOutgoingStatus(String chatId, MessageStatus status) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    var changed = false;
    final msgs = _chats[i].messages.map((m) {
      if (m.isMe && m.status.index < status.index) {
        changed = true;
        return m.copyWith(status: status);
      }
      return m;
    }).toList();
    if (changed) _replace(i, _chats[i].copyWith(messages: msgs));
  }

  /// Records which key actually protected [messageId] — an
  /// [EncryptionLabel] code, so the Message info dialog can say so instead of
  /// guessing from whatever rung the chat happens to be on today.
  ///
  /// It only ever LOWERS. A group message is sealed once per member, and
  /// members are not all on the same rung, so recording the last one would
  /// claim the strongest key for a message that also went out under the
  /// weakest. A message is exactly as protected as its weakest delivery.
  void noteMessageEnc(String chatId, String messageId, int enc) {
    final i = _indexOf(chatId);
    if (i == -1 || enc < 0) return;
    var changed = false;
    final msgs = _chats[i].messages.map((m) {
      if (m.id != messageId) return m;
      final now = m.enc;
      if (now != EncryptionLabel.codeUnknown && now <= enc) return m;
      changed = true;
      return m.copyWith(enc: enc);
    }).toList();
    if (changed) _replace(i, _chats[i].copyWith(messages: msgs));
  }

  /// Removes every message from a conversation (keeps the chat itself).
  void clearMessages(String chatId) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    _tombstone([for (final m in _chats[i].messages) m.id]);
    _replace(i, _chats[i].copyWith(messages: const [], clearPinned: true));
  }

  /// Replaces a message's text and marks it edited, preserving the original
  /// text (from the first edit) so it can be viewed later.
  void editMessage(String chatId, String messageId, String newText) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    final msgs = _chats[i].messages
        .map((m) => m.id == messageId
            ? m.copyWith(
                text: newText,
                edited: true,
                originalText: m.originalText ?? m.text)
            : m)
        .toList();
    _replace(i, _chats[i].copyWith(messages: msgs));
  }

  /// Deletes a message. When [forEveryone] is true it stays in the thread as a
  /// "This message was deleted" tombstone (mirroring WhatsApp/Telegram); a
  /// plain delete (for me) removes it entirely.
  void deleteMessage(String chatId, String messageId,
      {bool forEveryone = false}) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    final List<Message> msgs;
    if (forEveryone) {
      msgs = _chats[i].messages.map((m) {
        if (m.id != messageId) return m;
        return m.copyWith(
            text: '', isDeleted: true, reactions: const []);
      }).toList();
    } else {
      // Deleted for me only: the message leaves the list entirely, so the
      // tombstone is the only thing stopping a mailbox replay bringing it
      // back. A delete-for-everyone stays in place as an empty bubble and
      // is caught by the ordinary duplicate check.
      msgs = _chats[i].messages.where((m) => m.id != messageId).toList();
      _tombstone([messageId]);
    }
    // Drop the deleted message from the pin list (leaving other pins intact).
    final pins = _chats[i]
        .pinnedMessageIds
        .where((id) => id != messageId)
        .toList();
    _replace(i, _chats[i].copyWith(messages: msgs, pinnedMessageIds: pins));
  }

  /// Free accounts can pin up to this many messages per chat; Okay Pro lifts
  /// the cap entirely.
  static const int freePinLimit = 3;

  /// Whether another message could be pinned in [chatId] right now, given the
  /// caller's Pro status. Pro members are never capped.
  bool canPinMore(String chatId, {required bool isPro}) {
    if (isPro) return true;
    final chat = chatById(chatId);
    final count = chat?.pinnedMessageIds.length ?? 0;
    return count < freePinLimit;
  }

  /// Pins [messageId] in [chatId] (most-recent last). No-op if already pinned.
  /// Callers gate the free-tier limit via [canPinMore]; this method itself is
  /// limit-agnostic so Pro pins aren't blocked.
  void pinMessage(String chatId, String messageId) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    if (_chats[i].pinnedMessageIds.contains(messageId)) return;
    final next = [..._chats[i].pinnedMessageIds, messageId];
    _replace(i, _chats[i].copyWith(pinnedMessageIds: next));
  }

  /// Records the local user's vote on a poll message, moving their tally from
  /// any previous choice. Returns the option index they previously held (-1 if
  /// none), so callers can broadcast the delta.
  int votePoll(String chatId, String messageId, int option) {
    final i = _indexOf(chatId);
    if (i == -1) return -1;
    var previous = -1;
    final msgs = _chats[i].messages.map((m) {
      if (m.id != messageId || !m.isPoll) return m;
      if (option < 0 || option >= m.pollOptions.length) return m;
      previous = m.pollMyVote;
      if (previous == option) return m; // already voted this option
      final votes = [...m.pollVotes];
      while (votes.length < m.pollOptions.length) {
        votes.add(0);
      }
      if (previous >= 0 && previous < votes.length && votes[previous] > 0) {
        votes[previous]--;
      }
      votes[option]++;
      return m.copyWith(pollVotes: votes, pollMyVote: option);
    }).toList();
    _replace(i, _chats[i].copyWith(messages: msgs));
    if (previous != option) {
      ScoreStore.instance.award(ScoreStore.pointsPerPollVote, source: 'poll');
      ScoreStore.instance.recordFlag('voted_poll');
    }
    return previous;
  }

  /// Applies a remote peer's poll vote (increment [addOption], decrement an
  /// optional [removeOption]) without touching this device's own choice.
  void applyRemotePollVote(String chatId, String messageId, int addOption,
      int removeOption) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    final msgs = _chats[i].messages.map((m) {
      if (m.id != messageId || !m.isPoll) return m;
      final votes = [...m.pollVotes];
      while (votes.length < m.pollOptions.length) {
        votes.add(0);
      }
      if (removeOption >= 0 &&
          removeOption < votes.length &&
          votes[removeOption] > 0) {
        votes[removeOption]--;
      }
      if (addOption >= 0 && addOption < votes.length) votes[addOption]++;
      return m.copyWith(pollVotes: votes);
    }).toList();
    _replace(i, _chats[i].copyWith(messages: msgs));
  }

  /// Marks [payerPhone]'s share of the split bill [messageId] as paid — used
  /// both when this device pays a share and when a remote 'billpaid' update
  /// arrives, so every participant's card converges on who's settled up.
  void markBillSharePaid(String chatId, String messageId, String payerPhone) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    var changed = false;
    final msgs = _chats[i].messages.map((m) {
      if (m.id != messageId || m.billSplit == null) return m;
      changed = true;
      return m.copyWith(billSplit: m.billSplit!.markPaid(payerPhone));
    }).toList();
    if (!changed) return;
    _replace(i, _chats[i].copyWith(messages: msgs));
  }

  /// Marks a "view once" message as opened, so it can't be viewed again.
  ///
  /// A received ghost TEXT loses its words here too, not only its
  /// openability: the bubble never renders them again, so keeping them would
  /// be keeping a copy purely for whoever gets hold of the store. The
  /// sender's own copy keeps its text — their words, their device — which is
  /// also what the far side's 'vopen' receipt marks.
  void markViewOnceOpened(String chatId, String messageId) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    var changed = false;
    final msgs = _chats[i].messages.map((m) {
      if (m.id == messageId && m.viewOnce && !m.viewOnceOpened) {
        changed = true;
        final wipe = !m.isMe && !m.isImage;
        return m.copyWith(viewOnceOpened: true, text: wipe ? '' : null);
      }
      return m;
    }).toList();
    if (changed) _replace(i, _chats[i].copyWith(messages: msgs));
  }

  /// Removes a single pinned message from [chatId].
  void unpinMessage(String chatId, String messageId) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    if (!_chats[i].pinnedMessageIds.contains(messageId)) return;
    final next =
        _chats[i].pinnedMessageIds.where((id) => id != messageId).toList();
    _replace(i, _chats[i].copyWith(pinnedMessageIds: next));
  }

  /// Removes every pinned message from [chatId].
  void unpinAll(String chatId) {
    final i = _indexOf(chatId);
    if (i != -1) _replace(i, _chats[i].copyWith(clearPinned: true));
  }

  // Message ids are only unique within a chat, so star keys are composite.
  String _starKey(String chatId, String messageId) => '$chatId::$messageId';

  bool isStarred(String chatId, String messageId) =>
      _starred.contains(_starKey(chatId, messageId));

  void toggleStar(String chatId, String messageId) {
    final key = _starKey(chatId, messageId);
    if (!_starred.remove(key)) _starred.add(key);
    notifyListeners();
  }

  /// All starred messages paired with the conversation they belong to.
  List<({Chat chat, Message message})> starredMessages() {
    final out = <({Chat chat, Message message})>[];
    for (final c in _chats) {
      for (final m in c.messages) {
        if (_starred.contains(_starKey(c.id, m.id))) {
          out.add((chat: c, message: m));
        }
      }
    }
    out.sort((a, b) => b.message.time.compareTo(a.message.time));
    return out;
  }

  /// A mutable deep copy of a message's per-emoji reactor map.
  static Map<String, List<String>> _copyReactionsBy(Message m) => {
        for (final e in m.reactionsBy.entries) e.key: List<String>.from(e.value)
      };

  /// Forces [emoji] on a message to [present] (used to mirror a peer's
  /// reaction received over the relay). [reactor] is the reactor's digits so a
  /// "reacted by" list can name them; empty falls back to the old anonymous
  /// flat toggle (older wire that carried no sender).
  void setReactionState(
      String chatId, String messageId, String emoji, bool present,
      {String reactor = ''}) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    var changed = false;
    final msgs = _chats[i].messages.map((m) {
      if (m.id != messageId) return m;
      final reactions = List<String>.from(m.reactions);
      if (reactor.isEmpty) {
        final has = reactions.contains(emoji);
        if (present && !has) {
          reactions.add(emoji);
        } else if (!present && has) {
          reactions.remove(emoji);
        } else {
          return m;
        }
        changed = true;
        return m.copyWith(reactions: reactions);
      }
      final by = _copyReactionsBy(m);
      final list = by.putIfAbsent(emoji, () => <String>[]);
      final had = list.contains(reactor);
      if (present && !had) {
        list.add(reactor);
      } else if (!present && had) {
        list.remove(reactor);
      } else {
        return m; // nothing to do — a duplicate event
      }
      if (list.isEmpty) {
        by.remove(emoji);
        reactions.remove(emoji);
      } else if (!reactions.contains(emoji)) {
        reactions.add(emoji);
      }
      changed = true;
      return m.copyWith(reactions: reactions, reactionsBy: by);
    }).toList();
    if (changed) _replace(i, _chats[i].copyWith(messages: msgs));
  }

  /// Toggles [emoji] on a message: adds it if absent, removes it if present.
  /// [reactor] is the toggling account's digits, recorded so the message can
  /// say WHO reacted; empty keeps the old anonymous flat behaviour.
  void toggleReaction(String chatId, String messageId, String emoji,
      {String reactor = ''}) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    final msgs = _chats[i].messages.map((m) {
      if (m.id != messageId) return m;
      final reactions = List<String>.from(m.reactions);
      if (reactor.isEmpty) {
        if (reactions.contains(emoji)) {
          reactions.remove(emoji);
        } else {
          reactions.add(emoji);
        }
        return m.copyWith(reactions: reactions);
      }
      final by = _copyReactionsBy(m);
      final list = by.putIfAbsent(emoji, () => <String>[]);
      if (list.contains(reactor)) {
        list.remove(reactor);
      } else {
        list.add(reactor);
      }
      if (list.isEmpty) {
        by.remove(emoji);
        reactions.remove(emoji);
      } else if (!reactions.contains(emoji)) {
        reactions.add(emoji);
      }
      return m.copyWith(reactions: reactions, reactionsBy: by);
    }).toList();
    _replace(i, _chats[i].copyWith(messages: msgs));
  }
}
