# Okay Messaging — a WhatsApp-style messenger in Flutter

A WhatsApp-style messaging app built with Flutter. You sign in with a **phone
number**, and **everything is stored locally on the device** — there is no
server and no message is ever uploaded anywhere.

## How it works

- **Phone-number login.** On first launch you enter your name and phone
  number. That becomes your identity and is saved only on this device.
  (Real SMS verification isn't wired up — entering the number signs you in.
  There's a clear spot to add an OTP provider later.)
- **On-device storage.** Chats, messages, reactions, stars, your profile,
  theme, and wallpaper are all persisted to local storage (`shared_preferences`
  / the browser's local storage) so they survive a restart or reload. Nothing
  leaves the device.

## Features

- **Chats** — conversation list with avatars, last-message preview, timestamps,
  unread badges, pinned/muted chats, swipe-to-archive, and delivery ticks.
- **Start a chat** — pick a sample contact or **start a chat with any phone
  number**; the conversation is created and stored locally.
- **Conversation screen** — WhatsApp-style bubbles, day separators, reply
  quotes, forwarding, star, pin-to-top, multi-select, and in-chat search.
- **Photos** — send image messages, a full-screen viewer with pinch-to-zoom,
  and a **Media, links, and docs** gallery per chat.
- **Reactions** — long-press for the emoji row, or double-tap to quick-react
  with a heart (with an animated heart burst).
- **Links** — URLs in messages are detected and rendered as tappable links.
- **Calls** — a call screen (ringing → live timer, mute/speaker/video/end),
  reachable from a chat and the Calls tab.
- **Settings** — profile, dark/light theme toggle wired app-wide, wallpaper,
  and **Sign out**.

## Running

No configuration needed — it runs entirely on the device:

```bash
flutter pub get
flutter run          # pick a device, or -d chrome for web
flutter test
```

## Project structure

```
lib/
├── main.dart                    # Entry point: loads local session + storage
├── app_state.dart               # Theme / profile / wallpaper notifiers
├── state/
│   ├── session.dart             # Phone-number identity, stored on device
│   ├── chat_store.dart          # In-memory source of truth (ChangeNotifier)
│   └── persistence.dart         # Saves everything to local storage
├── models/                      # user / message / chat / call
├── widgets/                     # avatar, bubble, input bar, linkable text…
├── tabs/                        # chats, calls
└── screens/
    ├── auth/
    │   ├── auth_gate.dart        # Phone login vs. home, from local session
    │   └── phone_login_screen.dart
    ├── home_screen.dart          # bottom-nav host
    ├── chat_screen.dart          # conversation view + actions
    ├── call_screen.dart          # simulated call UI
    ├── image_view_screen.dart    # full-screen photo viewer
    ├── media_gallery_screen.dart # per-chat media & links
    └── … contact/group info, settings, forward, starred, wallpaper
test/
└── widget_test.dart              # Widget tests (28)
```

> Built and verified against Flutter 3.44 / Dart 3.12. `flutter analyze` is
> clean and the widget tests pass.
