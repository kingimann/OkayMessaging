# OkayMessenger — working notes for Claude

Read this first in a new session. It covers the environment, the rules that
must not be broken, and where things live.

## What this is

A privacy-first Flutter messenger (iOS + web). Everything is local-first:
chats, calls, and media are stored **only on each device**. A Supabase
project is used for ephemeral message relay (Realtime broadcast — no message
tables), a tiny username/profile directory, payments, and push.

## Environment

Flutter **3.44.7 stable** is preinstalled at `/opt/flutter`. It is not on
PATH by default — export it in every shell:

```bash
export PATH="/opt/flutter/bin:$PATH"
cd /home/user/OkayMessaging
flutter pub get          # only needed after dependency changes
```

Do **not** run `flutter upgrade`, change the channel, or bump the Dart SDK
constraint (`>=3.0.0 <4.0.0`) — the pinned toolchain is what CI uses.

`flutter` warns about running as root; that warning is expected and harmless.

## The gates — run before every push, no exceptions

```bash
flutter analyze     # must print "No issues found!"  (infos/warnings fail)
flutter test        # all tests must pass (~298 tests, ~1 min)
```

`flutter test` takes about a minute; run it in the background and poll rather
than blocking. **Never judge a gate through a pipe**: `flutter test | tail`
exits with tail's status, so a failing suite still reads as success — use
`set -o pipefail` (or read the actual "All tests passed!" line) before
treating a gate as green. This has caused a red push once already.

**After touching anything under `supabase/functions/`, type-check it:**

```bash
dart tool/paste_functions.dart   # regenerate docs/edge_functions_paste/
sh tool/check_functions.sh       # must end "0 failing"
```

**After touching anything in `docs/*.sql` or `supabase/schema.sql`:**

```bash
sh tool/check_sql.sh   # must end "SQL checks passed"
```

The dashboard used to be the first thing that ever ran these, and two bugs
shipped that way in one file: functions placed above the tables they read
("relation does not exist" — a SQL body is parsed at creation), and
`revoke select (col)` which looks like column protection and does nothing when
the role holds a table-wide grant, as Supabase gives every new table in
`public`. Every poster's phone number was readable. The script spins up a
throwaway Postgres, applies the migrations in order, and asserts what they
enforce — impersonation, phone columns, sanctions, ban-hiding.

Neither Flutter gate looks at TypeScript, so for a long time the Supabase
dashboard was the first thing that ever compiled these — and three breakages
reached it: Stripe rate constants used but never declared, `grossUp` used
without its import, and byte arrays that stopped satisfying `BufferSource`.
The script installs Deno to `/tmp` on first run and checks both the sources
and the generated paste copies. Always regenerate the paste copies first, or
the thing being checked isn't what gets deployed.
When touching web-visible code or dependencies, also confirm
the web build compiles:

```bash
flutter build web --release --no-web-resources-cdn \
  --dart-define=SUPABASE_URL=https://trbdqucphtsstnrwwfnw.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=sb_publishable_PrY-Aru0AryWyhHgfD2Tow_uXca1owt
```

## Deploying

Develop on `claude/whatsapp-clone-flutter-jx9ja8`. GitHub Pages only deploys
from `main`, so every change goes to both — with a pause between pushes to
avoid a Pages concurrency race:

```bash
git config user.email noreply@anthropic.com
git config user.name Claude
git add -A && git commit -q -m "…"
git push -u origin claude/whatsapp-clone-flutter-jx9ja8
sleep 12
git push origin claude/whatsapp-clone-flutter-jx9ja8:main
```

Commit trailers to include:

```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015P97LVudGW2edqtwWSjQKV
```

Never put a model identifier in commits, PRs, code, or anything pushed.

**Two things publish to Pages and the wrong one is faster** — still true, and
it is the first thing to suspect when the site 404s. Every push to `main`
fires `deploy-web.yml` (Flutter, ~4 min) *and* GitHub's own
`pages-build-deployment` (README through Jekyll, ~40 s), so for the minutes in
between the live site is the README and `identity.html`, `connect.html` and
`main.dart.js` are all 404. Re-verified: `identity.html` answered 404 at
16:27 and 200 at 16:28 on the same push. One setting fixes it and it is the
user's to change — see `docs/server_deploy_checklist.md` §3b. The ID check
works around it (`IdentityVerification.pageIsServed` falls back to Stripe's
hosted page); nothing works around a missing `main.dart.js`.

iOS builds run on **Codemagic** (`codemagic.yaml`, workflow
*iOS release (TestFlight)*) — the user starts those manually.

## Rules that must not be broken

- **No fake data in release builds.** Sample contacts, seeded servers, and
  demo chats are gated behind `kReleaseMode`. Never show invented people,
  follower counts, or activity to a real user.
- **AI only on the device.** The blanket "no AI" rule was lifted for
  on-device work only. A model may read a chat *in the app's own process* —
  Apple's `FoundationModels` via `okay/smartreplies` is the only one wired up.
  Sending message content to any hosted model is still out: bodies are
  encrypted before they leave the device, so a cloud call means decrypting
  somebody's conversation somewhere it can be read. The public newsfeed is
  the one exception — those posts are world-readable by design, so a hosted
  model over *that* content breaks nothing. Anything that cannot generate
  (most iPhones, the whole web build) shows nothing rather than a canned
  stand-in; see the no-fake-data rule above.
- **No readable messages on the server.** Message bodies are end-to-end
  encrypted before they leave the device, delivered by Supabase Realtime
  broadcast to `inbox_<digits>` channels, and — since the user approved
  store-and-forward — also queued as ciphertext in the `mailbox` table for
  offline recipients (deleted on delivery, swept after 14 days). Plaintext
  message content must never be stored or logged server-side, and the
  mailbox must only ever hold the same sealed envelopes the broadcast
  carries.
- The Supabase **publishable** key (`sb_publishable_…`) and the Stripe
  **publishable** key (`pk_live_…`) are client-safe and intentionally inlined
  in build configs. Secret keys (`sk_…`, APNs `.p8`) must never enter the
  repo or chat — they live in Supabase Edge Function secrets.
- Web builds ship the **standard JS build**. `--wasm` was tried and broke
  loading on iPhone Safari; don't re-enable it without a way to test Safari.

## Layout

| Path | What |
|---|---|
| `lib/screens/` | Full screens (chat, call, maps, profile, settings, login) |
| `lib/tabs/` | The five bottom-bar tabs |
| `lib/state/` | Singleton stores (chats, calls, score, follow, push, …) |
| `lib/relay/` | Supabase relay: encode/decode, inbox, call + feed signaling |
| `lib/crypto/` | E2E encryption and key exchange |
| `lib/payments/` | Stripe client + payment sheet |
| `supabase/` | `schema.sql` and Edge Functions (payments, push-send) |
| `test/widget_test.dart` | The entire suite — add tests here |

Docs worth reading when relevant: `docs/push_notifications_setup.md`,
`docs/ios_signing_setup.md`, `docs/edge_functions_paste/` (dashboard-paste
copies of the Edge Functions), `docs/supabase_setup.sql`.

## Working style the user expects

- Ship complete, tested work and deploy it — don't hand back a plan.
- Verify claims. Reproduce bugs where possible instead of guessing; say
  plainly when something is unproven or when a fix didn't work.
- Match the surrounding code: comments explain *why*, never narrate the diff.
- Be honest about what needs the user's own action (Apple portal, Supabase
  secrets) versus what you completed.

## iOS API availability — the mistake that keeps costing builds

The app targets **iOS 13.0** (`IPHONEOS_DEPLOYMENT_TARGET`, and `Podfile`).
Anything newer needs `if #available(iOS 14.0, *)` with a fallback. This has
failed the archive twice — `CXProviderConfiguration()` and
`UNNotificationPresentationOptions.banner` — both minutes after a green
suite, because there is no Xcode here and `flutter analyze` never looks at
Swift. The test *newer iOS APIs are guarded* now scans `ios/Runner/*.swift`
for the known offenders; add to its list rather than rediscovering this.

## Verified-only features

The **marketplace, wallet and Okay Drop** are behind
`IdentityVerification.allowsTrusted` — the Stripe Identity check, the same
one that earns the blue check. The gate is inside each screen
(`VerifiedGate`), not on the drawer row that opens it, because a row is one
way in of several; sending money from a chat carries the same check for the
same reason.

Two things that look like bugs and are not:

- **It is off wherever verification is impossible.** `identity-start` is an
  Edge Function, so a build with no relay could never unlock the door the
  gate closes — the whole suite runs that way, which is why the gated branch
  needs `IdentityVerification.debugGateOverride` to be reachable at all.
- **The verdict is stored on the device.** It lives on the server, but Send
  nearby's entire point is working with no network; an offline launch would
  otherwise read a verified account as unverified. `refresh()` still
  overwrites it, including downgrades.

## Open items (verify before assuming)

- **Push notifications**: all code is in place (register on sign-in, token
  upload, message + call pushes, `push-send` Edge Function). **Done already:**
  the Push capability is enabled on the `com.okaymessaging` App ID and the
  stale provisioning profile was deleted — do not raise either again. The
  `push_tokens` table exists and `push-send` is deployed (both verified live).
  The `APNS_*` secrets are **reported set** and have not been confirmed from
  here — they cannot be, because `push-send` is behind the Supabase JWT gate
  and no probe from this box carries a session. **Settings → Notifications &
  calls → Check push setup** is the confirmation: `push-send` answers
  `POST { what: "check" }` by signing a provider token and offering a push to
  a device token nobody owns, so Apple validates the key, the team and the
  topic and names whichever it disliked (`BadDeviceToken` is the pass).
  `APNS_SANDBOX` is the one that can be valid and still wrong — `false` for
  TestFlight, `true` only from Xcode — so the check compares it against
  `kReleaseMode` rather than guessing. Requires the current `push-send`; an
  older deployment says so rather than reading its reply as "nothing is set".
- **Default messaging app (iOS 18.2+)**: entitlement
  (`com.apple.developer.messaging-app`), `im:` scheme, scene-delegate →
  `okay/links` channel → `openChatForPhone` are all wired. If the IPA export
  fails with "profile doesn't include entitlement", the App ID needs the
  Default Messaging capability enabled in the developer portal (same visit
  as the Push toggle) and the old profile deleted so Codemagic mints a
  fresh one.
- **Payments split**: Stripe is ONLY for peer-to-peer transfers (`sendMoney`);
  its publishable key is wired and the Edge Functions still need deploying with
  `STRIPE_SECRET_KEY` set. Digital goods — the cloud-storage subscription and
  developer tips — bill through Apple/Google In-App Purchase
  (`lib/payments/store_purchases.dart` + `apple_iap*.dart`), which App Store
  rules require. The IAP products still need creating in App Store Connect and
  the In-App Purchase capability enabling — see `docs/in_app_purchases_setup.md`.
  Payments test mode simulates both without charging.
- **Unit economics are enforced by tests** (`lib/payments/storage_economics.dart`,
  `docs/storage_economics.md`). Storage sells at ~$0.20/GB against a $0.095/GB
  break-even (Supabase bucket rate ÷ Apple's 70% net); the P2P platform fee is
  3.4%+35¢ against Stripe's 2.9%+30¢. If you change a price, the suite fails
  when a line would lose money. **Chat backups must stay in the `chat-backups`
  Storage bucket** ($0.0213/GB) — moving them back into a Postgres table
  ($0.125/GB) would make every storage plan unprofitable. Bucket setup:
  `docs/chat_backup_bucket.sql`.
- **GIFs**: the picker is built and tested, but GIF *search* needs a free
  KLIPY key passed at build time (`--dart-define=KLIPY_API_KEY=…`), from
  `partner.klipy.com/api-keys`. Without it the GIF tab says so; emoji and
  everything else are unaffected, and a GIF someone already sent still plays.
  **It was Tenor until Google shut that API down on 30 June 2026** — keys
  stopped being issued that January and live ones started erroring on the
  day. KLIPY is where Bluesky and WhatsApp went; it is Tenor-shaped on
  purpose, so the swap was a base URL and a key. GIPHY was the other
  candidate and no longer has a free tier. `GifService.parseResults` reads
  *both* the Tenor-compatible response and KLIPY's native one, because the
  two are documented inconsistently and neither can be checked without a key
  — betting on one and losing means a GIF grid that is silently always empty.
  **Nothing here has been run against the live API.**
- **Feed media**: both feeds take a photo, a GIF and a video, one per post.
  A GIF is stored as a **URL** — the provider already serves it, so copying
  it into a bucket would mean paying to serve it twice. Video is **bytes**,
  and the two feeds store it differently on purpose: a server post seals it
  with the server key into `market-media` (reusing `FeedPost.listingVideo`,
  so it inherits the envelope, persistence and tombstone cascade), while a
  public post puts it **unsealed** in `public-media` — a world-readable post
  has nobody to keep it from, and that is also what lets it stream on the
  web, which a sealed listing video cannot. Both capped at 12 MB: storage is
  cheap ($0.0213/GB-mo), egress is not ($0.09/GB) and on a public feed it has
  no ceiling. **Re-run `docs/public_feed.sql`** for the `gif_url` /
  `video_path` columns — until then `PublicFeedStore.mediaSupported` is false
  and the composer hides both buttons rather than offering a post the insert
  would reject.
- **Cloud storage is a paid subscription** (`lib/state/storage_store.dart`):
  backup used to be free and on for everyone; now everything except chats
  (servers, feed, follows, places, score, email) rides the encrypted cloud
  sync (`lib/state/cloud_sync.dart`) only while storage is active, gated by
  `StorageStore.instance.active`. **Chats are never in the backup** — message
  content stays on the device it was sent from, paid or not (the old
  "passphrase includes chats" path is gone; a passphrase now only changes the
  key). A purchase (`PaymentService.buyStorage`, test-mode aware) extends the
  entitlement 30 days; it's a monthly pass you renew, not a silent auto-renew
  — true recurring billing would need a Stripe subscription Price + webhook
  deployed. There's no server-side auth (`REQUIRE_OTP` off), so the gate is
  client-side and the key (phone-derived, or a user passphrase) is what makes
  restoring on a new device possible at all.
- **Bluetooth mesh** (`lib/mesh/`, `ios/Runner/Mesh.swift`): messages to people
  nearby with no internet, off by default behind Privacy & security → "Message
  people nearby". The routing, framing and reassembly are pure Dart and covered
  by tests; **the Swift has never been compiled or run** — there is no Xcode on
  the Linux box these sessions run on, so the first real check is a Codemagic
  build, and the first proof it works is two phones in a room. Text only
  (`MeshPacket.maxBytes`, because a photo is a minute a hop) and foreground only
  (no Bluetooth `UIBackgroundModes` — adding `bluetooth-central` and
  `bluetooth-peripheral` turns background on with no code change, at the cost of
  slow overflow-area discovery and questions at App Review). Servers ride it
  too: a server marked **Findable over Bluetooth** (off by default, in its
  settings) is beaconed to anyone in range, and a stranger who asks gets the
  invite **encrypted to the key they asked with** — never in the clear, because
  the invite contains the server secret and a plaintext reply would hand it to
  everyone within earshot. The server's own invite policy still applies.
- **Okay Drop** (`lib/mesh/nearby_share.dart`, drawer → Okay Drop): AirDrop's
  shape on the same radio — you appear to people around you only if you say so
  (Privacy & security → "Who can send me things", off by default, the same three
  answers AirDrop gives), an offer says what is coming and how big, and nothing
  moves until the other person accepts. A transfer is **direct**:
  `MeshPacket.directOnly` means it is never relayed, because flooding 100 KB
  through every phone in the room to deliver one photo would pin four radios.
  **Photos, videos and files** all go (`lib/mesh/nearby_pick.dart`). Video is
  allowed *here and nowhere else*: `FileModeration.inspectNearby` exists
  because the block everywhere else ("Videos can't be uploaded") is a statement
  about what the app will store, and this path stores nothing — executables,
  scripts and blocked hashes are still refused. **The ceiling is the
  transport**, not a constant: `TransferChunks.limitFor(fast)` gives 200 K
  characters over BLE (a photo) and 16 M over the fast link (~12 MB, a short
  video). That ceiling is the *pipeline*, not the link — everything moves as
  base64 text, so the receiver's peak memory is several times the file; raising
  it means moving bytes through the channel on both sides, in Swift as well as
  Dart. A picture arrives as a picture in the chat; a video or file is written
  with `saveIncomingFile` and the chat gets a line naming it. **Either end can
  stop one** (`NearbyShare.cancel`) — a "no" arriving mid-transfer used to be
  ignored, so a receiver who changed their mind watched the video arrive
  anyway. What is moving shows as a pill over whatever screen you are on
  (`NearbyTransferBanner` in `NearbyOfferHost`), because the transfer list
  lives on the screen you would have *sent* from, which is exactly the screen
  a receiver is not on.
- **The fast link** (`lib/mesh/nearby_fast.dart`, `ios/Runner/NearbyFast.swift`):
  the second transport, MultipeerConnectivity — Bluetooth discovery, then a
  direct Wi-Fi link, which is the supported half of what AirDrop does. A photo
  goes in about a second instead of tens of seconds. It rides alongside the mesh
  and is never required: `NearbyShare._send` asks `NearbyFast.hasPeer` and falls
  back to `MeshService.sendDirect`, and the chunk size is decided **once**, at
  offer time (`NearbyTransfer.fast`), because the count is in the offer and the
  far end counts to it. What goes in the air before a link exists is a **random
  token minted per run** and nothing else; who you are crosses the encrypted
  link, and only when findable ≠ off — the same condition the BLE hello goes out
  under, but not in the clear. Only `MeshPacket.directOnly` kinds may cross it:
  it carries files, not the message bus. Needs `NSLocalNetworkUsageDescription`
  + `NSBonjourServices` (`_okay-nearby._tcp/._udp`, asserted by a test to match
  the Swift `serviceType`) and triggers iOS's Local Network prompt on first
  browse. **Never compiled** — same caveat as `Mesh.swift`, and the two land on
  the same Codemagic run.
  A third-party app **cannot** appear in or receive from the real AirDrop
  sheet; AWDL is private with no public API. This is the same choreography and
  the same speed, between two copies of this app.
- Check `git log` for what actually shipped most recently.
