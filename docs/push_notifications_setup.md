# Push notifications — setup status

A message or a call wakes the recipient's phone with the app closed, killed,
or the screen locked. Everything except **Your steps** below is written and
tested; nothing works until those are done, and the app fails silently rather
than loudly when they are not.

## How it gets there

The app is local-first: there is no server holding messages to notify about,
and Realtime broadcast only reaches a device that is currently connected. So
the push is sent by the **sender's** phone.

```
sender's app
  ├─ RelayService.send()  ──► Supabase Realtime broadcast  (recipient online)
  │                      └──► mailbox row, ciphertext      (recipient offline)
  └─ PushService.notify() ──► push-send Edge Function ──► APNs ──► recipient
```

`push-send` looks the recipient up in `push_tokens` by phone digits and posts
one alert to Apple. Message content never enters it: the payload is the
sender's **name** as the title, a generic body ("New message", "Incoming
call"), and the sender's number so a tap can open that conversation. A test
pins this — *a push never carries the message*.

That number reaching Apple is a real cost and a deliberate one. The
alternative is an alert you cannot act on, and the sender's name is in the
title either way. To not pay it, drop `fromPhone` from `PushService.notify`;
a tap then opens the app instead of the chat.

**A push is only sent while the sender's app is running.** Nothing on the
server watches the mailbox, so a message queued for an offline recipient
pushes at the moment it is sent and not again.

## What is in the repo

| Piece | Where |
|---|---|
| `push_tokens` table + RLS (a device reads only its own row) | `supabase/schema.sql` |
| APNs sender | `supabase/functions/push-send/index.ts` |
| Permission prompt, token upload | `lib/state/push_service.dart`, `ios/Runner/AppDelegate.swift` |
| Registration on sign-in | `lib/screens/auth/auth_gate.dart` |
| Sender-side triggers | `RelayService.send`, `CallService` (1:1 and group) |
| Foreground banner + tap → the right chat | `AppDelegate` `UNUserNotificationCenterDelegate` |
| `aps-environment` entitlement | `ios/Runner/Runner.entitlements` |

A tap builds `im:+<digits>` and hands it to the same `okay/links` path a
default-messaging-app tap uses, so there is one way into a chat from outside
rather than two — including at cold launch, where the URL is buffered until
Dart asks for it.

## Your steps

1. **developer.apple.com → Certificates, IDs & Profiles → Keys → +** → enable
   **Apple Push Notifications service (APNs)** → download the `.p8`. Note the
   Key ID; the Team ID is top-right of the page. Apple lets you download the
   key **once**.
2. ~~**Identifiers → com.okaymessaging** → enable **Push Notifications**, then
   delete the existing provisioning profile.~~ **Already done.** Left here
   because the IPA export fails on the entitlement without it, so anybody
   re-creating the App ID from scratch still needs it.
3. ~~Run `supabase/schema.sql` so `push_tokens` exists.~~ **Already done** —
   the table is live.
4. ~~Deploy `push-send`.~~ **Already deployed.** Set the Edge Function
   secrets, which is the only step still outstanding:

   | Secret | Value |
   |---|---|
   | `APNS_P8` | the whole `.p8` file contents, `-----BEGIN…` line included |
   | `APNS_KEY_ID` | the key's 10-character id |
   | `APNS_TEAM_ID` | your Apple team id |
   | `APNS_BUNDLE_ID` | `com.okaymessaging` |
   | `APNS_SANDBOX` | `true` for a build run from Xcode, `false` for TestFlight and the App Store |

   `APNS_SANDBOX` is the one that silently sends nothing when it is wrong: a
   token minted by a development build is not valid on the production host,
   and Apple answers `BadDeviceToken`.

## What will not get a push, and why

- **Accounts with no phone number.** `Session.signInWithoutNumber` mints a
  local account code and never establishes a Supabase session, so the token
  upload fails the `push_tokens` RLS check and `push-send` answers 401. Push
  needs a phone-verified sign-in (`REQUIRE_OTP=true`, which the iOS builds
  set). Testing on a second phone without a number works for everything
  except this.
- **The web build.** No APNs. `PushService.register` returns immediately off
  iOS.
- **A muted chat.** Mute is local to the recipient and the sender decides
  whether to push, so the sender cannot know. Suppressing on arrival needs a
  Notification Service Extension, which is a separate target.
