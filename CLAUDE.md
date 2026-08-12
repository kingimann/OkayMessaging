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

**`main` is the branch that matters.** It is what GitHub Pages deploys and
what Codemagic builds, so nothing is shipped until it is there.

A session is usually handed its own `claude/…` branch to work on. Push to
both, with a pause between — the two Pages publishers race, and back-to-back
pushes make it worse:

```bash
git config user.email noreply@anthropic.com
git config user.name Claude
git add -A && git commit -q -m "…"
git push -u origin <this session's branch>
sleep 12
git push origin <this session's branch>:main
```

Working directly on `main` is fine when no branch was assigned. What is not
fine is stopping at the feature branch: it deploys nothing and builds nothing.

Commit trailers to include:

```
Co-Authored-By: Claude <noreply@anthropic.com>
Claude-Session: <this session's claude.ai/code URL>
```

Never put a model identifier in commits, PRs, code, or anything pushed — which
is why the trailer above is plain `Claude`. An earlier version of this file
had a model name in that very example.

**Two things publish to Pages and the wrong one is faster** — still true, and
it is the first thing to suspect when the site 404s. Every push to `main`
fires `deploy-web.yml` (Flutter, ~4 min) *and* GitHub's own
`pages-build-deployment` (README through Jekyll, ~40 s), so for the minutes in
between the live site is the README and `identity.html`, `connect.html` and
`main.dart.js` are all 404. Re-verified: `identity.html` answered 404 at
16:27 and 200 at 16:28 on the same push. One setting fixes it and it is the
user's to change — see `docs/server_deploy_checklist.md` §3b.

**The app itself no longer depends on any of it.** Every URL it used to name
on that site now comes off the Supabase project it already cannot work without
(`lib/relay/app_pages.dart` → the `pages` Edge Function): the email
confirmation landing, the page Stripe's hosted flows return to, and the
invite/share link. The two embedded pages that really are web-build artifacts
(`identity.html`, `connect.html`) are off by default and have no default URL
at all. A test asserts nothing under `lib/` or `supabase/functions/` names
`github.io`, so a single pasted URL cannot quietly undo it. `SITE_URL`
overrides the lot when there is a real domain. What is still exposed is the
**web build** — a missing `main.dart.js` is a blank page and nothing in the
code can work around that.

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
- **Pairwise traffic rides the Signal Double Ratchet**
  (`lib/crypto/double_ratchet.dart`, enc 3) wherever the peer's identity key
  is known, with the static-ECDH path (enc 2) as the floor and the
  phone-derived key (enc 1) under that. This is EVERY pairwise surface, not
  just message bodies: 1:1 and group chat, call and file signaling (SDP/ICE),
  group-call metadata and group structural updates all seal through one
  ladder — `RelayService.sealContent`/`openContent`, the single place the
  four rungs live, so a surface's encryption is never an accident of which
  method built its payload. (Call MEDIA stays DTLS-SRTP — WebRTC's own layer,
  below this.) Two documented substitutions from the spec: DH is P-256 (the
  app's one curve), and the X3DH prekey server is stood in for by the
  existing in-band exchange — bootstrap trust is the safety number, same as
  before. Roles are fixed (smaller digits initiates; the responder answers
  only), which prevents the two-Alices race. Sessions persist on-device; an
  identity-key change buries the session. Tests pin the properties —
  including the honest healing boundary: a stolen session reads until a
  post-theft DH enters the root, and nothing after.
- **Leaving a server now ANNOUNCES itself (2026-08-11)**, and that is what
  makes departure rotate the keys. It used to be purely local —
  `deleteCommunity` on the leaver's device and nobody else told — so every
  remaining device kept them on the roster forever: the member count stayed
  wrong, a mailbox copy of every message went on being queued for someone who
  had gone, and `onMemberRemoved` never fired, so the sender keys were never
  rotated. `sendServerLeave` sends `chleave` on the **signed sender-key**
  path, not the shared secret that `chjoin` uses: a join says "add this
  member" and is checked against the invite, but a leave says "remove that
  member", and on the shared-secret path `from` is unauthenticated — any
  member could forge a departure for anyone. The receiver takes the leaver
  from the event's verified `from`, never a body field, and routes through
  `removeMember`, which already refuses to drop an owner. It must be sent
  BEFORE the local delete (sealing and the mailbox fan-out both need the
  secret and the roster); a test pins that ordering in the source, and
  another watches `onMemberRemoved` fire rather than trusting that the roster
  edit implies rotation.
- **Sealed sender (2026-08-05)**: between up-to-date builds, 1:1 traffic no
  longer says WHO IT IS FROM on the wire or in the mailbox — the entire
  legacy payload (event name included: 'msg', 'typing', 'call' are metadata
  too) rides inside an outer envelope (`lib/crypto/sealed_sender.dart`,
  ephemeral P-256 → ECDH with the recipient's identity key → AES-GCM),
  broadcast as event `sealed`. The recipient opens it with its own key —
  needing to know nothing about the sender — and routes the inside through
  `applyInboxEvent`, ONE router mirroring the live subscription and the
  mailbox switch; an event type added to either MUST be added there (a test
  pins the roster) or its sealed form is silently dropped. **The handshake
  is the safety**: legacy messages advertise `sv: 1`, and a device seals
  only to peers who advertised AND whose identity key it holds — a sealed
  envelope sent to an old build is a LOST message, worse than metadata.
  Honest limits: the host still sees IPs/timing and the recipient inbox;
  key-exchange (`key`) events stay legacy (bootstrap must be maximally
  compatible); an envelope that fails to open is anonymous by design, so
  the sealed-to-old-key repair path exists only for legacy traffic; push
  titles still carry sender names (Apple-side metadata, deliberately
  unchanged this round). The `sealedEnvelopeFor` funnels: `send`,
  `_sendInboxEvent`, `_ping`, both call-signaling sites.
- **The server/community broadcast bus rides Signal Sender Keys**
  (`lib/crypto/sender_key.dart`), because a pairwise ratchet can't key a
  one-to-many broadcast. Each sender owns a forward-secret symmetric chain
  (random root, HMAC ratchet, one key per message deleted on use); the chain
  root reaches members as a distribution message (SKDM) carried over the
  PAIRWISE ratchet (`sealContent`), never under the server's shared secret —
  so compromising that secret reveals no past content. Wire fields `skc`/
  `skn` on the community payload; the shared-secret `data` path remains only
  as legacy fallback for older builds. A member removal rotates the epoch
  (`onMemberRemoved` → `rotateServerKey`) so a departed member's chain reads
  nothing after; a receiver that lacks a sender's chain sends `skreq` and the
  sender re-delivers the SKDM. **Every broadcast is signed** with a per-sender
  P-256 key whose private half never leaves the device (the SKDM carries only
  the public half): a member who holds another's chain to DECRYPT still cannot
  forge as them, because `open` verifies the signature before touching the
  chain. That is Signal's group unforgeability. **Remaining limit, stated
  rather than hidden:** the multi-device distribution/rotation path is first
  proven on real devices, like the mesh — the chain and signature core are
  proven in-process by their tests.
- The Supabase **publishable** key (`sb_publishable_…`) and the Stripe
  **publishable** key (`pk_live_…`) are client-safe and intentionally inlined
  in build configs. Secret keys (`sk_…`, APNs `.p8`, service-role, DB
  passwords) must never enter the **repo or git history** — a key committed to
  a public repo is scraped by bots within seconds, before it can be revoked;
  they live in Supabase Edge Function secrets. **The owner MAY paste a
  short-lived, rotate-after-use token** (e.g. a Supabase personal access token,
  `sbp_…`) into chat for a one-off runtime DB task — used once and revoked
  immediately after, the value logged in the transcript is already dead. That
  is the only sanctioned way a secret reaches chat, and only the owner may do
  it; never write such a token to a file or commit it.
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

The app targets **iOS 15.0** — raised from 13 on 2026-08-09, at the owner's
request and ahead of App Store Connect's Spring 2027 cutoff. Declared in
**three** places that must agree: the three `IPHONEOS_DEPLOYMENT_TARGET`
entries in `project.pbxproj`, `platform :ios` in the `Podfile`, and the
Podfile's post-install override that holds every POD to the same floor (a pod
left lower is the "building for iOS 15 but linking a dylib built for iOS 13"
archive warning). A test pins all three together.

Anything newer than the floor needs `if #available(iOS N, *)` with a
fallback. This has failed the archive twice — `CXProviderConfiguration()` and
`UNNotificationPresentationOptions.banner` — both minutes after a green
suite, because there is no Xcode here and `flutter analyze` never looks at
Swift. The test *newer iOS APIs are guarded above whatever the floor is now*
scans `ios/Runner/*.swift`, and it holds each symbol against **its own**
minimum (`.banner` 14, `setBadgeCount` 16, `TranslationSession` 17) rather
than one blanket "is the target below 14" switch. That switch was a trap: the
bump to 15 would have turned the entire check off and taken the still-too-new
`setBadgeCount` and `TranslationSession` with it. Add to the map rather than
rediscovering this.

The iOS 14 guards already in `AppDelegate.swift` are now dead code but are
deliberately **left alone** — unwinding an `#available` if/else is exactly the
kind of Swift edit that cannot be compile-checked from this box.

No device is lost by the bump: everything that could run iOS 13 (iPhone 6s and
SE 1st-gen included) also runs 15. What is lost is users who never updated.

## Business profiles (2026-08-04)

`AppUser.isBusiness` + `businessCategory` (fixed list on the model) +
`businessHours` (free text, never parsed). A self-declaration, NOT the blue
check, and it changes presentation only: a storefront chip on the contact
card and public profile, a category-and-hours line, the toggle + chips +
hours field in Edit profile. Rides the sealed profile share UNGATED by the
privacy audiences (turning it on IS the decision to announce it) but sends
'' for category/hours when off — and the flag applies at the receiver AS
SENT, like `verified`, so a business that stops being one clears itself on
contacts (the never-zeroed rule the other profile strings follow would keep
it forever). Adding a profile field still means touching every full-rebuild
site: `Session.signIn`/`updateProfile`/`setVerified`,
`AppState.updateProfile`/`setVerified`, `ChatStore.updateContactProfile`,
relay encode/send/applyIncoming — `AppState.setVerified` had the
strip-the-profile-bare bug fixed twice elsewhere and got it fixed here.
Round 2 (same day): `NameWithBadge.business` draws the storefront glyph
beside the name (chat header + chat list; quieter than, and never instead
of, the check), the chat header's presence line reads "Category · online",
the People rows carry glyph + category, and the marketplace listing detail
shows a seller's storefront — via `knownBusinessSeller` (marketplace file,
pure), which resolves ONLY from a business contact this device has really
chatted with (handle match, case-insensitive; the directory carries no
business fields, so anything else would be invention). `DemoSeed` adds a
`demo_biz` café chat so screenshots show the surfaces.

## Marketplace seller profiles (2026-08-05)

`SellerScreen` (`marketplace_screen.dart`) is the Facebook-Marketplace-shaped
seller profile — opened from the seller row on any listing. It gathers a
seller's WHOLE shop (`FeedStore.listings()` filtered by handle, split into
**For sale** and **Sold** sections), their rating across every listing
(`sellerRating`), a reputation band (rating · for-sale · sold), verification
chips (ID/Phone/Business, reusing `_SellerChip`), a **member-since** line from
the earliest listing year, and their recent **reviews** gathered across all
their listings (`_SellerReviews`). Actions: Message (`openSellerChat`), Follow
(`FollowStore`), and Subscribe (`showSubscribeSheet`) when the seller offers it.
The rich identity — storefront chip + category, location, bio — resolves ONLY
from a seller this device knows (`_sellerUser`: yourself or a contact); a
stranger shows what their listings can vouch for (name, verified badge, phone
chip, rating) and no more, the same honesty rule `knownBusinessSeller` follows,
because the directory carries no profile fields.

**Your own marketplace profile (2026-08-11).** Two gaps closed, both about
the seller looking at themselves. (1) `SellerScreen` had **no door for you** —
it always handled `isMe`, but the only route was opening one of your own live
listings and tapping the seller row, so a seller with nothing up could not
check how they appeared. `MyListingsScreen` now leads with a profile row
(avatar, name, rating) that opens it, and the row is on the EMPTY state too,
which is exactly when somebody is deciding whether to sell here. (2) Your own
profile was a page with **no buttons on it**: every action sat behind
`if (!isMe)`. It now carries **New listing · Manage** and the sentence "This is
how buyers see you." Also: the filter matches `'you'` when it is you (what
`FeedStore` files a listing under before the account has a handle) or a
handle-less seller saw their own shop as empty; and **`SellerShopScreen` is
gone** — a bare grid of a seller's active listings was the profile minus the
rating, chips and reviews, so its one call site (`SellerShopButton`) opens
`SellerScreen`. One marketplace profile, and a test pins the name out of the
file.

## Username-only accounts, and the one thing they can do

Signing up with no phone number is a first-class choice on both login forms
(*Sign up without a phone number*, 2026-08-04: the step asks for a NAME only
— the username is MINTED via `RandomIdentity` and claimed with retries,
never chosen at sign-up). The handle matters because it is optional
everywhere else: with no number in anybody's contacts there is
nothing to match on, so a handle is the only thing another person can be told
and can type. A display name is optional; left blank it gets a friendly
random one (`RandomIdentity`, 2026-08-04 — same for a blank username on the
phone forms, claimed in the directory best-effort) — the account code is not
a name anybody would recognise. Related: the reviewer/demo account
`+1 500 555 0006` (`ReviewerMode`) passes the ID gate and is PINNED to the
payments sandbox, and "Use a different account" clears the previous
account's prefilled identity (it used to carry the old name into the next
sign-up). `AccountCode.mint()`
stands in for the number, so addressing works unchanged.

**Chat works; nothing else does, and that is a fact rather than a policy.**
Supabase authenticates a phone, so these accounts have no session at all.
Message delivery does not need one — Realtime broadcast and the `mailbox`
table are both reachable with the anon key (`mailbox_*` policies grant
`anon`) — so chat is the same encryption, the same delivery, the same
store-and-forward. Everything that reads or writes the server has nothing to
answer with.

So `PhoneGate` (`lib/widgets/phone_gate.dart`) wraps what genuinely needs a
session — the **Wallet** — around the screen, never the row, for the same
reason as `VerifiedGate`.
**Servers OPENED for numberless on 2026-08-04** (a correction, not a
loosening): the community bus is sealed broadcast + the anon-key mailbox +
the sealed `community_posts` store — the same transports numberless chat
already rides. **The Newsfeed and Servers went READ-ONLY for numberless on
2026-08-05** (the owner's call): reading the public feed is served by the
anon key (like browsing the marketplace), so a name-only account can now
LOOK — but every WRITE needs a session, and a public post with no number
behind it has nobody to answer for it, which is the spam a name-only signup
would otherwise wave through. So `postNeedsPhone(context)` (in `phone_gate.dart`)
gates each write ACTION — the public composer/reply/quote (one funnel,
`_openComposer`), like, repost, vote; the server composer and reply — showing
a "Posting needs a phone number" sheet, with `PublicFeedStore.post()` throwing
as the backstop under it. The newsfeed drawer row lost its padlock (a padlock
on a row that opens is a worse lie than none). Marketplace is browse-only for
numberless (selling needs the ID check), Okay Drop and Maps are open. Notes and
Settings stay
open: Notes is local-only and locking it would protect nobody, and Settings is
the way out. There is **no owner waiver** — an owner without a number has no
session either, so letting them through would show a screen that cannot load.
`PhoneOnlyHint` puts a padlock on the drawer row; `_GateHint` in
`home_screen.dart` shows one padlock for a row behind both gates.

**There is no in-place upgrade.** The number *is* the account, so adding one
means a new account, and the gate says so rather than offering a button that
would sign somebody out. A test asserts chat is not gated.

## Encrypted push previews — built, undocumented, never confirmed live (found 2026-08-12)

The push banner has always been content-free by design ("New message" — see
`docs/push_notifications_setup.md`, which still describes only that): a push
is composed on the *sender's* phone and passes through `push-send` and then
Apple, so putting real text in it hands the plaintext to both, breaking the
one promise this app cannot break.

**The fix already exists in the repo, fully wired, on both ends** —
`lib/crypto/notification_preview.dart` (Dart) and
`ios/NotificationService/NotificationService.swift` (a genuine second Xcode
target, `NotificationService.appex`, already embedded in
`project.pbxproj`). The sender seals a one-line preview under a key derived
from the static ECDH secret (HKDF, domain-separated from the message key —
a leaked preview key opens no message body); `push-send` relays it as
opaque bytes (`p` + `from`, beside `aps` not inside it) and sets
`mutable-content: 1` only when there is something to open; the recipient's
Notification Service Extension decrypts it via a key the app already left
in a **shared keychain access group**
(`$(AppIdentifierPrefix)com.okaymessaging.shared`, declared in both
`Runner.entitlements` and `NotificationService.entitlements`) and rewrites
the banner before it draws. Every failure branch — no key, wrong key,
touched payload, a peer never key-exchanged with — falls through to the
same safe content-free body, by design: a wrong banner is worse than a
vague one.

**What's missing is proof, not code.** Unlike every other feature in this
file, this one has no "RUN + verified live" entry — nobody has confirmed a
real device actually shows a decrypted preview. Reported 2026-08-12: a
user's regular contacts (so key exchange isn't the gap) still show generic
alerts with Private notifications off (so that setting isn't the cause
either). Three things stand between "coded" and "working" here, none
checkable from this box:
1. **A Codemagic build postdating this extension.** The recurring failure
   mode all session — a feature can be fully coded and still be invisible
   on a phone running an older TestFlight/App Store build.
2. **The deployed `push-send` matching the repo.** The source and
   `docs/edge_functions_paste/push-send.ts` agree with each other, but
   neither proves what's actually live on the Supabase project — that needs
   either a fresh redeploy or a probe with the owner's own short-lived
   token.
3. **Keychain Sharing provisioning.** Unlike an App Group, a keychain
   sharing group is usually managed automatically by Xcode's signing rather
   than needing separate portal registration — but this has never been
   confirmed on a real archive, and it is exactly the class of thing that
   has broken silently before (NFC's `[TAG]` entitlement, Push's capability
   toggle).

`docs/push_notifications_setup.md` was never updated for any of this — it
still says a muted chat "needs a Notification Service Extension, which is a
separate target," present tense, as if one doesn't exist. Update that doc
once this is confirmed live rather than before.

## Locked and hidden chats

`lib/state/chat_lock.dart`. Two separate things, and the difference matters:

- **Locked** — the row stays in the list. You can see *who* the conversation
  is with; the preview, the unread count and "typing…" are all replaced with
  "Locked". Tapping asks for the password.
- **Hidden** — no row anywhere: not in the list, not in the archive, not in
  search. The only way back is typing that chat's password into the chat
  search field. There is deliberately no folder, no count and nothing in
  Settings, because any of those announce that hidden chats exist.

**Every chat has its own password**, and none of them is the app PIN
(`AppLock`) — that one keeps a stranger out of the app; this keeps somebody
already holding your unlocked phone out of one conversation. PBKDF2-HMAC-SHA256
at 120k rounds over a per-chat random salt, the same derivation the encrypted
backup uses, run through `compute` because that much arithmetic on the UI
thread is a frozen screen mid-password (the isolate hop is skipped when
`debugRounds` is set, or a test spends minutes spawning isolates).

**It is a gate, not a second encryption layer** — the messages sit in the same
local store as everything else. Say so rather than implying more.

Hidden chats are filtered in `ChatStore.chats`/`archivedChats` rather than in
the widgets that draw them, and search goes through `ChatStore.searchableChats`
(which drops locked chats) — so a screen added later is private by default
instead of private only if somebody remembered. `allChats` still returns
everything and is what delivery uses: a hidden chat keeps receiving messages.
`ChatLock.closeAll()` runs on background, so an unlock lasts a session.

## Screenshot & forward protection (per chat)

One toggle on a conversation (contact info), `Chat.protectContent`. Two
different kinds of promise, and the UI says which is which:

- **Forward and copy are off**, both ends. The flag rides out on every
  message (`Message.protected`, stamped once in `ChatScreen._deliver` so a
  send path added later cannot forget) and the receiving app honours it — so
  turning your own setting off does not unlock what somebody sent you under
  theirs. It is a request their app honours, not a guarantee about their
  device.
- **A screenshot is announced** to both sides, as an ordinary message in the
  conversation. `okay/screenshot` → `ScreenshotWatch` → a `shot` relay ping
  (the same fire-and-forget shape as `typing`, carrying only who).

**iOS cannot prevent a screenshot** — there is no public API, and the private
`UITextField` trick is undocumented and an App Review risk. Detection after
the fact is all there is, so the toggle's own subtitle says "Screenshots
cannot be blocked". Don't let that sentence get edited out; a test asserts it.

`UIApplication.userDidTakeScreenshotNotification` is iOS 7+, so unlike the two
APIs that have broken the archive it needs no `#available`. The observer is
registered once (`watchingScreenshots`) — a second one reports every
screenshot twice, which reads as two screenshots. The chat only acts on the
app-wide notifier when its route `isCurrent`, or a screenshot of the chat list
would be announced as one of the conversation.

**Screen recording and mirroring** are the capture nothing used to notice: they
never fire the screenshot notification. `UIScreen.capturedDidChangeNotification`
+ `isCaptured` (iOS 11+, under the iOS 13 floor) drive
`ScreenshotWatch.capturing`, and a protected chat **replaces itself** with a
notice for as long as it lasts — a recording is still going, so announcing and
carrying on would be filming somebody while telling them they are being filmed.
Announced on the edge only, and as its own sentence over its own relay event
(`cap`), because calling a recording a screenshot is a wrong sentence. The
state is read at `watch` time, not only on the next change: a recording already
running has fired its notification already.

**The app-switcher snapshot is covered app-wide** (`watchAppSwitcher` in
`AppDelegate`), on `UIApplication.willResignActive`/`didBecomeActive` rather
than by overriding the scene delegate — those notifications predate scenes,
fire in a scene app anyway, and need no assumption about what
`FlutterSceneDelegate` implements. Not per chat: the chat *list* is names and
previews too. This is the leak people mistake for screenshot blocking in
banking apps, and unlike a screenshot it really is preventable — iOS writes
that snapshot to disk and it outlives the session.

## Threads in a group chat

`Message.threadRootId`. A reply sent into a thread is defined by where it does
**not** appear: not in the room's transcript, and not as the chat list's
preview (`Chat.lastMessage` skips them — otherwise it is the same spam one
screen further out). The message it hangs under grows a quiet "N replies"
line, which is the only way in.

**A thread is the same `ChatScreen`**, opened with `threadRootId` set: the
transcript becomes the root plus its replies, and `_deliver` — the one funnel
every outgoing message already passes through — stamps the id on the way out.
A separate, thinner thread screen would have drifted from this one the first
time either changed, and would have needed its own composer, attachments,
reactions and delivery.

**Both newsfeeds thread too**, and had before this: replies carry a parent,
neither timeline shows them, both walk the ancestor chain root-first with the
same depth bound and cycle guard, and both draw a spine. What they gained is
X's distinction — `selfThreadOf` on each store, and a **"Show this thread"**
line when the AUTHOR continued their own post, which is a different event from
strangers answering and is not what the reply count means. Never drawn on the
post that already is the thread on screen.

**Flat, groups only.** "Reply in thread" is hidden in a 1:1 (the room is the
two of you, there is nothing to spare it from) and inside a thread (a thread
of threads is a second place to lose a conversation). The header says
"Thread · Stays out of <group>", because the same avatar and name as the group
would leave somebody typing into a side conversation believing they were
talking to everyone.

## Custom forms

`lib/models/form_spec.dart`, sent from the chat attachment panel. **A form is
a richer poll and is built as one on purpose**: it goes into a conversation as
a message (`Message.isForm`), the answers come back over the same E2E path as
a `form` relay event, and none of it touches a table. Posting answers to a
server would make this the one feature collecting people's replies in the
clear, and forms collect exactly the kind of answer worth protecting — a test
asserts no form file reaches for `supabase` or `http`.

Five field kinds (short, long, number, choose-one, yes/no). A number stays
**text** — a phone number with a leading zero stops being one once parsed.
Answers are **positional and always as long as the form**; an unanswered
optional question is `''`, because a shorter list shifts every later answer
onto the wrong question. Answering twice corrects rather than duplicates. The
card says a different thing to each side: the sender gets the count and can
read them, recipients are never shown who else answered.

**Group forms answer their author** (closed 2026-08-05; it used to be a
known limit): a response addresses the member who sent the form —
`senderPhone` rides every group message — never the whole room, because
recipients are never shown who else answered and their devices shouldn't
hold the answers either. The old gate required the chat's CONTACT to be a
real peer, which a group's pseudo-contact never is, so a group form's
answers went nowhere.

## Quick replies

`lib/state/quick_replies.dart` — the sentences somebody types most, saved
once. Settings → Quick replies, or hold a message → Save as quick reply;
inserted from the attachment panel. **Inserted, never sent**, and appended to
what is already typed: a canned reply that sends itself is a message nobody
read before it left.

On the device and nowhere else — not on a server, not in the encrypted backup,
and a test holds it there. The list of sentences a person uses most is a fair
description of their life. The starter suggestions are *offered*, never
seeded, which is the no-fake-data rule wearing a different hat.

`reorder` takes the index **after** the lift (`onReorderItem`), so there is no
off-by-one to compensate for — the old `onReorder` is deprecated and
compensating anyway swaps the wrong pair.

## Creator subscriptions (2026-08-05)

A creator turns on **Offer subscriptions** in Edit profile (a fixed monthly
price tier from `AppUser.subscriptionTiersCents` + a free-text pitch). The flag
`subscribable` + `subscriptionTier` + `subscriptionPitch` ride the sealed
profile share UNGATED like `isBusiness` (turning it on IS announcing it),
applied at the receiver AS SENT (a lapsed creator clears its tier/pitch), so it
touches every full-rebuild site — `Session.signIn`/`updateProfile`/
`setVerified`, `AppState.updateProfile`/`setVerified`,
`ChatStore.updateContactProfile`, relay `encode`/`applyIncoming`.

A creator can then mark a public-feed post **Subscribers only** (composer
toggle, standalone text post — no reply/quote/poll/media). Readers pay a
**monthly pass** (`CreatorSubStore`, a per-creator 30-day entitlement modelled
on `StorageStore`) to read it.

**Access-control, NOT end-to-end sealing — on purpose.** The public feed is
world-readable and SERVER-MODERATED (`moderation-screen` reads every post's
text). A sealed paid body could never be screened, and unscreenable paywalled
content is the abuse vector that has burned other creator platforms. So the
public row (`public_posts`) carries only a **teaser**; the real text lives in
`public_paid_bodies`, which NOTHING may select directly — `public_paid_body(p)`
(security definer, `docs/creator_subscriptions.sql`) is the one door and opens
only for the author or an account with an active pass. `check_sql.sh` asserts
the body is un-selectable, that only author/active-subscriber read it, and that
a client cannot grant itself a pass. **True sealing is reserved for paid
servers** (the follow-up), whose feed is already private.

**Billing is IAP, and the entitlement is receipt-verified.** A creator sub is
a CONSUMABLE (`StorePurchases.creatorSubProductId`, one per tier) — an
auto-renewable SKU can't express per-creator, since Apple treats a second buy
of one sub SKU as renewing the first. The write to `creator_subscriptions`
happens ONLY in the `creator-subscribe` Edge Function, which verifies the Apple
JWS (like `iap-validate`), refuses a non-tier product, and dedupes the
transaction (`creator_sub_receipts`) so one receipt buys one month. The client
never grants itself a paid body. Test mode simulates the purchase; `unlock()`
reveals a locked post through the `public_paid_body` RPC.

**Tiers (2026-08-06):** a creator offers up to four named price TIERS, not one.
`SubscriptionTier` (name + cents + perks) — the list rides `AppUser`'s
`subscriptionTiersJson` (a JSON string, so it flows through every rebuild site
and the profile share like any scalar), read through `subscriptionTiers` which
falls back to the legacy single `subscriptionTier`/`subscriptionPitch` for older
profiles. `subscriptionCents` is now the CHEAPEST tier (the "from $X/mo"
headline). Every tier unlocks the SAME subscribers-only posts — tiers are price
levels + whatever perks the creator names, and each maps to one of the four
`creatorsub.tierN` IAP products, so no new SKUs. Edit profile has a tier editor;
`showSubscribeSheet(tiers:)` shows a pick list.

`PublicPost.paid`/`subCents`/`unlocked` + `locked`/`displayBody`. The locked
card (`_PaidLock`) auto-unlocks for the author or an active subscriber and
otherwise shows a Subscribe button; `showSubscribeSheet` (a reusable widget)
runs the purchase. A creator's profile shows a Subscribe button when this
device knows they're subscribable (a contact carries the flag). **Needs the
user's own action to go live:** run `docs/creator_subscriptions.sql`, paste the
`creator-subscribe` function, and create the `com.okaymessaging.creatorsub.
tierN.monthly` consumable IAP products in App Store Connect. Until then it runs
in test/simulation only.

## Editing a public-feed post (2026-08-06)

A narrow, deliberate opening in the otherwise **append-only** public feed
(`docs/public_feed.sql` `revoke update`s outright — an editable public post with
no history is a way to bait people then rewrite it). The author may edit their
OWN post's TEXT, only within **15 minutes** of posting, and every edit is
**stamped** (`PublicPost.editedAt` → "· edited" via `FeedPostHeader.edited`).
`PublicFeedStore.editPost` re-screens the new text through the same
`moderation-screen` speed bump as a new post, then writes `body` + `edited_at`;
`canEdit` gates the UI (own, not paid/poll/repost, in-window) and the chat ⋮
shows "Edit post". **The server is the real gate**, in `docs/public_feed_edit.sql`:
a column-level `grant update (body, edited_at)` (so nothing else can move) + a
`public_posts_update_own` RLS policy carrying `author_phone = jwt.phone` AND the
15-minute window in both USING and WITH CHECK. That file also **re-creates the
feed view as the final word on its shape** — carrying `paid`/`sub_cents` (from
creator subs) AND the new `edited_at`, appended LAST because create-or-replace
can only add view columns at the end — so running it also restores the paywall
columns if a `public_feed.sql` re-run dropped them. `check_sql.sh` applies it
last and pins: author edits within window (stamped), a stranger can't, an edit
can't touch anything but the text, and the window closes. **Needs the user's
action:** run `docs/public_feed_edit.sql` (after `public_feed.sql` +
`creator_subscriptions.sql`). Deliberately NOT built for the community/server
feed here — that was the public-feed ask.

## Custom server roles (2026-08-06)

A server admin/owner defines **custom roles** — the Discord "role" people ask
for: a name, a colour, and a **permission tier** (`CustomRole` on
`Community.roles`, `Member.roleId` points at one). The tier is the whole trick:
a role carries one of member/moderator/admin (never owner — a role can lift at
most to admin), and `Community.effectiveRole(member)` returns the HIGHER of the
member's built-in role and their role's tier. `CommunityStore.myRole` reads
`effectiveRole`, so a moderator- or admin-tier role grants real power through
the ONE funnel every permission check (`canModerate`/`canManageServer` and
their callers) already uses — no second, forgettable code path. A member-tier
role is cosmetic: just a coloured badge.

Managed in **Server settings → Roles** (`CommunityRolesScreen`): create, edit
colour/name/tier, delete. Deleting a role strips it from everyone wearing it
(no member left pointing at a ghost). Assigned from the member sheet
(`_pickCustomRole` in `communities.dart`), badged as a colour+name chip
(`_CustomRoleChip`) beside the built-in `_RoleBadge`. All admin-gated
(`canManageServer`), the same gate every structural change uses.

Rides the existing structural sync: `roles` is in `Community.toJson`, so
`applyStructure` and `joinFromInvite` carry it, and `Member.roleId` rides the
member roster already synced. No server work — this is the local-first
community model, propagated over the sealed community bus like every other
structural update. `CustomRole.fromJson` reads an unknown/`owner` tier as the
harmless member floor, so a newer build can't smuggle power onto an older one.

**Role emoji badges + settings reorg (2026-08-09).** A role now also carries an
optional **emoji badge** (`CustomRole.badge`), picked in the role editor from a
quick row (⭐️👑🛡️🔧💎🎨🎮🏆🚀❤️) or ANY emoji via the "+" (`showEmojiGifSheet`,
`allowGif:false`). `_CustomRoleChip` draws the emoji in place of the colour dot
when set. **Bug it also fixed:** `exportInvite` never carried `roles`, so roles
(colour, tier, badge) never actually synced to members — only the local
`toJson`/structure path did. `exportInvite` now includes `roles` when non-empty
(readers already parse it), so a joiner sees the same roles/badges. The role
editor sheet is now a `SingleChildScrollView` (the added badge row overflowed a
short sheet). **Server settings reorg (same day):** the one giant "MODERATION"
card of ten rows in `CommunitySettingsScreen` is split into scannable groups —
`MEMBERS & ROLES`, `WHAT MEMBERS CAN DO`, `MEMBERSHIP & DISCOVERY`,
`DANGER ZONE` — the appearance labels (ICON/COLOR/GRADIENT) are unchanged (a
test pins those).

## Public/private servers + Discover directory (2026-08-09)

Servers are now **public or private**. Private is the default and what every
existing server is — reachable only by invite/code. A **public** server
(`Community.listed`) is published to a world-readable **Discover directory**
(`docs/public_servers.sql`, table `server_directory` + phone-free
`server_directory_view`) that anyone browses and joins WITHOUT an invite.

- **The join secret is world-readable ON PURPOSE.** A public server's directory
  row carries its whole `exportInvite` snapshot, SECRET INCLUDED — "anyone may
  join" is the same decision as "anyone may hold the key". The owner's PHONE is
  the one thing kept back (the same column-grant pattern as market_listings:
  revoke the table-wide select, grant every column but `owner_phone`; read
  through the view). A **paid** server can never be listed — its secret must
  stay behind the paywall — so `Community.listed` and `paid` are exclusive;
  turning on the paywall unlists a public server, and `setListed` refuses while
  paid.
- **Transport:** `RelayService.publishServerDirectory(id)` upserts (listed +
  free) or deletes (private/paid/gone) the row; `fetchServerDirectory()` fills
  `ServerDirectoryStore` (pure state, no crypto/net — a test pins it) from the
  view with the anon key, so a name-only account can browse. Fetched on relay
  start and pull-to-refresh, and republished on structure changes to a listed
  server (keeps member_count fresh). Wired via `CommunityStore.onListedChanged`
  (toggle) + `onStructureChanged` (in `main.dart`).
- **UI:** `ServerDiscoverScreen` (`server_discover_screen.dart`) — the explore
  (compass) icon in the Servers app-bar, beside Join-with-a-code — search +
  cards + Join. Joining routes through the shared `joinServerFromSnapshot`
  helper (the #128 convergence path: `joinFromInvite` + `sendServerJoin`), the
  same one Join-with-a-code now uses. Settings → MEMBERSHIP & DISCOVERY gains a
  **Public server** toggle (disabled while paid); turning it ON confirms first
  (the secret goes public), OFF is immediate.
- `check_sql.sh` pins list-as-self, phone-unreadable, `select *` refused,
  edit-own-only, banned-owner-hidden, anon browse. **RUN + verified live
  2026-08-09** (table + phone-free view + 4 policies confirmed via the
  Management API; anon reads the view 200, `owner_phone` refused 42501) — do
  not re-raise as pending.

## Name-only accounts expire after 14 days (2026-08-11, owner's call)

`NumberlessGrace` (`lib/state/numberless_grace.dart`). A name-only account is
minted in seconds and answers for nothing, so it now has a life: **14 days,
then the account is ERASED and signed out.** An earlier round built a timed
TRIAL that locked the account and it was removed as the wrong shape — this is
not that. Nothing is locked; the account works normally and then ceases to
exist.

Because it destroys real data irreversibly, the rule is that nobody reaches
the deadline uninformed, and it is said in three places: the sign-up
confirmation names the days and the word *deleted* BEFORE the account exists;
an undismissable banner above every tab counts down and turns from amber to
the error colour in the last three days; and the login screen explains the
deletion afterwards, so being signed out with no chats does not read as the
app having lost them. Every message also says the way out — add a phone
number, keep everything, **and choose your own username** instead of the
minted one.

**Accounts that pre-date the rule get ONE WEEK, from the launch that tells
them** (`existingAccountDays` = 7, `adoptExisting`), not backdated to whenever
they signed up — backdating would delete the data of people who were never
warned, which is the one thing the rest of this exists to prevent. Somebody
who does not open the app for a month simply starts their week then; a
name-only account has no server session, so it cannot be expired while the app
is closed and pretending otherwise would only mean deleting data behind
somebody's back. The window is persisted per account, so a 7-day account never
reloads as a 14-day one. `adopted` is true for these, and the notice is a
LOCAL notification (`markTold`, sent once) because a name-only account has no
push token for any server to reach.

**The banner is what takes the status bar on the two bar-less tabs
(2026-08-11).** Reported as "click the top notification, come back, and the UI
messes up" — a layout fault, not a navigation one. Home draws NO app bar on
**Newsfeed (5)** and **Okay AI (6)**, and Flutter's `Scaffold` only strips the
status-bar inset from its body when there IS one (`removeTopPadding:
widget.appBar != null`). So the banner, first in home's body column, stood IN
the status bar with its first line under the clock, and the tab's own
`Scaffold` then added the same inset above ITS app bar, leaving a band of
nothing between the two. Home now reads `NumberlessGraceBanner.showing` (a
static, with `.listenable` for the rebuild) and — ONLY while it is drawing —
wraps the banner in `SafeArea(bottom: false)` and the tab beneath it in
`MediaQuery.removePadding(removeTop: true)`. Both halves are conditional and
both are pinned by tests: strip the inset with no banner and the newsfeed's
own app bar slides under the clock instead. The test sets a 47pt view padding
and asserts the banner starts at or below it AND that the app bar begins where
the banner ends; it was confirmed to FAIL (banner top `0.0`) against the old
plain column, so it is a real regression guard rather than a restatement.

Mechanics worth not rediscovering:
- `start()` is IDEMPOTENT. It runs on every launch, and a clock that
  restarted each time would turn a 14-day limit into no limit. `load()`
  never invents one.
- `daysLeft` rounds UP, or the final morning would read "0 days" while the
  account still worked.
- Keyed BY ACCOUNT CODE and **device-scoped** in `account_wipe`'s
  classification — same reasoning as `abuse_guard`: clearing it on an account
  switch would restart the fortnight every time somebody switched away and
  back. Each code keeps its own entry; `attachNumberInPlace` removes that
  account's entry outright.
- Enforced at launch AND on resume: on iOS the process outlives many days, so
  a deadline crossed in the background must still be honoured.
- Expiry does BOTH `eraseCurrentAccount()` and `signOut()`. Either alone is
  worse than neither — erasing without signing out leaves somebody inside an
  empty account; signing out without erasing leaves their chats on disk for
  whoever holds the phone next.

## Newsfeed chrome + bottom bar, fourth iteration (2026-08-11, owner's calls)

Reverses three earlier decisions. They were deliberate then and they are
deliberate now; do not "restore" any of them.

- **The newsfeed app bar is the APP MARK, centred, and nothing else.** Gone:
  the "Newsfeed" title (it named the thing you were already looking at), the
  **For you / Following** switch (removed from the product, not moved — the
  store still serves For you), and the screen's own **search** magnifier.
  What is left on the right: Notifications, and Shape your feed.
  **It is the MARK, not the icon tile** (2026-08-11): the raw
  `assets/icon/icon.png` is a white bubble on a near-black rounded square, and
  in an app bar that square reads as a sticker — light is `#FFFFFF`, dark is
  `#23262B`, the tile is `#101820`, so it matches neither and rounding its
  corners did not help. `BrandMark` (`lib/widgets/brand_mark.dart`) uses the
  PNG as a LUMINANCE MASK through one `ColorFilter.matrix` — RGB rows constant
  (the bar's own foreground), alpha row `1.6 × luminance − 60` — so the tile
  AND the three dots inside the bubble fall below zero and clip to fully
  transparent while the white bubble clamps to 255. The gain and bias are the
  point: plain luminance leaves the tile at ~8%, a grey ghost of the square.
  Drawn at **34pt** (was 30) since nothing boxes it in any more. Tests check
  the arithmetic against the real asset's own pixels — corners and dots ≤ 0,
  bubble ≥ 255 — because no screenshot can be taken from this box. Use
  `BrandMark` rather than the asset anywhere the mark appears as chrome; the
  login screen still shows the TILE deliberately, where an app icon is the
  right thing to show.
- **Notifications left the bottom bar for the newsfeed's top right**, badge
  and all. It is still tab 3 — `HomeScreen.goToTab(context, 3)` — so no index
  moved. Tests reach it by tapping Newsfeed then the bell (`openNotifications`).
- **Search took the middle slot it vacated**: Newsfeed · Chats · **Search** ·
  Calls · AI. Search is the ONE pill that is not a tab — `onSelect` receives
  `AppBottomNavBar.searchTab` (-2, deliberately not a real index) and it
  opens `showSearch(delegate: ChatSearchDelegate())` over whatever is on
  screen, so it never reads as selected.
- **New post is a hovering button again**, bottom right (`endFloat`), after a
  spell as a top-right pencil. **It has to be told about the bar**
  (2026-08-11): the bar FLOATS (home sets `extendBody`), so the tab's own
  Scaffold laid the FAB out as if nothing were there and half of it sat behind
  the glass, half off the corner. `AppBottomNavBar.overlayHeightFor(context)`
  (`contentHeight` 66 + the safe-area inset, or 10) is what lifts it, applied
  as the FAB's own padding so the button keeps its size and hit box. Only
  `asTab` — pushed, the bar is laid out below the content and there is nothing
  to clear.

## Liquid Glass, and the bar floats everywhere (2026-08-11, owner's call)

`LiquidGlass` (`lib/widgets/liquid_glass.dart`) is the ONE material worn by
the two pieces of chrome that float over content: the bottom bar and the chat
composer.

**The first version was frosted plastic and the owner said so.** It blurred
the backdrop and laid a **45%** tint over it — a slab you cannot see through,
and a white gradient over a slab is a slab with a gradient on it. The four
things that actually make the material, tint last:

1. **You can see through it.** `tintAlpha` is **0.13 dark / 0.30 light**.
   It COLOURS the backdrop; it does not replace it. **And in dark mode the
   tint is a LIGHT colour** (`tintBase` `#EAF0F7`) — the round-two bug a real
   phone showed was a base of `#0E1116`, DARKER than the `#16181C` scaffold,
   so over an empty screen the panel landed at luminance 22.9 against a
   background of 23.9: not glass, not even a panel, a hole with a hairline
   round it. Elevated glass CATCHES light. Light mode is the mirror — a white
   tint on a white screen vanishes too, so it steps slightly DOWN
   (`#DCE3EC`). `LiquidGlass.over(background)` is the composite a test
   measures: dark must come out ≥10 luminance ABOVE the dark scaffold, light
   below white.
2. **What is behind gets MORE vivid, not greyer.** A blur desaturates, and
   desaturated-behind-a-panel is the frosted-plastic look itself. `vibrance()`
   is a saturation matrix (×1.7) plus a small black lift, composed with the
   blur via `ImageFilter.compose` — `ColorFilter implements ImageFilter`, so
   this rides inside the backdrop filter rather than being painted over it.
3. **The edge BENDS what is behind it.** The signature, and the one part a
   gradient cannot fake. `assets/shaders/liquid_glass.frag` computes a
   rounded-rect SDF, displaces the sample inward along the edge normal with a
   cubed falloff (linear looks like a dent), and adds a specular term.
   Reached through `ImageFilter.shader`, which **requires Impeller** and
   throws otherwise — so it is loaded once, guarded, and dropped silently.
   **Uniform order is the engine's contract**: the first `vec2` is the bound
   texture size and the ENGINE writes it, so indices 0/1 are never set here
   (a test pins that). Asking the widget for its size does not work anyway —
   a `bottomNavigationBar` is laid out with unbounded height.
4. **The rim catches light unevenly** — `_SpecularRim` strokes a
   `SweepGradient`: bright on the upper-left curve, a weaker bead opposite,
   dark between. A rim that glows evenly all the way round is an outline,
   which is what version one had. Painted OUTSIDE the BackdropFilter; a
   blurred edge is what makes glass look like a smudge.

Lengths crossing into the shader are scaled by the device pixel ratio — it
works in the texture's physical pixels. **Web keeps blur+vibrance at
`flatAlpha` ~0.93** (CanvasKit re-blurs the whole scene every frame). Do not
hand-roll a second imitation: a test pins both files through this widget.

**Verified from this box only as far as it can be**: `flutter build web`
compiles the shader through impellerc, so the GLSL is known to be valid and
it really lands in the bundle. How it LOOKS is unverifiable here — no device,
no screenshot.

**The bar floats on pushed screens too**, not just home: `extendBody: true`
on Weather, Sports, Store, Settings, Wallet, the public Forum and Servers.
That comes with a debt the test pins — a floating bar is laid out around by
nothing, so each list pads itself by **`HomeNavBar.clearance(context)`**
(`overlayHeightFor` + 12) or its last row is stranded under the glass.
`extendBody` and the padding go together or neither does.

**Round three, and it is the SHAPE that was wrong (2026-08-11).** The owner
said "still not right" twice; the material was only a third of it.

- **The bar shrink-wraps now.** The pill row is `MainAxisSize.min` inside an
  `Align(heightFactor: 1)`, so the pane hugs its five pills and centres. It
  used to stretch the full width minus 14 either side, which meant the pills
  spread into the far corners AND there was nothing behind the glass but the
  scaffold — a transparent material with nothing to be transparent about
  reads as a slab no matter what the tint is. Pill padding went 14 → 10 and
  the gaps 6 → 2 to buy the room (the row was 346pt inside a 362pt bar on a
  390pt iPhone: 16pt of slack). `heightFactor: 1` is load-bearing — a
  Scaffold measures `bottomNavigationBar` with a BOUNDED height, so a bare
  `Align`/`Center` expands and the bar swallows the screen.
- **`bottomMarginFor(context)` is the new single source for how high it
  sits**, and `overlayHeightFor` is `contentHeight + it`. It was the whole
  safe-area inset (34pt), which parked the bar a third of an inch up with an
  empty band under it; the home indicator only occupies the bottom ~21pt, so
  it is `max(12, inset − 14)` → 20. Every FAB, list and composer clearance
  moves with it because they all read `overlayHeightFor`.
- **The three home TABS were the overlap.** `chats_tab`, `calls_tab` and
  `activity_tab` each padded by a hardcoded `bottom: 96` — SHORT of the
  bar's real 100 on a home-indicator iPhone, so the last row genuinely sat
  under the glass, and a constant cannot follow the bar when the bar moves.
  All three now use `HomeNavBar.clearance(context)`. The **Okay AI composer**
  was worse: a text field behind the glass, because as a tab it gets home's
  floating bar and its `SafeArea` knew nothing about it. A test pins all four.
- **Material, the half that does not need a GPU**: blur 24 → 18 (at 24 the
  backdrop was an even wash, transparent in principle and a flat tint on
  screen), and `_SpecularRim` now draws an **inner bevel** — lit along the
  top face, shadowed along the bottom — inside the rim. That is the thickness
  cue, and unlike the refraction it needs only the pane's own rectangle, so
  it survives every platform. `ImageFilter.isShaderFilterSupported` is asked
  before loading the shader rather than catching its throw.

## The forum card leads with the title (2026-08-11)

The vote pill used to be a column pinned to the LEFT — old-Reddit-on-desktop
— which cost the title about a third of the card on a phone and started the
headline halfway down and halfway across. Now: byline full width (with the
tag chip beside it, where a label belongs), then the **title at 17pt as the
headline**, then a capped body preview, then media, then ONE action row along
the bottom carrying the vote pill, the comment count and the section. A test
pins the order byline → title → votes.

**The cap is `forumCardBodyLines` (4) passed to the SHARED `FeedBodyText`**,
and both boards use it. A private `_BodyPreview` was written first and was
the wrong call: it quietly cost the public card its tappable mentions,
hashtags and links plus the "Show more" every other surface has, while
leaving the in-server board on `CollapsibleText`'s default 10. `FeedBodyText`
grew a `maxLines` pass-through instead (null keeps the timeline default), so
one widget and one constant serve both boards and both newsfeeds. A test
pins the constant out of both files and the copy out of existence.

## The app is named once, in the sidebar (2026-08-11, owner's call)

**Chats wears the MARK, centred, like the Newsfeed.** The word
"OkayMessenger" is gone from home's app bar: it named the app you were
already inside, and at 20pt beside three actions it had to be scaled down to
survive a 390pt iPhone (the `FittedBox` and the whole "brand name is never
cut off" test existed for that). Every OTHER tab keeps its text title —
Calls, Notifications, You say something the screen does not.

**The name lives at the top of the sidebar**, above the profile card:
`_SidebarTitle` in `home_screen.dart` — the mark plus **OKAYMSG**, tracked
out as a wordmark rather than set in app-bar type. Short on purpose: the full
name at that weight ran into the drawer's edge on a narrow phone, and a
clipped brand name is worse than a shortened one. The full name still appears
where it must be exact (login, About, the store listing).

The clipping test was not deleted with the text it guarded — it now measures
the MARK against the actions and the sidebar button on four widths, and a
second test opens the drawer at 320pt to check the wordmark is neither
truncated nor below the profile card.

## The bar goes with a pushed screen too (2026-08-11, owner's call)

`HomeNavBar` (in `home_screen.dart`, beside `AppBottomNavBar`) is the bar as a
PUSHED screen wears it: `index: -1` so no pill lights up, live badges, and
every pill routes through `HomeScreen.goToTab` — which pops to home first,
Search included (home answers `searchTab` by opening the one search). Mounted
on **Servers**, **a server itself** (`CommunityScreen` — added 2026-08-11 at
the owner's report; the servers LIST had the bar while the thing you opened
from it did not, which is the one you actually sit on), the **Wallet**, the
**public Forum**, the **Store** and **Settings**, which were dead ends
reachable only backwards, and it replaced the copy-pasted block the pushed
newsfeed already carried. On Settings it is
on `SettingsScreen` (the pushed one) and NOT inside `SettingsView`, which is
also the You tab's body where home already draws the bar — a copy in the view
would stack two, and a test counts them. Deliberately no ad slot: banners run on the two
PUBLIC surfaces only, and those mount their own.

## One search, X-shaped (2026-08-11, owner's call)

"Search — want it the same as X, remove search from other screens too." So
there is now exactly ONE app-wide search: the bottom bar's Search pill →
`ChatSearchDelegate` (`chat_search_delegate.dart`), filters
All/People/Messages/Posts/Servers/Calls/Links.

**Removed** — every magnifier that was the app-wide search a second time, or
the same search scoped to one screen: home's app bar, `servers_screen`, the
in-server forum board (`forum_screen`), the server feed (`feed_screen`), and
the newsfeed's own field (`PublicFeedScreen.startSearching` is gone with it —
the pill no longer pushes a screen).

**The Posts filter had to grow to make that honest.** It only walked in-server
forum channels, so removing the other magnifiers would have made two whole
surfaces unfindable. It now covers all three post kinds — forum posts (through
`filterPosts`, the board's own helper, so matching is unchanged), PUBLIC
newsfeed posts (`_publicPosts` over what the store has loaded — there is no
server-side post search to call), and SERVER-feed posts (`_serverPosts`, via
`FeedStore.searchPosts` over `allPosts`, listings excluded). Each is labelled
in the row ("Newsfeed" / "Server") because the three look identical and are
seen by very different sets of people. All three count toward `total`, or a
query matching only a newsfeed post renders "No results" over a list with
results in it.

**Kept, and this is the rule rather than an oversight:** a screen keeps its
own search when the app-wide one cannot reach its content — marketplace
listings (price/category/attributes, which a text match would half-answer),
notes, the contacts address book, the server Discover directory, and
find-in-chat / find-in-channel (a *find*, not a second global search). Removing
those would delete the only way to find that content, not consolidate it.

## Navigation model (settled 2026-08-09, third iteration — owner's calls)

The shape the owner landed on after two ☰ experiments; do not resurrect either:

- **Bottom bar (five pills):** Newsfeed · Chats · Calls · Notifications
  (renamed from "Alerts") · AI. Newsfeed is tab index 5
  (`PublicFeedScreen(asTab: true)` — the flag suppresses its own copy of the
  bar; the ad banner stays) and Okay AI is 6 (`AiChatScreen()`), appended to
  the `IndexedStack` so the old indices (1 Servers, 4 You) keep working from
  the drawer. Home's own AppBar hides for 5/6 — those screens carry their own.
- **Servers and Profile** stay OFF the bar. The profile card switches to tab 4
  (`_goToTab`); the **Servers row PUSHES `ServersScreen`**
  (`lib/screens/servers_screen.dart`, wrapping the same `CommunitiesTab` with
  the search/Discover/join-code/new-server actions home's bar used to carry) so
  it leaves with a normal back arrow — the owner's call. Tab index 1 stays in
  the IndexedStack (removing it would shift every index) but nothing routes to
  it. Tests that visit Servers must POP back after (the const app re-pump keeps
  a pushed route).
- **Sidebar rows carry no subtitles** (owner's call): names only, no one-line
  descriptions.
- **The sidebar lost 'okayai' and 'newsfeed'** (`SidebarPrefs.defaultOrder`;
  `load()` filters saved orders against it, so stale ids drop themselves).
- **Every pushed sidebar destination has a NORMAL BACK ARROW.** The
  ☰-on-destination pattern (2026-08-08) and the overlay sidebar that replaced
  it (earlier 2026-08-09) are BOTH gone — `SidebarMenuButton`,
  `showSidebarOverlay`, `AppSideBar.overlay` deleted.
- **Your own PROFILE PICTURE opens the sidebar, not a ☰** (2026-08-11, the
  owner's call — X's shape). `HomeDrawerButton` draws the same `UserAvatar`
  the drawer's profile card does, off the one `AppState.profile` notifier, so
  a changed photo changes it in the same frame. It is home's app-bar `leading`
  AND the button the two bar-hiding tabs carry, so there is one widget to
  change rather than three places to forget. The tooltip still says "Open
  navigation menu" — a screen reader announcing "your photo" would not say
  what tapping does.
- **The Newsfeed and AI TABS carry that button of their own**
  (`HomeDrawerButton` in `sidebar_menu_button.dart`, beside `homeScaffoldKey`):
  they hide home's app bar, so without it the sidebar would be unreachable
  from them. It opens home's drawer IN PLACE (the tabs live inside home's
  Scaffold — no navigation, no bounce). This is NOT the deleted
  pushed-destination ☰: it exists only where the drawer is already present.
  Pushed instances of both screens keep the normal back arrow (`canPop`
  branches). The feed's old avatar-leading OPENED THE PROFILE; this one is an
  avatar that opens the DRAWER, whose profile card is the way to the profile.

**Nav deep-dive round 2 (same day), from a full audit:** (1) the CALL screen is
an app-wide OVERLAY above the Navigator, not a route — so the system back
gesture passed THROUGH it and silently popped whatever screen was hidden
underneath; ending the call then landed somewhere the user never navigated to.
`CallScreen` now wraps in `PopScope(canPop: false)`: back MINIMIZES a connected
call (same as the ⌄ button) and is swallowed while ringing (answer/decline is
the decision). (2) The newsfeed's ☰ was swapped for a default back arrow while
searching — which popped the whole screen when the person meant to close the
search; the ☰ now stays put (the X in the actions is search's own close). A
source-pin test covers both. Audited clean: Alerts-tab pushes (all default
back), every ☰ screen's `fromSidebar` guard, all `popUntil(isFirst)` sites.

## Shadow bans and area bans (2026-08-09)

Two sanctions beside timeout/suspend/ban, both **admin+ enforced in
`moderation-act`** (the console's own role check only decides which buttons to
draw).

- **Shadow ban** (`SanctionKind.shadow`) leaves the account working and never
  tells it: its public posts, listings and forum threads stay visible to the
  author and to nobody else (`is_shadow_banned` → `content_visible(author)` in
  the read policies). It **never expires** — one that lapsed would announce
  itself — so the sheet hides the duration chips and the sanctions list draws
  `visibility_off`, not the clock the other kinds fall back to.
  `docs/moderation_scopes.sql` **redefines `is_silenced` to exclude `'shadow'`**:
  without that, adding the sanction row would also refuse the account's writes,
  which is exactly how somebody discovers they are shadow banned.
- **Area ban** (`account_area_bans`, `BanArea` = marketplace/servers/forum/feed)
  takes away one part of the app and leaves the rest, so a marketplace scammer
  keeps their conversations. Indefinite unless given a duration.

**Console** (`_SanctionSheet` in `admin_screen.dart`): a `SegmentedButton`
picks **Whole account** vs **One area** — the second only for admin+, because
drawing a button the server will only refuse teaches a moderator to distrust
the console. The area side lists what the account is **already** barred from
(`areaBansFor`), and its three states are deliberately distinct — not looked
up, looked up and barred from nothing, and unanswerable — since the last must
never read as the second. "Give back <area>" is disabled unless that area is
actually barred, and the sheet stays open after an area action because one is
usually followed by another.

**RUN + verified live 2026-08-09.** `docs/moderation_scopes.sql` applied and
`moderation-act` redeployed (v22) — the deployed body carries `area_ban`,
`area_lift` and `shadow`, read back through the Management API rather than
inferred. Anon probes: `is_shadow_banned` and `is_area_banned` both answer
200 (they were `PGRST202 — no matches` before), and `moderation-act` answers
an anon caller `401 unauthorized`, which is the body's own check — so it
boots. `check_sql.sh` pins all four behaviours (own post still visible, hidden
from everyone else, an area-banned seller refused, the area lookup scoped to
its own area). Do not re-raise as pending.

`account_area_bans` is world-readable by design (`using (true)`), the same
posture as `account_sanctions`: every device has to agree on who is barred,
and a barred account has to be able to be told why. A shadow ban is NOT in
that table — it is a sanction row, and `is_silenced` excludes `'shadow'` so it
stays invisible to the person it hides.

## Every admin tool is in one Settings section (2026-08-11, owner's call)

`_staffTools` in `settings_screen.dart`, one **ADMIN TOOLS** section sitting
below the settings anybody uses and above About. It replaces four scattered
places: a "Moderation" section near the top, "Diagnostics (admin)" in the
middle, two owner-only rows buried inside About between Terms and the version
number, and "Screenshot fixtures" near the bottom.

**The gates did not merge with the sections** — they are three different
ranks and stay per row: the console is `canModerate`, the four probes and the
demo fixtures are `canAdminister` (fixtures also behind `DemoSeed.available`,
whose literal a test pins), and the two editors that change what EVERY device
shows are `isOwner`. The section itself renders nothing unless at least one
row would, so an ordinary account sees no empty heading announcing that staff
tools exist. Tests pin the one heading, the absence of the old three, that all
nine rows survived the move, and that each rank is still checked.

## The Store, and where it sits (2026-08-09)

`StoreScreen` (`lib/screens/store_screen.dart`) is the one place a person can
find everything the app sells: Okay AI Pro, cloud storage and Support the
developer as buyable `_StoreCard`s, plus a `_WhereCard` each for creator
subscriptions and paid server membership — TEXT, not buttons, because those
are bought on a specific creator's profile or a specific server's invite and
there is nothing honest for a generic button to do. Restore purchases sits at
the bottom (App Review Guideline 3.1.1). Settings keeps a **Store** section
whose one row's subtitle names subscriptions, storage and tipping, so all
three stay findable by search.

**It lives in the drawer's FIXED block, immediately above Settings** — not in
the customizable Apps list, and deliberately not in `SidebarPrefs.defaultOrder`
(a comment there says so). Both it and Settings are unhideable for the same
reason: somebody who has switched off every app row must still be able to
reach the way to pay and the way to change things. A test pins 'store' out of
`defaultOrder` and pins the row's position above Settings in `home_screen.dart`.

**The support screen may not boast about what stopped being true.** Its blurb
used to claim there was no advertising, no tracking and no subscriptions —
while AdMob banners run on the two public surfaces and four kinds of
subscription are on sale. It now names both, keeps the claim that IS true
(bodies are E2E encrypted), and says a tip buys and unlocks nothing. A test
pins the old sentence out of the file, so do not quote it back in even in a
comment. If a paid surface is added, this blurb is part of the change.

## Marketplace search matches the newsfeed + tap-off dismisses (2026-08-09)

Third shape in one day, at the owner's direction — do not "improve" it back:
first it was a pill crammed into the title beside four icons (ugly), then a
persistent `bottom:` bar (owner asked for the newsfeed instead). NOW: the SAME
chrome as the newsfeed — the ☰ stays put, the magnifier action swaps the title
for a plain borderless field (hint `'Search Marketplace'`) and becomes the X
(`'Close search'`), and the other actions (Filter/Saved/Your-listings) step
aside while searching. `_SearchField` is gone. **Tap-off dismisses** on BOTH
public surfaces (`_tapOffSearch`, a `Listener` wrapping each body): a tap in
the content drops the keyboard, and an EMPTY search closes entirely — an idle
bar doesn't linger. A `Listener`, not a `GestureDetector`, so listing/post taps
still land. `_applySavedSearch` reopens the field when the saved query has
words. A source-pin + behavioural test cover the toggle, the step-aside, and
tap-off on both screens.

## Paid servers (2026-08-06)

The membership twin of creator subscriptions. A server owner/admin turns on
**Paid membership** in Server settings (`setPaidMembership`, a fixed monthly
tier from `AppUser.subscriptionTiersCents`) → `Community.paid`/`priceCents`/
`subPitch`, which ride the structure sync and the invite snapshot
(`exportInvite`) so a recipient sees the price before joining. The invite card
(`_ServerInviteContent`) then shows **Subscribe · $X/mo** instead of Join;
tapping runs a consumable IAP through `CommunitySubStore` (per-server 30-day
pass, modelled on `CreatorSubStore`) and joins on success. Test mode simulates
the buy. Reuses the four price tiers as a SEPARATE SKU family
(`StorePurchases.communitySubProductId` → `communitysub.tierN.monthly`).

**Access-control at the JOIN, not sealing — and honest about where the line
is.** A paid server's traffic is already E2E sealed under its `secret`, so the
paywall gates getting IN. The MVP is CLIENT-enforced at the join button and the
sealed invite still carries the secret, so a modified client isn't stopped by
it — stated plainly in `community_sub_store.dart`. The receipt-verified
hardening (`community-subscribe` verifies the Apple JWS and writes
`community_passes`; the owner's device then releases the secret to a
verified-paid joiner, sealed to them, like a Bluetooth-findable server answers
a stranger) is the follow-up; content sealing is unchanged either way. A member
who lapses keeps the secret they hold, like any departed member, until the
owner rotates the key.

**Needs the user's own action to go live:** run `docs/paid_servers.sql`, paste
`community-subscribe`, and create the `com.okaymessaging.communitysub.tierN.
monthly` consumable IAP products. Until then it runs test/simulation only.

## Admins add members directly (2026-08-08)

The invite-and-wait flow (share a link / send an invite card someone taps) is
now joined by the WhatsApp-group move: an **owner/admin adds contacts straight
into the server**. Invite sheet → **Add members** (gated on `canManageServer`,
so a plain member never sees it) → `AddServerMembersScreen`
(`add_server_members_screen.dart`, the `create_group_screen` picker over
`groupCandidates()` minus who's already in). `CommunityStore.addMembersByAdmin`
puts the picks on the roster now, fires `onStructureChanged` so every member's
copy converges, and returns the invite snapshot flagged **`added: true`**; the
screen sends that snapshot to each contact over the normal message path
(sealed, mailboxed).

The recipient's device **auto-joins on receipt** — `RelayService`'s
`maybeAutoJoinServer`, called from `applyIncoming`. Consent is the guard: it
joins ONLY from a **known, non-request 1:1** (`knownChat != null &&
!knownChat.isRequest`), so nobody can force you into a server by messaging you
cold — a stranger's flagged invite just lands as a normal tap-to-join card. It
also refuses a **paid** server (the paywall stands — the added person sees the
Subscribe card) and a numberless account (no relay identity to join with). The
joiner's own `sendServerJoin` still fires, so the SKDM/roster converge through
the same path a manual join uses (the #128 fix). A plain shared invite (no
flag) is untouched. `_ServerInviteContent` already renders the joined state, so
the card reads "Joined" once auto-join lands.

## Okay AI — the built-in assistant (2026-08-06)

A general-purpose assistant in the shape of Grok or Claude, reached from the
drawer (`okayai`, first in `SidebarPrefs.defaultOrder`) → `AiChatScreen`.
`AiAssistant` (`lib/state/ai_assistant.dart`) holds the conversation locally and
sends the tail to the `ai-chat` Edge Function → OpenRouter (a capable model via
`OPENROUTER_AI_MODEL`, falling back to the cheap moderation model, then a
default). The API key stays server-side; inert without `OPENROUTER_API_KEY`
(the client says "not set up yet").

**Why a HOSTED assistant is allowed beside the "AI only on device" rule.** This
is a different thing from a human chat: the user is knowingly talking to a
machine, not to a person the app is keeping private — the same reasoning that
lets the public feed use a hosted model. It is **walled off**: `AiAssistant`
names no `ChatStore`, `RelayService`, or crypto (a test pins this), so it can
only ever see what the user types into the assistant chat. It never reads a
human-to-human conversation, a server feed, or any encrypted content. Do not
wire it to any of those. Labeled "AI assistant · can make mistakes" so nobody
mistakes it for a person. The conversation is account-scoped (wiped on account
switch).

**In-chat "AI draft"** (attachment panel): the user says what they want to say,
`AiAssistant.draft(instruction)` sends ONLY that instruction (a one-shot, never
the conversation, never appended to the assistant chat) to `ai-chat`, and the
result drops into the composer draft — inserted, never auto-sent. This is the
compliant shape of "help me reply": the encrypted thread is never read, so no
chat content reaches the model. A test pins that `draft()` sends the
instruction and not the conversation.

**Smarter answers + readable code (2026-08-06).** The default model is
`openai/gpt-4o` (was `gpt-4o-mini` — weak at fact-checking and coding), kept
vision-capable so attachments still work; `OPENROUTER_AI_MODEL` overrides. The
system prompt frames it as a POWERFUL general assistant (ChatGPT/Claude/Grok
level), capable and willing across EVERY subject, told to DELIVER what's asked
(write the whole app, not "snippets and guidance"), no needless disclaimers —
while keeping the true limits (not a human, can't read private chats or act in
the app) and the accuracy discipline (reason first, never fabricate
sources/APIs, admit uncertainty). `temperature` 0.4; `max_tokens` defaults to
**8000** (env `AI_MAX_TOKENS`) so it can return a WHOLE file/app in one go.
Because a huge answer can truncate the learning-turn JSON wrapper,
`unwrapReply` salvages the reply field (or shows content verbatim) so a long
answer is never lost to a format hiccup. Replies render as light
Markdown (`lib/util/mini_markdown.dart`, pure/tested — `MiniMarkdown.blocks`
splits fenced code, `.inline` does **bold**/`code`): assistant bubbles show
code in a monospaced, horizontally-scrolling panel with a Copy button, an
unclosed fence still reads as code. User bubbles stay plain.

**Photos and files (2026-08-06).** The assistant composer's + button attaches
an IMAGE or a TEXT FILE (`AiAttachment.prepare`, `lib/state/ai_attachment.dart`,
pure/testable): an image is run through `PhotoPrep` to a vision-sized
`data:image/jpeg` URL and rides to a vision model as OpenRouter multimodal
`content` (`{type:'image_url'}`); a text file's decoded content (capped) is
folded into the text part. Everything else — video, PDF, archive, executable —
is REFUSED with a plain reason (the model can't read raw bytes, and a paid call
on nothing is worse than a no). Same `FileModeration` gate as every other
out-of-device path. Only the just-sent turn carries attachments (old images are
never re-sent); the saved turn keeps a small display ref + thumbnail, not the
full image. `ai-chat` `normalizeContent` accepts string OR parts array, caps
images (6) and data-URL size, and only lets USER turns carry images. This is the
SAME carve-out as the rest of Okay AI — the user is knowingly showing the file
to the machine — and `ai_attachment.dart` names no chat/relay/crypto, so it can
only ever see what the user explicitly attaches HERE. Needs a vision-capable
`OPENROUTER_AI_MODEL` (the default `gpt-4o-mini` is one).

**It "learns as it talks" — per-user MEMORY, not weight training.** The
`ai-chat` function, on a learning turn (`learn: true`), returns `{ reply,
memories }`: the model puts durable, non-sensitive facts about the user in
`remember`, and `AiMemory` (`lib/state/ai_memory.dart`) folds them into an
ON-DEVICE, per-user list (deduped, capped at 60). Those memories ride back as
context next turn, so it gets more personal. It is NOT weight training and must
never be: you can't retrain a hosted model live, and training on live chats
would learn nonsense and leak one user's words into another's — the reason
memory is per-user, on-device, and built only from what the user typed TO THE
ASSISTANT. A viewer (the chat's ⋮ → "What Okay AI remembers") shows and deletes
each item. `draft()` sends `learn: false` and no memory. A test pins that
`ai_memory.dart` has no network path. **The real "trained by users"** path is a
later pipeline, and its FOUNDATION is now built: `AiConsent` (opt-in, OFF by
default, "Help improve Okay AI" in the chat ⋮) + 👍/👎 on each assistant reply.
When consented, `AiAssistant.rate` sends the exchange + rating to the
`ai-feedback` function → `ai_training_samples` (a corpus; `docs/ai_training.sql`,
no client grants — a `check_sql.sh` assertion pins it can't be read or written
by a client; the submitter is a salted hash, not a phone). ONLY assistant
conversations are ever eligible — never human chats — and the rating is the
curation signal (`rating = 1` is what a fine-tune trains on, filtered). What's
left is the periodic fine-tune itself: export the thumbs-up rows → train an open
model → point `OPENROUTER_AI_MODEL` at it. **Needs the user's action:** run
`docs/ai_training.sql`, paste `ai-feedback`.

**Owner is never rate-limited (2026-08-06).** The app OWNER
(`PlatformModeration.instance.isOwner`, a server-verified role no client can
forge) skips BOTH gates: client-side `AiAssistant._unlimited` waives the free
tier / pay sheet, and server-side `ai-chat` skips the cap when the caller's
phone digits are in the `AI_OWNER_PHONES` env (comma-separated). The client
half is cosmetic (bypassable); the env is the real exemption. Owner status is
false until it loads, so the safe way round. **Needs the owner's action:** set
`AI_OWNER_PHONES` to their number.

**Rate limit + pay gate.** Two layers. The CLIENT product tier: a free
`AiAssistant.freePerDay` (15) messages a day; past it `needsUpgrade` shows an
upgrade sheet, and `AiPassStore` sells a 30-day unlimited pass (a consumable
IAP, `StorePurchases.buyAiPass` → `okayai.pro.monthly`; test mode simulates).
The SERVER ceiling (the real cost control, since a modified client bypasses the
first): `ai-chat` bumps `public.ai_note_usage(caller)` before the model call and
returns 429 past `AI_DAILY_CAP` (env, default 40) — counted per caller (their
phone, or the request IP), checked before any tokens are spent, and FAILS OPEN
if `docs/ai_usage.sql` isn't run. `ai_usage` has no client grants (a
`check_sql.sh` assertion pins that a client can't bump it or read it). The
server cap is an abuse ceiling above the 15/day free tier; a paid user is still
capped at `AI_DAILY_CAP` until the pass is recorded server-side (a follow-up) —
so set `AI_DAILY_CAP` generously. The price is the owner's to finalise.

**Needs the user's own action to answer:** set `OPENROUTER_API_KEY` (already
there if the feed moderator runs) and paste the `ai-chat` function; optionally
`OPENROUTER_AI_MODEL` for a smarter model; create the `okayai.pro.monthly` IAP
product when going live on the pass.

**Incognito + personality (2026-08-06).** Two per-user AI controls, both in the
chat ⋮. **Incognito** (`AiAssistant.incognito`/`setIncognito`) is an ephemeral
session: `_save()` is guarded to a no-op so the thread never touches disk (and a
`clear()` mid-incognito can't wipe the real saved chat), no on-device memory is
sent or folded back, `learn: false`, and `rate()` uploads nothing to the corpus
regardless of consent. Entering starts a fresh thread and leaves the saved one
on disk; leaving reloads it. Honest limit stated in-app: it hides the chat on
the DEVICE, not from the host (the request still leaves the usual usage/IP
trail). **Personality** (`AiPersona`, `lib/state/ai_persona.dart`) is a
persisted tone preference — five presets + a free-text Custom — sent as the
`style` field on the `ai-chat` request; the function folds it into the system
prompt AFTER the real rules (a tone, not a jailbreak). `AiPersona` names no
chat/relay/crypto (a test pins it), same wall as the rest of Okay AI. The daily
allowance still counts in incognito — it's about not remembering, not being
free. (The `ai-chat` re-paste for the `style` field is DONE — the deployed
body carries it, verified 2026-08-09.)

**"Write a message for me" tries on-device first, free (2026-08-11).** The
in-chat AI draft was always a ONE-SHOT instruction to the hosted `ai-chat`
function — never the conversation — which made it the one Okay AI surface
already shaped for Apple's on-device model: single instruction in, single
reply out, no memory either side. `OnDeviceDraft` (`lib/state/
on_device_draft.dart`) + `ios/Runner/AiDraft.swift` (`okay/aidraft`) mirror
`SmartReplies` exactly — same two guards (`canImport` at compile time,
`@available(iOS 26.0, *)` at runtime), same on-device-only honesty (no
network path in the Dart file, a test pins it), same three reasons it may say
no (OS, hardware, model off/downloading). `AiAssistant.draft()` tries it
FIRST and only reaches for `ai-chat` when the device declines — so a draft
that succeeds on-device never touches `AI_DAILY_CAP` or the free-tier count,
because it never reaches the server at all. Reach is the same ceiling
`SmartReplies` has (iPhone 15 Pro+/iOS 26), so on most phones this silently
falls through to the hosted path exactly as before — nothing about the
feature changed for them, it just got free for the phones that can.
**Unverified from this box** — same as `SmartReplies` and the whole
Foundation Models surface, no Xcode here to compile Swift and no iPhone 15
Pro+ to run it on.

## On-device translation (2026-08-06)

`TranslateService` (`lib/state/translate_service.dart`) + `okay/translate` →
`ios/Runner/Translate.swift` (Apple's **Translation** framework). A "Translate
to <lang>" action on any text message opens a sheet with the translation, the
original, and a Copy button; the target language lives in Settings → Chats
(`_pickTranslationLanguage`), defaulting to the device locale.

**On-device, ALWAYS — same rule as `SmartReplies`.** Message bodies are E2E
encrypted, so a cloud translator would mean decrypting somebody's chat
somewhere it can be read. There is NO network path in `translate_service.dart`
(a test asserts it names no `http`/`Supabase`/`functions.invoke`), not even for
the public feed, so one Translate button behaves the same everywhere. Apple's
framework fetches the language pack once (with the system's own consent) and
translates offline after.

**Translate.swift is a COMPILE-SAFE STUB right now** (`available` → false).
Apple's Translation framework exposes NO constructable `TranslationSession` — it
is vended only through SwiftUI's `.translationTask` (iOS 18+), so a working
version must host an off-screen SwiftUI view and drive it from the channel. The
first attempt constructed the session directly and **failed the Codemagic
archive** (`'nil' is not compatible with 'Locale.Language'`), which no gate here
can catch — there's no Xcode on the box. So on-device translation currently
reports unavailable and the Dart side degrades to "Translation isn't available
on this device yet." The real `.translationTask` implementation is a follow-up
whose only test is a device build — write it carefully or leave the stub.

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

## Owner-editable legal documents (2026-08-06)

The Terms of Service and Privacy Policy can be updated by the OWNER from inside
the app — no build. The build still ships built-in documents
(`legal_content.dart`, `legalVersion`); `LegalStore` (`lib/state/legal_store.dart`)
overlays an owner-published version on top and is what every screen reads
(`LegalScreen`, `LegalConsent`). `LegalConsent.needsConsent` now compares the
accepted version against `LegalStore.version` (the higher of the build's
`legalVersion` and the published version), so publishing re-prompts everyone.
Publishing goes through the owner-gated `legal-set` Edge Function (checks
`platform_roles` = owner, exactly like `roles-set`); the `legal_documents` table
(`docs/legal_documents.sql`) is world-readable but has NO client write grants —
`check_sql.sh` pins that a client can read it and cannot publish/alter it. The
editor is Settings → **Edit legal documents** (owner-only, gated on
`PlatformModeration.isOwner`); it edits each doc as plain text where a `# ` line
starts a section. Fetched on launch and cached (survives offline). **Needs the
owner's action:** run `docs/legal_documents.sql`, paste `legal-set`.

## The legal documents have a public URL (2026-08-11)

The App Store will not take a build without a reachable **Privacy Policy
URL**, and App Review reads it against what the app says. `legal_content.dart`
was written for exactly this ("kept as structured data so the exact same text
can be published at a public URL"), so `tool/build_legal_pages.dart` now
GENERATES the hosted copies from the same constants the in-app screens render.
There is no second copy of the text to fall behind, and a test fails if the
generated files stop matching their source or if the version drifts.

It writes three things:

* `web/privacy.html` / `web/terms.html` — shipped with the web build. These
  are for a custom domain later; they are **not** the submission URL, because
  that build is served from a code host.
* `supabase/functions/_shared/legal_pages.ts` — the same pages as TS, which
  `pages/index.ts` serves at `/pages/privacy` and `/pages/terms`. **This is the
  URL to submit.** It names the app's own host and nothing else — the owner's
  call: a link given to App Store Connect is published, and it must not
  advertise where the source lives. It is the same reasoning that already
  takes every public URL the app names off this function.

`paste_functions.dart` inlines the shared module, so the dashboard copy stays
self-contained.

**DEPLOYED + verified live 2026-08-11** — `pages` v17, ACTIVE, `verify_jwt`
still **false** (a browser opens these and has no session; letting the deploy
default it back to true would break them and the Stripe/landing pages). Probed
after: `/pages/privacy` and `/pages/terms` both answer **200** with the right
`<title>`, both say **version 6**, the policy carries its real sections
("What we do NOT store", "Offline message queue"), the Terms carry the
corrected store-and-forward sentence, and **zero** occurrences of `github` in
either. The function root still serves the landing page. Do not re-raise as
pending. **What still needs the owner:** put the privacy URL in App Store
Connect, and re-run `dart tool/build_legal_pages.dart` + redeploy whenever
the documents change.

**Both accuracy problems found while doing it are FIXED, at the owner's
say-so — `legalVersion` is now 6:**
1. The **Terms** said "we don't guarantee delivery, since nothing is stored
   to retry later", which stopped being true when store-and-forward shipped.
   The **Privacy Policy had always been correct** (it describes the offline
   queue and the 14-day sweep); this is the Terms catching up, so the two
   documents no longer contradict each other in front of a reviewer. The
   replacement says what actually happens: held as ciphertext, delivered on
   reconnect, deleted on delivery or swept within 14 days, unreadable to us.
2. `legalLastUpdated` is now "August 2026".

The bump is not cosmetic — `LegalConsent.needsConsent` compares the accepted
version against `LegalStore.version`, so **everyone is asked to agree again**.
That is the correct price for changing a promise about what happens to
somebody's message, and it costs nothing before launch.

The scanning test that catches an undeclared constant in an Edge Function
(the `STRIPE_PERCENT` class of bug) learned about `import { X }` here: a name
that is imported cannot fail with "Cannot find name", and it flagged the new
module's exports until told so.

## Store images: exact sizes, flattened (2026-08-11)

`tool/store_screenshots.dart` converts phone screenshots to the pixel sizes
App Store Connect accepts. **Pure Dart, so it runs on Windows** as well as
macOS — `sips` is macOS-only, and the owner works on a PC.

```
dart run tool/store_screenshots.dart screenshots            # 1290x2796
dart run tool/store_screenshots.dart screenshots --all
dart run tool/store_screenshots.dart art --size=1024x1024 --cover
```

Sizes are keyed BY PIXELS (`kSizes`), not by inches: Apple moves which device
an inch label means, and the pixel count is what the upload checks. Covers the
iPhone 6.5"/6.7"/6.9" slot (1290x2796, 1320x2868, 1260x2736), iPad 13"
(2064x2752) and the **In-App Purchase promotional image** (1024x1024).

Three decisions worth not relitigating:
- **It stretches only when stretching is invisible.** A 1179x2556 iPhone shot
  into 1290x2796 is 0.02% out of shape and 1170x2532 is 0.16% — forcing those
  to size adds nothing to notice, while padding them would add bars for
  nothing. Past `kAspectTolerance` (1%) it scales to FIT and pads with the
  picture's own corner colour instead, so an iPad shot dropped into an iPhone
  slot is never handed to Apple squashed. Each file's line says which happened.
- **`--cover` crops to fill** rather than padding, for the square promo image
  where two thick bars either side of a phone screenshot look like a mistake.
  Padding stays the default because it loses nothing.
- **Every output is flattened**, three channels, no alpha — Apple states this
  outright for the promo image. It is done by compositing onto a
  `numChannels: 3` canvas, because a PNG saved from an image that still
  carries an alpha channel is not flattened even when every pixel in it is
  opaque. A test pins that, the exact output dimensions, and the
  resize/pad/crop choice.

Output goes to `build/store_screenshots/<WxH>/`; originals are never touched.
DPI is deliberately not written: App Store Connect checks pixel dimensions,
and embedding no density claim is what satisfies "72 dpi".

## The demo seed fills the app, not the shared tables (2026-08-11)

`DemoSeed` grew from "some chats, a server, two listings" to covering every
surface a fresh install leaves blank — so an App Store screenshot of any
screen has something in it. Both gates are unchanged and pinned: the
`DEMO_SEED` compile flag, and `PlatformModeration.canAdminister` re-checked
inside `populate()` itself.

Added: a **second server** (Trail Runners, with its own channels and
timeline) so Servers is a list; **four more marketplace listings** across
real categories including a free one; the **Notifications tab** via the
store's own `noteChannelMention`; **Notes**; **bookmarks** with a folder; and
a **chat folder**.

**Two omissions on purpose, and they are the interesting part.**
* The public **newsfeed and forum** stay empty. Their posts live in real
  shared tables — content invented here would be invented for everyone.
* The **Okay Score** stays untouched, because `award()` only adds and there
  is no public way to take points back. Seeding it would leave permanent
  invented points on the owner's own phone and make `clear()`'s promise
  false. A real check-in costs one tap. If it ever needs seeding, it needs a
  reversible hook first.

Three tests hold it: every `demo_*` id used is a member of a const list
`clear()` walks (so a new fixture cannot become litter), the file names no
shared-surface store, and both gates are still in the source.

**A trap worth knowing**: the older "the seed is local-only" test bans the
substrings `http`, `supabase`, `relay_service` and `push` across the WHOLE
file, comments included. Demo prose tripped it twice — "HP5 pushed to 800",
then the comment explaining the first fix. Reword the prose; do not loosen
the guard, which errs on the safe side by design.

## The Store screen used to claim one billing model for four different ones (2026-08-12)

Four things the app sells are genuinely different mechanisms, and the UI
used to describe all four with the language of ONE of them.

**Only cloud storage auto-renews.** Okay AI Pro, creator subscriptions and
paid server memberships are all `AppleIap.buy(id, consumable: true)` —
`store_purchases.dart` says so outright ("Deliberately a CONSUMABLE, not an
auto-renewable subscription"). A consumable is charged once, unlocks
something for 30 days, and then simply stops — nothing appears in Settings
→ Subscriptions for it, ever, and nothing charges again unless the user
comes back and buys another 30 days by hand. Storage alone is
`consumable: false`, a real Apple auto-renewing subscription that bills
every month until cancelled. `CloudSyncScreen._subscriptionDisclosure`
already says this correctly and is untouched — it is the one screen that
was right.

Everywhere else read like a subscription anyway: the Store screen's footer
said flatly **"Billed by the App Store. Cancel in Settings → your name →
Subscriptions."** for the WHOLE page, which is true only for storage — a
buyer following that instruction for an AI Pro pass, a tip, a creator sub
or a paid server would find nothing there. And four purchase buttons
printed **"$X/mo"** on a one-time charge — `subscribe_sheet.dart`,
`message_bubble.dart`'s paid-server sheet (and its inline invite-card
label), the public-feed creator-subscribe button, the paid-post lock badge,
the composer's subscribers-only chip, the marketplace seller card and the
creator's own tier editor — "/mo" is exactly the shorthand that means
"billed every month" to anyone who has seen an App Store subscription
sheet, and none of these are.

**Fixed with one shared widget** — `PassBillingNote`
(`lib/widgets/pass_billing_note.dart`) — dropped into every place that
sells a 30-day pass: the Store screen's Okay AI Pro card, the in-chat
upgrade sheet (which used to show `Text('Subscribe to Okay AI')` with **no
price on the sheet at all** — now carries a `StorePriceLabel` before the
button that charges it), `subscribe_sheet.dart`, and the paid-server
sheet. One sentence, one file, so the four dependents can't drift apart the
way four independent guesses would. Every `"$X/mo"` price label across the
app was changed to `"$X · 30 days"` or `"$X for 30 days"` — everywhere
except storage, which keeps `/mo` because it is telling the truth.

The Store screen's footer is now two sentences instead of one wrong one:
storage renews automatically until cancelled in Settings; everything else
is a one-time App Store charge that does not renew on its own.

Pinned by tests: `PassBillingNote`'s exact wording; that `store_purchases.dart`
has exactly four `consumable: true` sites and one `consumable: false` (the
mechanism the copy is describing); the old blanket footer sentence is gone
from `store_screen.dart` and both replacement sentences are present; the AI
upgrade sheet shows a real `StorePriceLabel` and no longer says the old
price-less button text; every fixed file carries `PassBillingNote`; and a
digit-anchored regex (`\d/mo['"]`) sweeps every non-storage screen for a
surviving rendered `"$X/mo"` — anchored to a digit specifically so it can't
false-positive on `models/user.dart` import lines or this section's own
prose.

## Owner-editable prices (2026-08-09)

Settings → **Prices** (owner-only, beside the legal editor): a price for each
of the ten storage sizes, the storage per-GB rate, the four subscription tier
levels, the four tip amounts — published to every device via the owner-gated
`pricing-set` function into the world-readable `app_pricing` row, cached
locally, read by `PricingStore`.

**The invariant that makes this safe: a real StoreKit price ALWAYS wins.**
What is published fills only the gaps a store price cannot — web,
payments-test mode, the frame before StoreKit answers — plus the tier ladder a
creator picks from (a choice the app must offer before any purchase exists).
So nothing set here can advertise a price different from the charge. An
editor that could override a live store price would be a way to promise one
number and bill another; do not "improve" it into one. **To change what people
pay it is still App Store Connect** — the in-app banner says so.

**Storage is priced PER SIZE, and the one per-GB rate it used to derive was
the bug** (2026-08-09, second report of "the prices don't match no matter what
I do"): one rate locks all ten sizes into a fixed relationship, so a rate
chosen to line 10 GB up with App Store Connect necessarily threw 50 GB out —
the owner was right and there was no rate that could work.
`PricingStore.storageCentsFor(gb)` now prefers a published per-size price and
falls back to the rate formula for any size without one; the rate survives for
that fallback and for the economics figures. Both ladders — tiers and sizes —
are validated TWICE, in the function and again in `_apply`, so one that goes
backwards (the 70-GB-dearer-than-80 fault in App Store Connect) is ignored
rather than rendered, even by an older build. The cache is device-scoped like
`legal_store.dart` (app-wide config, no account data); the account-switch test
pins that classification.

**`publish` applies what the FUNCTION echoes back, not what was sent.** The
function sanitizes, so echoing is the only way a device learns a field was
dropped — and the editor turns that into the sentence naming the cause ("the
deployed pricing-set is older than this build"). Without it, publishing a
field an older deployment doesn't understand looks like it worked and quietly
vanishes on the next launch.

**The editor shows Apple's own price beside every field** (`_storeLine`, fed by
`StorePrices` which the editor loads on open): "App Store: $2.99", or "App
Store charges $X — this field is only the fallback." when it disagrees with
what is typed, or nothing at all where no store was asked. This is what ends
the "prices don't match" loop, because the three numbers involved are all
real and only one is the charge: the card shows Apple's PRODUCT METADATA, the
purchase sheet shows the LIVE price, and the editor holds the app's fallback.
Metadata and sheet can disagree for a while after a price change in App Store
Connect — neither is the app's doing, and no amount of editing here moves
either. The tip screen says so too ("the App Store confirms the exact amount
before you pay") rather than presenting its figure as final.

**A price names its currency when the symbol cannot.** The US and Canadian
stores BOTH format as a bare `$`, so Apple's own localized string for a
Canadian buyer is `$1.99` — indistinguishable from the US price, and read as
it ("I'm getting USD prices not CAD"). `StoreQueryResult.currencies` now
carries `ProductDetails.currencyCode` alongside the price, and
`StorePrices.labelled` appends the ISO code when the string has no letters of
its own: `$1.99 CAD`. A string that already disambiguates (`CA$1.99`, `€1,99`)
is left exactly as Apple wrote it. The plain USD fallback is deliberately NOT
labelled — there is no charge behind it to be right or wrong about.

**Never print a price the store might contradict.** `StorePrices.money` has a
fourth case now: when a query completed and reported NO reachable store
(offline, signed out of the App Store), it returns `unknownLabel` ('—') rather
than the cents the code assumes. A thrown query teaches nothing and leaves the
fallback alone — which is also what keeps the web build and the whole test
suite on plain USD figures.

**RUN + verified live 2026-08-09** — `app_pricing` created (RLS on, 1 policy,
**zero** client write grants, anon+authenticated SELECT), and `pricing-set`
deployed ACTIVE with `verify_jwt=true`. Probed: no-JWT → 401, anon `what=get`
→ `{"prices":{}}` (it boots), anon `publish` → `unauthorized`, anon INSERT on
the table → 42501. Do not re-raise as pending.

**A raised App Store Connect price now reaches the app (2026-08-09).**
`StorePrices.load()` ran once at launch and on opening the three purchase
screens — and on iOS the app is RESUMED far more often than relaunched, so a
price raised in App Store Connect could stay wrong for as long as the process
lived. It now re-runs in `main.dart`'s resume handler, beside the follow-count
re-seed that fixed exactly this staleness for a different number. The Store
screen also gained pull-to-refresh (`RefreshIndicator` → `load`, with
`AlwaysScrollableScrollPhysics` so a short page can still be pulled).

**What that does NOT fix, and nothing in the app can:** Apple's product
metadata (`queryProductDetails`) can lag Apple's own purchase sheet for hours
after a price change — the card and the sheet are both Apple's numbers,
disagreeing with each other. Re-asking more often shortens the window; it
cannot close it. The card is never the app's invention: the AI pass carries
`cents: 0` and the label is "the store's price, or nothing".

**On a phone the app prints Apple's price or NOTHING (2026-08-09).**
`money()` used to end in `usd(cents)` — the built-in or owner-published figure
— whenever the store had not answered yet. On a device that is a number the
app invented, sitting beside a Buy button, which the charge need not match.
It now returns `unknownLabel` ('—') instead whenever `AppleIap.hasRealStore`,
so tips and storage follow the rule the AI pass already had by carrying
`cents: 0`. Off-device — web, payments-test mode, the whole suite — the plain
figure still stands, because there is no store to be contradicted by. The
owner-published prices in `PricingStore` keep their real job (the tier ladder
a creator picks from, and the economics figures); they are no longer shown as
if they were a charge.

**THE TESTFLIGHT SANDBOX TRAP — suspect this FIRST, before any of the above.**
It burned three rounds of debugging (twice misdiagnosed as stale metadata) and
it is not a bug at all. A sandbox build reads its PRICES from the device's
**storefront** but runs the purchase sheet against the **Sandbox Account**
(Settings → App Store → Sandbox Account) — and the two can be different
countries. Observed: App Store Connect set to **US$9.99**, the Store card
showed **$9.99 USD** (US storefront, correct) and the sheet quoted **$12.99**
(CA$12.99, Apple's Canadian point for the US$9.99 tier, from a `.ca` sandbox
account). Both numbers right, from two accounts.

The giveaway is Apple's tier ladder, which is fixed points and NOT an FX
conversion — US$4.99↔CA$6.99, US$6.99↔CA$9.99, US$9.99↔CA$12.99. If the card
and sheet are a matched pair on that ladder, it is two storefronts, not a
cache. Real buyers never hit this: their storefront and purchase account are
the same. `_StorefrontCard` in `store_products_screen.dart` now says all of
this on screen, and a test pins it.

**`pricing-set` DEPLOYED with `storageCents` (v3, 2026-08-09)** — the deployed
body was read back and contains the field, so per-size storage prices publish
for real. The editor's "the deployed pricing-set is older than this build"
message stays as the guard for the next time the shape changes. Do not
re-raise as pending.

**Deploying a function from this box**: the Management API's JSON
`POST /v1/projects/{ref}/functions` stores a body with NO entrypoint and the
function answers `BOOT_ERROR`. Use the multipart
`POST /v1/projects/{ref}/functions/deploy?slug=<slug>` with
`metadata={"entrypoint_path":"index.ts",...}` + a `file=@index.ts` part, and
deploy the **paste copy** (self-contained; the sources' `_shared` imports do
not resolve there).

## Weather and Sports (2026-08-11)

Two sidebar rows (`'weather'`, `'sports'` in `SidebarPrefs.defaultOrder`,
above Maps), each a pushed screen with `HomeNavBar`, plus two chat
attachments.

**Weather — no key, and a deliberately coarse location.** `WeatherService`
(`lib/state/weather_service.dart`) calls **Open-Meteo**, which serves
anonymous callers, so there is no secret to keep and no Edge Function to run.
`coarsen()` rounds the fix to a **0.1° grid (~11km)** before it is sent —
weather is the same across a town, so the precision buys nothing and giving
it away costs something. That is the whole reason a location feature belongs
in this app, so the screen says it: "Your location is rounded to about 10km
before it is sent." Latitude CLAMPS to ±90; longitude WRAPS, and only PAST
180 — 180 is a real meridian, so snapping 179.97 up to it is correct (a test
got this backwards first). Everything but `fetch` is pure; the parser is
tested against a trimmed copy of a **live** response, and Fahrenheit is asked
of the provider rather than converted locally (converting would round twice).

**Sports — the key stays server-side.** `supabase/functions/sports/` proxies
TheSportsDB; `SPORTSDB_API_KEY` lives in Supabase secrets and is never echoed
back (an upstream error would carry the request URL, and the URL carries the
key — hence the flat `"upstream failed"`). `SportsService` names no provider
at all. **Leagues are resolved BY NAME, not by hardcoded ids**:
TheSportsDB's numeric ids are undocumented and the free test key only answers
with five of them, so a table typed from memory would be guesses that render
empty sections. `SPORTS_LEAGUES` holds names (or ids), looked up against
`all_leagues.php` with the owner's own key — wrong name, empty section, no
invention. **Results and Fixtures only, no LIVE section**: in-play is the
provider's paid tier, and a stale scoreline labelled live is worse than none.
A passed kickoff with no posted score stays under Fixtures, which is true
either way. `configured: false` is a DIFFERENT screen from "nothing on" —
from a bare empty list the owner could not tell which they were looking at.

**In chat both INSERT, never send** (`_handleShareWeather`,
`_handleShareScore` → `_insertDraft`), the rule quick replies set. Plain text
on the ordinary encrypted path — no new message kind. The weather line says
"Weather here", not a place name: the app does no reverse geocoding, so
"here" is the only honest word.

**Needs the owner's action:** paste the `sports` function and set
`SPORTSDB_API_KEY` (and optionally `SPORTS_LEAGUES`). Until then Sports says
it is not set up. Weather needs nothing.

## Public forum (2026-08-08)

A world-readable, Reddit-shaped discussion board that lives OUTSIDE any server —
its own **drawer row** (`'forum'` in `SidebarPrefs.defaultOrder`, between
Newsfeed and Maps), `PublicForumScreen`/`PublicForumStore`
(`lib/screens/public_forum_screen.dart`, `lib/state/public_forum_store.dart`).
Forums until now only existed as `ChannelType.forum` channels INSIDE a community,
synced over the sealed community bus; this is the public sibling of the
**newsfeed** — same transport shape, not the community one.

**Plaintext the server can read, ON PURPOSE — the public-feed rule.** A board
whose audience is everyone has no key to seal under (a public key is no key), so
`public_forum_store.dart` names no crypto/seal path (a test pins no
`double_ratchet`/`sender_key`/`sealContent`). What is still protected is the
author's PHONE: `docs/public_forum.sql` revokes the table-wide select and hands
back every column but `author_phone`, and clients read the phone-free
`public_forum` view (attribution by username). `check_sql.sh` pins post-as-self,
phone-unreadable, `select *` refused, votes/comments own-only, a silenced
(timed-out) account refused, and the score/comment tallies coming off the view.

**Reddit-shaped:** a post leads with a **title** + optional body + one **tag**
(`forumTags`) + one photo/GIF, has up/down **votes** (`public_forum_votes`,
toggle/undo — score = sum of dirs, author auto-+1 on create) and **threaded
comments** (`public_forum_comments`, flat rows + `parent_id`, one level like the
group-chat threads). Post voting only for v1 — comments carry
no votes yet, and posts are append-only (no edit path yet; `edited_at` reserved).

**Sort is top-right, and there are user-creatable SECTIONS (2026-08-08).** The
old Hot/New/Top + tag-filter chip row is GONE from BOTH forums (public + the
in-server `forum_screen.dart`); sort (Hot/New/Top) is a top-right
`PopupMenuButton`, matching the newsfeed's For you/Following. **Sections** are
subreddit-style boards anyone signed in can create (`public_forum_sections`,
slug + title + description; `created_by_phone` never exposed): the app-bar title
is the section switcher (tap → picker sheet with **Create**), a post carries a
`section` slug ('' = General), and browsing one narrows server-side. Tags stay a
post flair (composer only). `PublicForumSection.slugify` makes a safe slug;
`check_sql.sh` pins create-as-self, phone-unreadable, and the `section` column on
the view. **Re-run `docs/public_forum.sql`** for the sections table + column
(done live already). The in-server forum has no sections — a server IS the
container; only its sort moved.

**Input bar matches the newsfeed** (the paired ask): compose is the **top-right
edit pencil, no FAB**, and the detail's comment bar is the shared
`FeedReplyBar` — the same widgets the newsfeed and the in-server forum (#118)
use, so all three read as one feature. The card/detail reuse `feed_post_parts`
(`FeedAvatar`/`FeedPostHeader`/`FeedBodyText`/`FeedPostImage`).

**Same access rule as the newsfeed:** reading is served by the anon key (a
name-only account may browse — no padlock on the drawer row), but posting,
commenting and voting go through `postNeedsPhone` (a numberless account is told
why), and the server RLS refuses a sessionless write as the backstop. Moderation
reuses the public feed's `moderation-screen` speed bump at post time.
Images ride the shared world-readable `public-media` bucket.

**Needs the user's own action to go live:** run `docs/public_forum.sql` (after
`docs/platform_moderation.sql` + `docs/public_feed.sql` — it leans on
`is_locked_out`/`is_silenced`). Until then it runs empty against a project that
doesn't have the tables. No new Edge Function.

**Down-voting was broken by the column grant that hides who voted
(2026-08-11).** Reported as "when I try to downvote it says my account can't
post right now", which sounded like moderation and was not. The app changes a
vote with PostgREST's upsert — `insert … on conflict (post_id, voter_phone)
do update` — and **Postgres requires SELECT on the columns of the conflict
target**. `voter_phone` was deliberately left out of
`grant select (post_id, dir, created_at)`, so every DOWN-vote and every vote
CHANGE came back `42501 permission denied for table public_forum_votes`. The
first up-vote is a plain INSERT and worked, which is exactly why it looked
like an account problem.

`voter_phone` is now in the grant, and **it costs no privacy**: the read
POLICY (`public_forum_votes_read_own`) scopes SELECT to `voter_phone = your
own`, so the only number the column can hand back is the one you already
know. A column grant was never what protected it. `check_sql.sh` now proves
the fix and the guarantee separately — downvote, change-a-vote, the score
following the change, and another account's vote staying invisible.

**Why only this table.** The same phone-hiding pattern is on
`market_listings` and `server_directory`, and both are fine: their primary
key is `id` alone, which IS in the grant, so their upserts never touch a
withheld column. `public_forum_comment_votes` has the same composite key but
a TABLE-level select grant. Reach for this whenever a client upsert on a
composite key meets a column-level grant.

**`_explain` learned the difference too.** A `permission denied` while signed
in used to say "Your account can't post right now" — it now says the forum
isn't set up correctly on the server, because a missing GRANT is not the
account's fault and that message sent us looking at moderation for a schema
bug. Only an RLS ROW refusal is about the account.

**RUN + verified live 2026-08-11.** The grant was applied to the real project
and read back from `information_schema.column_privileges`: `authenticated`
now holds SELECT on all four columns (`post_id`, `voter_phone`, `dir`,
`created_at`) and `anon` still holds **none**. Then the exact statement the
app sends was run against a real post as an impersonated authenticated user
inside a `do $$ … $$` block that raises at the end — it reached the raise,
so the upsert was accepted, and the raise rolled the block back (a follow-up
count confirmed **0** rows left behind). The before/after causality lives in
`check_sql.sh`, which reproduced `permission denied` first and passes now;
proving the negative again on production would mean breaking down-votes for
a window, for evidence already held. Do not re-raise as pending.

**"Couldn't reach the forum. Try again." was a lie (2026-08-11).** `_explain`
answered that to EVERY failure, and it is the worst available sentence: it
names the network and asks for a retry, and the common causes are neither
transient nor retryable. The one that produces most of them is a **lapsed
Supabase session** — every forum write is granted `to authenticated`, so a
signed-out device reaches Postgres as `anon` and is refused with `42501
permission denied for table …` *before RLS is consulted*, while READS keep
working (served to `anon` by design). That is why the board renders perfectly
around an action that cannot succeed, and why retrying forever felt
reasonable. Now: `signedOutOfServer` (there IS a client and no session —
FALSE when there is no client at all, since a relay-less build has no server
to be signed out OF and already says "No server configured.") refuses all five
writes up front, so nothing doomed is sent; and `_explain` separates a missing
relation (`PGRST205`/`42P01`) from an RLS row refusal from a table
permission-denied, leaving the retry sentence only for a real transport
failure. Verified live against the project: `anon` really does get
`{"code":"42501","message":"permission denied for table public_forum_votes"}`
on every write table, while `public_forum`, `public_forum_comments_v` and the
granted `public_forum_sections` columns all answer 200. Do not collapse these
back into one message.

## Both newsfeeds match (2026-08-08, re-matched 2026-08-11)

The CARDS never diverged — both feeds draw through `feed_post_parts`
(`FeedAvatar`/`FeedPostHeader`/`FeedBodyText`/`FeedPostImage`/
`FeedPostActions`) and both threads use `FeedReplyBar`. What drifted was the
CHROME, because the public newsfeed had its fourth iteration on 2026-08-11
and the server feed did not follow. It does now:

- **Compose is the hovering circular button, bottom right** (`endFloat`), not
  an app-bar pencil — the shape the public newsfeed settled on after its own
  spell as a pencil. It needs NO clearance padding, unlike the newsfeed's: a
  server's feed carries no bottom bar, so nothing floats over it.
- **For you / Following is GONE** from the server feed too. The 2026-08-08
  round had just ADDED it here to match; the owner then removed it from the
  product on the public side, and a picker on one feed and not the other is
  exactly the difference you notice. The whole server timeline is what it
  serves. (`FeedFilter` still lives in `public_feed_store.dart` and
  `PublicFeedStore` still serves For you — the enum is not dead.)
- **Actions are Notifications (badged) + Shape your feed**, in that order,
  same as the public newsfeed. "Add and follow people" went: the public feed
  has no such action and `PeopleScreen` is reached from Chats, Calls, New
  chat and the one search — it was a fifth door, and the fifth door is what
  made the two bars read as different apps.
- **The empty state uses the public feed's words** ("Nothing here yet. Be the
  first to post…"), since "tap the pencil" named a control that no longer
  exists.

**The title matches too, since 2026-08-11** — the owner's call, made after
the reservation below was put to them, so do not "restore" the name.

The reservation, recorded rather than acted on: this is ONE server's feed
and you can be in several, so the bar no longer says which. What carries
that is the ROUTE — you arrive from the server you opened, and the back
arrow beside the mark returns to it. A test pins the mark in and the
`<name> · Feed` title out.

The trending row stays. (Saved-post filtering went with the old Latest/Top/
Saved strip; the bookmark action on a post remains, into the shared
`BookmarkStore`.) Ads stay public-surfaces-only — the server feed mounts no
`AdBannerSlot`, and that is the documented rule, not an oversight.

## In-app prices show the store's real currency (2026-08-08)

Digital purchases (tips, creator subs, paid servers, the storage plans, the AI
pass) are IAP, so **Apple/Google set and localise the price** — the app is sold
in the US and Canada only, so a real buyer sees USD or CAD, whichever their
store region is. The UI used to render prices computed from hardcoded `cents`
(`$2.99`), which (a) showed USD to a Canadian and (b) drifted from the charge
the moment a price was adjusted in App Store Connect. `StorePrices`
(`lib/payments/store_prices.dart`) fixes both: it queries StoreKit once at
startup (`main.dart`, fire-and-forget) for every product's localized price
string and caches it; `StorePrices.instance.money(cents, productId:)` returns
that string when known, else a plain USD figure (`usd(cents)`) — the fallback
for web, payments-test mode, and the first frame before the query lands. The
store's price is the source of truth (it IS the charge); the cents are only the
fallback. Wired at every purchase point: `subscribe_sheet` (creator tiers →
`creatorSubProductId`), `okay_pro_screen` (tips), `cloud_sync_screen` (storage,
via `_priceLabel`), `message_bubble` `_ServerInviteContent` (paid server →
`communitySubProductId`). The AI pass upgrade sheet shows no amount, so nothing
to localise there. Profile "from $X/mo" ADVERTISING (a creator's own set price)
is left as the creator entered it. A test pins the fallback/store-price logic
and that each surface routes through `StorePrices`.

## Chat folders (2026-08-09)

Telegram-shaped tabs above the chat list. `ChatFolders`
(`lib/state/chat_folders.dart`) + `ChatFoldersScreen`. Membership is
**EXPLICIT** — a folder is the chats you chose, not a rule that might quietly
start matching something new; Telegram offers both, and the rule version is the
one that surprises people.

The tabs join the **existing filter strip** (`_FilterBar` in `chats_tab.dart`)
rather than starting a second one, so All/Unread/Favourites/Groups and the
folders read as one control. Two behaviours that are deliberate:
- **`ChatsTab.filtersVisible` defaults to FALSE, and folders show anyway.**
  Without that, somebody could make three folders and never see a tab. When the
  bar is hidden the strip carries **All + their folders only** — hiding it was a
  decision about Unread/Favourites/Groups, not about these. With no folders and
  the bar hidden, there is no strip at all (discovery is then a chat's
  long-press → Add to folder → New folder).
- A folder deleted or renamed elsewhere drops the selection back to All; a tab
  pointing at a name that no longer exists reads as every chat vanishing.

`rename` keeps the folder's POSITION (a remove-and-re-add would send a typo fix
to the end of the strip). `reorder` takes the index **after** the lift
(`onReorderItem`), like `SidebarPrefs`. `ChatStore.deleteChat` calls
`forget(id)` so no tab counts a conversation that is gone. Cap
`maxFolders` = 10.

Device-local, no table, no column (a test pins no `supabase`/`http`), like
`BookmarkStore`'s folders — which conversations somebody groups as "Family" is
a statement about their life. **Account-scoped**: wired into `account_wipe.dart`
(reset + reload), because a folder names THIS account's chats and the next
account would inherit tabs pointing at conversations it cannot see.

## Sparks are OFF posts — you tip a person, not a post (2026-08-09)

The owner's catch, and it was right: Lightning sparks were built profile-only
because of the Damus precedent, while the older **Stripe** sparks still sat on
feed posts — the same shape, on fiat rails. Money attached to one piece of
content is a payment for digital content; a tip to a person is a
person-to-person payment, which Apple permits outside IAP (Venmo, Cash App).
The rail was never the point.

So there is now ONE rule: **a spark goes to a person, on their profile or in a
chat.** Deleted rather than merely unwired, so nothing lingers as a way to
re-enable it: `canSparkPublicPost`/`offerPublicSpark` (public feed) and
`canSparkPost`/`offerSpark` (server feed). Both call sites pass
`onSpark: null`.

**The tally stays.** `FeedPostActions` draws the bolt when
`onSpark != null || sparkCents > 0`, with a null `onTap` and the tooltip
'Sparked' — that money really moved, and hiding it would be the lie.
`FeedPostAction.onTap` is nullable now, which is the read-only-tally shape.

**The profile has ONE Spark button whatever the rails**, because two controls
both called Spark is a worse screen than a chooser. `sparkRailsFor(user)`
(pure, in `public_feed_screen.dart`) answers from what THIS device holds:
Lightning when they published an address, cash when we hold a phone number
(i.e. a contact). A stranger gets no button at all rather than one that fails
— the username directory carries neither field. `offerProfileSpark` asks which
rail only when both exist, then hands off to `showLightningSparkSheet` or the
existing `offerSparkTo`.

**In-chat sparks are untouched** (long-press their message → Spark): a private
transfer between two people is the least ambiguous P2P case there is.

**"They can't receive money yet" is a screen, not a dead end (2026-08-09).**
`showCannotReceiveSheet` (in `spark_sheet.dart`) replaces the snackbar all
three surfaces used to end on — it is the check almost every real tip dies on,
because a transfer needs the RECIPIENT to have finished Stripe onboarding and
hardly anybody has. Three things it must keep saying, in order: **nothing was
charged** (a sheet appearing after an amount was picked otherwise reads as a
payment that half-happened); **Lightning needs no onboarding**, so it is
offered right there when they published an address — the rail that has this
problem and the rail that doesn't are one tap apart; and the sender may **ask
them once**, since only the recipient can fix it and nobody can fix what they
were never told about. The nudge is an ordinary chat message (both people see
it in the transcript — a thing the sender said, not something the app did in
their name), local copy first because `send()` deliberately does not store,
and `_nudged` keeps it to once per person. That set is in memory and a
courtesy brake, not a security control. `chat_screen._sparkMessage` routes
here too rather than keeping a second copy of the message.

**What is NOT solved, and cannot be in the app:** money has to land somewhere.
There is no escrow and no holding a tip until they sign up — that would make
this app a custodian. If they never set up payments, the cash tip never
happens.

**Three person-shaped surfaces, one flow.** `SparkRail`, `sparkRailsFor` and
`offerProfileSpark` live in `lib/widgets/spark_sheet.dart` — NOT in a screen —
because the public profile and the **contact info card** both call them, and a
helper that lives in one screen is how the second copy gets written. Contact
info's `_ActionButtons` gains a Spark tile beside Message/Audio/Video/Profile,
null (so absent) for a group or when `sparkRailsFor` is empty. A test pins the
shared home and that nothing drawing a POST reaches a spark sheet.

## Lightning sparks — bitcoin tips on a PROFILE (2026-08-09)

The owner asked for sparks to "work the same way zaps do", and chose real
Lightning, **profiles only**. `lib/payments/lightning.dart` (transport,
pure-testable parsing) + `lib/widgets/lightning_spark_sheet.dart` +
`AppUser.lightningAddress`.

**Profile-only is the whole design constraint, not an unfinished feature.**
Apple made Damus strip zaps off POSTS and allow them only on profiles, because
tipping content inside an app reads as a digital purchase owing Apple its cut.
A test pins `showLightningSparkSheet` OUT of `feed_post_actions.dart`. Do not
"finish" it by adding a spark button to a post.

**The app never touches the money.** LNURL-pay (LUD-06) through a Lightning
Address (LUD-16): `name@domain` → `https://domain/.well-known/lnurlp/name` →
callback → a BOLT11 invoice → handed to the sender's own wallet via
`lightning:<invoice>`. No custody, no cut, no in-app payment step — a test pins
`StorePurchases`/`PaymentService`/`AppleIap` out of the file, and chat/relay/
crypto tokens too.

**The honest limit, stated in the sheet as well as the code: the app CANNOT
confirm a Lightning payment.** Nothing reports back from the wallet, so there
is no counter, no receipt and no "sparked" state. Nostr gets that from zap
receipts a relay publishes; there is no equivalent here, and a count the app
cannot verify would be a number made up on screen. This is why the existing
Stripe spark counters are untouched — the two are separate features.

Parsing is deliberately strict at BOTH ends because the address arrives from
another device and becomes a URL on this one: `LightningAddress.parse` refuses
paths, schemes, whitespace, `%`, a second `@`, and a dotless host; the relay
re-validates on receipt; `parseInvoice` refuses anything not starting `lnbc`.
`LnurlPayParams.parse` treats `{"status":"ERROR"}` as a failure (it arrives as
a 200), rounds the min UP and the max DOWN so every offered amount is really
accepted, and requires an https callback.

The field rides the profile share **UNGATED** like `isBusiness` (entering one
IS publishing it — it is a tip jar, not a credential) and is applied **AS
SENT**, so a creator who takes it down clears it on every contact card. That
meant touching every full-rebuild site: `Session.signIn`/`updateProfile`/
`setVerified`, `AppState.updateProfile`/`setVerified`,
`ChatStore.updateContactProfile`, relay `encode`/`applyIncoming`/
`applyProfileUpdate`/`broadcastProfile`. A test pins each.

**Unverified from this box** — no Lightning wallet, no LNURL server and no
device has been near it. The parsing is proven in-process; the round trip is
not.

## Money the app itself moves names its currency (2026-08-09)

The other half of "it shows USD". `StorePrices` fixed the **store** prices;
this fixes the **Stripe** ones, and that half was entirely the app's own
fault. Every P2P amount already CARRIED its currency — `WalletStatus.currency`
off the Stripe account, `PaymentRecord.currency` off the transaction,
`PaymentService.sendCurrency` off the sender's own choice (default **cad**,
and it is what `payments-create-intent` is handed) — and every screen threw it
away and printed a bare `'$'`. A Canadian wallet holding CA$50 read as
"$50.00", which anybody takes for US dollars.

`Money` (`lib/payments/money.dart`, pure) is the one formatter:
`Money.symbolFor` never returns a bare `'$'` (USD/CAD/AUD all render as `$` in
their own locales, so a lone `$` names no currency) — `US$`, `CA$`, `A$`, `£`,
`€`, and an unknown code names itself. `Money.format(cents, currency)` puts
the two together. `PaymentService.symbolFor` now delegates to it; **it used to
fall CAD through to a bare `$`**, which was the bug at its source. Wired at
`WalletStatus.money` (the balance hero), `payment_history_screen` (rows +
detail, each transaction in the currency IT was charged in, not today's),
`payment_amount_sheet` (the input prefix already named the currency while the
fee rows and the Pay button under it printed `$`), and the wallet top-up sheet.

**Deliberately NOT relabelled:** creator tier advertising, listing prices,
spark and bill-split amounts. Those are numbers a *user* typed, not a charge
in a known currency — the same rule that leaves a creator's "from $X/mo" as
they entered it. A source-pin test keeps the three wired files off bare-dollar
formatting, and the label assertions read through `Money.format` so they stay
currency-agnostic.

**The IAP half cannot be fixed, only explained.** Apple charges in the
currency of the **storefront** — the country on the Apple ID signed in to the
App Store — not the device's region, not its IP, and not what is set in App
Store Connect. Nothing in this app can change it, and displaying anything
other than what Apple will charge would be false advertising. So
`AppleIap.storefront()` (`InAppPurchase.instance.countryCode()`; the stub
answers `''`) is surfaced as a `_StorefrontCard` in the store-products check:
"Store region: USA · quoting USD", plus the sentence naming where the currency
comes from. That turns an unanswerable complaint into a fact somebody can
check.

## Bookmarks: folders + search (2026-08-08)

Bookmarks (`BookmarkStore`, device-only, still no server table) gained
**folders** and **search**, X-style. The flat `_ids` list stays the master set
("All"); folders are named subsets (`_folders`, name → ids, persisted as JSON
under `public_feed_bookmark_folders`). A post can sit in any number of folders;
filing one that isn't saved yet saves it too. Unsaving a post (or `forget`ting a
deleted one) drops it from every folder. API: `folders`, `idsInFolder`,
`folderCount`, `foldersFor`, `createFolder`/`deleteFolder`/`renameFolder`,
`setInFolder`. UI: the post ⋮ gains **"Add to folder"** (`showBookmarkFolderPicker`
— checkbox sheet + New folder); `BookmarksScreen` gained a search field and a
folder-chip row (All + each folder·count + New), with long-press on a chip to
rename/delete (deleting keeps the posts in All). Behavioural + source-pin tests
cover it. Deliberately still device-local — no reading-habits table.

**Server-feed posts bookmark into the SAME list (2026-08-08).** Bookmarking used
to be public-newsfeed-only; the server feed had its own separate `FeedStore.
isSaved`/`toggleSaved` flag (which shares `_savedIds` with marketplace
saved-listings and had NO viewing surface — a saved server post went nowhere).
Now `feed_screen.dart`'s bookmark action routes through `BookmarkStore.instance.
toggle`/`contains` like the public feed, so both feeds save into one list with
one set of folders. `BookmarksScreen` renders a mixed `List<Object>`: it resolves
each id first against the public feed (`PublicFeedStore.postsByIds`) and then
against `FeedStore.instance.postById`, drawing a `PublicPost` as the normal card
and a `FeedPost` as a `_ServerBookmarkTile` (forum icon, author, a "Server" tag
chip, snippet, ⋮ → Add-to-folder/Remove, tap → `FeedPostScreen`). `forget` only
drops an id that is missing from BOTH stores, so a server post that's simply not
in the public feed is never culled. `FeedStore._savedIds`/`savedListings()` is
left untouched — it still backs marketplace saved-listings, a different feature.

## The marketplace is GLOBAL now (2026-08-08)

**Listings live on the server, not just locally** — a world-readable table
`market_listings` (`docs/public_market.sql`), so ANY account sees the whole
marketplace: a brand-new user in no servers, or a member who joined a server
after an item was posted. This REVERSES the old "no global listings database"
line (which made the marketplace a UI aggregation of the servers you'd joined,
each listing sealed under that server's secret — the reason "listings don't
show up for new members"). A marketplace listing is an ADVERTISEMENT: its
audience is everyone, so it follows the **public-feed rule** — plaintext the
server can read, because a board whose audience is everyone has no key to seal
under. Private chat, and a server's own sealed feed, are untouched.

- **The seller's phone is still protected**: the global row never carries it
  (`RelayService.publishMarketListing` does `post.toJson()..remove('authorPhone')`),
  the table revokes the table-wide select and hands back every column but
  `author_phone`, and clients read the phone-free `market_listings_view`. A
  buyer reaches a seller by **username** — which is already how `openSellerChat`
  / `_resolveSeller` resolve one (contact first, then the directory), so
  stripping the phone costs nothing.
- **Transport**: `RelayService.publishMarketListing` / `fetchMarketListings` /
  `deleteMarketListing` (Supabase client, so the authenticated JWT satisfies the
  RLS `author_phone = jwt.phone`). Hooked into the ONE funnel every listing
  mutation already uses: `sendFeedPost` publishes when `post.isListing ||
  post.mediaPart > 0` (covers create, edit, sold, reserved, and photo parts),
  `sendFeedDelete` removes the row. Fetched on relay start and pull-to-refresh
  (`requestFeedCatchup`), so a fresh install opens straight to a full
  marketplace. **Listings are marketplace-only** (owner's call, 2026-08-08):
  `sendFeedPost` publishes a listing/photo-part to the global table and RETURNS
  — a listing is NEVER sealed to a server feed or written to `community_posts`.
  Ordinary non-listing server posts still seal to their community as before.
- **Selling no longer needs a server**: the composer dropped the "Join or
  create a server first" wall and the "pick a server" error; a new listing's
  `_communityId` is '' (global-only), and the audience line reads "Anyone on Okay can find
  this…". Selling still needs a verified number (wallet + ID check) as before,
  so `publishMarketListing` no-ops for a numberless account.
- **Moderation**: RLS hides a banned/suspended seller's listings
  (`is_locked_out`), refuses a silenced account's write (`is_silenced`), and the
  composer still runs the `moderation-screen` speed bump at post time. Takedowns
  (moderation-act) are unchanged. `check_sql.sh` pins post-as-self,
  phone-unreadable, `select *` refused, edit-own-only, banned-seller-hidden, and
  anon browse. **RUN + verified live 2026-08-08** (`market_listings`,
  `market_listings_view`, phone-free view all confirmed via the Management API)
  — do not re-raise as pending.
- **Sell composer — tap a photo to set the cover (2026-08-08).** The "Cover"
  badge on the first photo used to be descriptive only; the sole way to change
  which shot led the listing was to delete the lot and re-add in order. Now
  tapping any non-cover photo in the composer's photo strip promotes it to the
  front (`photosWithCover`, a pure/tested helper → `_setCover`), and a
  "Tap a photo to make it the cover." hint shows once there are 2+. The cover is
  still just the first photo everywhere downstream (`_photos.first` → `photoUrl`),
  so nothing else changed.

## Banning a number + email from signing up (2026-08-08)

When a user is banned, keep their NUMBER and EMAIL from coming back
(`docs/banned_signups.sql`, after `platform_moderation.sql`).
- **Phone**: a ban already lives in `account_sanctions`; `is_phone_banned(p)`
  (definer, canonicalizes E.164 vs digits like the follow/admin lookups) is
  what the signup path calls. `PhoneLoginScreen._refuseIfBanned` checks it at
  `_sendCode` (OTP) and `_continueLocal` (instant) — a banned number is turned
  away at the door ("This number is banned"), not merely locked out after it
  signs in. Fails OPEN (a network hiccup never blocks a real new user).
- **Email**: there is NO server column mapping an email to an account (a
  verified email lives only in the encrypted backup blob), so a phone-ban
  cannot capture it automatically. Instead a `banned_emails` list (reachable
  ONLY through definer functions — never enumerable) is filled by an
  owner/admin via `ban_email(e)` (Moderation console → **Ban an email**), and
  `AccountEmail.setEmail` refuses anything `is_email_banned(e)` returns true for
  (`EmailSaveResult.banned`). `PlatformModeration.isPhoneBanned`/`isEmailBanned`/
  `setEmailBanned` wrap the RPCs (test hooks: `debugPhoneBannedOverride`,
  `debugEmailBannedOverride`, `debugBanEmailOverride`). `check_sql` pins the
  phone lookup, staff-only email ban, case/space-insensitive match, and that
  the list is not client-readable. **RUN + verified live 2026-08-08**
  (`banned_emails` + `is_phone_banned`/`is_email_banned`/`ban_email`/`unban_email`
  confirmed; canonicalization and case-insensitive match tested via the
  Management API) — do not re-raise as pending.

## Okay Score round 2: check-in streak, points breakdown (2026-08-08)

Two features added to `ScoreStore` + the score screen:
- **Daily check-in STREAK with an escalating bonus.** `dailyCheckIn` now tracks
  consecutive days (`checkInStreak`, persisted): a check-in the day after the
  last builds the streak, a gap resets it to 1. The bonus grows
  `checkInStreakStep` (5) per day up to `checkInStreakCap` (7) days —
  `checkInBonusFor(day)` (day 1 = `pointsPerDailyCheckIn` 20, day 7 = 50);
  `nextCheckInBonus` is what tomorrow pays. Seven in a row earns the new
  `checkin_week` badge. A `_CheckInCard` on the score screen shows the streak
  and tomorrow's bonus.
- **Per-source points breakdown.** `award(delta, {source})` tallies points by
  source (`_bySource`, persisted); `pointsBySource` returns labelled totals
  largest-first (`sourceLabels`), shown as a `_PointsBreakdown` card ("Where
  your points came from"). Every real award site now passes a `source`
  (message/call/reaction/poll/feed/forum/forumComment/listing/sale/daily).
- **Level-up notifier.** `award` fires `leveledUpTo` (a `ValueNotifier<int>`)
  when points cross into a new level, so a surface can celebrate it.
Behavioural tests pin the streak growth/reset + week badge, the by-source
tally, and the level-up notifier; the old daily-check-in test was updated for
the streak bonus.

## Bug pack: follow counts, group typing, group settings, added-you, demo seed (2026-08-08)

- **Follow counts agreed across devices.** The own "Following" number read the
  DEVICE-LOCAL `FollowStore._following` set, so two devices on one account
  showed different numbers. `FollowStore.followingCountDisplay` now prefers the
  SERVER graph's count (`_serverFollowingCount`, seeded from
  `public_follow_counts`) and falls back to the local set only until it answers;
  a toggle nudges it optimistically. The profile stat (own) and the sidebar both
  read `followingCountDisplay`, and `main.dart` seeds it at startup, so the
  number is the same everywhere. Followers were already server-sourced.
  **Round 2 (2026-08-09), "doesn't update properly":** (1) tapping
  Follow/Unfollow on someone's profile never moved their Followers stat — the
  count was a one-shot fetch. The header now shows the fetched snapshot PLUS a
  live ±1 delta (`_Header.followedAtFetch` vs `FollowStore.isFollowing`), so
  the number moves with the button, race-free (no timer; the next fetch
  replaces both). (2) The own-following seed was launch-only, so a follow made
  on another device stayed invisible until a cold start — `main.dart`'s
  foreground handler now re-seeds `noteServerFollowing` on every resume.
  **Round 3 (same day): the X-shaped follow lists.** `FollowListScreen`
  (`lib/screens/follow_list_screen.dart`) replaces the old bare bottom sheet:
  a full screen titled with whose lists they are, a Followers | Following
  `TabBar` (initial tab = the stat tapped), and a row per person — `FeedAvatar`,
  bold name, @handle, and a per-row Follow/Following button (FollowStore-live;
  your own row gets none). Rows open the profile; pull-to-refresh refetches.
  BOTH profile stats route here now — your own Following stat too (it used to
  open `PeopleScreen`, which still exists elsewhere).
- **Group typing no longer leaks to the 1:1.** A typing ping carried only the
  sender's phone, so a member typing in a group also lit the 1:1 tile/screen
  with that person. `sendTyping(phone, {groupId})` now carries the group id
  (wire field `g`); `noteTypingPing(digits, {groupId})` records `typingGroupId`.
  A group tile/screen matches on `typingGroupId == chat.id`; a 1:1 matches only
  when `typingGroupId` is empty AND the sender phone matches. `ChatScreen`
  sends `widget.chat.id` for a group.
- **More group settings.** `group_info_screen.dart` gained a visible management
  section: **Edit group** (name/photo/description → `openGroupEditor`), **Add
  members**, and **Disappearing messages** (Off/1 day/1 week/90 days →
  `ChatStore.setDisappearing`); the admin (roster index 0, resolved by identity)
  can **tap a member to remove** them (`updateGroup` + `sendGroupUpdate`).
- **"Added you to X" shown to the adder — hardened.** `add_server_members_screen`
  resolved the adder's own copy chat via a constructed `chat_<phone>` id that
  missed the real chat, so the adder-side "You added X" copy was skipped and only
  the recipient-worded wire text was ever seen. It now resolves by CONTACT
  (`chatWithContact`, id or phone) and `send()` never stores locally, so the
  adder always sees "You added X", never "Added you to X". **Needs a Codemagic
  build to reach the phone** — the deployed build predates the fix.
- **Demo/screenshot fixtures are admin/owner only.** `DemoSeed.available =
  enabled && PlatformModeration.canAdminister` — even a `DEMO_SEED` build only
  offers the fake data (and `populate()` only runs) for an admin/owner, never a
  real user. Settings gates on `DemoSeed.available`.

## Join a server with a code (2026-08-08)

Servers → **Join with a code** (the key icon in the Communities app-bar, and a
button on the empty state) opens a sheet to paste an invite code. The code is a
REAL, self-contained token now (`CommunityStore.inviteToken` →
`OKAY-<base64url(exportInvite)>`), carrying the server's identity, channels and
E2E **secret** — so decoding it (`CommunityStore.decodeInviteToken`, tolerant of
a bare code, a URL-wrapped one, or raw JSON) is all a device needs to join. No
server-side code registry: the old `inviteCode`/`inviteLink` were a one-way hash
with nothing to resolve them, and are no longer shown. Join reuses the exact
`joinFromInvite` + `sendServerJoin` pair a tapped invite card uses (roster +
SKDM converge, the #128 path). A **paid** server's code is refused with a nudge
to its invite card (the paywall runs the purchase there); an already-joined code
says so. The invite sheet now shares this token as the copyable "invite code".
Because the token carries the secret, it is as sensitive as the invite card —
the sheet says to share it privately.

## Community notes: reader fact-checks on the public feed (2026-08-08)

X-style Community Notes for the public newsfeed. A signed-in reader adds a NOTE
giving context to any public post; anyone rates a note helpful / not helpful;
a note enough readers find helpful is SHOWN on the post. `CommunityNote`
(`lib/state/community_note.dart`, pure) holds the model + the **consensus rule**
(`isShown` = ≥5 ratings AND ≥60% helpful; `topShown`/`ranked` pick what to
display). **Honest limit stated in-app + code:** this is a plain helpful-majority,
NOT X's bridging algorithm (which needs a cross-rater matrix this app doesn't
collect) — labelled "Readers added context", never "verified true".
- Store (`PublicFeedStore`): `notesFor` (from `community_notes_view`),
  `proposeNote` (screened by `moderation-screen` like a post, length-capped at
  280), `rateNote` (upsert, changeable). Test
  seams: `debugNotesOverride` / `debugProposeNoteOverride` / `debugRateNoteOverride`.
  **Adding OR rating a note needs FULL verification (2026-08-08)** — phone +
  email + ID, via `AccountVerification.fullyVerified` (see the verification
  section below). Reading notes is open; contributing to the fact-check layer
  costs an account that has proven who it is (was: numberless-only refusal).
  The store throws `_notesVerificationMessage` naming what's still missing; the
  UI (`CommunityNotesScreen._needsVerification`) shows a sheet with a **Verify**
  button → `VerificationScreen` instead of the old `postNeedsPhone` nudge.
- UI: `CommunityNotesScreen` (`lib/screens/community_notes_screen.dart`) —
  propose + rate + see status — opened from a post's ⋮ "Community notes".
  `CommunityNoteInline` shows the shown note under a post, but only when
  `focused` (the opened post) so the timeline never fans out a request per card
  (feed-view-carried inline notes are a follow-up).
- Server: `docs/community_notes.sql` — `community_notes` + `community_note_ratings`
  tables, definer helpful/not tallies, a phone-free `community_notes_view`, RLS
  (post/rate as yourself only, silenced refused, banned authors hidden). Same
  pattern as `public_forum.sql`. `check_sql.sh` pins: note-as-self,
  phone-unreadable, `select *` refused, ratings own-only, tallies off the view.
  **RUN + verified live 2026-08-09** (both tables + the phone-free view
  confirmed via the Management API; anon reads the view 200) — do not re-raise
  as pending. No new Edge Function.

## Verification lives in one place now (2026-08-08)

`AccountVerification` (`lib/state/account_verification.dart`) is the ONE reader
of all three signals — `phoneVerified` (real number behind sign-in, i.e.
`!isNumberless` on an enabled account), `emailVerified`
(`AccountEmail.isVerified`), `idVerified` (`IdentityVerification.isVerified`,
STRICT — not the permissive `allowsTrusted`) — plus `fullyVerified`, `missing`
and `missingSentence`. Test overrides: `debugPhoneVerified/EmailVerified/
IdVerified` + `resetForTest`. `VerificationScreen`
(`lib/screens/verification_screen.dart`) shows all three as one checklist with a
"$n of 3 verified" header and an action per row (phone → `NumberlessVerifyScreen`,
email → `AccountEmailScreen`, ID → `ScoreScreen`); Settings reaches it through a
single **Verification** row (replaced the three scattered `ProfileVerificationRow`
chips on the hub — the class still exists for the profile/type tests but is no
longer on the settings hub). Community notes are the first gate that requires all
three.

## Marketplace search covers category + attributes; wallet test-mode is admin-only; media likes (2026-08-08)

Three small fixes shipped together:
- **Marketplace search** (`listingMatchesQuery`, pure) now also matches the
  listing's **category** and its structured **attributes** (model, storage,
  size…), not just title/description/brand/place — a buyer typing "electronics"
  or "128gb" was getting zero results even with matching listings, which read as
  a broken search.
- **Wallet test/simulated payments** (`_TestModeTile` + the "Try test mode"
  button in `wallet_screen.dart`) are now gated behind
  `PlatformModeration.instance.canAdminister` — an ordinary buyer could flip
  real money into make-believe. The tile rides a `ListenableBuilder` so it
  appears once the (async) role loads.
- **Liking media in chat**: the fullscreen media viewer (`ImageViewScreen`,
  opened by tapping a photo/GIF bubble) had no way to react. It now carries a
  **Like** + **React** bottom bar, wired from `chat_screen._openImage` through
  `onToggleLike`/`onPickReaction` → the existing `_react`/`_pickReactionEmoji`.
  (There is no video message type in chat — only photos and GIFs, both
  `isImage`.)

## Group chats: who's seen it, and who's here now (2026-08-08)

Two group additions on top of the existing per-member read receipts (`seenBy`):
- **Seen-by is now always visible.** Under your newest OWN message in a group,
  a tappable line reads "Seen by everyone" / "Seen by N of M" / "Sent · tap to
  see who's seen it" (blue once anyone has) — opening the same `_showSeenBy`
  sheet (SEEN BY / NOT YET) that used to be reachable only by long-press.
- **Who's currently in the chat.** `GroupPresenceStore`
  (`lib/state/group_presence_store.dart`, live-only, never persisted/mailboxed —
  modelled on `VoicePresenceStore`) keyed `groupId → memberDigits → lastSeen`,
  heartbeat 15s / stale 40s. A viewing device fans a new **`gpres`** ping (carries
  only `{from, g: groupId}`) to `groupRecipients` via
  `RelayService.sendGroupPresence`, applied in `applyInboxEvent` (added to the
  sealed-roster test). `ChatScreen` broadcasts it on a group heartbeat and shows
  a green **"N here now"** in the header (else "M members"); the seen-by sheet
  gains an **"IN THIS CHAT NOW"** section + a green "Here now" dot next to
  present members. Names resolve from the roster, so no name rides the wire.
  Gated exactly like 1:1 presence (`AppState.shareLastSeen`, route-current, not
  a request). Live-only: a force-quit or backgrounded app ages out.

## A message says which key protected it (2026-08-11)

`Message.enc` — an [`EncryptionLabel`](lib/crypto/encryption_label.dart) code
recorded on the message, surfaced as a line in **Message info** in a 1:1/group
chat and in a **new Message info** entry on a server channel's long-press
sheet.

**Recorded, never inferred at display time.** The pairwise ladder CLIMBS as
keys arrive, so asking "how is this chat encrypted now" would re-label
yesterday's messages with today's answer — the flattering lie, and exactly
the one worth not telling about encryption. Incoming reads `payload['enc']`;
outgoing reads what `encode`/`sealContent` actually produced, in `send()`,
right where the seal happened.

**It only ever LOWERS** (`ChatStore.noteMessageEnc`). A group message is
sealed once per member and members are not all on the same rung, so recording
the last one would let one strong delivery vouch for a message that also went
out under the floor key. A message is exactly as protected as its weakest
delivery.

**Two ladders, one vocabulary.** Chat rides the four pairwise rungs (0
plaintext / 1 phone-derived / 2 static ECDH / 3 Double Ratchet); a server
channel rides the community bus, which carries **no `enc` field at all** —
`_onCommunityEvent` now tells its `apply` callback WHICH key opened the
envelope (sender key vs the legacy shared secret) and `_sendCommunityEvent`
returns the one it sealed with, or **null when nothing was sent**, so an
unsent message keeps saying "no record" rather than claiming a key it never
met. Codes **4 and 5 are local-only** and `EncryptionLabel.fromWire` refuses
them: a payload naming one is not a stronger message, it is a payload lying.

Copy rules, pinned by tests: the two answers that are **worse** than the
headline say so (`Not encrypted` names the relay; the shared server key names
"every member of this server holds"), the strongest claims only what it earns
("a key stolen later cannot unlock it"), and **no screen hand-rolls the
words** — a test fails if `chat_screen.dart` or `communities.dart` contains
the phrase "Double Ratchet", because two copies of that sentence is how one
of them ends up describing encryption a message never had. `unknown` covers
both real cases honestly ("never left this device, or stored before the app
began keeping track") — a note-to-self is not an old message.

Only `none`/`unknown` draw the open padlock, and only `none` is coloured; an
amber line beside every message would turn the strongest rung into a warning.

**And the three PUBLIC composers say the opposite** — `PublicContentNote`
(same file), one grey line with the same open padlock: "Anyone can read this
post — it is not encrypted." On the newsfeed composer (which serves new
post/reply/quote), the public forum's New post, and the marketplace Sell
form, where it REPLACED the old "Anyone on Okay can find this in the
marketplace." rather than sitting under it — the reach and the encryption are
one sentence, not two lines (a test that pinned the old string now pins the
widget plus the `never a server feed` comment). A **subscribers-only** post
swaps the subject to "Your subscribers", because the paywall narrows WHO, not
whether: the body is access-controlled so `moderation-screen` can still read
it, which is the documented reason paid posts are not sealed.

Justified against "copy says the thing once": every other composer in the app
seals before the text leaves the device, so *this one is too* is the
reasonable assumption, and it is wrong. Deliberately NOT on a server's own
feed, its forum board, a channel or a chat — those really are sealed, and a
test pins the widget OUT of those four files. A warning about a leak a
surface does not have is the worse direction of lie.

## Chat status ticks: sent / delivered / seen (2026-08-08)

The receipt machinery already existed (a `'receipt'` event with `kind`
delivered/read, auto delivered-ack on receive, read-ack on chat open,
monotonic `setOutgoingStatus`) — but delivered and read looked almost
identical (same `done_all` glyph, only a faint colour shift), so "seen" was
invisible. Now `MessageStatusIcon` renders read as a distinct **blue**
(`readBlue` = `0xFF34B7F1`, the WhatsApp/Messenger seen hue) — sending = clock,
sent = one grey tick, delivered = two grey ticks, read = two BLUE ticks — the
same on text, media (over the photo scrim) and view-once bubbles (the bubbles
no longer pass a `readColor`, so blue is the default everywhere). Plus a
**Facebook/Messenger-style status line** under the newest OWN message in a 1:1
(`chat_screen._buildItems`): "Seen" (blue), else "Delivered"/"Sent" — never in a
group (that's "Seen by"), never in notes-to-self, and only when your message is
the last in the thread. Honest limits carried over: read-receipt reciprocity is
cosmetic (disabling send still applies incoming), delivered receipts always
fire, and status is chat-wide prefix, not strictly per-message.

## Channel ticks: sent / delivered / read, sealed (2026-08-12)

Text channels never had the 1:1/group receipt machinery at all — a channel
message just stayed at whatever status the sender's own device gave it. This
extends the existing model rather than inventing a second one: channels get
the same coarse, "first responder" semantics the GROUP path already has (a
group chat's tick advances the moment the first member acks, not when every
member has), because a channel is far closer to a group than to a 1:1.

**A new sealed community-bus event, `chack`**, carries `{channelId, kind, id}`
(`kind` 'delivered'|'read'). It rides `RelayService._sendCommunityEvent` — the
sender-key-sealed, mailbox-fanned path every persistent structural event uses
— never the live-only `_broadcastCommunityEvent` that `chtyp`/`vpres` use,
because an ack has to reach the original sender even when they're offline at
the moment it's sent, or their ticks would only ever move while they happen to
be watching. Registered in both places a community event must be (the live
`.onBroadcast` chain and the mailbox-drain switch roster) — missing either
silently drops it, same discipline as every other community event.

- **Delivered fires automatically**, relay-side, the instant a channel message
  is genuinely new — `CommunityStore.addRemoteChannelMessage` was changed from
  `void` to `bool`, returning `true` only on a real first-time add, so a
  replayed mailbox copy (the mailbox keeps re-offering an undelivered row
  until it expires) never re-acks something already acked.
- **Read fires only when the channel screen is actually open and drawing** —
  `_ChannelScreenState._maybeSendChannelReadReceipt`, hooked into the same
  postFrameCallback that already drives the local `markChannelSeen` unread
  counter, and deduped per newest-incoming-id so reopening a quiet channel
  doesn't re-broadcast.
- On receipt, `_applyCommunityEvent`'s `chack` case calls
  `CommunityStore.setChannelOutgoingStatus` (upgrades every own message in
  THAT channel to at least the acked status — monotonic, never regresses, and
  scoped so an ack for one channel can't touch another in the same server) and,
  only for `read`, `noteChannelSeenUpTo` (records who, mirroring the "delivered
  is ticks-only, read names names" split `ChatStore.applyReceipt` already draws
  for a group).
- UI reuses the existing pieces rather than building new ones: `_ChannelBubble`
  draws `MessageStatusIcon` beside an own message's timestamp, and the newest
  own message in a channel gets the same tappable "Seen by N of M" /
  "Seen by everyone" line the group chat has, opening a sheet built from the
  server's own member roster (no channel-level presence store — that's the
  group chat's "in this chat now" feature, not asked for here, so it wasn't
  added).

## Sidebar destinations show a ☰, not a back arrow (2026-08-08) — SUPERSEDED

Reverted 2026-08-09 at the owner's direction: every pushed sidebar destination
shows a **normal back arrow** again (see "Navigation model (settled
2026-08-09)"). The `fromSidebar` flags still ride the constructors (callers
pass them) but no longer change the leading. Do not reintroduce the ☰.

## The UI should not look generated (2026-08-09)

The owner's words were "I want the UI to be less AI like", and four things
were making it so. All four are now rules, not preferences:

- **One radius scale.** `AppRadius.sm/md/lg` (8/14/20) in `app_theme.dart`.
  The app had TWELVE radii in use (6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26,
  30) — each defensible alone, and the set of them the reason the app read as
  assembled. Pick by what a thing IS (chip / card / panel), not by its size.
  A value off the scale needs a reason in a comment; circles are exempt.
- **The accent is ink, not violet.** A `#7A5CFF` had spread into nine files'
  CHROME — a gradient hero on the tip screen, score chips, the announcement
  card, two attach buttons — while the brand is near-black/near-white. Use
  `AppColors.accentOn(context)`. A test fails on `0xFF7A5CFF`/`0xFF5B3CE0`
  anywhere except three files where it is **data**: the bubble-colour palette
  (`chats_settings_screen`), the forum tag palette (`forum_screen`), and the
  fallback for a colour somebody else chose (`status_screen`).
- **No decorative gradient heroes.** A gradient panel with a big icon on it,
  restating the title already in the app bar, is the loudest tell. The tip
  screen now opens with a heading and two sentences; a test pins
  `LinearGradient` out of that file. Gradients that do a JOB stay — photo
  scrims, avatar fills.
- **Emoji are content, not chrome.** Emoji a user picked (reactions, role
  badges, stickers) are theirs. Emoji as functional UI — the tip tiles' ☕🍩🍕🎉
  standing in for labels — became text and icons.
- **Copy says the thing once.** Rows and sections carried a paragraph each.
  Keep an explanation only where it prevents a real mistake or App Review
  requires it; the honesty sentences on the tip screen (ads, subscriptions,
  "buys nothing", "the App Store confirms the exact amount") are pinned by
  tests and are NOT the padding to cut.

Done so far on the highest-traffic screens (tip, Store, settings, score,
contact info, Discover, communities). The rest of the app has not had the
pass — apply the scale as you touch a screen rather than in one sweep.

## A bubble's contents take the BUBBLE's colours (2026-08-09)

`VoiceNoteBubble` drew its play/pause control and the played half of its
waveform in the theme accent (`colorScheme.primary`). In **both** themes that
constant is exactly the outgoing bubble's background — dark paints `primary`
and `outgoingBubbleDark` the same `#E7E9EA`, light paints `primary` and
`outgoingBubbleLight` the same `#0F1419` — so a voice note you SENT drew its
button in the colour of the bubble underneath and vanished, while the same
widget on an incoming bubble looked perfectly fine. That asymmetry is why it
read as "sometimes".

The rule this leaves behind: **anything drawn inside a message bubble takes
`textColor`/`metaColor`, which the bubble already computes against its own
background (including a user's custom bubble colour). Never the app accent** —
that colour is chosen against the app background, and a bubble is not the app
background. A widget test pins the control's colour and a source pin keeps the
accent call out of the file.

## The media viewer is X-style (2026-08-08)

`ImageViewScreen` was a plain tap-to-dismiss photo box; it's now modelled on
X's media viewer. **Swipe down to dismiss** (the image follows the finger via
`_onDragUpdate`/`_onDragEnd` and the black backdrop fades with drag distance;
past ~130px or a flick it pops). **Tap toggles chrome** (the top bar + bottom
action bar slide away for an immersive look). **Double-tap zooms** to the tapped
point and back, over a `TransformationController` animated by a `Matrix4Tween`,
with pinch-zoom/pan on top via `InteractiveViewer` (`panEnabled` only once
zoomed, so the dismiss drag and the pan never fight — dismiss is off while
zoomed). Like/React live in the bottom bar (double-tap is the ZOOM gesture here,
as on X; the timeline bubble is still where double-tap-to-like lives). A liked
tap still pops a heart. No video message type exists in chat (photos + GIFs,
both `isImage`), so this covers all chat media.

## See who reacted to a chat message (2026-08-08)

Chat reactions were an anonymous flat `List<String>` of emoji — you could see
THAT a message had ❤️, not WHO. The reactor's phone already rode the wire as
`from` on the `'reaction'` event; the receiver just dropped it. Now
`Message.reactionsBy` (emoji → reactor digits, mirroring `seenBy`) records it:
`ChatStore.toggleReaction`/`setReactionState` take a `reactor` (empty = the old
anonymous behaviour for older wire), `applyMessageEvent`'s `'reaction'` case
passes `digits(from)`, and `chat_screen._react` passes this account's digits.
`reactions` stays the source of truth for WHICH emoji are present (an emoji
clears when its last reactor drops). Tapping the reaction pill — or the new
**"Reacted by"** row in the message long-press sheet — opens `_showReactedBy`, a
sheet cloned from `_showSeenBy` that lists each emoji with the people who added
it (resolved from the group roster / the 1:1 contact / yourself as "You").
Reactions from older builds have no names and say so honestly. In a group this
is how a member's device learns WHO reacted (every `sendReaction` stamps
`from`). Backward compatible: `reactionsBy` is additive JSON, older messages
just have an empty map.

## A name-only account can verify from anywhere it hits a wall (2026-08-08)

Every locked surface a name-only account taps offers an in-place verify, not a
dead-end: `PhoneGate` and the `postNeedsPhone` sheet both carry a **"Verify your
number"** button → `NumberlessVerifyScreen` → `Session.attachNumberInPlace`
(keeps the account + all on-device data). Settings also shows a **"Verify your
number"** row at the top for a name-only account, so it's reachable without
hitting a wall first. Rating/adding a community note routes through
`postNeedsPhone` too, so it nudges the same way.

## Unverified accounts are spam-limited, not trial-locked (2026-08-08)

NOT a timed trial (an earlier round built one; it was the wrong shape and was
removed). A name-only (numberless) account is **unverified** — trivially
minted, answers for nothing — so it's held to **tighter anti-spam limits**
until it verifies a number, rather than being locked out on a clock. It can
still use the app; it just can't blast.
- **Tighter caps in `AbuseGuard`:** `messageBlockReason` / `outgoingBlockReason`
  take `unverified:` and apply lower ceilings for a name-only account
  (`unverifiedMaxToOneRecipient` 8 vs 20, `unverifiedMaxNewRecipients` 3 vs 8,
  `unverifiedMaxBurst` 4 vs 6). `ChatScreen._deliver` passes
  `unverified: Session.instance.isNumberless`. The refusal copy nudges toward
  verifying.
- **The honest server limits still stand:** `PhoneGate` / `postNeedsPhone` /
  `PhoneOnlyHint` gate the server-session features (wallet, posting) off a
  name-only account exactly as before — reverted from the trial round back to
  raw `isNumberless`. A numberless account has no Supabase session, so those
  genuinely can't work until it verifies.
- **Verify = in-place upgrade, data kept, no forced lock:** the gate's
  "Verify your number" button (and the `postNeedsPhone` sheet's) push
  `NumberlessVerifyScreen`, which runs OTP (or, with no SMS provider, just the
  number) → `Session.attachNumberInPlace`. That moves the account-wipe owner
  marker to the new digits FIRST (so nothing reads it as an account switch and
  no data is parked/cleared), then re-points the profile identity from the
  account code to the number, carrying every other profile field — chats,
  servers, notes all kept. This replaced the old gate's "sign out and start
  over" dead-end.
Behavioural + source-pin tests cover the tighter unverified caps and the
in-place upgrade keeping the account.

## In-chat thumbs-up (2026-08-08)

`ChatInputBar` shows a one-tap 👍 button when the composer is empty (like
Messenger's like button) — once you're typing, the words are the reply, so it
hides. It fires the same `onSend` path as any message (so it rides the abuse
guard, sealing, delivery — all of it), sending '👍'.

## Abuse guard: spam, floods, bots, bad URLs, new-device (2026-08-08)

`AbuseGuard` (`lib/state/abuse_guard.dart`) is the device's anti-abuse layer.
All four parts are enforced ON THE DEVICE — honest ceiling, same as the AI
client rate limit: a hand-modified client can skip them, and a true ceiling
needs server-side limits the anon-key transport can't do without a backend
follow-up. What they stop is the ordinary abuse (accidental floods, a script
blasting bit.ly, a tap-farm minting accounts):
- **Blocked URLs** — `blockedUrlHosts` (bit.ly, tinyurl, cutt.ly, … link
  shorteners that HIDE where a link leads; t.co is deliberately NOT on it).
  `blockedUrlIn(text)` matches on host boundaries (so "orbit.lyric.com" is
  safe). Refused on SEND (chat funnel), and folded into `AppState.looksLikeSpam`
  so a stranger's shortener drops on receipt regardless of the links toggle.
- **Message rate limit + bot burst** — `messageBlockReason(toDigits)`: refuses
  hammering one person (20/min), blasting many NEW people (>8 distinct/min —
  existing conversations never throttled), and an inhuman burst (6 sends in 4s,
  the "non-human" signal). In-memory (resets on relaunch, by design).
  `outgoingBlockReason` = URL block then rate limit, the one call
  `ChatScreen._deliver` makes for real-peer / group sends; `noteSend` records
  after it's allowed.
- **Account-creation throttle** — `accountCreateAllowed` / `noteAccountCreated`,
  max 3 per device per 24h. Wired into the numberless signup and the local
  (no-OTP) phone signup. Device-scoped persistence (keys on
  `AccountWipe.keepKeys`, `abuse_guard.dart` is device-scoped in the switch
  test) so a switch can't reset the brake.
- **New-device sign-in flag** — `registerSignIn(digits, isSignup:)` records
  accounts seen on this install; a returning account signing in on an install
  it's never been on (isSignup false, not seen) → `Session.signIn` fires a
  local "New device sign-in" notification. Signup paths pass `isSignup: true`
  so a fresh account never self-flags. Local detection; alerting the account's
  OTHER devices in real time is a server device-registry follow-up.

## Verified reviews are bound to the buyer (2026-08-08)

The confirmed-purchase chip used to be earnable by anyone holding the sale
code: the seller minted a 6-digit code at the sold handshake, only its hash
rode the listing, and any review typing the code got the chip. A seller could
hand the code to a friend, or a leaked code could be reused. Now the code is
**bound to the buyer's handle**: `saleCodeHashOf(code, {buyer})` folds the
buyer's username into the hash, `mintSaleCode(listingId, {buyerHandle})` binds
to the buyer the seller marked sold-to (the handle NEVER rides — only the
combined hash does), and `addReview` confirms only when
`saleCodeMatches(..., buyerHandle: myUsername)` — i.e. the reviewer IS that
buyer, typing the code under their own handle. A different account with the
same code hashes to something else and stays an unconfirmed opinion. So the
chip is a genuine two-sided handshake: the seller chose the buyer (mint), the
buyer proves it (their handle + the code). `saleCodeMatches` falls back to the
old unbound hash so a sale to a handle-less account (or an older listing) still
confirms. **Honest ceiling:** a seller colluding with one specific account can
still stage a review — no local-first, E2E system without central escrow can
stop that; what's closed is codes leaking to or being reused by anyone else.

## Chat backup / storage: more user options (2026-08-08)

`BackupPrefs` (`lib/state/backup_prefs.dart`) + a **Backup options** section on
the Cloud storage screen give the user real control over the communal backup
(servers, posts, follows, places, notes, score, contacts — chats are separate,
under the user's own key, and never in this blob):
- **Back up now / Restore** buttons + a last-backed-up line.
- **Automatic backup** toggle. Off ⇒ `scheduleSync` no-ops, so nothing uploads
  until "Back up now". On ⇒ the responsive on-change debounce plus a periodic
  backstop, `CloudSync.maybeAutoBackup()`, fired from `main.dart`'s foreground
  handler when the chosen **frequency** (Daily/Weekly, `BackupPrefs.dueSince`)
  has elapsed since `lastSync`.
- **What's included** — per-category switches; `CloudSync.buildPayload` omits
  an excluded category from the blob (email is always carried — it's the
  recovery anchor, not a data category).
- **Delete all cloud data** — `CloudSync.deleteCloudData()` removes the communal
  blob AND the encrypted chat backup object and zeroes the quota meter; local
  data is untouched.
Wi-Fi-only was deliberately NOT added: there's no `connectivity_plus` in the
app, so the toggle couldn't be enforced, and an unenforceable control is worse
than none (the no-fake rule). Behavioural + source-pin tests cover the category
filter, delete, and the due/frequency logic.

## Tag people in a feed post (2026-08-08)

Both feeds already RENDERED `@mentions` as tappable spans (`FeedBodyText` →
opens the profile) and the SERVER feed's composer already offered tag-a-person
chips (`mentionCandidates` → `activeMentionPrefix`/`mentionMatches`, the pure
helpers in `feed_screen.dart`). The gap was the **public newsfeed composer**,
which had a plain field. It now shows the same chip row (`_ComposerState.
_mentionBar` in `public_feed_screen.dart`) while an `@` token is being typed —
candidates drawn from who you follow + contacts you've chatted with + authors
already on screen (no directory lookup, so it's offline-safe and reveals nobody
you don't know). Tapping a chip completes the `@handle` in place. One
`_Composer` serves new post / reply / quote, so all three gained it.
**Honest limit:** a feed-post mention does not PING the tagged person — the
public timeline is world-readable with no per-user delivery, so like the
server feed's posts it relies on the rendered, tappable mention rather than a
notification (a scan-on-load notifier would be a separate follow-up).

## Moderation roster: who's online + more (2026-08-08)

`usernames.last_seen` (added by `docs/admin_users.sql`) is stamped by
`AccountService.touchLastSeen()` → the `touch_last_seen()` RPC (definer,
resolves the caller by digits) on **sign-in** and every app **foreground**
(`main.dart` resume). Only the account writes its own; only staff read it (via
`admin_list_users`, which now returns `last_seen` + `updated_at`, still no
phone). A **name-only account has no session**, so it can never stamp — its
`last_seen` stays null and the roster reads "Never signed in here", which is the
honest answer. `AdminUser` gained `lastSeen`/`joined` + `online` (seen within
`onlineWindow` = 5 min); the moderation **Users** tab shows a green online dot,
a presence line, and a tap opens a **detail sheet** (verified, name-only,
deactivated, last seen, joined — everything the directory can honestly answer).
`check_sql.sh` pins the column and that an account stamps its own row. **Needs
the user's action:** re-run `docs/admin_users.sql` for the column + RPC.

## Name-only signup is one-way, and now says so (2026-08-08)

A numberless account has no number to recover it and no Supabase session, so
logging out / switching phones / deleting the app ends it for good. The
`_noNumberFields` step now carries a prominent amber warning, and
`_continueWithoutNumber` shows a **confirm dialog** ("This account can't be
recovered") that must be acknowledged BEFORE the account is created — discovered
up front, not the day they can't get back in.

## Profile changes reach contacts immediately (2026-08-08)

Profile fields (avatar, bio, badge, business/creator flags, …) have always
been shared by PIGGYBACKING on each 1:1 message (`from*` keys in `encode`,
applied on the receive path via `ChatStore.updateContactProfile`). The cost
was latency: a changed avatar or bio only appeared on the other side whenever
you next messaged them — "the chat takes time to update."

`RelayService.broadcastProfile()` closes that gap: it pushes the current
profile to every 1:1 contact NOW. Called fire-and-forget from the two edit
surfaces — `edit_profile_screen` (save) and `score_screen._setVerified`
(badge). It rides a new sealed inbox event, **`prof`**, carrying the same
gated `from*` bundle a message does; the receiver applies it through
`applyProfileUpdate` (in `applyInboxEvent`, so it's in the sealed roster the
test pins). It **only ever sends sealed** — a peer we can seal to is a peer on
a current build that HAS the `prof` handler, so a peer we can't seal to would
drop it anyway, and sealing avoids putting profile fields on the wire in the
clear (the thing the message path is careful not to do). Those older peers
keep getting the update the old way, on the next message. Like the message
path, `prof` deliberately does **not** change a contact's NAME (a contact
never renames itself on your device) and starts no conversation (an existing
chat only). Behavioural + source-pin tests cover it.

## Tap-to-pay NFC — wired on TAG, awaiting a device build (2026-08-08)

`ios/Runner/NfcPay.swift` holds a real **CoreNFC** read/write implementation
(`read` returns a tag's URI/text record, `share` writes a pay link onto a blank
tag), wired in `AppDelegate` (`OkayNfcPay`). The Dart/UI is complete: Wallet →
"Tap to pay" reads a tag and routes it via `IncomingLinks.addTarget` →
`openChatForPhone`; Receive → "Write an NFC tag" and My QR → "Write a contact
tag" write a `okaymsg://…` link to a sticker. `nfc_pay.dart` is a transport only
(a test pins no chat/relay/crypto tokens).

**It reads/writes NDEF through the TAG protocol, on purpose.** Adding
`com.apple.developer.nfc.readersession.formats = [NDEF]` FAILED the App Store
upload (error 90778, twice): the **Xcode 26 SDK at min-iOS 13 demands `TAG` and
DISALLOWS `NDEF`** in that entitlement. So the reader is **`NFCTagReaderSession`**
(polling ISO 14443 + 15693), not `NFCNDEFReaderSession` — a detected `NFCTag`'s
associated value conforms to `NFCNDEFTag`, which is where `queryNDEFStatus` /
`readNDEF` / `writeNDEF` live. The entitlement is `[TAG]`,
`NFCReaderUsageDescription` is back in Info.plist, and `available` returns the
real `NFCTagReaderSession.readingAvailable`. **Do NOT switch the entitlement
back to `[NDEF]`; it will re-break the upload.**

**Still unverified here — the only test is a device build.** There is no Xcode
on this Linux box, so the Swift has never compiled and no phone has held a tag
to it. The Flutter gates cannot catch a Swift mistake (this is the class of bug
that has broken the archive before). Two things must go right on the user's side:
(1) a Codemagic archive succeeds with the `[TAG]` entitlement, and (2) the
**Near Field Communication Tag Reading** capability is enabled on the
`com.okaymessaging` App ID in the developer portal (and the stale provisioning
profile deleted so Codemagic mints a fresh one). If the archive fails again,
that is where to look first. Honest iOS limit remains: an iPhone can read/write
a tag but can't BE one (no third-party HCE), so it's sticker-based, never
phone-to-phone — QR is the phone-to-phone path.

Separately, App Store's warning that min-iOS 13 must become **15** by Spring
2027 is DONE — the floor was raised on 2026-08-09 (see the iOS API
availability section). Like everything else in this file that touches the iOS
project, it is unverified until an archive runs.

## The directory stops handing out phone numbers (2026-08-10)

Found while auditing what a username search returns. Two doors, and the
second made fixing the first theatre:

1. **`find_people(q)` is granted to ANON and returned `phone` per row.** A
   two-character prefix answered 25 rows, so ~1,300 queries with nothing but
   the publishable key — which ships in the web build — walked the handle
   space collecting real E.164 numbers.
2. **`usernames_read` was `for select to authenticated using (... or not
   is_locked_out(phone))`** — any account that could sign up could then select
   the WHOLE table, phone column included, unbounded.

`docs/directory_phone_privacy.sql` fixes both. `find_people` returns a phone
**only when `q` is the EXACT handle** (a prefix is a browsing result and names
no numbers); `usernames_read` narrows to the caller's OWN row. Everything that
used to read across other people's rows moved to a definer function answering
one question: `username_status` (free/mine/taken, never who),
`find_people_by_hashes` (contact sync — the caller hashed numbers out of its
own address book, so the hash IS proof it already holds them; capped at 500),
`is_on_app`, `username_for_phone`.

**Why the anon door can't just be shut:** sign-in by username happens signed
OUT, and `accountForUsername` needs the number to send a code to it. That is
the whole reason for the exact-vs-prefix seam.

Client: `_rowToUser` treats a phone-free row as normal (keyed on `'@handle'`,
avatar colour derived from it) instead of returning null, `resolvePerson`
asks by exact handle when somebody actually picks a person, and the table
fallbacks are **gone** — a direct select now answers only your own row, so a
fallback would return nobody rather than erroring. `find_people_screen` and
the moderation console resolve on pick; the marketplace already asked by
exact handle.

**`find_people` is now defined THREE times across the migrations** —
`directory_numberless.sql`, then `account_lifecycle.sql` (adds the `hidden`
filter), then this one. Replacing it without copying every earlier `and`
quietly reactivates everybody who deactivated; `check_sql.sh` caught exactly
that here. Whatever redefines it next: copy all four conditions.

**Still open, stated rather than implied.** Exact-handle resolution is
unmetered — enumerate handles, then ask once per handle, and numbers come out
one at a time. Far slower and far more attributable than 25-at-a-time, but a
cost increase, not a wall. A wall needs per-caller rate limiting, and a
SECURITY DEFINER function cannot see the caller's IP, so it belongs in an
Edge Function. That is the follow-up.

**RUN + verified live 2026-08-10.** Before: `find_people('su')` answered 3
rows with 3 real numbers. After: 3 rows, **0 numbers**, an exact handle still
resolves (sign-in by username intact), `usernames_read` reads
`(phone = (auth.jwt() ->> 'phone'))`, and all four filters are still in the
function body. Do not re-raise as pending.

**`revoke ... from public` DOES NOT REVOKE anon on this project**, and it cost
a security hole that only the live probe caught. Supabase's default privileges
on schema `public` grant EXECUTE on every NEW function to `anon` and
`authenticated` outright; revoking the PUBLIC pseudo-role leaves those explicit
grants standing. `find_people_by_hashes` — which turns phone hashes back into
numbers — came out anon-callable, i.e. a 500-guesses-a-call oracle for a
signed-out caller. Fixed with an explicit `revoke ... from anon`, and
`check_sql.sh` now asserts the GRANT rather than calling the function, because
the throwaway Postgres has no such default and can never reproduce this.
**Name the role when revoking; always verify a new function's grants live.**

## Waiting on the user (nothing here is code)

0c. **Ads (2026-08-04):** AdMob banners on the two PUBLIC surfaces only
   (newsfeed + marketplace) + native cards inside the newsfeed timeline
   (every 8 posts, never trailing — `AdService.timelineWithAds`),
   non-personalized (`npa=1`, no ATT), OFF in release until
   `ADMOB_BANNER_IOS`/`ADMOB_NATIVE_IOS` exist in the Codemagic `test`
   group; debug shows Google's labeled test ads, and `ADMOB_TEST_ADS=true`
   in that group makes a RELEASE build show them too (owner's placement
   check while AdMob verification blocks real fill — remove before App
   Store release; a real id always beats it). `google_mobile_ads` is a NEW
   POD — first suspect if a build fails. The build scripts strip ALL
   whitespace from UI-sourced variables: a trailing newline pasted into a
   Codemagic field made flutter read the whole `--dart-define` as the
   build target ("Target file ... not found", reproduced + fixed
   2026-08-04). The real App ID is in Info.plist. `web/app-ads.txt` ships
   with the web build; AdMob's crawler only reads the DOMAIN ROOT of the
   store listing's website, so full verification needs the user's
   `kingimann.github.io` repo (told them) and the App Store listing to
   exist. A test pins ads out of every chat file.

0b. **`docs/community_posts.sql` is RUN** (verified live 2026-08-04 by an
   insert/select/delete probe — do not raise again). Server feed posts +
   marketplace listings keep a DURABLE sealed copy in `community_posts`
   (ciphertext under the community secret — server reads nothing; chats
   deliberately excluded). Fetched on relay start and pull-to-refresh.

0a. **TURN relay is LIVE** (verified 2026-08-04: the deployed
   `turn-credentials` function answers 5 Metered servers with credentials
   — do not re-raise setup). History: the free public relay was dead
   (user's Check call setup screenshot, STUN green / relay red), fixed via
   metered.ca + `METERED_DOMAIN`/`METERED_API_KEY` secrets; a 401 there
   means the key/domain pair went stale, and the function's empty answer
   carries a `note` naming the fault. The iOS build must postdate
   2026-08-03 evening for the phone to FETCH credentials; Check call setup
   verifies end-to-end.

0d. **Admin power pack — DONE, verified live 2026-08-09.** `roles-set` is
   deployed, and the deployed `moderation-act` body contains the `takedown`
   action, so the re-paste happened. Do not raise either again.

0. **Delete/deactivate account — DONE, verified live 2026-08-09.**
   `usernames.hidden` exists and `delete-account` is deployed. Do not raise
   again.

**SQL + FUNCTIONS RUN LIVE, 2026-08-11 — the backlog is empty again.**
Applied and verified against the real project (`trbdqucphtsstnrwwfnw`) with
the owner's own token, then the token was revoked:

* `docs/public_forum_comment_votes.sql` **RUN** (it was the only migration
  added since the 2026-08-09 audit). Verified after: the table and the
  `public_forum_comments_v` view exist, RLS is on with 2 policies, `anon`
  **cannot** select the vote table (so who voted stays private), `anon` can
  read the view and execute `public_forum_comment_score`, and the view's
  columns carry **no `author_phone`**. Forum comment voting is live.
* **`sports` DEPLOYED** (v1, ACTIVE) via the multipart endpoint with the
  paste copy — it was the one function in `supabase/functions/` that had
  never been deployed. **`verify_jwt` is FALSE**, deliberately: the Sports
  screen is reachable by a name-only account, which has no Supabase session,
  and the publishable key is not a JWT — the same posture as
  `turn-credentials`, which is also a proxy holding a provider key. Probed
  live: it answers `{"configured":false,...}` until `SPORTSDB_API_KEY` is
  set, which is exactly what the screen turns into "Scores aren't set up
  yet". The cost of JWT-off is that the endpoint is reachable by anyone who
  finds it, so it can burn the provider quota; `MAX_LEAGUES` and the
  sequential fetch bound the blast radius, and a per-caller cap is the
  follow-up if it ever matters.
* **Everything else re-verified**: every table, view, function and column
  named by every documented migration exists (one query, zero missing), the
  deployed function list matches the repo exactly with nothing extra, and
  the six `verify_jwt=false` functions are still exactly `pages`,
  `payments-webhook`, `iap-notify`, `payments-payout`, `moderation-screen`,
  `turn-credentials`.
* **The two security regressions this file warns about are still closed**:
  `find_people_by_hashes` is NOT anon-executable, and neither
  `market_listings.author_phone` nor `server_directory.owner_phone` carries
  a SELECT grant for `anon`/`authenticated` (they hold INSERT/UPDATE/
  REFERENCES only, which a seller needs to write their own row — count the
  PRIVILEGE, never the row, or this reads as a leak when it is not).

**The Management API blocks `Python-urllib`** (Cloudflare 1010 on POST, while
GET succeeds — a browser-signature ban, not auth). Use `curl` with
`--data-binary @file` for the query endpoint.

**FULL SERVER AUDIT, 2026-08-09.** Every function in `supabase/functions/`
is deployed (checked by diffing the directory against the Management API's
function list — the difference was empty), and every documented migration's
objects exist: all the tables above plus the column-only ones that a table
check would miss — `usernames.hidden`, `usernames.last_seen`,
`public_posts.edited_at` / `.gif_url` / `.video_path` — and the functions
`touch_last_seen()` and `public_paid_body()`. **The SQL/paste backlog is
empty.** What genuinely remains below is the Codemagic build, the App Store
Connect products, and the Codemagic/AdMob variables — none of which is SQL.

**Re-run in full, 2026-08-09 (second pass).** All 23 migrations were applied
again in `check_sql.sh` order — 0 failing — and all 32 Edge Functions
redeployed from `docs/edge_functions_paste/` — 0 failing. Two things worth
keeping: the migrations are safe to re-run (scanned first — every `delete`/
`insert` is inside a function body, and the one top-level insert, the
`public-media` bucket, is `on conflict do update`), and **`verify_jwt` must be
carried per function on a redeploy**, read from `GET /v1/projects/{ref}/
functions` first. Six run with JWT OFF — `pages`, `payments-webhook`,
`iap-notify`, `payments-payout`, `moderation-screen`, `turn-credentials` — and
letting the deploy default them back to `true` would break the Stripe webhook
and the landing pages. Verified after: `pages` 200 HTML, `turn-credentials`
answers real Metered servers, `moderation-screen` answers
`{"verdict":"ok","configured":true}`.

Carried across several sessions; none of it can be done from this box. The
SQL/bucket/function facts below were re-verified live on 2026-08-03 by
probing with the anon key (a missing column answers 42703, a missing bucket
404s, a missing function 404s) — trust them over older notes.

1. **Start a Codemagic build.** Everything since the last one is unbuilt,
   including ~115 lines of new Swift (`okay/screenshot`, the capture observer,
   the app-switcher cover) plus `Mesh.swift` and `NearbyFast.swift`, which have
   still never been compiled anywhere.
2. `docs/payment_controls.sql`, `docs/public_feed.sql` and
   `docs/identity_backup.sql` are RUN (the `note` column, the view's spark
   tallies, and the identity-backup table + RPCs all answer live — done, do
   not raise again). When probing feed columns, ask the **`public_feed`
   view**, not `public_posts`: the tallies are view columns computed by the
   counter functions, and probing the table reads as "sparks missing" when
   nothing is.
3. The three Storage buckets (`voice-notes`, `chat-backups`,
   `market-media`) EXIST — verified 2026-08-03 by a tiny upload+delete, the
   only probe that works: they are PRIVATE buckets, and the public-object
   endpoint answers "Bucket not found" for a private bucket that exists,
   which misled a whole session. Done, do not raise again.
4. The payments functions + `push-send` were re-pasted 2026-08-03 (user
   said; versions cannot be read through the JWT gate from here).
5. `KLIPY_API_KEY`, `moderation-screen` (+`OPENROUTER_API_KEY` since
   2026-08-04 — it classifies via OpenRouter now, `openai/gpt-4o-mini`
   default, `OPENROUTER_MODEL` overrides; needs a re-paste to take
   effect), and the Pages
   Source setting: the user said to IGNORE these (2026-08-03) — do not
   raise them unless asked. GIF search stays off and image moderation
   fails open until they choose otherwise.
8. `pages` is DEPLOYED with JWT off (answers 200 unauthenticated — done, do
   not raise again). What cannot be checked from here: whether
   `…/functions/v1/pages/email-confirmed` was added to Supabase →
   Authentication → Redirect URLs; confirm before shipping a build.

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
  KLIPY key. **The wiring is done** — `codemagic.yaml` and `deploy-web.yml`
  both pass `--dart-define=KLIPY_API_KEY=…` — so what is left is putting the
  key in the Codemagic **`test`** variable group and in the GitHub Actions
  secret of the same name. Deliberately not in the repo: it ends up in the
  binary either way, but a key in git history is public to everyone who ever
  clones. From `partner.klipy.com/api-keys`. Without it the GIF tab says so; emoji and
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
  (`MeshPacket.maxBytes`, because a photo is a minute a hop). **Background is
  ON** (the user chose it): `bluetooth-central` + `bluetooth-peripheral` ride
  in `UIBackgroundModes`, so the radio keeps listening while the app is
  backgrounded, and an Okay Drop offer arriving then posts a LOCAL
  notification (`PushService.localNotify` — no server anywhere in a Drop).
  The costs stay what they were: a backgrounded iPhone advertises in the BLE
  overflow area (slower discovery, iOS-to-iOS only), the MPC fast link does
  not run in background, and App Review may ask what the modes are for. Servers ride it
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
