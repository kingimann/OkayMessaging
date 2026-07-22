import 'package:flutter/material.dart';

import 'data/mock_data.dart';
import 'models/user.dart';

/// Who a given piece of your profile / activity is shared with. Mirrors the
/// familiar Everyone / My contacts / Nobody privacy control.
enum PrivacyAudience {
  everyone,
  contacts,
  nobody;

  /// Human-readable label for the settings UI.
  String get label => switch (this) {
        PrivacyAudience.everyone => 'Everyone',
        PrivacyAudience.contacts => 'My contacts',
        PrivacyAudience.nobody => 'Nobody',
      };

  static PrivacyAudience fromName(String? name) => PrivacyAudience.values
      .firstWhere((a) => a.name == name, orElse: () => PrivacyAudience.everyone);
}

/// Lightweight global app state. Kept intentionally simple (a couple of
/// [ValueNotifier]s) since this is a UI-only demo with no persistence layer.
class AppState {
  AppState._();

  /// The active theme mode; toggled from the Settings screen.
  static final ValueNotifier<ThemeMode> themeMode =
      ValueNotifier<ThemeMode>(ThemeMode.light);

  /// The current user's editable profile (name + about).
  static final ValueNotifier<AppUser> profile =
      ValueNotifier<AppUser>(MockData.me);

  /// The chat background color; null uses the default wallpaper.
  static final ValueNotifier<Color?> chatWallpaper =
      ValueNotifier<Color?>(null);

  /// Whether to broadcast your online / last-seen status to people you chat
  /// with. When off, peers won't see you as "online".
  static final ValueNotifier<bool> shareLastSeen = ValueNotifier<bool>(true);

  /// Whether to send read receipts. When off, senders won't see blue ticks
  /// from you (mirroring WhatsApp's read-receipts setting).
  static final ValueNotifier<bool> sendReadReceipts = ValueNotifier<bool>(true);

  /// Whether to broadcast the "typing…" indicator to the person you're
  /// messaging. When off, they won't see when you're composing.
  static final ValueNotifier<bool> sendTypingIndicators =
      ValueNotifier<bool>(true);

  /// When on, calls from numbers you've never chatted with don't ring — they're
  /// silently declined (à la iOS "Silence Unknown Callers"). Blocked numbers
  /// never ring regardless.
  static final ValueNotifier<bool> silenceUnknownCallers =
      ValueNotifier<bool>(false);

  /// When on, only people you already have a chat with can message you; a
  /// message from an unknown number is dropped instead of starting a new chat.
  static final ValueNotifier<bool> messagesFromContactsOnly =
      ValueNotifier<bool>(false);

  /// Whether callers can leave you a voicemail after an unanswered call. When
  /// off, incoming voicemails are ignored.
  static final ValueNotifier<bool> allowVoicemail = ValueNotifier<bool>(true);

  /// Whether to show in-app notifications for the simulated demo replies.
  static final ValueNotifier<bool> notificationsEnabled =
      ValueNotifier<bool>(true);

  /// Whether tapping Enter/return in the composer sends the message (vs.
  /// inserting a newline). A common messaging-app customization.
  static final ValueNotifier<bool> enterToSend = ValueNotifier<bool>(true);

  /// Relative size of message text, 0.85–1.30 (1.0 = default). Lets people
  /// scale chat text up or down to taste.
  static final ValueNotifier<double> messageTextScale =
      ValueNotifier<double>(1.0);

  /// Who can see your profile photo. When restricted, people outside the
  /// audience see your initials on a neutral avatar instead.
  static final ValueNotifier<PrivacyAudience> profilePhotoAudience =
      ValueNotifier<PrivacyAudience>(PrivacyAudience.everyone);

  /// Who can see your "about" / status text.
  static final ValueNotifier<PrivacyAudience> aboutAudience =
      ValueNotifier<PrivacyAudience>(PrivacyAudience.everyone);

  /// Who is allowed to add you to group chats without an explicit invite.
  static final ValueNotifier<PrivacyAudience> groupAddAudience =
      ValueNotifier<PrivacyAudience>(PrivacyAudience.everyone);

  /// When on, asks the OS to hide app contents in the task switcher and block
  /// screenshots on devices that support it (Android FLAG_SECURE / iOS).
  static final ValueNotifier<bool> blockScreenshots = ValueNotifier<bool>(false);

  /// Default disappearing-messages timer (in seconds) applied to brand-new
  /// chats you start. 0 means messages don't disappear by default.
  static final ValueNotifier<int> defaultDisappearingSeconds =
      ValueNotifier<int>(0);

  /// Phone-number digits of contacts the user has blocked. Blocked contacts
  /// can't be messaged until unblocked.
  static final ValueNotifier<Set<String>> blockedContacts =
      ValueNotifier<Set<String>>(<String>{});

  static String _digits(String phone) => phone.replaceAll(RegExp(r'\D'), '');

  /// Whether [phone] is currently blocked.
  static bool isBlocked(String phone) =>
      blockedContacts.value.contains(_digits(phone));

  /// Blocks or unblocks [phone].
  static void setBlocked(String phone, bool blocked) {
    final next = Set<String>.from(blockedContacts.value);
    if (blocked) {
      next.add(_digits(phone));
    } else {
      next.remove(_digits(phone));
    }
    blockedContacts.value = next;
  }

  /// Resets global state; used by tests to isolate cases.
  @visibleForTesting
  static void resetForTest() {
    themeMode.value = ThemeMode.light;
    profile.value = MockData.me;
    chatWallpaper.value = null;
    shareLastSeen.value = true;
    sendReadReceipts.value = true;
    sendTypingIndicators.value = true;
    silenceUnknownCallers.value = false;
    messagesFromContactsOnly.value = false;
    allowVoicemail.value = true;
    notificationsEnabled.value = true;
    enterToSend.value = true;
    messageTextScale.value = 1.0;
    profilePhotoAudience.value = PrivacyAudience.everyone;
    aboutAudience.value = PrivacyAudience.everyone;
    groupAddAudience.value = PrivacyAudience.everyone;
    blockScreenshots.value = false;
    defaultDisappearingSeconds.value = 0;
    blockedContacts.value = <String>{};
  }

  /// A palette of avatar accent colors the user can choose from.
  static const List<String> avatarPalette = [
    '#E57373', '#F06292', '#BA68C8', '#9575CD',
    '#7986CB', '#64B5F6', '#4FC3F7', '#4DD0E1',
    '#4DB6AC', '#81C784', '#AED581', '#FFB74D',
    '#FF8A65', '#A1887F', '#90A4AE', '#5C6BC0',
  ];

  /// Updates the current user's name, about, and optionally username / avatar
  /// color. Empty values fall back to the existing profile fields.
  static void updateProfile({
    required String name,
    required String about,
    String? username,
    String? avatarColor,
  }) {
    final p = profile.value;
    profile.value = AppUser(
      id: p.id,
      name: name.trim().isEmpty ? p.name : name.trim(),
      avatarColor:
          (avatarColor == null || avatarColor.isEmpty) ? p.avatarColor : avatarColor,
      about: about.trim().isEmpty ? p.about : about.trim(),
      phone: p.phone,
      username: username == null ? p.username : normalizeUsername(username),
    );
  }

  /// Lowercases and strips a leading '@' / invalid characters from a username.
  static String normalizeUsername(String raw) => raw
      .trim()
      .replaceFirst(RegExp(r'^@+'), '')
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_.]'), '');
}
