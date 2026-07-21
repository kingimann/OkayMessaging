# Okay Messaging — a WhatsApp-style messenger in Flutter

A WhatsApp-style messaging app built with Flutter. It runs in two modes:

- **Demo mode (default)** — self-contained, backed by in-memory sample data
  and browser storage. No setup, no server. This is what the hosted build uses.
- **Real backend mode** — point it at a free [Supabase](https://supabase.com)
  project and it becomes a real messenger: actual accounts, and messages that
  persist and sync between devices in real time.

The app auto-detects which mode to use: if Supabase credentials are provided at
build time it runs against the real backend; otherwise it falls back to demo
mode so it always runs.

## Features

- **Chats** — conversation list with avatars, last-message preview, timestamps,
  unread badges, pinned/muted chats, swipe-to-archive, and delivery ticks.
- **Conversation screen** — WhatsApp-style bubbles, day separators, reply
  quotes, forwarding, star, pin-to-top, multi-select, and in-chat search.
- **Photos** — send image messages (real uploads in backend mode; gradient
  placeholders in demo), a full-screen viewer with pinch-to-zoom, and a
  **Media, links, and docs** gallery per chat.
- **Reactions** — long-press for the emoji row, or double-tap to quick-react
  with a heart (with an animated heart burst).
- **Links** — URLs in messages are detected and rendered as tappable links.
- **Calls** — a call screen (ringing → live timer, mute/speaker/video/end),
  reachable from a chat and the Calls tab.
- **Accounts** (backend mode) — email/password sign-up & sign-in, per-user
  profiles, and starting a chat with anyone who has an account.
- **Settings** — profile, dark/light theme toggle wired app-wide, wallpaper.

## Running in demo mode

No configuration needed:

```bash
flutter pub get
flutter run            # pick a device, or -d chrome for web
flutter test
```

## Enabling the real backend

1. Create a free project at [supabase.com](https://supabase.com).
2. In the dashboard, open **SQL → New query**, paste the contents of
   [`supabase/schema.sql`](supabase/schema.sql), and run it. This creates the
   `profiles`, `conversations`, `conversation_members`, and `messages` tables,
   the row-level-security policies, realtime config, and a public `media`
   storage bucket.
3. From **Project Settings → API**, copy your **Project URL** and the
   **anon / publishable** key (the anon key is designed to be shipped in a
   client — access is enforced by the RLS policies, not by keeping it secret).
4. Run or build with those values passed as `--dart-define`:

   ```bash
   flutter run \
     --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
     --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_KEY
   ```

   Open the app on two devices/browsers, sign up as two different users, start a
   chat, and messages flow between them live.

## Project structure

```
lib/
├── main.dart                    # Entry point; picks demo vs backend mode
├── config/backend_config.dart   # Reads SUPABASE_* --dart-defines
├── services/
│   ├── supabase_service.dart     # Init + auth (sign up / in / out)
│   └── supabase_chat_service.dart# Loads + realtime-syncs conversations
├── state/
│   ├── chat_store.dart           # In-memory source of truth (ChangeNotifier)
│   └── persistence.dart          # Saves prefs (+ demo chats) to storage
├── models/                       # user / message / chat / call
├── widgets/                      # avatar, bubble, input bar, linkable text…
├── tabs/                         # chats, calls
└── screens/
    ├── auth/                     # auth_gate, login_screen
    ├── home_screen.dart          # bottom-nav host
    ├── chat_screen.dart          # conversation view + actions
    ├── call_screen.dart          # simulated call UI
    ├── image_view_screen.dart    # full-screen photo viewer
    ├── media_gallery_screen.dart # per-chat media & links
    └── … contact/group info, settings, forward, starred, wallpaper
supabase/
└── schema.sql                    # Tables, RLS policies, realtime, storage
test/
└── widget_test.dart              # Widget tests (28)
```

## How the two modes fit together

The UI always reads from `ChatStore` (a `ChangeNotifier`). In demo mode the
store is filled from `mock_data.dart` and saved to browser storage. In backend
mode, `SupabaseChatService` loads the signed-in user's conversations into the
same store and subscribes to a realtime channel, so an incoming message updates
the store — and therefore every screen — automatically. Because both paths feed
the same store, the entire UI works identically in both modes.

> Built and verified against Flutter 3.44 / Dart 3.12. `flutter analyze` is
> clean and the widget tests pass. The real-backend paths compile and are wired
> end-to-end; connect a Supabase project (as above) to exercise them live.
