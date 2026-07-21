# Okay Messaging — a WhatsApp clone in Flutter

A UI-focused WhatsApp clone built with Flutter. It reproduces the core
WhatsApp experience — chat list, conversation view with bubbles and delivery
ticks, Status (stories), Calls log, contact info, and settings with a
light/dark theme toggle — running entirely on in-memory mock data (no backend).

## Features

- **Chats tab** — conversation list with avatars, last-message preview,
  timestamps, unread badges, pinned chats, and delivery ticks.
- **Conversation screen** — WhatsApp-style message bubbles (incoming/outgoing),
  day separators, delivery status ticks (sent → delivered → read), a working
  composer, and a simulated auto-reply so the demo feels alive.
- **Message actions** — long-press a bubble to **Copy** (to the clipboard),
  Reply, or **Delete** it from the conversation.
- **New chat** — the Chats FAB opens a contact picker to start a fresh
  conversation with any contact.
- **Search** — the app-bar search filters conversations by contact name and
  message content, and opens the matching chat.
- **Status tab** — "My status" plus recent and viewed updates with story rings.
- **Calls tab** — call log with incoming/outgoing/missed indicators and
  voice/video icons.
- **Contact info** — collapsing header, about, phone, and actions.
- **Settings** — profile row and a **dark/light theme switch** wired through
  the whole app.
- **Light & dark themes** matching WhatsApp's palette.

## Project structure

```
lib/
├── main.dart                  # App entry point + MaterialApp
├── app_state.dart             # Global theme-mode notifier
├── theme/
│   └── app_theme.dart         # Colors + light/dark ThemeData
├── models/                    # Plain data classes
│   ├── user.dart
│   ├── message.dart
│   ├── chat.dart
│   ├── status.dart
│   └── call.dart
├── data/
│   └── mock_data.dart         # In-memory sample chats/statuses/calls
├── utils/
│   └── date_formatter.dart    # WhatsApp-style relative time labels
├── widgets/                   # Reusable UI pieces
│   ├── user_avatar.dart
│   ├── message_bubble.dart
│   ├── message_status_icon.dart
│   ├── chat_input_bar.dart
│   └── chat_list_tile.dart
├── tabs/                      # The three home tabs
│   ├── chats_tab.dart
│   ├── status_tab.dart
│   └── calls_tab.dart
└── screens/
    ├── home_screen.dart       # Tab host
    ├── chat_screen.dart       # Conversation view + message actions
    ├── new_chat_screen.dart   # Contact picker for starting a chat
    ├── chat_search_delegate.dart
    ├── contact_info_screen.dart
    └── settings_screen.dart
test/
└── widget_test.dart           # Widget tests (7)
```

## Running the app

The Android, iOS, and web platform folders are included, so the project runs
straight after cloning.

1. Install Flutter (3.0 or newer): https://docs.flutter.dev/get-started/install
2. Fetch dependencies and run:

   ```bash
   flutter pub get
   flutter run          # pick a device, or use -d chrome for web
   ```

3. Run the tests:

   ```bash
   flutter test
   ```

> Built and verified against Flutter 3.44 / Dart 3.12. `flutter analyze` is
> clean and the widget tests pass.

## Notes

- **UI only.** There is no server, database, or real networking. Messages you
  send are held in memory for the session and a canned auto-reply is generated
  to demonstrate the ticks and scrolling.
- Avatars are colored initials placeholders, so the app ships with no image
  assets and no network calls.
