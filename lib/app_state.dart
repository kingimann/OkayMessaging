import 'package:flutter/material.dart';

import 'data/mock_data.dart';
import 'models/user.dart';

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
    notificationsEnabled.value = true;
    enterToSend.value = true;
    messageTextScale.value = 1.0;
    blockedContacts.value = <String>{};
  }

  /// Updates the current user's name and about text.
  static void updateProfile({required String name, required String about}) {
    final p = profile.value;
    profile.value = AppUser(
      id: p.id,
      name: name.trim().isEmpty ? p.name : name.trim(),
      avatarColor: p.avatarColor,
      about: about.trim().isEmpty ? p.about : about.trim(),
      phone: p.phone,
    );
  }
}
