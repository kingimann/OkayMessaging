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

**What's missing is proof, not code — and now it's missing one Codemagic
build, not even that.** Unlike every other feature in this file, this one
still has no "RUN + verified live" entry, because that entry can only be
written after a real device shows a decrypted preview, and the fix (below)
already shipped — nothing further is owed to the Apple Developer Portal.
Reported 2026-08-12: a user's regular
contacts (so key exchange isn't the gap) still show generic alerts with
Private notifications off (so that setting isn't the cause either), and the
user confirmed they build and test from a current Codemagic build (so a stale
binary isn't it either). That narrowed it to two remaining suspects, both now
closed out:

1. ~~**The deployed `push-send` matching the repo.**~~ **RUN + verified
   live 2026-08-12** — redeployed from a freshly regenerated
   `docs/edge_functions_paste/push-send.ts` (version 28 → 29, content hash
   changed, `verify_jwt` preserved as `true`). Two live probes confirm it
   boots on today's code rather than an old or broken one: a malformed
   call answers `{"error":"bad request"}` and an unauthenticated
   `what:"check"` answers `{"error":"unauthorized"}`, both exact matches
   for lines that sit right beside the sealed-preview logic — the whole
   file has to parse and boot for either to fire. This was NOT the cause
   here, but it's worth knowing the Management API's function list exposes
   an `ezbr_sha256` per function, which is what made "did this redeploy
   actually change anything" checkable rather than assumed.
2. ~~**Keychain Sharing provisioning.**~~ **CONFIRMED live 2026-08-12, and
   FIXED the same day — this really was a code bug, not a portal
   setting.** The new self-test below was run on a real TestFlight build
   and the "Shared keychain" step failed with `PlatformException(Unexpected
   security result code, Code: -34018, Message: A required entitlement is
   not present., -34018, null)` — `errSecMissingEntitlement`. Every step
   above it passed (server, signed in, identity keys), isolating the fault
   to exactly this one write.

   **First guess was wrong and is recorded here so it isn't repeated:**
   this file originally sent the owner to the Apple Developer Portal to
   enable a "Keychain Sharing" App ID capability, on the assumption it was
   the same class of bug as NFC's `[TAG]` entitlement. The owner reported
   back that no such capability exists to enable — correctly; unlike NFC
   or Push, keychain sharing groups are not gated by a portal-side App ID
   toggle at all, they are handled entirely by entitlements and code
   signing. That correction is what led to the real cause:

   **The real bug: `$(AppIdentifierPrefix)` doesn't mean anything inside
   compiled source.** It is an Xcode BUILD-SETTING substitution, expanded
   only when Xcode processes an `.entitlements`/`.plist` file — never
   inside a Dart or Swift string literal. `NotificationService.swift` had
   `static let keychainGroup = "$(AppIdentifierPrefix)com.okaymessaging.shared"`,
   which Apple's Keychain Services read as the literal, un-substituted text
   — never equal to the real, resolved group the entitlements file signs
   with (the team ID followed by that suffix). Worse on the write side:
   `PreviewKeyStore` passed `groupId: 'com.okaymessaging.shared'` — the bare
   name with no team-ID prefix at all — straight through to
   `kSecAttrAccessGroup`, which is exactly what produced this error: the OS
   was asked for an access group that, spelled that way, does not exist.

   **The fix needs no team ID anywhere in this codebase, and needs nothing
   from the owner.** Confirmed against Apple's own documented Keychain
   Services default: when an app's `keychain-access-groups` entitlement has
   exactly one entry — true for both `Runner.entitlements` and
   `NotificationService.entitlements` here — that entry is used
   automatically whenever `kSecAttrAccessGroup` is left unset, on both the
   read and write ends. So both sides now omit it entirely instead of
   trying to reconstruct the resolved string. `PreviewKeyStore.accessGroup`
   and the bare name in the Swift file's comments still exist so a test can
   pin that all three files (Dart, Swift, both entitlements) name the same
   group — they are no longer passed to any Keychain Services call. A
   regression test pins that neither side names `kSecAttrAccessGroup`
   again.
3. **A second, independent fault, found the SAME day after this fix
   shipped and the owner reported "Shared keychain" now passes but the
   notification still says the fallback.** That exact combination — the
   write confirmed working, the banner still generic — is what the
   self-test's own honest-limits text warns can't be told apart from a
   real extension bug without checking the lock screen, so the extension
   source got a line-by-line re-read rather than assuming fix 2 alone
   would be enough.

   `PreviewKeyStore` writes a base64-encoded STRING through
   `flutter_secure_storage`; that plugin's Swift side stores a string by
   its **UTF-8 BYTES verbatim** (`value.data(using: .utf8)`) — so what
   actually sits in the keychain is the base64 TEXT of the 32-byte key
   (44 bytes as UTF-8), never the 32 raw bytes themselves.
   `NotificationService.previewKey(forSender:)` checked `data.count == 32`
   on the raw retrieved `Data` directly — 44 is never 32, so that guard
   was **false for every real key, every time**, entirely independent of
   the keychain-group fault. `previewKey` always returned `nil`, and the
   extension always fell through to the safe fallback — which, for a text
   message with the recipient's own Private-notifications setting off,
   *is* the literal words "New message" (`RelayService`'s own comment: "a
   type at best… for a plain text message the literal string 'New
   message'"), making a silently-never-working extension indistinguishable
   from the un-patched app on the one signal available: the banner's own
   words.

   **Why the test suite never caught it:** the one test exercising this
   round trip (`the key the app stores is the key the sender sealed
   with`) uses `PreviewKeyStore.debugWrites`, an in-memory Dart map — the
   TEST ITSELF calls `base64.decode(stored)` to recover the key, correctly
   modeling what the Swift code SHOULD have done, never touching the real
   native storage layer where the bug actually lived. A test double this
   exact and this wrong is worth naming: it modeled the fix, not the bug.

   **The fix:** `previewKey` now decodes the retrieved `Data` as a UTF-8
   string first, THEN base64-decodes that string into the real 32 raw
   bytes — matching what `flutter_secure_storage` actually round-trips. A
   regression test pins both calls (`String(data:encoding:.utf8)` then
   `Data(base64Encoded:)`) directly in the Swift source, since nothing
   Dart-side can exercise the real storage format to catch a regression.

**Both fixes need a new Codemagic build to reach a device** — nothing about
either can be verified from this box. Run it, then Settings → ADMIN TOOLS →
Check notification preview again: "Shared keychain" passing confirms fix 2;
the lock screen actually showing the test sentence (not just "Test push:
Sent" in the self-test, which only confirms the server accepted it) is the
only thing that confirms fix 3, and is the real end-to-end proof this whole
section has been missing.

`docs/push_notifications_setup.md` was never updated for any of this — it
still says a muted chat "needs a Notification Service Extension, which is a
separate target," present tense, as if one doesn't exist. Update that doc
once a preview is confirmed showing the real text on a real phone, rather
than before.

**"Check notification preview" self-test, added 2026-08-12.** Settings →
ADMIN TOOLS, beside "Check push setup" — the tool the debugging above was
missing. `NotificationPreviewSelfTest` (`lib/state/
notification_preview_diagnostics.dart`) sends this device a REAL test push,
sealed the same way `RelayService.send` seals one, through the real
`push-send` pipeline, with the sentence "If you can read this, the
encrypted preview is working." rather than inventing a fake result.

**Why the keychain write is checked separately from sending the push.** The
extension's own design makes every failure look identical on purpose (a
wrong banner is worse than a vague one), so this self-test surfaces the one
thing IT can actually observe: whether the shared keychain group is
writable by the main app process right this moment.
`PreviewKeyStore.testWrite()` does the SAME write `remember()` does, but
bypasses `_unavailable` — the flag that latches true on the first failure of
the whole app run and never retries, which is correct for the real feature
(no per-contact try/catch spam) and wrong for a diagnostic asking "is this
true RIGHT NOW." A keychain failure is reported as a provisioning fault,
explicitly NOT something fixable from a phone setting — see the
`errSecMissingEntitlement` entry above for what that actually turned out to
be, and why the verdict text now points here rather than at a nonexistent
Developer Portal capability.

**The one thing it cannot prove: whether the EXTENSION can read what the app
wrote.** A successful write from the main process doesn't guarantee the
extension's own view of the "same" shared group can read it back — that's a
different process with its own provisioning. So the verdict always ends by
asking the owner to look at the actual lock screen for the test sentence,
and says plainly what a generic alert despite every check passing would mean
(the fault is on the extension's side of the keychain, not the app's).

**One automatic retry on "sent:false" (found 2026-08-12), because a real
device showed exactly the race it exists for.** Reported live: "sometimes
the test push is red and when I restart the app it's green again." That
symptom has a precise cause in `PushService.register()`'s own documented
behavior: iOS re-issues an APNs token on every launch, and `PushService`
re-uploads it to `push_tokens` through an async round trip — a genuine,
expected, self-resolving race this self-test can easily outrun if it is run
right after opening the app, since `push-send` answers `{sent:false}`
whenever that row has no current token yet. Restarting doesn't fix
anything; it just gives the ALREADY-IN-FLIGHT upload from the earlier
launch more wall-clock time to land before the next check.

Two layers, addressing the actual causal chain rather than papering over its
symptom:

1. **Wait for the real precondition BEFORE the first attempt.** If
   `PushService.instance.tokenReceived` is false when `run()` reaches the
   send, it polls (every `tokenPollInterval`, 500ms) for up to
   `tokenWaitTimeout` (8s) rather than firing a send very likely to find
   `push_tokens` with nothing current — a bounded wait for the actual thing
   being waited on, not a fixed delay unrelated to how close the token
   registration actually is. Skipped entirely once a token is already known
   (the common case once the app has been open a moment).
2. **One retry after `retryDelay` (3s)** if the send still comes back
   `sent:false` with no thrown exception — covers the shorter residual gap
   between the token arriving locally and the Supabase upsert actually
   committing. A thrown error is a harder failure neither wait helps with,
   so only the non-throwing "not confirmed" case retries.

The verdict reads `PushService.instance.tokenReceived` (by then reflecting
whatever the WAIT settled on) to tell the race apart from a real fault in
words: "this device has not confirmed a push token since it was last
opened" names the race explicitly — meaning the wait timed out too — distinct
from "check push setup first" for a `sent:false` with a token that WAS
confirmed, which means something else is actually wrong. Both the "Test
push" step and the verdict say when a retry happened, so a genuinely-passing
report never reads as silently different from a first-try pass. All three
timings (`retryDelay`, `tokenWaitTimeout`, `tokenPollInterval`) are test
seams for the same reason: a test sets them to zero rather than actually
pausing.

Same shape as every other self-test in the app: pure `stepsFor`/`verdictFor`
functions (tested without a keychain or a server) feeding the shared
`SelfTestScreen`. `canAdminister`-gated, tested alongside the other three
admin probes in the same widget test.

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

**Flat, and now offered in a 1:1 too (2026-08-12, the owner's call —
reverses the original "groups only").** "Reply in thread" is still hidden
from INSIDE a thread (a thread of threads is a second place to lose a
conversation, in a group or a 1:1 alike) — that half of the reasoning never
changed. What changed is the other half: a 1:1 was denied threading on the
theory that "the room is the two of you, there is nothing to spare it from,"
and the owner asked for it back once they actually tried it and missed it —
two people can just as easily be mid-argument about flights while also
wanting to talk about dinner, and a thread lets one wait without the other
scrolling past it. Nothing in the mechanism was group-specific to begin
with: `_messages`' filtering, `_openThread`, the thread header, and the
"N replies" line were already written against `widget.chat` generically —
the ONLY gate was the `if (widget.chat.contact.isGroup && ...)` on the menu
item itself, so enabling it was a one-line change. The header still says
"Thread · Stays out of `<name>`" (a group's name or a 1:1 contact's, whichever
this chat is), because the same avatar and name as the room it hangs off of
would leave somebody typing into a side conversation believing it was the
main one. The menu subtitle now reads "the main group" or "the main chat"
depending which kind of room it is, so the wording never lies about which
room a reply is being kept out of.

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

**City name + more detail (2026-08-12), and the coarsening is still real.**
The screen and the "Share weather" composer insert used to name no place at
all ("Weather here") because — as the code said at the time — the app did no
reverse geocoding. That was true only in the narrow sense that WEATHER never
called it; `lib/util/geocoding.dart` already reverse-geocodes elsewhere (Maps,
marketplace, share-location) via **Photon** (Komoot's OpenStreetMap-backed
geocoder, keyless, the same provider search already uses). `WeatherService.
cityFor` wires it in, but only after re-running [`coarsen()`] on the position
— it reverse-geocodes the SAME ~11km-rounded point already sent to Open-Meteo,
never the raw fix, so naming a town costs nothing beyond what the forecast
request already leaks. **And it names a town, never an address**: Photon's
own reverse lookup returns the single nearest OSM feature (a shop, a house) at
whatever coordinate it's given, which for an already-coarsened point would be
a false precision — a specific address the rounding was built to avoid ever
sending. `localityLabel()` (`geocoding.dart`) reads only the admin-hierarchy
tags (city/town/village/county, then state/country), never street or POI,
regardless of what feature Photon actually snapped to. Both call sites
(`WeatherScreen`, `ChatScreen._handleShareWeather`) fall back to no name /
"Weather here" on any lookup failure — offline, provider down, rural
coordinate with no locality tag — rather than blocking or guessing.

The forecast request itself grew four fields, all free and keyless on
Open-Meteo's existing anonymous tier: `wind_direction_10m` and `precipitation`
(current), `uv_index_max`/`sunrise`/`sunset` (daily). `windDirectionLabel()`
reduces degrees to an 8-point compass (a forecast is not a sailing chart, so
16-point reads as invented precision) and `uvLabel()` maps the index to the
standard EPA/WHO exposure bands (Low/Moderate/High/Very high/Extreme). The
old single "Feels like … humidity … wind" line became a wrapped row of short
chips (`_DetailGrid`) so the new fields have room without truncating on a
narrow phone.

**Multiple cities (2026-08-12).** A tab strip across the top of the screen
(`_CityTabs`) — "My location" plus every saved [`WeatherCity`], plus an
add button — lets someone track other places besides where the phone is.
`WeatherCitiesStore` (`lib/state/weather_cities_store.dart`) persists the
list, modelled directly on `SavedPlacesStore`: `ChangeNotifier` +
`SharedPreferences`, a `maxCities` cap (10 — a tab row stops being usable
well before that), de-duplication by rounded coordinates so two searches
for the same city don't open two tabs. `_CityTabs` is a
[`ListenableBuilder`] over the store rather than threading the list through
the screen's own state, so adding or removing a city from the sheet below
updates the strip the instant it happens.

**Added cities are NOT coarsened, and that is correct, not an oversight.**
[`WeatherService.coarsen`] exists to keep a live GPS reading from pinning
down where THIS PHONE is; a city somebody typed into a search box and
picked by name is not a location fix at all — rounding "Paris, France" to
the nearest 11km protects nothing, since the name already said which city.
So a `WeatherCity` stores exactly what the geocoder (`searchPlaces`,
`geocoding.dart`, the same Photon endpoint used elsewhere) returned, and
`_Provenance` says a different, still-accurate sentence for a searched city
than it does for "My location" — claiming a rounding promise that was
never made would be worse than saying nothing. Adding reuses the SAME
search-and-pick shape `ShareLocationScreen` already established
(`_AddCityScreen`, deliberately smaller — no current-location row, no
saved places, no map fallback, since this is choosing WHICH city, not
where the phone is).

Removing a city needs its own gesture (long-press → confirm dialog) — a
short tap only ever switches tabs, so a fumbled tap can never delete a
saved city. If the tab on screen is the one removed, the screen falls back
to "My location" rather than silently jumping to whichever tab happened to
land in its place; removing an EARLIER tab shifts the selected index down
by one so the forecast on screen stays put.

**Account-scoped, wired into `account_wipe.dart` like `SavedPlacesStore`.**
A list of cities somebody checks the weather for is a fact about their
life the same way a folder of chats or a saved map place is — this file's
own test (`every store that persists is cleared from the live slot on
switch`) enumerates `lib/state/*.dart` for anything touching
`SharedPreferences` and fails if it isn't named in `account_wipe.dart` or
the small device-scoped allowlist there; it caught this store the moment
it existed, before the wiring was added, which is exactly the job that
test exists to do.

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

**Why only this table. — THIS PARAGRAPH WAS WRONG, and it cost the entire
global marketplace (see the 2026-08-13 entry below).** It used to read: "The
same phone-hiding pattern is on `market_listings` and `server_directory`, and
both are fine: their primary key is `id` alone, which IS in the grant, so
their upserts never touch a withheld column." The reasoning only considered
the CONFLICT TARGET. It missed that `do update set <col> = excluded.<col>`
is itself a READ of `<col>` — so an upsert that WRITES the withheld column
needs SELECT on it too, whatever the key looks like. `market_listings`,
`market_reviews` AND `server_directory` all did exactly that, and every
publish to all three was refused.
`public_forum_comment_votes` has the same composite key but a TABLE-level
select grant. **The real rule: reach for this whenever a client upsert meets
a column-level grant — whether the withheld column is in the conflict target
OR merely in the SET list.**

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

## Messaging your own number redirects to Note to self (2026-08-12)

Reported as "when I message my own number the app doesn't know I'm messaging
myself." It didn't: every chat-creation site treated your own number as an
ordinary peer, and that was silently worse than a cosmetic miss — `send()`
still ran the full real-peer path (encrypt, key-exchange, broadcast, push to
yourself), which LOOKED like it worked, but the message was never delivered.
`RelayService`'s own echo-suppression filters (`digits(from) == digits(myPhone)`,
scattered across `applyIncoming`/`applyKeyEvent`/`applyGroupUpdate` and the
live-event handlers) exist to drop accidental broadcast echoes, and they drop
a genuine self-send exactly the same way — so a real-number self-chat was a
conversation that could never receive anything, even across your own devices.

The app already has the right shape for this: **Note to self**
(`ChatStore.instance.noteToSelfChat`, contact `id: 'self'`, `phone: ''`) is a
deliberate phone-less pseudo-contact that never touches the relay, gated via
`_isNoteToSelf` in `chat_screen.dart` (no calls, no payments). The fix is
detecting a self-number at every point a chat gets created and redirecting
there instead of building a phantom peer chat.

**`ChatStore.isOwnNumber(target, {myPhone})`** does the detection — reusing
`phoneCandidates`/`samePhoneNumber` from the new **`lib/util/phone_match.dart`**
(country-code-robust digit matching, factored out of `ContactsSync.
phoneCandidates` so both sides of the cycle below can use the same logic
instead of a fifth copy of it). `myPhone` is a PARAMETER, not read from
`Session` directly: this store is imported by `relay/relay_service.dart`,
which `session.dart` itself imports, so `chat_store.dart` importing
`session.dart` would be a cycle. Same reasoning `RelayService.applyIncoming`
already follows for `myPhone`.

**`ChatStore.startChatWith(AppUser, {myPhone, myAvatarColor, marketplace})`**
is the single funnel every "look up or create a chat with this person" call
site now goes through, replacing what used to be ~6 copies of the same
lookup-or-construct block: check `isOwnNumber` first (redirect to
`noteToSelfChat`), else the existing `chatWithContact` lookup, else construct
and `upsert`. Wired into `new_chat_screen.dart` (`_startChat` and the "chat
with a number or code" flow, `_startByNumber`), `contacts_screen.dart`,
`people_screen.dart`, `find_people_screen.dart`, `contacts_on_app_screen.dart`,
`chat_search_delegate.dart` (the one app-wide search), and
`marketplace_screen.dart`'s `openSellerChat` (messaging your own listing).
A test (`src.contains('isOwnNumber') || src.contains('startChatWith')`) pins
every one of those files so a new chat-creation site can't be added without
the check.

**Deliberately not done:** filtering your own profile out of Contacts-on-app /
People / Find-people directory LISTINGS. Showing yourself in a browse list and
correctly redirecting on tap is not the reported bug, and the People/Contacts
"add by number" paths that don't carry an `AppUser` yet (raw typed text) keep
their own `isOwnNumber` + `noteToSelfChat` calls rather than being forced
through `startChatWith`, since they still need to run the unknown-number
invite gate first. Also not done: migrating an already-existing broken
self-chat from before this fix — there's no way to tell a stray one apart from
data worth keeping, and the fix only needed to stop creating new ones.

## A message that arrives mid-visit relights the chat's unread badge (2026-08-12)

Reported with a screenshot: chats showing bold/unread rows right after being
inside them. `ChatScreen.initState`'s `_store.markRead(_chatId)` runs exactly
ONCE, in a post-frame callback on the first frame — it was never meant to be
the only clear. `ChatStore.addMessage` bumps `unreadCount` for every incoming
message regardless of whether the chat is on screen (there's no way for the
store to know that), and the existing comment beside it — "the open chat
screen clears it straight back via markRead" — was aspirational: nothing
actually did that for a message arriving after the first frame. A reply that
landed while you were reading the conversation left the badge lit the moment
you backed out.

The read-RECEIPT sent to a real peer (`_maybeSendReadReceipt`, listening for
new incoming messages while the screen is open) looked like the right place
to piggyback the fix, and would have been wrong: it's only registered when
`RelayConfig.isEnabled && _isRealPeer(contact)`, so it never runs for a GROUP
chat (`_isRealPeer` is false for one) — which is exactly the "Fam" case from
the report. The fix is a separate, unconditionally-registered listener,
`_markReadLive` (`chat_screen.dart`), alongside `_maybeFollowNewMessage` —
just `_store.markRead(_chatId)` on every store change. `markRead` already
no-ops once the count is 0, so this costs nothing on the overwhelmingly common
case of no new message, and it clears the badge for every chat shape (1:1,
group, and — moot, but for free — Note to self) rather than only the one the
read-receipt path happens to cover.

## The Moderation console's "Act on account" tooltip covered the row below it (2026-08-12)

Reported with a screenshot: the Users tab's dense list (avatar + name + a
two-line subtitle per row) had the gavel `IconButton`'s default `tooltip:`
pop up on long-press and land on top of an adjacent row, hiding that row's
own text under an opaque box. Flutter's `Tooltip` auto-positions itself and
gets clamped/shifted to stay on screen, which in a tightly-packed list can
mean landing over a neighbour instead of floating clear above or below —
nothing this app can fine-tune about *where* it lands. The fix instead stops
it from popping up on-screen at all: `Tooltip(message: ..., triggerMode:
TooltipTriggerMode.manual, child: IconButton(...))` keeps the label reachable
to a screen reader (still the accessibility name) while dropping the
interactive long-press/hover popup that was the actual glitch. Scoped to this
one `IconButton` in `admin_screen.dart` — the OTHER "Act on account" affordance
in the file is a full-width `FilledButton.icon` with a visible label, not a
bare-icon tooltip, so it was never at risk of this.

## Custom message sounds (2026-08-12) — in-app only, and that limit is real

Asked for plainly: "custom message sounds users can add." The honest ceiling
first: a real lock-screen/background notification sound on iOS has to be an
actual bundled audio file (`.caf`/`.aiff`/`.wav`, named in the push's `aps.
sound` or a local notification's `UNNotificationSound`) — there is no way to
pick a built-in system sound ID for either. This box has no audio-authoring
tools and no device, so that half is out of reach for now; the owner picked
"per-contact + global default, in-app-only" from that constraint rather than
waiting for real sound files.

**What's actually new: the ONE moment the app was already completely
silent.** `PushService.setOpenChat` suppresses the push banner — and with it
iOS's own default notification sound — for whichever chat is on screen, so a
message arriving in the conversation you're actively reading made no sound at
all. Every OTHER chat already gets the OS's standard sound via its own
banner while the app is foregrounded elsewhere; adding a second, different
Dart-side sound there would double-chime the SAME message, so this
deliberately does not touch that path.

`MessageSoundStore` (`lib/state/message_sound_store.dart`) holds an app-wide
default plus a per-chat override map (`chatId → MessageSound`), SharedPreferences-
backed and account-scoped (wired into `account_wipe.dart`/`main.dart`, like
`ChatFolders`) — a sound choice tied to a specific chat has no meaning once
that chat's account is gone. `ChatStore.deleteChat` calls `forget(chatId)` so
no orphaned override survives its chat.

**No new audio assets — reuses exactly what the call ringer already plays.**
`MessageSound` is four choices: `Chirp` (system sound 1007) and `Ring-back
beat` (1074) are the SAME two iOS System Sound IDs `AppDelegate.swift`'s
`okay/ringtone` channel already plays for incoming/outgoing call bursts — the
only two sound IDs this codebase has ever used, so the only two confidently
assumed to work on a real device — plus `Vibrate only` and `Silent`. A wider
catalog of "Tri-tone"/"Glass"/etc. needs the owner to confirm additional
system sound IDs actually sound right on a device before they're added;
picking unverified numeric IDs and inventing plausible-sounding names for
them would be exactly the kind of unverifiable claim this file's other
"unverified from this box" notes exist to avoid. The `okay/ringtone` channel
gained a `playSound` method (an int: >0 plays that system sound ID, -1 is
vibrate, 0/other is a no-op) alongside its existing `burst`.

**Wired into `ChatScreen`** via `_maybeSoundNewMessage`, a store listener
registered unconditionally (like `_markReadLive`) rather than gated behind
`_isRealPeer` — the read-RECEIPT listener is gated that way because it needs
a real peer to receipt to, but a LOCAL sound cue has no such requirement and
must fire for groups too. Seeded to the newest incoming message id already
present on open, so a chat with unread history doesn't sound retroactively —
only a message that lands during the visit does, once per arrival.

**The picker lives where "Wallpaper & sound" already promised it would.**
`WallpaperScreen` (`lib/screens/wallpaper_screen.dart`) was titled that for
a while with no sound section at all — a stale name from before this
existed. It now actually carries one, in the same dual-mode shape the
wallpaper grid already used (`chatId == null` edits the app-wide default,
`chatId != null` edits that chat's override with a "Default (<name>)" row to
clear back to following it), reached from Settings → Chats & appearance →
**Chat wallpaper & sound** (global) and a chat's contact-info → **Wallpaper
& sound** (per-chat) — one screen, no new navigation door. Each choice has a
preview play button. Plain `ListTile` + a manual checkmark, not
`RadioListTile` — its group API is deprecated in this Flutter, the same call
`form_fill_screen.dart`'s choice chips already made.

## Short-text reactions, beyond emoji (2026-08-13)

The fifth idea off the same pasted "WhatsApp lacks features" list ("Reactions
2.0 with Context" — short text like "On it"/"LOL"/"Will reply later" as
floating badges, no extra chat noise). Turned out to be almost entirely
already built: `Message.reactions`/`reactionsBy` and `ChatStore.
toggleReaction` already store and relay a reaction as plain text — nothing
there ever assumed a single emoji glyph — and `_ReactionPill` already draws
whatever string it's given as a small floating badge over the bubble corner,
which is the exact "no extra chat noise" shape asked for. The only real gap
was that neither entry point into `_react` (the quick-react row, the emoji
grid) ever offered anything but an emoji.

`TextReactions` (`lib/widgets/text_reactions.dart`) is the small new part: a
curated default list plus `clean()` (trim, reject empty/over 24 chars — a
floating badge, not a message). The "React with…" sheet
(`ChatScreen._pickReactionEmoji`) now opens with a horizontal row of these
defaults plus a **Custom** chip above the emoji grid; tapping a default
reacts immediately, Custom opens a one-line dialog for a one-off phrase.
Both funnel through the same `_react` every emoji tap already used, so
delivery, persistence, and "who reacted" (`_showReactedBy`) needed no
changes — a text reaction is exactly as real as an emoji one because it
rides the identical path.

**Deliberately NOT a saved/reusable list, unlike `QuickReplies`.** A quick
reply is inserted into the composer and sent as a real message; a text
reaction rides the reaction funnel and is never a message at all. Keeping
them as two separate lists (rather than teaching the reaction picker to read
`QuickReplies`) keeps "what I say" and "how I react" from blurring into one
settings surface neither asked to share.

## Smart Inbox Tiers (2026-08-13)

The other half of a two-idea ask ("A dual-identity mode" and "Smart inbox
tiers", pasted from a ChatGPT session titled "WhatsApp lacks features").
The first turned out to already exist — a handle is already the public
identity everywhere (the directory only ever answers a phone number on an
EXACT handle match, never a search — see "The directory stops handing out
phone numbers"), a phone number is only ever seen by someone who already
has it in contacts, and numberless signup already means a handle-only
account with no phone at all. Nothing to build. This section is the other
one, which genuinely was not built: chats auto-sort into three chips —
**Priority / General / Occasional** — riding the SAME filter strip
All/Unread/Favourites/Groups already uses, so this is three more
`ChatFilter` chips (`lib/tabs/chats_tab.dart`), not a second bar.

**The rule is stated, not hidden — the thing `ChatFolders` deliberately
avoided, done carefully this time.** `ChatFolders`'s own comment calls out
exactly this risk: "a rule that silently pulls a conversation into 'Work' is
the version that surprises people." That objection holds for a folder with
no way out; it does not hold here, because every rule is named in
`InboxTier.description` (shown right in the per-chat picker) and every chat
can be moved with one tap. `InboxTiering.autoTierFor` (`lib/state/
inbox_tiers.dart`, a PURE function — no store, so a test hands it a `Chat`
directly) is the whole rule, checked in order: favourited or pinned always
wins (an explicit choice always outranks a guess); then a REAL back-and-forth
in a 1:1 — both sides have sent at least one message — within the last 30
days (`InboxTiering.recentWindow`, a test seam) is Priority, because a
one-way chat or a stale one isn't the "close contact" signal it looks like;
then a business contact (`AppUser.isBusiness`) or a last INCOMING message
that reads like a one-time code (`looksLikeOtp` — a loose regex on 4–8
digits or the words "verification code"/"OTP"/"one-time code", matched
loosely on purpose: a false Occasional costs one tap back, a missed one
costs nothing) is Occasional; everything else — groups included — is
General, exactly where it would have shown up anyway. **Reciprocal
engagement always outranks the business flag**: a business you actually
talk back and forth with lands Priority, not Occasional — the rule reads
the conversation, not just the contact's badge. An outgoing message is never
read for an OTP shape; only what arrived FROM the other side counts.

**`InboxTiers` (the store) holds only the overrides, and only on the
device** — `chatId → InboxTier?`, SharedPreferences-backed,
account-scoped exactly like `ChatFolders`/`MessageSoundStore` (wired into
`account_wipe.dart`/`main.dart`; `ChatStore.deleteChat` calls `forget` so no
override outlives its chat). `InboxTiers.tierFor(chat)` is the override if
one exists, else the rule — the ONE call every surface reads through.
Long-press a chat → **Inbox tier** shows the current tier and opens a plain
`ListTile` + manual-checkmark sheet (not `RadioListTile` — deprecated group
API in this Flutter, same call `form_fill_screen.dart` already made): Auto
(names what the rule would say) or one of the three tiers by hand.

**No new data collection.** The classifier reads only what the app already
has on-device — `Chat.isFavorite`/`isPinned`, `AppUser.isGroup`/
`isBusiness`, and each `Message.isMe`/`text`/`time` already in the local
store. Nothing is sent anywhere, and nothing new is stored beyond the
override map itself.

## Two more chat bugs from the same report (2026-08-12)

**No way to dismiss the keyboard.** Dragging the transcript already did
(`ScrollViewKeyboardDismissBehavior.onDrag`, from an earlier round of this
exact complaint), but a plain TAP on empty transcript space did not — and a
`GestureDetector` was tried for that once already and reverted, because its
tap recognizer competed with a message's own double-tap-to-react and broke
it. The fix this time is a `Listener` wrapping the transcript `Stack`
(`chat_screen.dart`), not a `GestureDetector`: a `Listener` only OBSERVES
the raw pointer-down, it never enters the gesture arena, so it can unfocus
the composer on every tap without competing with anything underneath. Same
technique the marketplace/newsfeed tap-off-dismisses-search feature already
uses for an identical problem — "a Listener, not a GestureDetector, so
listing/post taps still land."

**The reply quote showed blank text for most non-text messages.**
`_startReply` built its OWN fallback — `isImage ? '📷 Photo' : isVoice ?
'🎤 Voice message' : message.text` — instead of using `Message.previewLabel`,
which already exists and already covers every kind: location, poll, form,
payment (request or not), contact card, file, sticker, poke, bill split,
view-once. `message.text` is empty for all of those, so replying to any of
them quoted nothing — which is what "when I reply to a message I can't see
the text" actually was. Fixed by delegating to `previewLabel` instead of
re-deriving a worse, partial copy of it.

**Found alongside it, same function: a group reply always quoted the GROUP's
name, never the member who actually sent the message being replied to** —
`senderName: widget.chat.contact.name` unconditionally. Now
`message.senderName.isNotEmpty ? message.senderName : widget.chat.contact.
name` — a group message carries its own sender name (the same field
`_SenderLabel` already draws above the bubble), and a 1:1 message doesn't,
so the contact name is still the right fallback there.

## A reply quote inside a sent bubble ignored the bubble's own colors (2026-08-13)

Reported as "replying to a message the text is still not readable" — "still"
because it is a different bug from the blank-reply-text fix directly above:
that one was about missing text, this one is about unreadable text on the
text that IS there. `_ReplyQuote` (`message_bubble.dart`) is the little
quoted-message strip drawn INSIDE an already-sent bubble (distinct from
`_ReplyPreview` in the composer, which was never affected) — it picked its
two text colors from raw `Theme.of(context).brightness` (`AppColors.accentOn`
for the sender name, `Colors.white70`/`Colors.black54` for the quoted line)
instead of the bubble-aware `textColor`/`metaColor` its own parent,
`MessageBubble.build()`, already computes.

**This is the exact bug class "A bubble's contents take the BUBBLE's colours
(2026-08-09)" exists to prevent, missed a second time.** That entry fixed
`VoiceNoteBubble` drawing its control in the app-wide accent — which happens
to equal the outgoing bubble's own background in both themes — after a
custom (`AppState.bubbleColor`) outgoing bubble made a sent voice note's
control vanish. `_ReplyQuote` had the same shape of bug for text instead of
an icon: a light custom bubble color chosen while the app is in dark theme
makes the PARENT bubble correctly pick near-black text
(`custom.computeLuminance() > 0.5 ? ink : Colors.white`), while `_ReplyQuote`
kept reading `isDark` straight off the theme and drew `Colors.white70` —
light text on a light bubble.

Fixed by threading the parent's already-computed `textColor`/`metaColor`
into `_ReplyQuote` instead of a bare `isDark` flag: the sender-name label
takes `textColor`, the quoted line takes `metaColor` — the same primary/
secondary split the bubble already draws its own message text and timestamp
with. The decorative left-border accent stripe and the low-alpha background
wash are left as `AppColors.accentOn(context)`/theme-based — they're not
text, so they were never the "not readable" complaint, and the border in
particular is meant to read as the app's accent regardless of bubble color.
A regression test pins a light custom bubble color against a dark theme and
asserts the reply-quote's sender-name color matches the bubble's own ink,
not `Colors.white70`/`Colors.black54` — the exact case that was wrong.

**Worth periodically re-auditing for a third instance.** Nothing catches
this class automatically; both known cases so far were found by a user
reporting a specific bubble content type as unreadable/invisible, not by a
sweep. Any future widget drawn inside `MessageBubble.build()`'s child tree
should take `textColor`/`metaColor` as parameters rather than reaching for
`isDark` or `AppColors.accentOn(context)` on its own.

## Weighted group polls: "Decision Voting" (2026-08-13)

The first of a three-part idea list ("Group Task Board", "Decision Voting",
"Anonymous Feedback"), scoped and sequenced smallest-first at the owner's
direction. A poll in a GROUP chat can now weigh the admin's vote at 2 against
everyone else's 1 — WhatsApp-group polls specifically, not the server/channel
polls in `community_store.dart` or the public/server-feed polls in
`public_feed_store.dart`/`feed_store.dart`, which are untouched.

**The gap this closed: a poll had a tally but no memory of WHO cast each
vote.** `Message.pollVotes` was (and still is) a flat per-option count —
enough to move or undo THIS device's own ballot (`pollMyVote` says which
option), but nothing else remembered a peer's choice once applied, which
made weighting impossible: you can't reweight a vote you can no longer
attribute to anyone. `Message.pollVotesBy` (voter phone digits → chosen
option) fixes that, mirroring `reactionsBy`'s emoji→reactor shape exactly —
`votePoll`/`applyRemotePollVote` in `chat_store.dart` now take an optional
`voter` digits string and keep `pollVotesBy` in step with `pollVotes` the
same way `toggleReaction`/`setReactionState` keep `reactionsBy` in step with
`reactions`. The voter's phone was ALREADY on the wire as the outer relay
envelope's `from` for every event (reactions read it the same way) — it was
just being discarded at the `'poll'` case in `relay_service.dart`'s
dispatcher; now it's threaded through as `voter: digits(from)`. An empty
`voter` (the default, and every pre-existing call site) skips the
bookkeeping entirely, so nothing about a 1:1 chat, an older test, or a
message that predates this changed.

**No new sync needed for admin identity — it was already on-device.** A
group's admin is roster index 0, the same convention `group_info_screen.dart`
already uses to decide who may remove a member. `ChatScreen._pollVoteWeight`
(a getter, not a stored field) reads `widget.chat.members.first.phone` and
returns a closure weighing that one voter's digits at 2, everyone else at 1
— null for a 1:1 chat (no admin concept) or a numberless-admin group with no
phone to compare against, in which case a poll tallies exactly as it always
has.

**The weighting itself lives in a pure, testable function** —
`weightedPollTally(optionCount, votesBy, weightFor)` in `poll_widgets.dart`
— reweighing `pollVotesBy` rather than trying to mutate the flat `pollVotes`
count in place (which can't be reweighted without knowing whose vote is
behind each unit). `PollBubble` computes it only when `weightFor` is
non-null AND the message actually has `pollVotesBy` entries; otherwise it
falls back to the plain `pollVotes` list unchanged — so an old poll's votes,
cast before this shipped, still render exactly as before rather than
reading as zero.

**The rule is stated, not hidden — same discipline `InboxTiering` and
`ChatFolders` already follow for a rule that isn't a plain 1:1 mapping.** A
weighted poll's footer reads "N people voted · admin's vote counts double"
instead of "N votes", specifically so the numbers never look like a
headcount that doesn't add up (2 people, admin's ballot worth 2, could read
"3 votes" with no explanation). `PollBody` takes a `weighted`/`voterCount`
pair for exactly this — `voterCount` is the real number of people
(`pollVotesBy.length`), separate from the weighted total the bars are drawn
against.

Threaded through `MessageBubble.pollVoteWeight` (nullable, defaults to
unweighted — every other call site of `MessageBubble`/`PollBubble`/
`PollBody` is untouched) and wired at the one place that builds a poll
bubble, `chat_screen.dart`'s `_buildItems`. Tests cover the pure tally
function, `pollVotesBy` bookkeeping in `ChatStore` (including that a voter
moving their pick moves the entry rather than duplicating it, and that an
empty `voter` never records a blank key), and the widget-level weighted vs.
unweighted footer/percentages.

## A view-once photo could not be liked, before OR after opening (2026-08-13)

Reported as "user can't like gifs, photos or video." An investigation across
every surface (1:1/group chat, server channels, both feeds) found every OTHER
media path wired correctly — `_ImageBubble`'s double-tap, `ImageViewScreen`'s
Like/React bar, `_ChannelBubble`'s double-tap, and both feeds' like buttons
are all unconditional on message/post kind, and the existing tests for all of
them pass. The one real gap: `_ViewOnceBubble` (`message_bubble.dart`) — the
bubble a view-once photo renders as — never had `onDoubleTap`/
`onDoubleTapDown` wired to it at all. `MessageBubble.build()` only forwarded
`onTap`/`onLongPress` into it, so double-tap-to-like — the primary "like a
photo" gesture everywhere else in the app — silently did nothing on a
view-once photo. Worse, once opened the recipient's copy sets
`onTap: spent ? null : onTap` (correctly disabling re-opening an already-spent
photo) — which, combined with double-tap never being wired in the first
place, left a spent view-once photo with **no tap-driven way to react to it
at all**, only the long-press → reaction-row path most people won't find.

Fixed by threading `onDoubleTap`/`onDoubleTapDown` through
`_ViewOnceBubble` the same way `_ImageBubble` already receives them, and
— unlike `onTap`, which only makes sense before the photo is spent —
leaving double-tap live UNCONDITIONALLY: liking something you already saw is
a reasonable thing to want to do after opening it, and it's the only tap
gesture left once `onTap` is nulled out. Two regression tests pin both
states (unopened, and opened-and-spent) against `MessageBubble` directly.

**Ordinary photos, GIFs, channel messages, and feed posts were never
affected** — this was scoped to the `viewOnce` bubble specifically, which
renders as a compact "View once"/"Opened" chip rather than the ordinary
`_ImageBubble`, so it needed its own gesture wiring and had simply been
missed.

## Spark is bitcoin-only now; the cash rail is Tip (2026-08-13, owner's call)

"Spark" used to mean two different rails behind one button: Lightning
(bitcoin, direct wallet-to-wallet) and cash (a real Stripe transfer). The
owner's instruction was direct — Spark should be bitcoin only, and the real
money should be called a Tip — so the two are now genuinely separate
actions, not a rail-picker sheet under one shared label.

**`sparkRailsFor`/`SparkRail`/`offerProfileSpark` are gone**, replaced by
four small pure/callback functions in `spark_sheet.dart`: `canSpark(user)` /
`canTip(user)` (eligibility — a Lightning address for one, a phone number
for the other, same conservative "never draw a button that leads nowhere"
rule as before) and `offerSpark(context, user:, fallbackLabel:)` /
`offerTip(context, user:, fallbackLabel:)` (the actions — Spark opens
`showLightningSparkSheet` directly, Tip calls the renamed `offerTipTo`).
Every surface that used to show one "Spark" button now shows up to TWO
buttons, each independently gated:

- **Public profile** (`public_feed_screen.dart`) and **contact card**
  (`contact_info_screen.dart`'s `_ActionButtons`, which gained a sixth tile)
  show Spark and/or Tip side by side.
- **A chat message's long-press menu** (`chat_screen.dart`) gained a Spark
  tile alongside the renamed Tip tile — new, for parity with the profile/
  contact-card buttons, resolving the same `AppUser` (`_recipientFor`,
  renamed from `_sparkRecipientFor` since it's now shared by both actions)
  to check `canSpark`.
- **A server channel message's long-press menu** (`communities.dart`)
  renamed its tile to Tip and gained **no** Spark option — a channel message
  carries only the sender's phone digits, never a resolvable `AppUser` with
  a Lightning address, so there's nothing to check `canSpark` against. Left
  as a stated limit rather than inventing a lookup.

**The rename touched the money-movement plumbing too, and had to stay
backward-compatible with data already on the server.** `PaymentRecord.isSpark`
→ `isTip`, matching `note.startsWith('Tip')` **or** the historical
`note.startsWith('Spark')` — a cash transfer sent before this split is still
on the server with its old note text, and it has to keep reading as a tip
(right icon, right filter, right history label) rather than falling through
to a plain "Sent"/"Received" row the day this shipped. `payment_history_screen.dart`'s
filter key is now `'tips'` (was `'sparks'`), and `earnings.dart`'s
"Payments received" exclusion (`r.isTip`) is the same logic, just correctly
named. **Bitcoin sparks never appear in this history at all** — Lightning is
a direct wallet-to-wallet payment `lightning.dart` never reports back to a
server, so `payment_history_screen.dart`/`earnings.dart` are, and always
were, 100% the cash rail; nothing there needed new Lightning-awareness, only
the rename.

**One accuracy fix found while touching `parental_controls.dart`'s
"Payments" toggle, stated rather than smoothed over**: its doc comment
claimed the toggle blocked "every path money leaves by," but Lightning sends
never touch `PaymentService.sendMoney`/`payFromWallet`/`addMoney` at all —
`showLightningSparkSheet` hands an invoice straight to the sender's own
connected wallet, outside that funnel entirely. The comment (and the
Settings row's own label, now "Wallet, Send money, Sparks and tips — every
way money leaves") is corrected to name that gap rather than implying
Lightning is gated when it isn't.

**Also fixed in passing**: `contact_info_screen.dart`'s spark fallback label
was `'@\${user.username}'` — a single-quoted string with an **escaped**
dollar sign, so it built the literal text `@${user.username}` rather than
interpolating the real handle. Caught only because the line was being
touched anyway for the `onTip` addition.

`get_paid_screen.dart` (the "how do I get paid" settings screen, and the
`NwcStore`/Nostr-Wallet-Connect "Connect your wallet for sending" card on
it — both undocumented here until this pass, found while mapping every
"Spark" reference before renaming) needed copy-only updates: everywhere it
described the CASH rail now says "tip"/"tips" instead of "spark"/"sparks";
everywhere it describes Lightning or NWC (which only ever pays a Lightning
invoice — confirmed no code path hands it a dollar amount) is untouched.

Regression tests: `canSpark`/`canTip` eligibility (stranger/Lightning-only/
phone-only/both/malformed), the source-pin test asserting every surface
calls the right pair of functions, the payment-history backward-compat case
(`note: 'Spark ⚡'` still filters under `'tips'` alongside a fresh
`note: 'Tip'` record), and the existing Lightning/get-paid/cannot-receive
tests updated for the renamed symbols
(`debugResetSparkNudges`→`debugResetTipNudges`,
`debugWasNudged`→`debugWasTipNudged`).

## Live location: an explicit Stop now really stops it for the other person (2026-08-13)

Reported plainly: "if I stop sharing location it doesn't stop sharing. And my
location isn't consistently shared with other user." Two different bugs, one
fixed, one an honest limit that was never true before this pass either.

**The stop button only ever told THIS device.** `_stopLiveShare` removed the
share from the sender's own `LiveShareStore` (so their bubble read "Stopped"
immediately) and nothing else — the recipient's copy of the message had no
way to hear about it, so their bubble kept reading "Live location" with a
countdown until the ORIGINAL window (15 min/1 hr/8 hr) ran out on its own.
Tapping Stop early looked like it worked because the only bubble you could
see was your own.

Fixed by naming the exact message a stop applies to and telling the peer.
`LiveShare` (`live_share_store.dart`) gained a required `messageId` field —
threaded through `start()`/`withPosition`/`toJson`/`fromJson` (an
already-persisted share with no `messageId`, from before this field existed,
decodes to `''` rather than throwing) — set from the real chat message id at
share time (`_handleShareLive` mints `messageId` first, starts the share with
it, THEN builds the `Message` with that same id, so sender and recipient
copies of the same live-location message always carry the same id). `stop()`
now returns the removed `LiveShare` instead of `void`, so the caller can read
its `messageId` back out.

A new sealed, mailboxed relay event, **`locstop`** — `{from, id}` — carries it
(`RelayService.sendLiveLocationStop`, riding `_sendInboxEvent` like every
other message-scoped event: edit, delete, reaction, poll vote, view-once-
opened). **It rides the SAME message-id-precise infrastructure those events
already use**, not a new one: `applyMessageEvent`'s switch gained
`case 'locstop': target.endIncomingLiveLocation(chat.id, id);`, which resolves
the right chat via the existing `chatWithMessage(id, senderId:)` lookup —
deliberate, so a stop signal reuses code already proven correct rather than a
parallel path that could drift from it. `ChatStore.endIncomingLiveLocation`
closes only the NAMED, still-incoming, still-active live-location message
(`liveUntil: now`) — never the sender's own outgoing copy of the same
conversation, and never an already-expired share, both pinned by tests.

**Caught while wiring it up: `'locstop'` was missing from
`applyInboxEvent`'s dispatch switch** — the one that unseals a live or
mailboxed `'sealed'` envelope and routes it by event name. `applyMessageEvent`
had the new case, but nothing called it for a REAL sealed delivery until
`'locstop'` was added to the `'edit' || 'delete' || … || 'vopen'` case list
there too — without that, a stop signal from a real device would have been
silently dropped exactly the way the file's own sealed-roster test warns
about ("an event missing here arrives sealed and is silently dropped"). That
test (`every inbox event type has a sealed road…`) now includes `'locstop'`
in its enumerated roster, so this can't regress unnoticed a second time.

**The "inconsistent" half is a real, stated limit, not a bug this pass
fixes.** A live share's position updates (`'loc'`, `RelayService.sendLocation`,
fired every 30s by `LiveShareBroadcaster`) are — like `'typing'` and `'shot'`
— a LIVE-ONLY broadcast with no mailbox fallback: a tick the recipient's
device isn't connected for at that exact instant is gone, not queued, by the
same design as every other ephemeral ping in this app. Usually harmless (the
next tick 30s later lands instead), but the app has no `location` entry in
`UIBackgroundModes` (`ios/Runner/Info.plist`), so on iOS the periodic `Timer`
driving those 30-second ticks simply stops firing the moment the app is
backgrounded — not a bug in this feature, a hard iOS limit on what a
non-location-tracking app is allowed to keep doing while backgrounded, the
same class of limit already stated for the Bluetooth mesh and Okay Drop.
Mailboxing position ticks was considered and rejected: a position ping is
meant to be CURRENT, and queuing a backlog of stale-by-the-time-it's-read
coordinates (unlike a real message, which is worth delivering late) would
turn "where they are now" into "where they were whenever the mailbox last
drained" — worse than the gap it would paper over. Foreground-to-foreground
sharing is unaffected by any of this.

Regression tests: `LiveShare`'s `messageId` round-trips through JSON
(including the empty-string legacy-decode case) and `stop()` hands back the
removed share; `endIncomingLiveLocation` closes only the matching, active,
INCOMING message and leaves an expired one and the sender's own outgoing copy
alone; a sealed `'locstop'` event dispatched through
`RelayService.applyMessageEvent` closes the right bubble; the sealed-roster
test's event list includes `'locstop'`.

## New server members couldn't see old posts — every join path now backfills (2026-08-13)

The #128 fix (2026-08-08) closed the roster/sender-key half of joining a
server, but left the OTHER half of "why is this server empty" open: nothing
actually asked for the durable copy of its old posts (`community_posts`,
fetched by `RelayService.fetchCommunityPosts()`) at the moment of joining —
only at relay start and on pull-to-refresh. A new member who joined and
never happened to pull-to-refresh (or refreshed before the join's own local
state had settled) saw a server with nothing in it, indistinguishable from
an empty one.

**Every place a device joins a server now calls `fetchCommunityPosts()`
right after announcing the join**, chosen over the peer-to-peer `backfillFeedTo`
because it reads the DURABLE store — it answers even when no other member
happens to be online at that exact moment, which a peer-to-peer ask cannot
promise. Four sites, all of them:

- `joinByCodeFlow` (`communities.dart`) — a pasted invite code.
- `joinServerFromSnapshot` (`communities.dart`) — the shared helper behind
  the Discover directory and any other snapshot-based join.
- `_join` (`message_bubble.dart`) — the tapped invite-card handler; keeps its
  own separate copy of the join logic rather than calling
  `joinServerFromSnapshot`, so it needed the same line added independently.
- `maybeAutoJoinServer` (`relay_service.dart`) — the SILENT admin-add
  auto-join. This one matters most: there's no screen open for the person to
  pull-to-refresh from, so this call is the ONLY chance that member gets to
  see the server's history before the next post arrives naturally.

All four are gated the same way the surrounding join code already is —
inside `if (RelayConfig.isEnabled)` for the three UI paths, unconditionally
in `maybeAutoJoinServer` since that whole function only runs when the relay
is already active.

A source-pin test enumerates all four functions and asserts each one's body
contains `fetchCommunityPosts()`, so a fifth join path added later — or one
of these four losing the call in a refactor — fails a test rather than
shipping a server that reads as empty to whoever joins it that way.

## Profile: more breathing room, bigger buttons (2026-08-13, owner's call)

The owner's own report was "too compact," narrowed on request to two
concrete complaints: the bio/stats block sat too close together, and the
Message/Follow/Spark/Tip buttons read as an afterthought row rather than the
primary actions on the screen. Both are `public_feed_screen.dart`'s `_Header`
and `_ProfileActions`, spacing/sizing only — no new fields, no new copy.

**Bio/stats**: the header's single rhythm widened from 14 to 17 between
primary blocks (the bio paragraph, the stat row, the Okay Score row) and from
10 to 11 between the lighter detail lines that sit directly under a heavier
block (business info, location, link) — kept intentionally tighter than the
primary rhythm since those lines belong visually to the block above them. The
outer padding grew from `(16, 12, 16, 4)` to `(16, 15, 16, 8)`. `ProfileStat`
(`profile_screen.dart`, shared by every screen that shows a stat) grew only
its own VERTICAL padding, 4→6 — a stat is a tap target as well as a number,
and the old padding gave it barely more hit area than the text.

**A first, wider pass (18/16/16/10 rhythm, the stat `Wrap`'s spacing 20→24,
`ProfileStat`'s horizontal padding 2→4, its number 16pt→17pt) broke
`type_metrics_test.dart`'s "a profile spends its first screen on the
person"** — a guard that pins the tab strip under 520pt so the header can
never again eat the fold the way an old decorative banner once did. It
measured 537. The overshoot wasn't the vertical gaps (those alone would have
landed around 494) — it was the WIDTH changes: four stats (Posts, Followers,
Following, Servers, on an `isMe` profile) got just wide enough to tip the
`Wrap` from one line to two, which cost the header a whole extra line, not a
little more room. The fix was narrower, not abandoned: every width-affecting
change (Wrap spacing, `ProfileStat`'s horizontal padding, its font size) was
reverted to its original number, keeping only the vertical-only additions —
which measures 469 (barely past the original 466; the width regression was
the real cost, not the spacing), the same margin under 520 the test's own
comment calls room for "a platform to lay type out slightly differently."
Anyone widening this header again should re-run
`flutter test test/type_metrics_test.dart` before trusting it fits.

**Buttons**: `_ProfileActions`' shared `dense` `OutlinedButton.styleFrom` —
which Message, Follow, Spark and Tip all reference, so one change reaches
all four — grew from 36pt tall / 14pt horizontal padding to 44pt / 18pt.
`VisualDensity.compact` stays: it only trims Material's own invisible touch
padding, not the button's visible size, and is still what lets two buttons
share a row on a 390-point phone. The Subscribe button — not named in the
report, but sitting directly under the four and previously carrying its own
separate, smaller (36pt) style — now reuses the same `dense` style rather
than a second copy of the old numbers, since a Subscribe button visibly
shorter than the row above it would read as a demotion nobody asked for.

A widget test pins the widest real combination — a contact this device holds
both a phone number and a Lightning address for, so Message+Follow draws
beside Spark+Tip — at a 390-point width and asserts no overflow exception,
since that's the exact width the original `dense` style was sized against.

**Round 2, same day: "still compact too many buttons."** Bigger buttons fixed
the original "afterthought row" complaint but created a new one — the button
block was three Rows, each FORCED onto its own line by construction (Message+
Follow always on line 1, Subscribe always alone on line 2, Spark+Tip always
alone on line 3) regardless of how much width was actually left over. A full
creator (subscriptions + a Lightning address + a phone number) got 5 buttons
stacked 3 rows tall no matter what, which is what "too many" actually meant —
not the count, the enforced height. `_ProfileActions` now builds one flat list
of applicable buttons and lays them out with a `Wrap` (`WrapAlignment.end`,
`spacing`/`runSpacing` 8) instead of three separate `Row`s — it packs as many
buttons per line as the width allows and only drops to a new line when it has
to, so a plain contact (Message+Follow only) is unchanged and a fully-loaded
creator profile is shorter than before without shrinking anything. Spark and
Tip stay two separate buttons in the list — the Wrap only changes whether they
sit beside or below Message/Follow, not the split itself, which was a
deliberate, separate owner decision the same day (see the Spark/Tip section
below) and is not undone by this. The existing 390-point overflow test still
passes unchanged, since a `Wrap` cannot overflow the width it's given.

## Marketplace checkout: a silent Stripe failure, and cash/e-Transfer as a door to chat (2026-08-13)

Reported plainly, with a screenshot of the "Buy" sheet: "Pay another way
doesn't work. Add cash/etransfer too." Two separate things.

**The bug.** `PaymentService.addMoney` (the wallet top-up) already had a
fix for exactly this shape of failure: `StripeSheet.presentPayment` can
return a bare `false` for TWO different reasons — a plain user cancel, or a
real failure (a decline, a connected account that can't yet receive) — and
only the second one carries a reason, in `StripeSheet.lastError`. `addMoney`
checks it (`if (!ok && StripeSheet.lastError != null) throw
PaymentException(StripeSheet.lastError!)`); `sendMoney` — the function
"Pay another way" calls, and the one every chat "Send money" and marketplace
purchase rides — never did. So a real failure came back as an unremarkable
`false`, and the caller's `if (ok) { ...show a success snackbar... }` simply
did nothing on `false` — no error, no snackbar, the sheet just sat there.
That silence was the entire complaint. Fixed by giving `sendMoney` the exact
same check `addMoney` already had. `chat_screen.dart`'s `sendMoney` catch
block already had a graceful `_ => 'Payment failed: ${e.code}'` fallback for
an unrecognized code, so a raw Stripe message surfacing through here reads
fine without any further change there.

**Cash and e-Transfer are not a third payment rail, and were never going to
be — stated plainly rather than half-built.** Cash obviously changes hands
in person; a real Interac e-Transfer moves bank-to-bank over email or phone
with no API for a third-party app to trigger. Building either would mean
either quietly doing nothing (the exact bug just fixed, reintroduced on
purpose) or pretending to process something that never happened. So the
"Add cash/etransfer too" ask became a THIRD button on the checkout sheet —
**Cash or e-Transfer — message the seller** — that closes the sheet and
opens the seller's chat via the existing `messageSeller` helper, the SAME
door a $0 listing already uses (`buyListing` routes a free item straight to
chat, since there's nothing to charge). The sheet's disclaimer, which
already assumed a chat handoff for anything you can't collect, now says so
plainly instead of only implying it: "Wallet and card payments happen
through the app. Cash and e-Transfer are arranged directly with the seller
in chat." (Deliberately not "Pay from wallet…" — that phrase collides with
the dynamic wallet-button label an existing test matches on by substring;
see the review-sync entry below for the same kind of test-copy collision.)

Regression tests: a source pin proving `sendMoney` carries the same
`StripeSheet.lastError` check as `addMoney`; a widget test confirming the
Cash/e-Transfer button opens `ChatScreen` rather than attempting any charge.

## Marketplace reviews never reached the seller — a second silent drop, same shape as the payment one (2026-08-13)

Reported the same day as the payment bug, and root-caused to the same class
of failure: something silently going nowhere. "Reviews on marketplace
aren't updated, user doesn't get a notification when a review is left."

**The bug.** `FeedStore.addReview` builds a review as a `FeedPost` carrying
`communityId: listing.communityId` — inherited from the listing it reviews.
Since the marketplace went global (2026-08-08, "Global server-side
marketplace listings"), a normal listing's `communityId` is `''`. In
`RelayService.sendFeedPost`'s dispatch, a review is not a listing (skips the
`market_listings` publish), its `communityId` resolves to no real
`Community` (skips the sealed community bus), and `if
(post.communityId.isEmpty) return;` drops it on the floor. A review only
ever existed on the reviewer's own device — nobody else, least of all the
seller, ever saw it or was told about it. This has presumably been broken
for every global listing since the marketplace went global; reviews were
last touched (sale-code binding) before that change and nobody re-checked
the transport.

**The fix is the exact `market_listings` pattern, copied for reviews.**
`docs/market_reviews.sql` — a new `market_reviews` table with the identical
phone-hiding shape: `revoke select … from anon, authenticated` then `grant
select` on every column except `author_phone` (the table-wide-grant trap
this codebase has now hit three times — Supabase grants every new table
SELECT by default, and a column-level revoke alone does nothing against
it), RLS scoped to `auth.jwt() ->> 'phone'` for write, `not
is_locked_out(author_phone)` for read, and a `security_invoker` view with no
phone column at all. `RelayService` gains `publishMarketReview` /
`fetchMarketReviews` / `deleteMarketReview`, verbatim mirrors of the listing
trio. `sendFeedPost` gains an `if (post.isReview)` branch, checked right
after the listing branch and before the dead `communityId.isEmpty` return
can ever see it. `sendFeedDelete` now also calls `deleteMarketReview`
(harmless no-op for a non-review id, same as `deleteMarketListing` already
was) — this is also what keeps `addReview`'s delete-then-repost rewrite from
leaving a stale global row behind. `fetchMarketReviews()` rides both
existing `fetchMarketListings()` call sites (relay start, pull-to-refresh),
so a review reaches its seller even if neither device is online at the same
moment — the durable-table pattern, not a live-only broadcast.

**The notification is local, matching how every other feed interaction
already notifies — not a new push mechanism.** `FeedStore._maybeNotify` /
`_alertFor` already raise an on-device banner (`PushService.localNotify`,
no server round trip) for a reply, mention, repost, like, or spark the
instant the interacting content arrives via `addRemote` — reviews now ride
the same pipe, because `fetchMarketReviews` feeds every review through
`addRemote` exactly like a listing. The one real gap: a review's `parentId`
points at the listing, which is indistinguishable from an ordinary reply's
`parentId` unless something checks first — so `FeedNotificationType.review`
was added and `notificationFor` classifies `post.isReview` (checked ahead
of the generic parentId/reply branch) as "reviewed your listing" rather
than "replied to you". `_alertFor`'s switch and `activity_tab.dart`'s two
exhaustive switches (icon, verb) all got the new case — Dart's exhaustive
`switch` expression is what caught every site that needed one; `flutter
analyze` would have failed loudly on any left unhandled.

**Deliberately NOT a push notification while the app is closed.** No
existing feed-level interaction (like, spark, repost, mention) pushes via
`push-send` — that path is phone-keyed end to end and reserved for chat
messages, calls, reactions and tips, all of which already have a known
recipient phone. A review's seller is known only by username on a global
listing (the phone-hiding rule this whole file exists to protect), so a
true push would need either a new definer RPC to resolve username→phone or
a server-side trigger calling `push-send` directly from the `market_reviews`
insert — a real follow-up, not something this fix invents client-side.

Verified end to end against a real throwaway Postgres via `tool/check_sql.sh`
(now applies `docs/market_reviews.sql` in order, right after
`public_market.sql`): review-as-self, phone-unreadable, `select *` refused,
edit-own-only, a banned reviewer's review hidden, anon can read. Regression
tests: a source pin for the new relay functions, the `sendFeedPost` dispatch
branch, the `sendFeedDelete` cleanup, and both fetch call sites; a behavioral
test confirming `notificationFor` classifies a review as `review` (not
`reply`) and that `_alertFor` raises "Grace reviewed your listing".

**RUN + verified live 2026-08-13** — applied via the Management API with the
owner's own token, then read back rather than assumed: `market_reviews`
carries all 7 columns; `author_phone` has no SELECT grant for `anon` or
`authenticated` (only INSERT/UPDATE/REFERENCES, same shape as
`market_listings`); all four RLS policies exist; `market_reviews_view`
exposes exactly the 6 phone-free columns. Live probes as `anon`: a direct
`select author_phone` and a `select *` both refused with `42501 permission
denied`; `select * from market_reviews_view` answers cleanly (empty — no
reviews yet). The view's broader INSERT/UPDATE/DELETE grants for
anon/authenticated were checked against `market_listings_view` and are the
identical baseline Supabase applies to every new view in this project, not
something this migration introduced — RLS on the base table still gates the
actual write either way. Do not re-raise as pending.

## Chat message avatars, Messenger-style (2026-08-13)

A small circular face now sits beside an incoming message, in both 1:1 and
group chats — the sender's own `AppUser` in a group (resolved from
`Message.senderPhone` against `Chat.members`, the same digits-matching
`_showReactedBy` already uses), the one contact in a 1:1.

**Shown once per run of consecutive messages from the same sender, on the
LAST bubble in that run — not on every message.** That is what Messenger
itself actually does; drawing the same face down a whole burst of texts
would be noise, not the "like Facebook" the request asked for.
`_isLastInSenderRun` (in `chat_screen.dart`, beside `_buildItems`) decides
by peeking at the next message in `_visibleMessages`: a different sender, a
different `isMe`, or a day boundary all end the run early. Messages between
those breaks share one reserved 30pt-wide slot so the bubble column stays
aligned whether or not that particular line drew a face.

**Never shown on your own messages.** Same rule Messenger follows — you
already know who sent those, and an avatar there would just be your own
face repeated down the transcript. `_senderAvatarFor` returns null for
`message.isMe` before it even looks at the sender.

Implemented OUTSIDE `MessageBubble` on purpose, wrapping it in `_buildItems`
rather than touching the bubble's own internals: `MessageBubble.build()` has
a dozen-plus branches (deleted, call event, poke, view-once, sticker, text,
media, poll, …), each already ending in its own `Align(alignment: isMe ?
centerRight : centerLeft, …)` sized to the full row width it's handed.
Wrapping the finished bubble in `Row([avatarSlot, Expanded(bubble)])` at the
one call site that already builds every message gets the avatar onto every
message kind for free, instead of touching — and risking drifting apart
across — every branch inside the bubble itself.

Regression tests: a group chat (two consecutive messages from one member,
one from another, one of your own) pins the exact avatar sequence by name;
a 1:1 chat pins that a two-message incoming run draws one avatar and your
own message draws none.

**This one real regression, caught by the full suite before it shipped, not
by either avatar test.** `openChatSettings` — the shared test helper every
"open the chat header, check contact settings" test calls — tapped
`find.byType(UserAvatar).first`, which was unambiguous only because the
header was the ONLY `UserAvatar` on screen. Once an incoming message can also
draw one, `.first` stopped reliably meaning the header, and 8 existing tests
broke with a confusing downstream `Bad state: No element` (the SETTINGS
screen they expected never opened, so a later `scrollUntilVisible` found
nothing to scroll to). Fixed by giving the header avatar's existing
`heroTag: 'chatHeaderAvatar'` something to do beyond the Hero animation — the
helper now matches on it directly (`find.byWidgetPredicate`) instead of tree
order. A second regression test pins that tapping DIRECTLY on a bubble that
now carries an avatar still dismisses the keyboard via the ancestor
`Listener` (see "Two more chat bugs from the same report" above) — added
after a same-day report of "can't dismiss keyboard in chat" raised the
question of whether this feature had broken it. It hadn't: the Listener
observes the pointer-down along the whole hit-test path regardless of what
wraps the bubble, and this pins that rather than leaving it argued from
reading the render pipeline. The keyboard report is most likely a build that
predates 2026-08-12's fix reaching whatever the owner tested on — see
"Waiting on the user" item 1 below, which was already the longest-standing
item on this list before this report.

## A like on a photo/GIF, sticker or view-once message was recorded but never shown (2026-08-13)

Reported plainly: "User still can't like gifs in chat, it doesn't show user
liked gif, notifications for liked gif is delayed." #182 (the same day)
fixed double-tap-to-like on a VIEW-ONCE photo by wiring `onDoubleTap` into
`_ViewOnceBubble` — but that fix, and its test, only proved the CALLBACK
fired. Nothing checked whether the reaction actually appeared, and it
didn't: `MessageBubble.build()`'s shared trailing `Stack` draws the
`_ReactionPill` for a plain TEXT message only. `_ImageBubble` (photos and
GIFs — a GIF rides as an ordinary image message with a real URL, see
`_handleSendGif`), the inline STICKER branch, and `_ViewOnceBubble` each
return their own widget tree early and none of the three ever drew a pill.
Double-tapping any of them recorded the reaction in `ChatStore` exactly
correctly — `_react`/`toggleReaction` don't know or care what kind of
message they're reacting to — so the state was right and the SCREEN was
wrong, which reads exactly like "liking does nothing."

Fixed by threading `hasReactions`/`onReactionsTap` into all three and
wrapping each one's content in a `Stack` with a `Positioned` `_ReactionPill`,
the same shape the text bubble already used. Three widget tests construct a
`MessageBubble` directly with `reactions: ['❤️']` (etc.) for an image, a
sticker, and a view-once message and assert the emoji actually renders —
the exact check #182's test never made.

**"Notifications delayed" is not a separate bug.** `RelayService.sendReaction`
already fires a push (`PushService.instance.notify`) on every ADD, regardless
of what kind of message was reacted to — there is no GIF-specific code path
to be slow. The most likely explanation is the same missing pill: with no
visible confirmation on the sender's own screen, a genuine but ordinary
push-delivery delay (APNs + the `push-send` round trip, the same latency
every chat push has) reads as "nothing happened yet" rather than "the other
side hasn't seen the banner yet." Unverified from this box either way — push
latency needs a real device to time.

**Worth periodically re-auditing for a fourth bubble kind.** `_CallEventBubble`
and `_PokeBubble` also return early and also never draw a pill; left alone
here because nothing has reported either as unlikeable, and a call record or
a poke reacting to itself is a different question from "can I like a photo."

## A server had no pull-to-refresh once you were already inside it (2026-08-13)

The SERVERS LIST (`CommunitiesTab`) has always wrapped in `PullToRefresh`;
`CommunityScreen` — what opens when you tap into one specific server — never
did, reported as "there's no pull down to refresh inside of servers."
`body: ListView(...)` is now `body: PullToRefresh(onRefresh: () =>
RelayService.instance.fetchCommunityPosts(), child: ListView(...))` — reusing
the shared `PullToRefresh` widget rather than a hand-rolled
`RefreshIndicator` (its own doc comment says to), which also runs the
standard `resync()` (rebuilds the relay's live subscriptions — see "the
Listener… `wake()`… rebuilds the live subscription rather than trusting it"
in `pull_to_refresh.dart`'s own comments) ahead of the community-specific
`fetchCommunityPosts()` call. That resync half matters beyond stale posts: a
server's REALTIME broadcast channel (`_feedChannel`, the transport `vpres`/
`vpreq`/every other community event rides) is subscribed once at relay
`start()` and never re-subscribed on its own — if it silently died, pulling
to refresh from inside the server you're looking at is now the way to force
it back, the same self-heal chat already had via its own pull-to-refresh.

## Voice channel presence: a joiner announced immediately, but nobody already asked to hear about it caught up (2026-08-13)

Reported as "servers aren't in sync, I'm in the same server on another
account yet they can't see me in voice channel." `VoicePresenceStore.join()`
already announces the JOINER the instant they join (`_announce(joined:
true)`), which reaches anyone with a live connection right away — but
presence has never had any REQUEST/RESPONSE shape, only announcements: a
device opening a voice channel screen for the first time, or one whose
`_feedChannel` subscription had silently died (see the server pull-to-refresh
section just above) and only just got rebuilt, had no way to learn who was
ALREADY in the room except by luck — waiting for each occupant's own next
20-second heartbeat.

**`vpreq`** — a new live-only community broadcast event, the same
`_broadcastCommunityEvent` shape `vpres`/`chtyp` already use (never mailboxed;
a "who's here" request replayed hours later from an offline queue would be
nonsense). `RelayService.sendVoicePresenceRequest(communityId)` fires it;
`_VoiceChannelScreenState.initState()` calls it unconditionally, whether or
not this device has actually joined the room — asking is free and every
device already in one of that server's voice channels
(`VoicePresenceStore.instance.myCommunityId == cid`) answers by calling the
EXISTING `announceNow()` (the same re-announce the app-resume foreground
handler already uses), so no new store method was needed. Registered in both
places a community event must be — the `.onBroadcast(event: 'vpreq', …)`
listener and the `_applyCommunityEvent` switch case — missing either
silently drops it, same discipline every other community event in this file
follows. No unit-testable seam without a live relay (like the #128 join
bootstrap and the fetchCommunityPosts backfill above it), so three source
pins hold it: the broadcast is actually listened for, the case re-announces,
and `initState` actually asks.

**Still an honest live-only limit, not fully closed.** If the OTHER device's
`_feedChannel` subscription is ALSO dead at the exact moment the request
goes out, neither the request nor the reply crosses — this narrows the
window (a live request now always gets a live answer instantly, rather than
depending on both sides' heartbeats aligning) but doesn't remove the need for
a genuinely dead socket to be rebuilt first, which is what the server
pull-to-refresh above now gives someone a manual way to force.

## An existing member never proactively shared their sender key with a new joiner (2026-08-13)

Reported plainly, and reproduced even on a server created fresh, on a
TestFlight build: "servers aren't working ... text channels don't show any
messages." #128 (2026-08-08) fixed the JOINER's half of the sender-key
bootstrap — a fresh member's `chjoin` rides the SHARED SECRET (not a sender
key the owner might not hold), and `backfillFeedTo` hands the joiner the
owner's key before sending catch-up FEED posts. What #128 never touched:
ongoing CHANNEL MESSAGES from members who were already established before
the join.

`_sealCommunity` auto-distributes a member's own SKDM only on their
FIRST-EVER send for a community (`!SenderKeyStore.instance.hasOwn(id)`).
Once established — true for ANY member who posted before today — that
auto-distribute never fires again. So a brand-new joiner only ever got an
existing member's key by ACCIDENT: fail to decrypt that member's NEXT live
message, send `skreq`, and hope the member posts something new while the
joiner is still around to receive the reply. A server whose existing
members simply hadn't posted since the join left the joiner staring at a
channel with nothing in it — not even a "couldn't decrypt" placeholder,
because there was never a failed decrypt to trigger the repair in the first
place. `chjoin`'s handler now closes the OTHER direction of the handshake:
on seeing a member join, a device that already has an established key for
this community (`SenderKeyStore.instance.hasOwn(cid)`) hands it directly to
the new joiner (`_distributeSkdm(community, toDigits: joinedDigits)`) —
mirroring what the joiner's own `sendServerJoin` already does for existing
members, just running the other way. Wire-only fix, no unit-testable seam
without a live relay (same as #128), so a source pin holds it.

**Voice presence is unrelated to this and was independently ruled out**: it
rides the plain shared community secret (`_sealCommunity`'s legacy `'data'`
path is available to every member immediately — no per-sender key needed at
all), so an empty voice channel reported alongside this is NOT explained by
the SKDM gap above. If it persists after this fix reaches a build, it's a
separate fault — the vpres/vpreq mechanism above (or the underlying realtime
connection) rather than key distribution.

**Unverified from this box, same honest limit as every relay fix in this
file** — there is no live two-account setup to confirm against here. This
closes a real, traced gap in the handshake; it has not been confirmed as the
one thing behind the report until a fresh build reaches two real devices.

## Servers get a central authority — Phase 1: structure, not content (2026-08-13)

The owner's direct ask: "I want this app to have a central authority."
Scoped down over two rounds of questions to something bounded rather than a
rewrite: **community/channel/membership/role structure becomes
server-authoritative via real Postgres tables + RLS. Message and
channel-message CONTENT stays exactly as end-to-end sealed and peer-relayed
as it always has.** This reverses a real gap stated plainly: until now a
"server" had no server-side authority at all — `CommunityStore` was pure
local state, every structural change (rename, add a channel, change a role,
remove a member, ban someone — ~25 methods) was a full re-serialization
broadcast + mailboxed to every other member, who unconditionally overwrote
their local copy from whatever arrived last, and — the part worth saying
plainly — nothing server-side ever checked that the change came from someone
allowed to make it. Two real bugs this same day (the sender-key handshake
gap, empty voice channels) both trace back to that: there was no durable,
permission-checked place to ask "who is actually on this roster right now."

**A cache-coherence backstop layered on top of the gossip protocol, not a
replacement for it.** Every existing broadcast/mailbox/mesh path (`chupd`,
`chjoin`, `applyRemoteStructure`, `sendServerJoin`, `rotateServerKey`, the
sender-key handshake) stays completely untouched and remains the ONLY path
for a fully offline device or one reachable only over Bluetooth mesh —
permanently, not a migration-window limitation. `docs/community_structure.sql`
adds five tables (`community_servers`, `community_members`,
`community_channels`, `community_roles`, `community_bans`), each following
this codebase's established four-part shape (table+RLS, column privileges,
policies, — no `_view` layer here, since real members legitimately see the
real roster and RLS alone does the work). A genuinely NEW RLS shape for this
codebase: every other table here is world-readable-minus-sanctioned or
owner-only; this is the first "readable only by the N actual members of
server X" pattern (`is_community_member`, modeled on
`community_pass_active`'s existing style).

**The server stores only `sha256(secret)`, never the raw content-decryption
key** — confirmed directly with the owner. `community_servers.secret_hash`
is withheld from every client SELECT grant (only `community_join`, running
as `security definer`, ever compares it), so a private server's real
content key never has a durable server-side home, and a compromised
service-role credential still can't read a private server's traffic. A
public (listed) server's secret already lives in the clear in
`server_directory` — that trade was made when Discover shipped and is
unchanged here.

**Join is an RPC, not a permissive insert policy, on purpose** —
`Community.id` is `'c_${name.hashCode}_${_communities.length}'`
(`lib/state/community_store.dart`), low-entropy and guessable, so a plain
insert policy would let a stranger enumerate ids and add themselves to any
roster with no invite. `community_join(cid, secret_hash, my_name)` silently
no-ops on a wrong hash, a per-server ban, a platform-wide lockout, or —
**the other decision confirmed directly with the owner** — an unpaid pass on
a paid server, reusing the existing `community_pass_active()` from
`docs/paid_servers.sql`. Today's `joinFromInvite` performs no payment check
at all (the paywall was a UI convention the app was trusted to have already
applied); a leaked invite for a paid server can no longer register a holder
as an authoritative member without an active pass. This doesn't change the
underlying crypto exposure — anyone holding the secret can still decrypt
content regardless of payment, same as today — it only tightens who is
listed as a roster member.

**Two real bugs caught and fixed before this ever ran, both worth naming
so they aren't rediscovered.** First, a self-caught security bug: the first
draft of `community_members_insert` let ANY authenticated, non-locked-out
account self-insert into ANY community's roster directly — bypassing
`community_join`'s secret check entirely, exactly the guessable-id hole the
RPC exists to close. Fixed before it was ever tested: the policy is now
admin-only (`role <> 'owner' and can_manage_community(community_id)`), with
self-join reserved for the RPC alone, which needs no client insert
privilege since it runs as table owner. Second, a real bootstrap gap the
fix above created: an admin-only insert policy means even the ACTUAL owner
can never insert their own first roster row (`can_manage_community` reads
`community_effective_role`, which reads `community_members` — circular for
a brand-new server with no rows yet). Closed with a trigger,
`community_servers_seed_owner`, that seeds the owner's own `'owner'`-role
row the instant their `community_servers` row is created — the Dart side
never has to special-case the owner's first insert, and the members
insert/update policies can stay strictly admin-only without a self-insert
branch reopening the original hole.

**Opportunistic, no forced migration, ever.** A legacy (still-local-only)
server gets authoritative rows for free the moment its owner's device next
publishes it — `RelayService.publishCommunityStructure` is OWNER-ONLY
(verified against `community.members.first`, the same roster-index-0
convention the rest of this app already trusts for ownership) and hangs
off `CommunityStore.onStructureChanged`, the one funnel every one of those
~25 mutation methods already calls, so no method needed its own dual-write
site. Every device also opportunistically re-registers itself
(`joinCommunityAuthoritative`, `community_join`'s `on conflict do nothing`
makes repeat calls harmless) for every community it already knows about,
once per relay start and pull-to-refresh
(`RelayService._syncCommunityStructure`). A community whose owner never
reopens the app again simply never gets a row here and keeps working
exactly as it does today, forever. A numberless account is not reached at
all — every policy/helper is phone-JWT-based, and a numberless account has
no Supabase session to carry one; it transparently keeps using legacy
peer-broadcast membership for every community, indefinitely, stated here
rather than discovered later.

**Reading it back**: `CommunityStore.applyAuthoritativeStructure` is a
SEPARATE method from `applyRemoteStructure`, not a replacement — a
different input shape (column-map rows from a SQL fetch, not one JSON
snapshot) and a different trust model (RLS already checked who could write
these rows). Channels/roles/members are rebuilt wholesale from the fetched
rows, which is what deletes anything no longer present server-side (a
channel removed, a role deleted, a member gone) — the same
"rebuild-deletes-by-omission" trick `applyRemoteStructure` already relies
on. Local-only fields (messages, pinned ids, forum posts) are preserved by
carrying them over from the existing channel rather than being reset, and
the owner is explicitly re-sorted to `members.first` regardless of the
fetch's row order, since that's an invariant the rest of the app depends
on and Postgres row order isn't something to trust for it. Never creates a
community from nothing, mirroring `applyRemoteStructure`'s own guard.

Sender-key/rotation mechanics for message CONTENT are completely
untouched by any of this: moving roster AUTHORITY to Postgres changes who
decides who's on the roster, not how content stays readable to exactly the
current roster. `onMemberRemoved` keeps firing `rotateServerKey` exactly as
today; republishing the whole roster from `onStructureChanged` naturally
drops a removed member's row and adds a fresh ban row (rebuild-by-omission
again), so no separate handling was needed there — a member leaving or
being kicked always fires `onStructureChanged` alongside `onMemberRemoved`
(`removeMember`/`banMember` both call it first).

`tool/check_sql.sh` pins the whole threat model against a real throwaway
Postgres, fresh apply AND idempotent re-apply: creating a server seeds the
owner's roster row; a stranger cannot self-insert into any roster; a
non-member cannot read a server's channels; `community_join` with the wrong
hash is a silent no-op and with the right hash actually joins; a per-server
ban refuses the join even with the right secret; a paid server refuses the
join with no active pass and admits one with a pass; `secret_hash` and
`select *` on `community_servers` are both refused.

**A THIRD bug, this one only visible live, found right after running the
migration for real.** The file's own header claimed "no anon grant anywhere
in this file" — true of what the file GRANTS, false of what the live table
actually ended up with. This is the exact `find_people_by_hashes` lesson
from `docs/directory_phone_privacy.sql` repeating itself: a live Supabase
project grants table-wide privileges to `anon` on every NEW table by
default, and only `community_servers` had gotten the explicit
`revoke select on table ... from anon, authenticated` this file's other
sensitive tables never did (there was no column to protect on the other
four, so the revoke dance felt unnecessary — it wasn't). `community_members`/
`community_channels`/`community_roles`/`community_bans` quietly held full
`SELECT`/`INSERT`/`UPDATE`/`DELETE` for `anon` from the moment they were
created. **RLS meant nothing actually happened** — every policy in this file
is scoped `to authenticated` only, so no policy ever matched an `anon`
caller, and reading structure would have returned zero rows regardless —
but a raw grant sitting unused is exactly the kind of thing this codebase
has already been burned by relying on RLS alone to guard: the day a policy
changes, the grant is already there waiting. Fixed with a blunt
`revoke all on <table> from anon;` on all five tables (simpler than naming
privileges, since anon should never reach any of them at all — unlike
`server_directory`/`market_listings`, nothing here is meant to be
world-readable), applied live and re-verified: an anon-key REST call
against all five tables now answers `42501 permission denied for table …`
directly (PostgREST's own hint literally names the grant that used to
exist). `check_sql.sh` pins the intent via `has_table_privilege` — the
throwaway Postgres has no such default and can never reproduce the bug
itself, same as the `find_people_by_hashes` assertion it's modeled on.

**RUN + verified live 2026-08-13.** All five tables, the seed trigger, all
eight functions, and 19 policies confirmed present via the Management API
after applying `docs/community_structure.sql` against the real project
(`trbdqucphtsstnrwwfnw`); `community_servers.secret_hash` carries no SELECT
grant for `anon`/`authenticated`; the safe column list on `community_servers`
reads back exactly as written. `community_join`'s EXECUTE grant is PUBLIC
(the same default-grant behavior as above) but that is NOT a hole the way
`find_people_by_hashes` was: the RPC's entire effect gates on
`auth.jwt() ->> 'phone'`, which a caller with no real Supabase Auth session
cannot forge no matter what parameters they pass — probed directly with the
anon key and it 204-no-ops, exactly as the "wrong secret / no session" path
promises. Do not re-raise the anon-grant question as pending; do treat any
FUTURE table added to this file as needing the same explicit
`revoke all ... from anon` — it is not automatic.

## Servers get a central authority — Phase 2: voice channel presence (2026-08-13)

The direct, concrete answer to "is Discord voice channels the same way":
opening a voice channel now runs one deterministic read for full current
occupancy, instead of only ever learning who's here from accumulated
broadcasts. Reuses Phase 1's helpers directly (`is_community_member` for
read, `can_moderate_community` for a force-disconnect) — near-zero new
design, one table.

**A ground-truth read, not a second source of truth.** The existing `vpres`/
`vpreq` live broadcast (`VoicePresenceStore`) is completely untouched and
stays the low-latency path for "someone just joined/left/muted while I'm
already watching this room" — nobody wants a 20-second heartbeat lag for
that. `docs/community_voice.sql`'s `community_voice_presence` table answers
the ONE thing broadcast structurally can't cover: opening a room you weren't
already watching. `_VoiceChannelScreenState.initState` now fires both —
`sendVoicePresenceRequest` (the existing live ask) and the new
`RelayService.fetchVoicePresence` (the table read) — because they answer
different questions: the table answers instantly from whoever already wrote
a row, the live ask answers a moment later from whoever is still genuinely
connected right now.

**One callback, two consequences — same shape `publishCommunityStructure`
took off `onStructureChanged` in Phase 1.** `VoicePresenceStore.onPresence`
already fires on every join/leave/mute/camera/screen-share AND the existing
20-second heartbeat; `main.dart` now wires it to call
`RelayService.publishVoicePresence` alongside the existing `sendVoicePresence`
broadcast, so nothing about `VoicePresenceStore` itself or its call sites in
`communities.dart` had to change. This is also what keeps `last_seen` fresh
in Postgres for free: the write rides the SAME heartbeat timer that already
exists, so no second timer was built.

**No server-side sweep, on purpose — the plan's own honest tradeoff, kept.**
A force-quit or a dead network stops the heartbeat, which stops `last_seen`
from advancing, and nothing ever deletes the row for it. A reader filters
`last_seen > now - 65s` CLIENT-SIDE — `VoicePresenceStore.applyGroundTruth`
feeds every fetched row through the SAME `applyRemote` a live broadcast
already uses (just with the row's own stored `last_seen` instead of "now"),
then calls the existing `sweep()`, so a fetched occupant ages out on the
exact clock a broadcast-heard one already does — one clock, not two. A row
already stale by the time it's read is applied and immediately swept rather
than skipped outright, so there is only ever one place ("is this older than
`staleAfter`") that decides what counts as current.

**The local user's own row is deliberately never applied from the fetch.**
The fetch would return this device's OWN write too — applying it under the
device's real wire digits would draw a second, stale copy of the local user
alongside the real `'me'` entry `VoicePresenceStore` already tracks.
`applyGroundTruth` takes `myDigits` and skips any row keyed under it: this
device already knows perfectly well whether it's still here.

**A real force-disconnect capability the old broadcast-only model literally
could not offer, because there was nothing to delete.** A moderator+'s
DELETE reaches this table (`can_moderate_community`); an ordinary member's
DELETE only reaches their own row. This is the roster-eviction half of a
kick, not the media half — it does not tear down the target's actual WebRTC
connection, which stays a client-driven hangup exactly as it always has. The
button in front of it shipped the same day — see below.

**The same anon-grant lesson Phase 1 had to learn live, applied from the
start this time.** `docs/community_voice.sql` opens with an explicit
`revoke all on public.community_voice_presence from anon;` before any grant
to `authenticated` — closed before the file was ever run, not found after.

`tool/check_sql.sh` pins the whole shape against a real throwaway Postgres,
reusing Phase 1's `t_cs1` test server rather than standing up a fresh one: a
member can announce and read their own channel's presence; a non-member can
neither announce nor read; a member cannot rewrite or delete another
member's row; a moderator (the owner) CAN force-disconnect someone else; a
plain member cannot; `anon` has no privilege on the table at all.

**RUN + verified live 2026-08-13.** Applied against the real project
(`trbdqucphtsstnrwwfnw`) and read back via the Management API: the table
exists, RLS is on, all 4 policies are present, `anon` holds zero privileges
on it, `authenticated` holds the expected set, and the FK to
`community_servers` resolves. A live anon-key REST probe confirms it end to
end: `42501 permission denied for table community_voice_presence`, closed
correctly from the start this time rather than found after. Do not
re-raise as pending.

Channel typing and read/delivery ticks stay pure ephemeral broadcast/
mailboxed events, permanently — see the plan's own reasoning for why those
don't belong here.

## Kick from voice: the button in front of Phase 2's DELETE (2026-08-13)

A voice channel's grid tile is now long-pressable: a moderator+
(`CommunityStore.canModerate`) long-pressing anyone else's tile gets a
confirm dialog ("Disconnect \<name\>? They'll be removed from this voice
channel. They can rejoin any time.") and, on confirm,
`RelayService.forceDisconnectVoice(communityId, channelId, digits)`. A plain
member's long-press on someone else's tile does nothing — `_memberTile`'s
new `onLongPress` is only wired for a moderator, and `GestureDetector`
wraps the existing tile rather than replacing it, so nothing about the
tile's own look changed.

**Two halves, and only one of them is real enforcement.** The DELETE against
`community_voice_presence` (Phase 2's `community_voice_presence_delete`
policy, gated on `can_moderate_community`) IS the actual kick — a
non-moderator's call matches nothing under RLS and silently changes zero
rows, same as every other moderation action in this app. Alongside it, a new
live-only community-bus broadcast, `vkick` (`{channelId, target}`, same
`.onBroadcast`/`_applyCommunityEvent` shape as `vpres`/`vpreq`), is a
best-effort nudge so the target's own device hangs up immediately instead of
lingering until it happens to notice its row is gone — nothing currently
polls for that. `forceDisconnectVoice` sends the broadcast regardless of
whether the DELETE actually matched a row, since a moderator's tap should
always at least ask the target to leave.

**`vkick` is deliberately NOT permission-checked on the receiving end.** A
forged `vkick` can only make the RECEIVING device hang up its OWN call — the
same as if that person had tapped Leave themself — never anyone else's, so
there is nothing to protect against beyond the annoyance of a bogus
disconnect. The handler reuses the exact same pair
`_VoiceChannelScreenState._leave()` already calls for the ordinary Leave
button: `RoomMedia.instance.leaveRoom()` (media teardown) and
`VoicePresenceStore.instance.leave()` (local presence), guarded on
`target == me && VoicePresenceStore.instance.myChannelId == channelId` so a
stray or late `vkick` for a channel this device already left does nothing.

Regression tests: a moderator long-pressing another occupant's tile sees and
can confirm the disconnect dialog; a plain (non-moderator) member sees no
dialog on long-press; a source pin holds `forceDisconnectVoice`, the `vkick`
broadcast, and that the `case 'vkick':` handler actually calls both
`RoomMedia.instance.leaveRoom()` and `VoicePresenceStore.instance.leave()`
rather than only dropping the local roster entry.

## Central authority, Phase 3: 1:1 and group chat structure (2026-08-13)

The same cache-coherence backstop Phase 1 built for servers
(`docs/community_structure.sql`), now for chats: `docs/chat_structure.sql`
adds `direct_chats` + `chat_members`, a durable RLS-scoped copy of who's in a
group and (for a group) its name/photo/about, layered over the existing
`gupd` gossip protocol, which is completely untouched and stays the only path
for a fully offline or mesh-only device. **Message content is not touched at
all** — 1:1 and group messages keep riding the same pairwise Double
Ratchet/static-ECDH ladder they always have (`sealContent`/`send`/
`sendToGroup`), and there is no sender-key/rotation concept here, unlike a
server's broadcast bus: group content crypto is independent pairwise sessions
per recipient, not a shared key a roster change would need to rotate.

**What this actually closes: `gupd` had no server-side permission check at
all.** Any device could forge a "remove this member" or "here's the new
roster" payload and every recipient trusted it unconditionally. The new RLS
matches what the CLIENT already promises rather than inventing a new rule —
found by reading `group_info_screen.dart` directly rather than trusting a
first-pass research summary that claimed there was no permission check
client-side either, which was wrong: the app already gates member REMOVAL to
the admin (roster index 0, `iAmAdmin && i != 0`), and there is no "leave
group" feature anywhere in the app. `chat_members_delete` enforces exactly
that (owner-only, owner can never remove themselves); adding a member and
renaming/re-photographing the group stay ungated for any member, because
that's what `openGroupEditor` and the add-members flow already are.

**Two shapes of chat, one pair of tables — `owner_phone` is the switch.**
A group has a real owner and an objective shared identity everyone sees the
same way. A 1:1 has neither: `Chat.contact.name` is each side's OWN local
name for the other person (you might call them "Mom", they call you "John"),
so publishing a shared "name" for a 1:1 would leak how you renamed them or
mean nothing. `owner_phone = ''` means a 1:1, and name/avatar_color/about
stay empty and are never published for one.

**Bootstrap has to be two different shapes, and the reason is worth stating
plainly.** A group gets the exact `direct_chats_seed_owner` trigger pattern
`community_servers_seed_owner` uses — creating the row auto-seeds the owner's
own `chat_members` row, closing the chicken-and-egg the admin-only insert
policy would otherwise create for the very first member. A 1:1 has no single
owner identity to seed from a trigger — BOTH real parties have to
self-register — so `phone_a`/`phone_b` (set once at insert, never in the
update column grant) name the two real parties directly, and a NEW
`security definer` function, `is_direct_chat_party`, is what the bootstrap
insert policy checks a self-insert against. **That function exists because
the first version didn't have it** — a plain `exists (select 1 from
direct_chats where ...)` embedded directly in the policy runs as the CALLING
role, which is itself subject to `direct_chats_read`'s own
`is_chat_member(id)` policy — false for the very party trying to bootstrap
their way in, so the row was invisible to its own check even though it
genuinely named them. `sh tool/check_sql.sh` caught this immediately (`new
row violates row-level security policy`) before it ever reached the app,
which is exactly the class of self-reference bug `is_chat_member` and
`is_community_member` are already `security definer` to avoid — the fix here
is the same fix, just for a policy that needed a NEW helper function rather
than reusing an existing one.

**A group is exactly as guessable as a `Community.id`, which is why the
1:1 bootstrap shape isn't reused for groups.** `Phase 1` refused a bare
self-insert bootstrap for a server's roster because `Community.id` is
`c_${name.hashCode}_${count}` — low entropy. A chat's id
(`group_${epochMicroseconds}`) is exactly as guessable, so a group's ONLY
bootstrap is the owner-seed trigger; every other member is added by an
EXISTING member (`is_chat_member`), never a stranger guessing the id. A
1:1's id (`chat_${contact.id}`) is no safer in the abstract, but
self-inserting into ITS roster requires already being named `phone_a` or
`phone_b` on a row that can only ever have been created by one of those two
real phones — guessing the id alone is not enough, closing the same class of
hole a different way.

**`direct_chats` is insert-once for a 1:1, never updated — a second
chicken-and-egg avoided rather than solved with more RLS.** Nothing about a
1:1's row is worth updating after creation (name/avatar/about are never
populated; identity columns are immutable by design), so
`publishDirectChatExistence` upserts with `on conflict (id) do nothing`.
Using a real UPDATE instead would have needed `is_chat_member(id)` to pass —
true for whichever party created the row, but not yet true for the SECOND
party the first time THEIR device syncs, since they haven't self-registered
into `chat_members` yet at that point either.

**No delete path on `direct_chats` at all, matching the shipped app.** There
is no "leave group" and no "delete this 1:1 forever" feature client-side;
`ChatStore.deleteChat` is LOCAL only (hides the conversation on this
device), and this table was never meant to track that. The only delete grant
is on `chat_members`, gated to the group owner removing a non-owner.

**Wiring, minimized rather than scattered.** `publishChatStructure` hangs
off `sendGroupUpdate` directly — the ONE funnel every group structural
change (create, rename, add member, remove member) already passes through,
confirmed by reading every call site rather than assumed — so there was no
need for a Phase-1-style `onStructureChanged` callback with ~25 hookup
points. A 1:1's existence publishes once, from `ChatScreen._deliver`'s
real-peer branch, guarded by a per-screen `_publishedDmExistence` bool so an
outgoing message after the first doesn't repeat the write.
`_syncChatStructure()` runs at the same two points `_syncCommunityStructure`
does — relay start and pull-to-refresh — republishing every group this
device owns and fetching current structure for every chat it already has
locally (a 1:1 with no authoritative row yet is never republished from
here; its existence is a one-shot from the first real message, not
something relay start manufactures).

**`ChatStore.applyAuthoritativeChatStructure` is honest about doing less for
a 1:1 than for a group.** Mirrors `CommunityStore.applyAuthoritativeStructure`
exactly for a group (never creates a chat from nothing, rebuild-deletes
members by omission, preserves local-only fields — messages, unread count,
pin/mute/favorite, disappearing-messages timer). For a 1:1 it is close to a
genuine no-op: `Chat.members` stays empty for a 1:1 by definition and the
contact identity is local-only, so there is nothing published to reconcile
beyond the row proving the relationship exists — stated in the method's own
doc comment rather than quietly doing nothing and leaving the reader to
wonder why.

`sh tool/check_sql.sh` pins the whole shape against a real throwaway
Postgres: creating a group seeds the owner; a stranger cannot self-insert
into a group OR read its structure; any existing member (not just the
owner) can add another member or rename the group, matching the shipped
app; a plain member cannot remove anyone; the owner can remove a non-owner
but never themselves; nobody can rewrite `owner_phone`/`is_group`/
`phone_a`/`phone_b` (not in the update column grant); a 1:1 can only be
created by one of its two named parties; a stranger cannot create one
naming two OTHER people or self-insert into one they aren't named in; both
real parties of a 1:1 CAN self-register; nobody can ever remove a 1:1's
party. **A DELETE that matches no row under RLS does not raise — it just
silently deletes zero rows**, the same "stranger's write is a no-op" shape
`community_voice_presence`'s own tests already rely on, so those assertions
are row-count checks rather than `expect_fail` (which would pass on a real
success too, since no exception is ever thrown either way) — caught by
running the tests, not assumed correct on write.

**RUN + verified live 2026-08-13.** Applied against the real project
(`trbdqucphtsstnrwwfnw`) and read back via the Management API, then probed
live rather than assumed: both tables exist with RLS on and the exact
policy counts (`direct_chats` 3, `chat_members` 3); `authenticated` holds
exactly the intended privileges, and `direct_chats`' UPDATE grant is
column-scoped to precisely `name`/`avatar_color`/`about`/`updated_at` — not
`is_group`/`owner_phone`/`phone_a`/`phone_b`; `is_chat_member`,
`is_direct_chat_party`, and `direct_chats_seed_owner` all exist, the two
functions are `security definer`, and the trigger is attached to
`direct_chats`. A live anon-key REST probe against both tables answers
`{"code":"42501","message":"permission denied for table …"}` — closed from
the start, confirmed rather than inferred from a migration file. Do not
re-raise as pending.

## Central authority, Phase 4: call presence (2026-08-13)

The same cache-coherence backstop as Phase 1-3, now for live calls:
`docs/call_presence.sql` adds `call_rosters`, a durable row per (call,
member) that corrects the one real gap `CallSession.members` has always
had — it's built purely from accumulated signaling events
(`onRemoteJoined`/`onRemoteLeft`), so a `left` that never arrives (a
force-quit, a dropped connection) leaves that peer permanently `joined` on
every other device forever, with nothing that sweeps it. Signaling and
media are completely untouched: `offer`/`answer`/`ice`/`end`/`decline`/
`joined`/`left` keep riding the same pairwise Double Ratchet/static-ECDH
ladder they always have, media stays DTLS-SRTP below any of this, and
there is no sender-key/rotation concept here — this is presence
bookkeeping, not a broadcast key.

**The one real design departure from Phase 1-3: no durable parent row to
gate against.** A voice channel's presence FKs to `community_servers`, a
real, join-gated identity. A call has nothing like that —
`CallSession.callId` is a client-minted signaling correlation id
(`call_${peerDigits}_${epochMs}_${seq}`), invented fresh every call and
never durably registered anywhere. So eligibility couldn't be
membership-based the way every earlier table's was; it's **dial-list-based**
instead: `call_dial_list(cid)` reads the real dial list off whichever row
carries a non-empty one — always the founder's, the only row ever allowed
to name one — and `is_call_eligible` is true for anyone on that list, or
the founder themself (covering their own later re-inserts/heartbeats, once
their first row already exists).

**The bootstrap-hole follow-up is CLOSED (2026-08-13, same day).** The
design still lets the FIRST row for any call_id be founder-claimable by
whoever gets there first — that part is permanent, since `call_id` has no
durable parent to gate against. What made that a real hole was that
`call_id` used to be guessable within a narrow window (a predictable
prefix, an epoch-millisecond timestamp, a small sequence counter), so
someone could in principle race to squat a call_id before its real
founder's row landed. `CallService._newCallId` now appends 128 bits of
real entropy (`Random.secure()`, the OS CSPRNG) — the timestamp and peer
digits stay for readability, but carry none of the actual unpredictability
any more. With that fixed, nobody can guess a call_id they were never
handed, so the founder-claims-first-row bootstrap only ever fires for
someone actually given the id over the existing sealed signaling.
**Deliberately still a client-side fix, not server-minted ids** — an
authenticated RPC that had to mint the id before a call could even start
ringing was considered and rejected: it would mean a numberless account
(no Supabase session at all) could no longer place or receive calls,
breaking the one invariant every phase of central authority has held —
the legacy path keeps working, unconditionally, forever. The bounded-
exposure reasoning stands regardless: the ACTUAL ringing, the ACTUAL
WebRTC media, and who can decrypt either are governed entirely by the
existing sealed pairwise signaling, which this table cannot see or
influence — a forged row here could at most confuse a *read* of this
table (wired conservatively — see below), never grant access to a call's
audio, video, or signaling itself. `_seq`, the field the old predictable
counter used, is removed — nothing else referenced it.

**No moderator-delete, unlike voice presence's force-disconnect.** A call
has no owner/moderator concept to grant that power to — even the founder
cannot evict another member's roster row, only their own. Read/update/
delete are all self-row-only.

**Cleanup is deliberately both client-side AND scheduled, unlike every
earlier phase.** A voice channel's presence sweeps client-side off a live
`staleAfter` clock the moment anyone opens the channel screen again — there
is always a next "someone opens this" moment to piggyback a sweep onto. A
call has no equivalent: once it ends by a force-quit or a dropped
connection, no client code ever runs again for that call, so a client-only
cleanup would leave stale rows sitting forever. `RelayService.
leaveCallRoster` is the client half, wired at every real termination point:
`end()`, `decline()`, `onRemoteDecline`, `onRemoteEnd`, and the "everyone
else left" branch of `onRemoteLeft` (this device's own leg of a group call
ending because the last other member left). The scheduled half is a
`pg_cron` job, **the first use of pg_cron in this project** — deleting
anything with `last_seen` older than 2 hours, every 15 minutes. The whole
cron block is guarded (`create extension if not exists pg_cron` wrapped in
its own exception handler, then a check against `pg_extension` before
scheduling) so a Postgres without the extension — this repo's own
throwaway-Postgres test harness included — skips scheduling with a
`raise notice` rather than failing the whole migration.

**The read side is wired conservatively, on purpose — still true after a
second call site, since both are the same kind of moment.** `RoomMedia.
updateCallPeers` already exists and is already the correct sink (no new
RoomMedia API was needed) — `fetchCallPresence` just feeds it. Live
signaling is already the primary, reliable source for a call genuinely in
progress, unlike a voice channel (which can be *opened* with no signaling
ping having reached this device first — the whole reason Phase 2's
ground-truth read exists at all). `fetchCallPresence` is called from
exactly two places, both a device's own "genuinely on this call now"
moment rather than every UI tick: `accept()`'s group-call branch (joining
a call someone else founded) and, added the same day,
`onRemoteJoined`'s ringing-to-connected transition (the FOUNDER's own
group call connecting once the first invitee answers) — the mirror case
`accept()` alone didn't cover, since `accept()` only ever runs on the
callee's device. Together they cover both directions of "this device just
became genuinely part of a group call," without pretending every UI
moment needs a fresh table read the way opening a voice channel does.

**Publish is wired at every real join, not one shared funnel — because
there isn't one.** Unlike a group chat (where `sendGroupUpdate` is the one
funnel every structural change already passes through), a call has no such
chokepoint: founding a 1:1 call (`startOutgoing`), founding a group call
(`startGroupCall`), and joining one (`accept()`, both its 1:1 and group
branches) are four genuinely separate code paths, each publishing at the
moment it actually knows what it's founding or joining.

`sh tool/check_sql.sh` pins the whole shape against a real throwaway
Postgres: a founder can claim a brand-new call_id with the real dial list;
nobody can found a call claiming somebody ELSE as its initiator; a
stranger cannot join an already-founded call or read its roster; a real
dial-list member can join, read, and update their own row; a member cannot
rewrite another member's row; a member can leave themself; nobody — not
even the founder — can evict another member (no moderator-delete);
`is_call_eligible` confirms the founder always qualifies for their own call
and a stranger never does; `anon` has no privilege on the table at all.

**RUN + verified live 2026-08-13.** Applied against the real project
(`trbdqucphtsstnrwwfnw`) and read back rather than assumed: `call_rosters`
exists with RLS on and exactly 4 policies; `authenticated` holds
INSERT/SELECT/UPDATE/DELETE, `anon` holds none. `call_dial_list` and
`is_call_eligible` both exist and are `security definer`. **`pg_cron` is
genuinely available on this project** (extension v1.6.4, not merely
guarded-around) and `call_rosters_cleanup` reads back from `cron.job` as
`*/15 * * * *`, `active=true` — a real schedule, not just a migration that
didn't fail. A live anon-key REST probe answers `{"code":"42501",
"message":"permission denied for table call_rosters"}`. Not yet checked:
whether the job has actually FIRED (`cron.job_run_details` needs the
schedule to have run at least once since creation) — the schedule being
registered and active is confirmed; its first real run is not, since
verification happened moments after applying. Do not re-raise the
migration itself as pending; a job-run-history check is the only thing
still open here.

## Text channels reach chat's message-attribution features (2026-08-13)

Reported plainly: "Can't understand who's messaging who. Make it have the
same features as chat." A text channel (`_ChannelScreenState`/
`_ChannelBubble` in `lib/screens/communities.dart`) has always been a
LARGELY PARALLEL implementation of `ChatScreen`/`MessageBubble` rather than a
shared one — it reuses many chat-level primitives (`Message`,
`MessageStatusIcon`, `RichMessageText`, `VoiceNoteBubble`, `PollBubble`) but
independently reimplements its own composer, grouping, read-receipt acking
and reaction handling. Four gaps closed this round, all mirroring chat's own
already-shipped shape rather than inventing a new one:

- **A Messenger-style sender avatar, the actual fix for the report.** A
  channel showed the sender's NAME only on the first message of a run — easy
  to lose once several people are posting back to back, and nothing at all
  identified who sent a later message in that run. Now mirrors chat's
  `_isLastInSenderRun`/`_senderAvatarFor` exactly: a circular avatar beside
  an incoming message, shown once per run of consecutive same-sender
  messages, at the LAST bubble in that run (name label stays at the FIRST,
  unchanged) — a fixed 30pt leading slot reserved on every incoming line so
  a run's bubbles stay aligned whether or not that particular line draws a
  face, the same technique chat uses. `Member` (a channel's roster entry)
  carries no avatar fields at all — no color, emoji or illustrated seed, the
  way `AppUser` does — so `UserAvatar` cannot be used here; `InitialsAvatar`
  (`lib/widgets/initials_avatar.dart`) is the lighter name-only fallback,
  built straight off `Message.senderName` (which a channel message always
  carries) rather than needing a `Member` lookup.
- **One shared name→color mapping, not two independent guesses.** The
  channel's sender-name label picked its color from
  `Colors.primaries[name.hashCode % Colors.primaries.length]`; the 1:1/group
  chat's `_SenderLabel` picked from its own private 6-color palette. A member
  who is in both a server and a group chat used to read as two different
  colors depending which screen you were looking at. `InitialsAvatar`
  is now the ONE place a name maps to a color — `_SenderLabel.colorFor`
  delegates to `InitialsAvatar.colorFor` (same palette, so no behavior change
  for chat), and the channel's sender-name label and its avatar both read off
  it too.
- **Reactions record WHO reacted, fixing a real bug along the way.**
  `setChannelReaction`'s own doc comment used to say plainly: "the model
  holds a set of emoji, not who reacted, so two people's 👍 is one 👍" — but
  it was worse than lossy. The toggle was keyed on the MESSAGE, not the
  reactor: if member A reacted 👍, the message's `reactions` list held one
  👍; when member B then tapped 👍, the toggle read "already present" and
  REMOVED it — B's reaction read as B un-reacting A's. `toggleChannelReaction`/
  `setChannelReaction` gained an optional `reactor` (digits) parameter, and
  `Message.reactionsBy` (emoji → reactor digits, the field chat's own
  `toggleReaction`/`setReactionState` already populate) now gets kept in
  step in `CommunityStore`, mirroring `ChatStore`'s exact shape including the
  same idempotency rule (a duplicate add/remove for a reactor who already
  holds/lacks that emoji is a no-op). The wire carries this for free — the
  community bus's sealed envelope already names `from` on every event, the
  same identity `chack` (read receipts) already reads — so only the dispatch
  in `RelayService._applyCommunityEvent`'s `'chrxn'` case needed to pass
  `digits(payload['from'])` through, and `channelReact` (the helper every
  screen-side reaction goes through) needed to pass this device's own
  digits. Tapping a reaction pill now opens `_showChannelReactedBy` — a
  direct port of chat's `_showReactedBy` sheet, resolving reactor digits to
  member names off the community's own roster — instead of re-toggling the
  reaction; un-reacting moved to the existing double-tap / long-press
  quick-react row, the same split chat already has. The chip's shown COUNT
  now sources from `reactionsBy[emoji]?.length` when available, falling back
  to counting flat-list occurrences for a message from before this shipped
  (an old message has no `reactionsBy` bookkeeping to read).
- **On-device translate, offered the same way chat offers it.** A channel
  message's long-press sheet gained "Translate to `<language>`", wired to the
  exact same `TranslateService` every other translate button in the app
  uses — no network path, same honest "isn't available on this device yet"
  fallback, same "the text never left the phone" sentence on the result
  sheet.

**Deliberately NOT done this round, named rather than silently skipped:**
thread support and view-once messages — **both since closed, see below**
(2026-08-13, same day) — and consolidating the composer/grouping/read-
receipt code between `ChatScreen` and `_ChannelScreenState` into one shared
implementation, which would prevent this exact class of drift from
recurring but is a refactor nobody asked for. That last one is still open.

## Channel threads and view-once messages (2026-08-13)

The two gaps the previous section named and deferred. Both mirror chat's
existing shape exactly rather than inventing a channel-specific version —
same reasoning as the avatar/reaction work above: a second, subtly
different implementation is how these two surfaces keep drifting apart.

**Threads.** `ChannelScreen` takes an optional `threadRootId`, exactly like
`ChatScreen` — a thread is the SAME screen, re-pushed (`_openThread`), not a
second thinner one. The main room filters to `threadRootId == null`; a
thread filters to the root plus its own replies only (flat by design, same
as chat — a thread of threads is a second place to lose a conversation, so
"Reply in thread" is hidden both inside an already-open thread and on a
message that is itself already a reply). `Channel.lastRoomMessage` (mirrors
`Chat.lastMessage`) skips thread replies for the server's channel-list
preview. `CommunityStore.channelThreadReplies`/`channelThreadReplyCount`
back a new `_ChannelThreadLine` ("N replies") under a root message in the
main room, opening the thread on tap — the exact widget `ChatScreen`'s
`_ThreadLine` already is, ported rather than duplicated.

**Outgoing stamping goes through ONE funnel.** `_post` — the single place
every channel send already routed through (text, photo, voice, GIF) — now
stamps `threadRootId: widget.threadRootId` when `_inThread`, mirroring
`ChatScreen._deliver`. `_createPoll` was the one send path that DIDN'T go
through `_post` — it called `CommunityStore.postMessage` directly, which
meant a channel poll never relayed to any other member at all (a real,
separate bug, found only because giving every send type the same
thread-stamping meant routing poll-sending through the same funnel as
everything else). Fixed as part of this, not a separate pass.

**View-once.** `_ChannelBubble` renders a `message.viewOnce` message through
`ViewOnceBubble` — the SAME widget `MessageBubble` uses for chat, made
public (`ViewOnceBubble`, was `_ViewOnceBubble`) specifically so a channel
message reaches it directly rather than re-implementing it. Two new
attachment options, "View once" (a photo, `_sendPhoto(viewOnce: true)`) and
"Ghost message" (view-once TEXT, `_composeGhost`, its own one-line prompt —
never the main composer, so a half-typed ghost can't get mixed up with an
ordinary message). Opening one (`_openChannelViewOnce`) pushes the same
`ImageViewScreen`/`GhostViewScreen` chat uses.

**The remote receipt needed real thought, not a straight port.** Chat's
`vopen` is peer-addressed (sent to a specific contact's phone); a channel
has no such addressing — everything rides the sealed, mailboxed community
bus and reaches every member. A new `chvopen` event does that (registered,
like every community event, in THREE places: `RelayService.
sendChannelViewOnceOpened`, the live `.onBroadcast` chain, and the mailbox-
drain switch roster — missing any one silently drops it, the exact trap
this file has documented before). On receipt, `CommunityStore.
applyChannelViewOnceOpened` checks `Message.isMe` before flipping
`viewOnceOpened` — deliberately, because every member's device receives the
SAME `chvopen` broadcast, and only the message's actual original sender
should have their own bubble learn "it was opened." A member who merely
holds a copy of someone else's view-once message must not have THEIRS
silently marked spent by a different member's open — that would have been
the bug ported straight over from a peer-addressed 1:1 event that,
broadcast to a whole channel, means something different. `markChannel
ViewOnceOpened` (the LOCAL "I'm the one opening this right now" action) is
a separate method with no such guard, because it only ever runs on the
device actually doing the opening.

**Also fixed while wiring the receive side: a whitelist that silently
dropped a voice message's audio.** `_applyCommunityEvent`'s `chmsg` case
reconstructs the received `Message` field-by-field rather than trusting the
sender's full JSON (deliberately — reactions/edits/poll-votes/seenBy are
separate mutable state that must start fresh, not whatever the sender's
local copy happened to hold). But the whitelist never included
`isVoice`/`voiceSeconds`/`audioUrl`/`audioPath`/`audioKey` at all — a voice
message sent in a channel has been silently losing its audio on every OTHER
member's device since voice channels shipped. Found only because
`threadRootId` and `viewOnce` needed adding to the same whitelist for this
round's own features. All five audio fields, plus `threadRootId` and
`viewOnce` (never `viewOnceOpened` — a fresh delivery must always start
unopened, or a sender could hand over a pre-spent message), are now
included.

## Channel text reactions and starred messages (2026-08-13, same day)

A broader "channels feel behind chat" pass. A research sweep (comparing
every remaining ChatScreen/MessageBubble feature against `_ChannelScreenState`/
`_ChannelBubble`) turned up several genuine gaps; these two were the
cheapest and highest-value, so they shipped first — a UI-only port of an
already-existing mechanism, not a new one, in both cases.

- **Text reactions.** The channel message action sheet's quick-react row
  gained `TextReactions.defaults` chips + a "Custom" one-line prompt
  (`_pickCustomTextReaction`), the exact shape `ChatScreen`'s
  `_pickReactionEmoji` already uses. No mechanism change was needed —
  `Message.reactions`/`reactionsBy` were already plain strings, per
  `text_reactions.dart`'s own doc comment; the emoji row and the "any
  emoji" picker were the only two entry points, and this is a third.
- **Starred messages.** `CommunityStore` gained a channel-message star —
  `isChannelMessageStarred`/`toggleChannelMessageStarred`/
  `starredChannelMessages()` — mirroring `ChatStore`'s shape, INCLUDING its
  defensive composite key: chat's own `_starKey` is `'$chatId::$messageId'`
  because message ids are only unique within one conversation, and the
  same is true across channels (`_send()`'s id is a bare epoch timestamp,
  not channel-scoped), so the channel star key is `'$channelId::$messageId'`
  — a test pins that starring a message in one channel does not star the
  same id in a different one. `StarredMessagesScreen` — previously reading
  `ChatStore` alone — now merges both sources into one list (the same
  "two differently-shaped sources, one screen" pattern `BookmarksScreen`
  already established for public-feed + server-feed posts): a channel
  entry shows `#channel · Server` and opens that channel on tap.

**Named, not built, this round — the next concrete batch.** The research
sweep's other findings, roughly in the order worth tackling: channel
messages can't yet be sent as a **Sticker, Location, Live location, or
Contact card** — `Message` already carries all four fields
(`isSticker`/`isLocation`/`isLiveLocation`/`isContact`), so like text
reactions and stars this would be UI-only, just a bigger batch (a compose
option plus a bubble-rendering branch per kind) than either of these two.
Also found and deliberately left as open PRODUCT questions, not silent
gaps: whether a channel should support **disappearing messages**
(`Message.expiresAt` — chat has it, a channel currently has no equivalent
timer or UI, and it's genuinely unclear whether ephemerality fits a
durable, semi-public channel the way it fits a private 1:1) and whether a
channel should show **live "N people viewing this right now"** presence
(`GroupPresenceStore`/`gpres` exists for chat; channels only have
`VoicePresenceStore`, which is voice-channel-only and answers a different
question — this could read as a real feature or as noise at server scale,
and deserves a decision rather than an assumption). Per-channel wallpaper/
notification-sound was also checked and judged likely out of scope by
design — a channel's look reads as a server-level thing, not a personal
per-conversation one the way a 1:1's wallpaper is.

## Channels can send stickers, locations and contact cards (2026-08-13, same day)

The next batch named in the section above — the channel/chat parity pass
continues. All three are UI-only ports: `Message` already carried
`isSticker`/`isLocation`/`isContact` plus their payload fields, and
`sendChannelMessage` already sent the full `message.toJson()`, so the whole
gap was (a) no compose entry point in the channel attach panel and (b) the
`chmsg` receive-side whitelist in `relay_service.dart` silently dropping all
eight fields on every OTHER member's device (fixed first, alone, in
`4145ae2` — the third round of the exact bug class `voice-audio` and
`threadRootId`/`viewOnce` hit before it: the manual field-by-field
`Message(...)` reconstruction on receipt is deliberate (mutable state like
reactions/edits must start fresh), but that means every new field needs to
be added to the list by hand, and three rounds running it's been forgotten).

- **Sticker.** `_handleSendSticker` mirrors `ChatScreen`'s exactly — same
  `showStickerSheet()`, same `StickerStore.savePhoto`/`noteUsed`. Rendering
  is the one genuine (not just ported) piece of new code: a sticker has no
  bubble on purpose (chat's own comment: "the whole point of the form is
  the thing itself, big and bare"), so `_ChannelBubble.build()` gained an
  early-return branch, the same shape `viewOnce` already uses to bypass the
  normal bubble Container — reactions render in the channel's own
  Wrap-under-the-content shape rather than chat's overlapping pill, since
  that's the shape every other channel reaction already uses.
- **Location — plain only, deliberately not Live location.** `Message`
  carries `isLiveLocation` too, but chat itself restricts Live location to
  a real 1:1 peer (`_isRealPeer`, excluding groups and notes-to-self) with
  the reasoning "it needs someone to keep updating… a group has nobody to
  answer for" — a channel, with potentially many members, has even less of
  a single "someone" than a group does, so the same restriction applies at
  least as strongly and Live location was left out rather than ported.
  `_handleSendLocation` pushes the same `ShareLocationScreen` chat uses;
  rendering reuses `LocationContent` (see below) rather than a second copy.
- **Contact card.** Chat's `_pickContactToShare` is an inline bottom sheet
  with no separate screen file, so the channel version
  (`_pickContactToShare` in `communities.dart`) is a second inline sheet,
  not a shared widget — sourced from `ChatStore.instance.allChats` (1:1
  chats + group members), the same list chat draws from, since a channel
  has no single "this conversation's peer" to exclude the way a 1:1 does.
  Tapping a card's Message button (`_openSharedChannelContact`) opens or
  starts a chat with that person, mirroring `_openSharedContact`.
- **`LocationContent`/`ContactContent` are now public** in
  `message_bubble.dart` (were `_LocationContent`/`_ContactContent`),
  exactly the same move `ViewOnceBubble` made for the same reason:
  `_ChannelBubble` reaches for them directly rather than carrying a second
  copy of either. `_LiveLocationContent` stays private — nothing in the
  channel needs it, by the design decision above.
- **The attach panel grew a second row** (Sticker/Location/Contact) rather
  than widening the first — seven items in one `Row` of `Expanded` cells
  would never overflow (Expanded evenly divides the width) but would
  squeeze each icon+label into an unreadably narrow column. A blank
  `Expanded` spacer keeps the second row's three items left-aligned under
  the first row's first three instead of stretching wider to fill four.

**Named, not built, still — carried over from the section above and
unchanged by this round:** Live location in a channel (explicitly ruled
out, not merely deferred, per the reasoning above), disappearing messages,
live "N people viewing this" channel presence, and per-channel
wallpaper/sound. All four remain open product questions or judged
out-of-scope, not silent gaps — see the section above for the reasoning on
each.

## Channels get disappearing messages and "N here now" presence (2026-08-13, same day)

The two questions the previous section deliberately left open, decided (at
the owner's direction — "keep going") rather than left pending forever.
Both are UI/store ports again, but each needed one real design call the
chat precedent doesn't answer on its own.

**Disappearing messages — genuinely local-only, on purpose, like chat's.**
`Channel.disappearingSeconds` (int, default 0) mirrors `Chat.
disappearingSeconds` exactly, including the part that looks surprising
until you trace it: `ChatStore.addMessage` — the ONE funnel both an
outgoing message (`_deliver`) and an incoming one (`applyIncoming`) already
call — stamps `expiresAt` fresh, based on THIS device's own chat setting,
regardless of who sent the message or what the sender's own setting was.
That's why the setting never needs to ride the wire: whether YOUR copy of a
conversation disappears is YOUR device's own decision, made at the moment
each message lands locally. `CommunityStore.postMessage` — the equivalent
single funnel for a channel (both `_post`'s own send and
`addRemoteChannelMessage`'s receive already call it) — now does the exact
same stamp, reading `ch.disappearingSeconds`.

**Verified safe to add straight to the `Channel` model, not a side table,**
by reading (not assuming) `exportInvite`/`exportStructure`,
`applyRemoteStructure`, and `applyAuthoritativeStructure` first: all three
build their OWN explicit channel dict (`{id, name, type, category, topic}`)
rather than spreading `Channel.toJson()` wholesale, and both apply paths'
existing-channel merge only ever overwrites name/type/category/topic via
`copyWith` — so a new field defaults harmlessly to 0 for a channel this
device has never seen, and is never reset on one it already knows. A
dedicated test proves this rather than trusting the read: seeds a channel,
sets its timer, round-trips it through both `applyRemoteStructure` and
`applyAuthoritativeStructure`, and asserts the timer survives both. Also
proven: `exportInvite`'s own channel dict never contains the key at all.

**The sweep is a straight copy of `ChatStore`'s**, `CommunityStore.
sweepExpiredChannelMessages`/`startSweeper` (`main.dart` now starts both
sweepers back to back), same 20s interval, same `now`-injectable signature,
same "only `notifyListeners()`, no eager `_save()`" choice chat's own sweep
already made. Settable from the channel-options sheet (⋮ next to Rename/
Edit topic/Move to category) — text channels only, four options (Off/1 day/
1 week/90 days), no "after viewing" sentinel: that one is about LEAVING a
conversation, a chat-specific idea a channel you can reopen any time
doesn't have an equivalent to.

**"N here now" — reuses `GroupPresenceStore`, not a second store.**
`GroupPresenceStore` (chat's own "who's viewing this group right now") is a
plain `Map<String, Map<String, DateTime>>`, keyed by whatever conversation
id gets handed to it, with zero chat-specific coupling and — its own doc
comment says so — never persisted, so it needs no `account_wipe.dart`
wiring either. Channel ids (`${communityId}_general`, etc.) and group-chat
ids (`group_${epochMicroseconds}`) never collide, so one store safely
serves both rather than a near-identical copy of 81 lines of pure map
logic — the same "reuse the shared thing" call this file's own text on
`ViewOnceBubble`/`LocationContent`/`ContactContent` already makes for
widgets, just applied to a store. The doc comment was updated to say so.

A new live-only community-bus event, `chpres` (`{channelId}`, `from`
already on the outer envelope), wired the standard three places
(`RelayService.sendChannelPresence`, the `.onBroadcast` chain, the
`_applyCommunityEvent` switch) and — like `vpres`/`vpreq`, unlike
`chack`/`chvopen` — deliberately NOT in the mailbox-drain roster: a
"viewing" ping replayed hours later would show a ghost sitting in an empty
channel. `_ChannelScreenState` gained the exact heartbeat shape `ChatScreen`
already uses for its own group presence (`initState` announces once via a
post-frame callback, then every `GroupPresenceStore.heartbeat` (15s);
`dispose` cancels the timer and removes the listener), gated the same way
chat's `_broadcastGroupPresence` is (`AppState.shareLastSeen`,
route-current) minus the "unanswered request" check chat has and a channel
doesn't. Skipped entirely inside a thread view — a thread is a side
conversation ABOUT the channel, not a second room people are separately
"viewing". The channel app-bar title gained a third line, "N here now" in
the same green as chat's, taking priority over the topic line exactly the
way chat's own header prioritises "here now" over the member count.

**Deliberately NOT ported: voice presence's `vpreq` request/response
half.** Voice presence grew that half specifically because an EMPTY-looking
room was a real functional bug (2026-08-13, "can't see me in voice
channel") — a device opening a room had no way to learn who was already in
it except by luck. Text-channel viewing has no equivalent stakes: worst
case, a channel you just opened doesn't show "N here now" until the next
person's 15s heartbeat cycles round, which is a minor, acceptable cosmetic
gap, not a routing bug. Mirroring chat's simpler heartbeat-only `gpres`
shape — the ORIGINAL feature this section's own "named, not built" entry
pointed at — was the right amount of machinery for what was actually asked.

Regression tests: the disappearing-message stamp on both the own-post and
remote-post path, a pre-stamped message never re-stamped, the sweep at
various clock positions, `Channel.toJson`/`fromJson` round-tripping the new
field (including an old saved copy with no such key defaulting to 0), the
local-survives-a-remote-structure-sync guarantee (both sync paths), a
`chpres` event landing in `GroupPresenceStore` via the same
`debugApplyCommunityEvent` hook every other community-event test uses, the
three-places source pin (plus a NEGATIVE pin proving `chpres` was never
added to the mailbox roster), a widget test showing "1 here now" appear in
a channel's header after a remote presence ping, and a widget test driving
the channel-options sheet's "Disappearing messages" row end to end.

## Following someone never registered for a name-only account (2026-08-13)

Reported plainly: "when I follow people with a name only account it doesn't
register." It didn't, and the button lied about it.

`FollowStore.toggle` always updates local state (the button flips, the local
timeline filter picks the person up) unconditionally, then fires
`PublicFeedStore.serverSetFollow` fire-and-forget to record the follow on
the server graph — the thing that makes follower/following counts real on
somebody else's device. That RPC pair (`public_follow`/`public_unfollow`,
`docs/public_feed.sql`) is `grant execute ... to authenticated` only, and a
numberless account has no Supabase session at all (the reason `PhoneGate`
exists in the first place) — so the call was always rejected, and
`serverSetFollow`'s bare `catch (_) {}` swallowed it silently. The button
looked like it worked because the LOCAL half genuinely did; only the half
that makes it visible to anyone else, or to another of your own devices,
silently never happened.

**Fixed the same way every other numberless-blocked write already is**, not
by trying to make the write actually succeed: every `FollowStore.instance.
toggle` call site — the public profile (`public_feed_screen.dart`), the
server feed's profile sheet (`feed_screen.dart`), the contact card
(`contact_info_screen.dart`), the People screen (`people_screen.dart`), the
marketplace seller card (`marketplace_screen.dart`), and the X-style
follow/follower list (`follow_list_screen.dart`) — now opens with `if
(postNeedsPhone(context, what: 'Following')) return;`, the exact gate
Like/Repost/Post already use in `public_feed_screen.dart`. Unlike those,
Follow had never been gated at all — six call sites, all silently broken the
same way. `PublicFeedStore.serverSetFollow` also gained a defense-in-depth
backstop (`if (Session.instance.isNumberless) return;`, checked even ahead
of the test-only `debugFollowOverride`) so a call site added later without
remembering the UI gate still can't attempt a doomed round trip — mirroring
`PublicFeedStore.post()`'s own backstop under `postNeedsPhone`.

**The sheet's own copy was part of the bug.** `postNeedsPhone`'s explanation
used to say "You can read and follow along with a name-only account" —
a real, literal promise that Follow worked numberless, sitting right next to
the mechanism that had never once let it. Reworded to "You can read with a
name-only account. Adding a post, reply, reaction or follow needs a phone
number." `FollowStore`'s own doc comment made the identical false claim
("works numberless") and is corrected the same way, with a note explaining
what actually happened so the next reader doesn't reintroduce it.

Gating (rather than building a numberless-safe write path) was the
deliberate, narrower choice: an authenticated write needs a real identity to
attribute it to, the same reasoning that already keeps posting, marketplace
selling and the wallet phone-gated — a numberless account's follow would
otherwise be an unattributable row nobody could ever trace back to who cast
it. Regression tests: `serverSetFollow` never reaches the network for a
numberless account (proven by a debug override that must NOT fire), a
widget test confirms the People screen's Follow button shows the sheet and
leaves `FollowStore` untouched (not just the server half — the LOCAL flip
is refused too, so the button never lies again), and a source-pin test
enumerates all six gated call sites so a seventh can't be added ungated.

## Typing a phone number to start a chat could address an inbox nobody heard (2026-08-13)

Reported plainly: "when someone types in my number and messages me, it
doesn't register." `NewChatScreen._startByNumber` (chat with a number or
code) sent a message with no error — it just never arrived, because the
relay addresses a chat by `RelayService.digits(phone)` — bare digits, no
country-code awareness (`lib/relay/relay_service.dart:158-161`) — so
`"5551234567"` and `"+15551234567"` are two different inbox channels even
though they're the same person. Typing a number the way it's normally given
out (no country code, exactly how someone reads their own number aloud)
created a `Chat` addressed to the wrong one.

Fixed by running the typed number through `phoneToE164` (already trusted at
the numberless-verify choke point for the identical reason —
`+4167813638` being read as Switzerland instead of Toronto) before it
becomes a `Chat`'s address: `final number = code ?? phoneToE164(typed);`,
applied only when the input isn't an account code. It's idempotent, so an
already-`+`-prefixed number passes through unchanged, and it defaults to
`+1` when nothing else is typed, matching how the number is actually dialled
in this app's markets. A regression test types a bare 10-digit number and
asserts the resulting `Chat.contact.phone` is the `+1`-prefixed form —
the exact inbox a reply from that number would address.

## Following someone never registered for a name-only account (2026-08-13)

Reported plainly: "When I follow people with a name only account it doesn't
register." `FollowStore.toggle` flips local state immediately (optimistic)
and fires `PublicFeedStore.serverSetFollow` fire-and-forget — a bare
`catch (_) {}` around an RPC call that is `grant`ed to `authenticated` only.
A numberless account has no Supabase session, so the write silently refused
every time; the button looked like it worked (the local half always
succeeded) while nothing ever reached the server, and a second device or a
fresh load of the same account never saw the follow.

**Fix: gate it like everything else, the user's own call.** Following is
now behind `postNeedsPhone` — the same "needs a phone number" sheet
Like/Repost/Post already show — at all six places a Follow button exists:
`public_feed_screen.dart` (profile), `follow_list_screen.dart` (the X-style
followers/following list), `contact_info_screen.dart`, `marketplace_screen.dart`,
`people_screen.dart`, `feed_screen.dart` (server-feed profile sheet). Each
wraps its `FollowStore.instance.toggle(...)` call in a shared local
`toggle()`/`toggleFollow()` that checks `postNeedsPhone(context, what:
'Following')` first — so the LOCAL flip is refused too, not just the server
half, meaning the button never silently lies about having worked.

**Backstop, same defense-in-depth as `PublicFeedStore.post()`:**
`serverSetFollow` now refuses a numberless caller before even consulting its
own debug override:
```dart
if (local.Session.instance.isNumberless) return;
```
checked ahead of the override so a test simulating a numberless account
can't accidentally exercise a network path production never reaches either.

**The sheet's own copy was part of the bug.** `postNeedsPhone`'s explanation
used to say "You can read and follow along with a name-only account" —
a real, literal promise that Follow worked numberless, sitting right next to
the mechanism that had never once let it. Reworded to "You can read with a
name-only account. Adding a post, reply, reaction or follow needs a phone
number." `FollowStore`'s own doc comment made the identical false claim
("works numberless") and is corrected the same way, with a note explaining
what actually happened so the next reader doesn't reintroduce it.

Gating (rather than building a numberless-safe write path) was the
deliberate, narrower choice: an authenticated write needs a real identity to
attribute it to, the same reasoning that already keeps posting, marketplace
selling and the wallet phone-gated — a numberless account's follow would
otherwise be an unattributable row nobody could ever trace back to who cast
it. Regression tests: `serverSetFollow` never reaches the network for a
numberless account (proven by a debug override that must NOT fire), a
widget test confirms the People screen's Follow button shows the sheet and
leaves `FollowStore` untouched (not just the server half — the LOCAL flip
is refused too, so the button never lies again), and a source-pin test
enumerates all six gated call sites so a seventh can't be added ungated.

## Signing out a name-only account with no recovery PIN now deletes it (2026-08-13)

Reported plainly: "If a user logs out of a user only account without
registering a number delete the account" — a name-only (numberless) account
signed out through the normal path used to be remembered for one-tap
resume, the same as any real account, even though most of them have no way
back in at all: there's no phone number to sign in with again.

**But not always none — this needed checking, not assuming.** The codebase
already has a real, working numberless recovery path: `IdentityRecovery`
(`lib/crypto/identity_recovery.dart`) lets any account, numberless included,
set a recovery PIN that seals its identity keys to the server
(`recovery_gate.dart`'s `RestorePinDialog`/`createPinBackup`, walked before
the first message can send — "X's rule for encrypted DMs, adopted whole").
`_numberlessPinSignIn` (`phone_login_screen.dart`) already signs a
numberless account back in with exactly that PIN. So erasing every
numberless sign-out unconditionally would have destroyed accounts that
genuinely can come back, and would have contradicted "Deactivate
temporarily"'s own numberless copy, which already promises that exact
PIN-based return.

`Session.signOut()` now branches on `isNumberless && !IdentityRecovery.
ready.value` — `ready` is this device's own record of whether a backup was
ever actually stored (only set true after the server confirms the write),
so it's the honest signal for whether this device's copy of the account can
really come back. Only when it's false — no backup was ever made, so
there's nothing to sign back in with, the same situation the 14-day
numberless-expiry clock (`enforceNumberlessGrace`) already erases for —
does `signOut()` mirror `AccountWipe.eraseCurrentAccount()`'s
erase-and-forget sequence instead of the normal remember-for-next-time path.
A numberless account WITH a stored backup still gets the normal
remember-and-resume treatment, because it genuinely can come back.

**Every dialog that names the outcome was corrected to match, not just the
mechanism.** Three sign-out entry points reach `Session.signOut()`: the
drawer's confirm dialog (`home_screen.dart`), Settings' plain "Sign out" row
(previously no confirmation at all — a silent one-tap into an unconditional
network round trip is one thing, into an account ERASURE is another, so it
now confirms first for exactly the unrecoverable case), and "Deactivate
temporarily" (`settings_screen.dart`), whose existing numberless copy
already assumed a PIN-based return — true only when a backup exists. All
three now check `IdentityRecovery.ready.value` and say the accurate thing:
the normal "you can sign back in" copy when a backup exists, and a plain
"this deletes it" warning when it doesn't. "Deactivate temporarily" goes
further: when unrecoverable, its dialog offers no "Deactivate" action at
all (only "Got it"), pointing at "Delete account" instead — a button
labelled Deactivate that actually erases would be the exact false promise
this fix exists to remove.

Regression tests: an unrecoverable numberless sign-out erases (user cleared,
nothing remembered, its prefs slice gone); a numberless sign-out WITH a
stored backup is a normal sign-out (remembered, not erased); a source-pin
test holds `Session.signOut`'s exact condition and that both UI files check
`IdentityRecovery.ready` before claiming reversibility.

## A numberless account can now clear the "email verified" checklist item (2026-08-13)

Reported plainly, alongside the sign-out fix above: "email verification
should unlock their account" — narrowed down with the user to a bounded
scope, "just the 'email verified' checklist item" (`AccountVerification`'s
phone+email+ID checklist that gates Community Notes), not the bigger "treat
email like a real sign-in."

**The actual bug: a numberless account could set an email but could NEVER
verify one, structurally.** `AccountEmail._requestVerification` (the send
half) and `refreshVerification` (the poll-for-confirmation half) both start
with `if (auth.currentUser == null) return`, because the existing flow is a
clicked LINK — Supabase mails it via `auth.updateUser`, which needs a real
signed-in session to attach the address to. A numberless account has no
Supabase session at all (see the "no session at all" numberless-accounts
section), so `auth.currentUser` was always null for one — `setEmail`
silently degraded to `savedUnverified` forever, with no path out. This
wasn't a UI oversight; the verification flow simply had no mechanism a
sessionless account could ever complete.

**The fix is a second, CODE-based flow — reusing existing infrastructure,
not inventing an email provider.** `AccountService.sendNumberlessEmailCode`/
`verifyNumberlessEmailCode` (`account_service.dart`) call the exact same
Supabase OTP machinery `sendEmailCode`/`verifyEmailCode` already use for a
phone-account's email sign-in — `auth.signInWithOtp`/`auth.verifyOTP` — just
with `shouldCreateUser: true` (this is the FIRST time Supabase has heard of
the address, unlike the sign-in-only `false` those use) and, critically,
**no phone requirement on the result**: `sendEmailCode`/`verifyEmailCode`
exist to let a phone-having account sign in with email as a backup, so they
discard any session with no phone attached ("messaging identity here is the
number... a session with none is a half sign-in"). This path is the mirror
case — proving inbox ownership for an account that has no phone by design —
so `verifyNumberlessEmailCode` accepts a phone-less session as success, then
**immediately signs it back out** regardless of outcome. A numberless
account's identity stays its account code, never a Supabase Auth session;
this is proof-of-ownership only, not a door in. Nothing in the app listens
for `onAuthStateChange` (checked directly — there is no such listener
anywhere in this codebase), so the brief transient session this creates has
nothing to be mistaken for a real sign-in by.

**`AccountEmail.sendNumberlessCode()`/`verifyNumberlessCode(code)`** wrap
those calls with the same honest-failure shape `resendVerification()`
already has (false when there's no address, or the request/relay isn't
reachable). On a real confirmed code, `_verified` is set true and persisted
— there is no server row of the app's own for a numberless account's
verification state, same as the address itself, held on the device only.
Once `_verified` is true, `AccountVerification.emailVerified` (which only
ever reads `AccountEmail.instance.isSet && isVerified`) needed no change at
all — the checklist item was already wired to read this field, it just
could never have become true before.

**The screen swaps its verification widget, not its whole shape.**
`AccountEmailScreen` gained `_NumberlessVerifyTile` — same `InfoSection`/
`ListTile` shell as the existing `_StatusTile`, but "Resend" (which would
sit there doing nothing forever) is replaced with "Send code" → a code
`TextField` + "Verify" button, chosen via `Session.instance.isNumberless`.
Everything else on the screen (the address field, remove, the password
section, the privacy note) is unchanged and works identically regardless of
how the account signed up.

**Deliberately not touched, and stated as the boundary the user chose:**
this does not give a numberless account a Supabase session for anything
else — the wallet, posting, and every other `PhoneGate`/`postNeedsPhone`
surface stay exactly as gated as before. Only the one checklist item moves.

Regression tests: `verifyNumberlessCode` accepts/refuses through
`debugVerifyNumberlessOverride` (a real device's OTP round trip has no
in-process seam) and refuses with no address set; `sendNumberlessCode` fails
closed with no relay configured, proven rather than assumed; a widget test
drives a numberless account through Send code → enter code → Verify and
confirms the tile reads "Confirmed" after.

**Confirmed live, same day: the real device hit two failures at once, one
fixed, one that needs the project's own action.** The user tried the flow
and reported "confirming email doesn't work, sends me a 404 localhost, app
asks for a code, email doesn't show code" — with a screenshot of the actual
email, which nailed both causes.

1. **The 404: `sendNumberlessEmailCode` never passed `emailRedirectTo`.**
   Every other place this app sends a Supabase Auth email
   (`_requestVerification` in `account_email.dart`) passes it precisely
   because leaving it out falls back to the project's Site URL —
   `http://localhost:3000` until someone changes it — the exact failure
   already documented and tested for the phone-account link ("the
   confirmation link lands somewhere real, not on localhost"). This numberless
   path was the one place that check didn't reach, because it's a different
   function in a different file. **Fixed**: `sendNumberlessEmailCode` now
   passes `emailRedirectTo: AppPages.emailConfirmed`, same destination the
   phone-account flow already uses. A source-pin test holds it, mirroring
   the existing one for the phone path.

2. **"Email doesn't show code": genuinely can't be fixed from this box, and
   isn't a code bug.** The screenshot is Supabase's plain, unmodified
   "Confirm signup" template — `shouldCreateUser: true` (required here,
   since this is the first time Supabase has heard of the address) routes
   through that template, and unlike the "Magic Link" template, it shows
   `{{ .ConfirmationURL }}` only by default — no `{{ .Token }}`, the 6-digit
   code `verifyNumberlessCode` actually needs. The code exists server-side
   (GoTrue always generates one); the DEFAULT template simply never prints
   it. No client-side call can change what text a project's own email
   template renders. **Needs the owner's action**: in Supabase Dashboard →
   Authentication → Email Templates → "Confirm signup", add `{{ .Token }}`
   to the body (Supabase's own docs show the exact placeholder). This can
   also be done from here via the Management API
   (`PATCH /v1/projects/{ref}/config/auth`, the `mailer_templates_confirmation_content`
   field) if the owner pastes a short-lived personal access token per this
   file's own sanctioned one-off-token rule — not attempted without one.
   Clicking the link that IS in the email today still won't complete
   verification either way: that link's token is valid only through
   Supabase's own `/verify` redirect flow, not `verifyOTP`'s `token`
   parameter, and this screen was built around a typed code on purpose (see
   above — the alternative, adopting a real session off that redirect, is
   the bigger "treat email like sign-in" scope the user explicitly declined).

## Inline recent-photos strip in the chat composer (2026-08-13)

Asked for as "make photo attachment in chat inline" — clarified with the
user to mean: instead of the paperclip's "Photos" tile opening a separate
full-screen native picker, show a horizontal strip of the device's own
recent photos right above the keyboard (iMessage's shape), so tapping one
sends it without ever leaving the chat screen. The existing "Photos" tile
is untouched and still opens the full picker underneath the strip, for
anything older than its most recent slice.

**A genuinely new capability, not a rewiring of what was there.** Neither
`file_picker` nor `image_picker` (the app's two existing picker packages)
can enumerate the gallery with thumbnails — both only ever open a one-shot
native picker sheet, which is the exact thing being replaced. `photo_manager`
is a new dependency for exactly this — **another new pod, same caution as
`image_picker`'s own comment in `pubspec.yaml` gives**: first suspect if an
iOS archive fails, unverified from this box (no Xcode, no device). It has NO
web platform entry in its own `pubspec.yaml` — there is no browser API for
"list my camera roll" — so `RecentPhotos.supported` is `!kIsWeb`, checked
before ever calling into the plugin; a web build simply never shows the
strip and keeps the existing full-picker "Photos" tile, which is why
`flutter build web` was re-verified to still compile after adding it.
`NSPhotoLibraryUsageDescription` already existed in `Info.plist` (from
`image_picker`'s own gallery-save capability), so nothing new was needed
there; the iOS floor's Podfile post-install hook already raises every pod
to iOS 15 uniformly, so this pod needed no special-casing there either.

**`lib/util/recent_photos.dart`** is the wrapper, modelled directly on
`PhotoPrep`'s existing shape (a `debugPickOverride`-style test hook, a pure
data type, no crypto/relay/chat imports — this file only lists what's on
the device and reads bytes, it never decides what may be sent or touches
the network). `RecentPhotos.recent()` returns `null` for "denied, or this
platform can't ask at all" and `[]` for "asked, granted, genuinely empty
library" — kept as two distinct outcomes so a future caller could tell
"nothing to show" from "offer to ask again", even though the current UI
treats both the same way (silently falls back to the plain picker-only
panel). `RecentPhoto` holds byte-provider closures rather than
photo_manager's own `AssetEntity` directly — `AssetEntity` cannot be hand-
constructed (there is no device photo library in a test), so
`RecentPhoto.forTest(...)` is the only way a test can ever produce one, and
production code goes through the private `RecentPhoto._fromAsset` factory
instead. `sendBytes()` deliberately asks for a 1280px `thumbnailDataWithSize`
rather than the asset's real origin bytes: an original can be many
megabytes and, with iCloud Photos storage optimization on, may not even be
downloaded to the phone yet, so asking for it can stall on a slow fetch for
a photo `PhotoPrep.prepare` is about to shrink to well under its wire budget
anyway — 1280px already matches `prepare`'s own first-attempt resize
ceiling, so nothing above that is ever kept regardless of source.

**`PhotoPrep.moderateAndPrepare(bytes)`** is the moderate-then-shrink step
`pickPhoto`/`takePhoto` already ran inline, pulled out so the strip's tapped
photo goes through the exact same gate as anything picked the old way —
nothing leaves the device unmoderated, and a rejection still surfaces as
the same `FileRejected` the existing snackbar already handles.

**`ChatInputBar` gained `onPickedImage`** (a `ValueChanged<String>?`,
default null): the strip only ever appears when a caller actually wires it
up, so a `ChatInputBar` nobody touched (channels' own composer, which
builds its attach flow independently rather than reusing this widget, is
untouched by this whole change) keeps behaving exactly as before. `chat_
screen.dart`'s `_handleSendImage` — which used to both pick AND deliver —
was split at that seam: `_sendImageDataUri(uri, {viewOnce})` is the deliver
half, reused by both the old picker path and the new strip, so there's one
place that builds the outgoing `Message` for a photo, not two drifting
copies of it.

**`_AttachmentPanel` became stateful** only because the strip has to load
asynchronously (`RecentPhotos.recent()`) the moment the panel opens — the
grid of options below it (Camera, Photos, GIF, Sticker, …) is completely
unchanged, just now built by a private `_buildGrid()` so the strip could sit
above it in one `Column`. Each `_RecentPhotoTile` loads its own thumbnail
lazily via a `FutureBuilder`, not a preloaded batch, so scrolling past a
long recent-photos list never means fetching every thumbnail up front; a
small `Map<String, Uint8List?>` cache on the panel keeps a tile that already
loaded from re-fetching when scrolled back into view.

Regression tests (all via `RecentPhotos.debugOverride`, since there's no
device photo library in a test): the strip renders above the grid and
tapping a thumbnail calls `onPickedImage` with a real moderated/prepared
data URI and folds the panel away, exactly like tapping a grid option does;
the strip never even asks `RecentPhotos` when `onPickedImage` is null (a
caller that never wired it up costs nothing extra); a denied/unsupported
library falls back to the grid alone, silently — no error text, no empty
strip. `flutter analyze` and the full suite were both re-run clean, and
`flutter build web --release` was re-verified to still compile.

**Needs a Codemagic build to confirm anything about the real device
behavior** — the permission prompt, actual thumbnails, the pod itself
compiling into an archive. Nothing here has been run on a real iPhone.

## A call now tells a would-be caller you're already on one (2026-08-13)

Asked for as "if someone is in a call let out others know so they don't
call." The mechanism to tell them ALREADY EXISTED, undocumented and half
finished: `CallService.isBusy` — "used to send 'busy'", its own doc comment
said — and `onRemoteOffer`'s busy branch really did fire when an offer
arrived mid-call. What it actually sent was `kind: 'decline'` — the SAME
wire event a real, deliberate rejection sends — so a caller reaching
someone who was simply on another call had no way to tell that apart from
being told no personally, and the busy device itself never learned anyone
had even tried: `onRemoteOffer`'s busy branch returned before ever calling
`_logCall`, since a busy call never becomes a live `CallSession` in the
first place.

**`CallStatus` and `GroupCallMemberState` both gained a real `busy` value**
— not reused `declined` — because the two are genuinely different facts: a
decline is "I don't want this call", busy is "I can't take this call".
`onRemoteOffer`'s (1:1) and `onRemoteGroupOffer`'s (group) busy branches now
send `kind: 'busy'` / one `kind: 'membusy'` per member instead of `'decline'`
/ `'left'` — new wire events, dispatched in `RelayService._applyCallEvent`
to new `CallService.onRemoteBusy`/`onRemoteGroupBusy` handlers that mirror
`onRemoteDecline`/`onRemoteLeft` exactly except for which status they land
on. Both are in the mailbox queue-eligible set alongside `'decline'`/`'end'`,
for the same reason those are: a busy device is definitionally online right
now (it just received a live offer to answer with 'busy' in the first
place), but the CALLER could still have briefly backgrounded between
sending the offer and receiving the reply.

**The busy device now files its own record too.** `_logMissedBusy` —
modelled directly on `onRemoteMissed`, the existing sibling that already
handles "this call never became a live session, but it still has to exist
in the log" — writes a `CallLog` entry and a chat `Message` with
`callEvent: 'busy'` the instant the busy branch fires, so being called
while on another call is no longer silent on the receiving end either.

**One wire word, two meanings, told apart by `Message.isMe`.** The SAME
`callEvent: 'busy'` string appears on both sides of the exchange —
`_recordInChat`'s outgoing-caller branch (`c.status == CallStatus.busy` →
`'busy'`, alongside the existing `'declined'`/`'noanswer'` split) and the
new `_logMissedBusy` incoming branch — and `_CallEventBubble._label` reads
`isMe` to say the right one: the caller's own bubble says "Voice call ·
Busy", the callee's own bubble says "Missed voice call · you were on a
call". The missed-call red-icon treatment (`_CallEventBubble.build`'s
`missed` flag) is extended the same way: red only for the callee's own copy,
since that side genuinely missed a call — the caller's side reads more like
a decline than a miss.

**`CallScreen` and `CallKitBridge` both had exhaustive `switch`es over
`CallStatus`/`GroupCallMemberState`, which is exactly the safety net this
kind of change is supposed to lean on** — the compiler refused to build
until every one of them named `busy`: `_statusLabel` ("`<name>`'s on
another call"), `_GroupRoster._describe` ("Busy", the same orange as
"Declined" — busy is a rejection outcome visually, just not a personal
one), `_offerVoicemail`/the auto-dismiss timer (both now treat `busy` as
terminal, and voicemail is offered on a busy call exactly like a declined
one — "they're on another call" is the moment a voicemail is worth
leaving), and `CallKitBridge._onSession`'s terminal check (so the native
CallKit UI retires on a busy reply the same way it does on a decline).

**Deliberately not built, stated rather than hidden:** no proactive "on a
call" presence badge shown to contacts BEFORE they dial (a chat-header
status line, a contact-card chip) — the ask was read as "tell the person who
tries", which a real-time busy signal answers directly; a persistent
broadcast-to-every-contact presence line is a different, bigger feature
(new network chatter for every call, a privacy question about who gets to
see it) and wasn't asked for. Group calls don't get the local `_logMissedBusy`
treatment 1:1 got — group invites already log nothing locally on an ordinary
decline (`onRemoteGroupOffer`'s decline branch never called `_logCall`
either, before or after this change), so adding it only for the new busy
path would have been a new asymmetry, not a fix to an old one.

Regression tests: an outgoing call moves to `CallStatus.busy` (distinct from
`declined`) on `onRemoteBusy`; an offer arriving mid-call is refused without
disturbing the live session, AND leaves a `CallLog` entry and a
`callEvent: 'busy'` chat message on the busy device; a group member's busy
reply lands on `GroupCallMemberState.busy` (not `declined`) and composes
correctly with a real `left` to end the call once everyone is genuinely
gone. `flutter analyze` catching both non-exhaustive switches before a
single manual test ran is exactly what pinning `CallStatus`/
`GroupCallMemberState` as real enums (not booleans or strings) is for.

**Unverified from this box, same as every call-signaling change in this
file** — no two real devices, no live relay round trip. The state
transitions and the mailbox eligibility are proven in-process; whether a
busy reply actually reaches a backgrounded caller's CallKit UI in time is
not.

## A message to an unknown number landed in Marketplace, not Chats (2026-08-13)

Reported plainly: "If an account that's unknow it is placed in marketplace
instead chat instead of chat. It thinks your messaging someone off
marketplace" — a message request from a stranger was showing up filed under
the Marketplace section rather than the ordinary message-requests list.

**Two prior investigations of this same report found nothing**, because both
traced the request/marketplace SPLIT logic itself (`ChatStore.chats` excludes
`isRequest || marketplace`; `marketplaceChats` requires both `marketplace:
true && !isRequest`; `messageRequests` shows any `isRequest: true` chat
regardless of the marketplace flag) and that logic is correct — a chat is
never actually lost between sections. What neither pass did was trace every
site that CONSTRUCTS a chat with `marketplace: true` to check whether that
site was genuinely marketplace-related. This pass did, and found one that
wasn't: `openSellerChat` (`marketplace_screen.dart`) is the marketplace's own
"message this seller" helper — `store.startChatWith(seller, ...,
marketplace: true)`, correct for its three real marketplace call sites
(`messageSeller`, making an offer, `SellerScreen`'s own Message button) — but
`public_feed_screen.dart`'s plain PROFILE "Message" button was ALSO calling
`openSellerChat`, purely to reuse its username-resolution convenience, and
silently inherited the hardcoded `marketplace: true` along with it. Messaging
a stranger from their public profile is an ordinary message request, not a
marketplace inquiry — but the chat it created was filed as one anyway.

**Fixed by making the marketplace flag a real parameter instead of an
assumption baked into the helper.** `openSellerChat` gained `bool
marketplace = true` (default true so the three legitimate marketplace call
sites need no changes) with a doc comment naming exactly why the parameter
exists — the profile-button reuse that prompted this fix — so the next
person reaching for this helper for a non-marketplace reason sees the trap
documented at the point they'd fall into it. The profile's Message button now
passes `marketplace: false` explicitly.

Regression tests: the existing "Message seller opens the chat" test gained
`expect(chat.marketplace, isTrue)` (the three real sites are unaffected); a
new widget test confirms `openSellerChat(marketplace: false)` produces an
ordinary chat that stays off the Marketplace section; a source-pin test holds
that the public profile's Message button passes `marketplace: false`.

## A silently-dead call channel could leave a hang-up unheard (2026-08-13, mitigation)

Reported plainly: "When I call someone and hang up, it doesn't hang up on
them" — confirmed by the user, when asked to narrow it down, as a real and
persistent defect ("It never ends until they manually hang up themselves"),
not network latency.

**A methodical elimination, not a guess.** Six places were checked and all
six were already correct: the wire-send in `end()`, the receive-dispatch in
`onRemoteEnd()`, CallKit's native end-action handler, `_CallOverlay`'s
`ValueListenableBuilder` rebuilding `CallScreen` on session changes,
`_CallScreenState.didUpdateWidget` re-running `_syncForStatus()` on status
transitions, and all three hang-up UI button handlers. With the application
logic clean on both ends, the remaining suspect is the transport underneath
it — and this codebase already has a proven precedent for exactly this
failure shape: the server feed's own realtime channel (`_feedChannel`) can
silently die mid-session with no automatic re-subscription, which is why
pull-to-refresh was added to force a rebuild (`RelayService.resync()`/
`wake()` — see "A server had no pull-to-refresh once you were already inside
it" above). A per-contact inbox channel is the same kind of Realtime
subscription, with the same absence of a self-heal, and a call screen has no
pull-to-refresh gesture of its own to force one.

**The fix is a backstop, not a cure — and a light one on purpose.** A full
`wake()` was ruled out: it tears down and rebuilds both the inbox and feed
channel subscriptions via `start()`, which is exactly the kind of disruption
that could drop in-flight ICE candidates if triggered mid-call. Instead,
`CallService` now runs a plain `RelayService.instance.fetchMailbox()` — a
simple HTTP GET against the mailbox table, with its own existing dedup and
claimed-row-delete safety, no channel teardown at all — every
`CallService.mailboxPollInterval` (10s, a test seam) for as long as
`current.value` is non-null. This isn't a new mechanism: `'end'`, `'decline'`,
`'busy'` and `'membusy'` are already in the mailbox's queue-eligible event
set (added alongside the busy-signal feature above), so a hang-up the live
channel missed is very likely already sitting there waiting to be asked for
— nothing before this ever asked, since mailbox draining otherwise only
happens on relay start, app resume, and pull-to-refresh, none of which fire
while sitting on an open call screen.

**Centralized in one place, not threaded through every call-lifecycle
method.** Rather than adding start/stop calls to `startOutgoing`,
`onRemoteOffer`, `accept`, `end`, `decline`, `onRemoteEnd`, `onRemoteDecline`,
`onRemoteBusy`, `onRemoteGroupBusy`, `onRemoteLeft` and `clear` individually,
`CallService`'s constructor adds one listener on its own `current` notifier
(`_syncMailboxPoll`) that starts the timer the instant `current.value`
becomes non-null and cancels it the instant it goes back to null — every one
of those methods already sets `current.value`, so this needed no changes to
any of them. `debugMailboxPollActive` is the test seam exposing the timer's
running state without exposing the timer itself.

Regression tests: the poll is inactive before a call, active once one starts
ringing, stays active through connecting, and stops the instant `end()`
returns `current.value` to null; `resetForTest()` leaves no timer running
across tests.

**Unverified from this box, and stated as a mitigation rather than a
confirmed fix** — same honesty this file already holds every relay-dependent
change to. There is no live two-device call here to prove a dead channel was
the actual cause, only that it is a real, precedented failure mode this
codebase has hit before in an adjacent feature, and that the backstop closes
the gap cheaply and without touching anything already proven correct. If a
report of "the other side never hangs up" recurs after a build carrying this
ships, treat the mitigation as insufficient rather than assuming the report
is stale.

## Newsfeed photo attach was silently broken on iOS; video and photo are now one button (2026-08-13)

Reported plainly, two messages: "Photos for new post on both newsfeeds don't work" and "Video and photos should be together, the video icon opens up file manager."

**The photo bug: an iPhone photo is HEIC, and nothing in the pipeline could
decode it.** `PhotoPrep.pickPhoto()` called `file_picker`, which on iOS hands
back the file exactly as it sits in Photos — HEIC, not JPEG. `FileModeration.
inspectImage` correctly allows HEIC (it's on the allowlist, sniffed by its
`ftyp` box brand), so nothing was ever refused; the failure was one level
down, in `PhotoPrep.prepare`'s `img.decodeImage(original)` — `package:image`
4.8.0 ships no HEIC/HEIF decoder at all, so it returned `null`, which
`prepare` and then `moderateAndPrepare` passed straight back out as `null`.
Both composers read that as "the user cancelled the picker" and did nothing
— no error, no snackbar, just a picker that closed with nothing to show for
it. Android wasn't affected (gallery photos there are overwhelmingly JPEG
already), which is why it read as "both newsfeeds" rather than "everything":
every other `PhotoPrep.pickPhoto()` caller (chat, marketplace, servers,
forum, Okay Drop) had exactly the same hole, just less likely to hit it —
chat's own inline recent-photos strip (2026-08-13, earlier this same day)
happened to dodge it entirely, since `photo_manager`'s thumbnails are always
JPEG, which is what made the newsfeeds the visibly broken ones by
comparison.

**Fixed at the one place every `pickPhoto()` caller shares, not per
caller.** `pickPhoto()` now opens `image_picker`'s gallery picker
(`ImagePicker().pickImage(source: ImageSource.gallery)`) instead of
`file_picker`. On iOS this routes through PHPickerViewController, which
decodes HEIC on the NATIVE side and hands Dart plain JPEG bytes
(`FLTPHPickerSaveImageToPathOperation`'s `processImage` falls through to
`UIImageJPEGRepresentation` for any type it doesn't specifically recognise
as JPEG/PNG) — so `img.decodeImage` never sees the format it can't read,
for every caller, not just the two reported. `PhotoPrep.pickBytes()` (the
identity-document upload path) is deliberately left on `file_picker` — it
never decodes the bytes locally, so it was never exposed to this bug, and
it wants the ORIGINAL file for Stripe rather than a re-encode.

**The silent-failure shape itself was also a bug, independent of the HEIC
cause — fixed as a permanent guardrail.** `moderateAndPrepare` now THROWS
`FileRejected` when `prepare()` returns null (undecodable bytes, or a
pathological image that won't compress under budget) instead of returning
null and leaving the caller to read that as "cancelled." Every caller
already has an `on FileRejected` handler wired for the moderation-refused
case, so this costs nothing and turns any future decode failure — on any
platform, for any reason — into a visible message instead of a silent no-op.
A test seeds real PNG magic bytes followed by garbage (passes `inspectImage`,
which only sniffs the header; fails `prepare`, which actually decodes) and
pins that this throws rather than vanishing.

**The video bug was separate: "Add a video" opened `NearbyPick`, built for
handing a file to someone standing next to you.** `NearbyPick.pick()` calls
`FilePicker.pickFiles(withData: true)` with no type filter — the right shape
for Okay Drop (any file, off the Files app), the wrong shape for "post a
video," which is why tapping it opened the generic file browser instead of
the Photos library. Fixed by replacing it with `MediaPrep`
(`lib/util/media_prep.dart`), which opens `image_picker`'s `pickMedia()` —
the SAME call that reaches PHPickerViewController on iOS, offering photos
and videos side by side in one picker, which is what "video and photos
should be together" actually asked for. `MediaPrep.pick()` sniffs the
result and moderates a video with `FileModeration.inspectNearby` (reused for
its size/hash checks only — the same thing the old video button already
did), leaving photo moderation to the caller's own existing
`PhotoPrep.moderateAndPrepare` so the check isn't duplicated.

**Both composers now show ONE media button, not two.** The public newsfeed's
separate photo and video `IconButton`s became one (`Icons.
photo_library_outlined`, `_pickMedia`), still gated by `PublicFeedStore.
mediaSupported` for the video half — when the server's schema doesn't have
the video columns yet, the button quietly falls back to the photo-only
picker (`_pickImage`) rather than offering a kind the insert would reject.
The server feed's `FeedComposerScreen` lost its separate `onAttachPhoto`/
`onAttachVideo` callbacks for one `onAttachMedia`; its reply composer (which
has no video-posting path by design — "a reply is answered the way a GIF
is") still fills that one slot with a photo-only implementation, since
`PhotoPrep.pickPhoto` itself can never hand back a video to reject.

**Found and fixed in passing: the server-feed composer used to close on a
cancelled picker.** `_openComposer`'s wrapping closure called
`await _attachPhoto(); Navigator.pop(pageContext);` unconditionally — so
tapping the media button and then cancelling the picker closed the whole
composer with nothing posted, which read exactly like "it swallowed my
post." `_attachMedia` now returns whether something actually posted, and the
closure only pops when it did. A test drives this exact sequence — cancel,
assert the composer is still open; pick for real, assert it closed.

Regression tests: `moderateAndPrepare` throws on undecodable input;
`MediaPrep.pick` tags a photo vs. a video correctly, moderates a video
against the caller's own limit, throws on an oversized one, and returns null
on cancel; both newsfeed composers show exactly one media button and no
separate video tooltip; a video picked through the unified button attaches
as a video and a photo as a photo; the server-feed composer stays open on a
cancelled pick and closes only once something is actually attached.

## History tab: bookmarks, likes and reposts in one place (2026-08-13)

A new sidebar row, **History** (`SidebarPrefs.defaultOrder`, end of the
list) → `HistoryScreen` (`public_feed_screen.dart`) — a `TabBar` of
**Bookmarks · Likes · Reposts**, replacing what used to be a single-purpose
Bookmarks screen with a place that answers "everything I saved, liked, or
passed along" in one screen instead of three separate hunts.

**`BookmarksScreen` is now a one-line wrapper** — `HistoryScreen(initialTab:
0)` — so the existing Settings → Bookmarks entry point, and anything that
constructs `BookmarksScreen` directly, is unchanged. The old
`_BookmarksScreenState` became `_BookmarksTabState`, with its `Scaffold`/
`AppBar` stripped out (the tab bar's parent now owns the app bar) and its
error/empty states factored into two small shared widgets, `_HistoryError`
and `_HistoryEmpty`, that all three tabs use.

**Likes and Reposts are each a merge of two sources, sorted newest first —
and the merge is honest about which half is durable and which is not.**
The public newsfeed side is server-backed and real: `PublicFeedStore.
myLikedPosts()` (an existing RLS-scoped query — a device can only ever read
its OWN likes, same rule the profile's Likes tab already follows) and
`PublicFeedStore.profileTab(await postsBy(myUsername), ProfileTab.reposts)`
(the same pure filter the profile screen's own Reposts tab already runs).
The server-feed side has **no durable index to query at all** — a
community's feed is end-to-end encrypted, so there is nothing server-side
that could answer "what has this account liked" — so it's `FeedStore.
instance.allPosts.where((p) => p.liked)` / `.where((p) => p.reposted)`:
whatever this device's local, already-loaded post cache currently holds.
This is not a shortcut taken here; it is the same stated limit the
profile's own Servers tab already carries, extended to the same two boolean
flags `FeedPost` already tracked.

**A third, read-only tile — `_ServerHistoryTile` — was added rather than
reusing `_ServerBookmarkTile`.** The existing bookmark tile carries a
trailing "Add to folder / Remove bookmark" menu that only makes sense for a
post that IS bookmarked; a post on the Likes or Reposts tab isn't
necessarily saved at all, so offering "Remove bookmark" on it would be
either wrong or a second, unrelated action bolted onto the wrong verb.

**Two pre-existing gaps in the sidebar customize screen, fixed in
passing.** `sidebar_customize_screen.dart`'s `metaFor(id)` switch — the
lookup that turns a `SidebarPrefs` id into an icon and a label for the
reorder screen — was missing `'weather'` and `'sports'` entirely, so
either row fell through to the raw-id fallback (`(Icons.apps, id)`) and
showed the literal word "weather" or "sports" in the customize list instead
of a real label. The file's own comment already names this exact bug class
("`'forum'` was missing and fell through…") for a case fixed earlier; these
two had simply never been added when the rows themselves shipped. Both are
in now, alongside `'history'`.

Regression tests: the History screen shows all three tab labels and an
honest empty state; the Likes tab merges a public like and a server-local
like (and excludes an unliked server post), newest first; the Reposts tab
merges a public repost (rendered as the ORIGINAL post, via the same
`_Entry`/`byId` resolution every repost already uses) with a server-local
repost, and excludes an ordinary post that isn't a repost; `'History'` is
in the drawer-destinations walk (opens, has a back arrow, leaves cleanly).

## New marketplace listings reached nobody: an upsert read the one column clients may not SELECT (2026-08-13)

Reported as "when a user posts a listing other users can't see it," and it
was worse than the report: **the row never reached the server at all.** The
global `market_listings` table had been empty since the day it shipped — not
"hidden from other users", genuinely zero rows, ever.

**An earlier pass of this same investigation got it wrong and blamed a stale
build. That conclusion is deleted, not softened** — it was reached from a log
query whose filter silently matched nothing, which read as "no traffic" when
the truth was "my query was broken." The owner pushed back that every device
was up to date, which was correct. Re-querying properly showed the app
calling `GET /rest/v1/market_listings_view` every few seconds, live, from the
build under test. Lesson worth keeping: **a log query returning zero rows is
a claim about the query until a control proves the query can return
anything.**

**The real cause, traced from a listing posted on demand while the logs were
watched.** Two `POST /rest/v1/market_listings` appeared, both **403**, and
Postgres named it exactly:

```
permission denied for table market_listings
HINT: Grant the required privileges to the current role with:
      GRANT SELECT ON public.market_listings TO authenticated;
```

`permission denied for table` is a GRANT failure, **not** the "new row
violates row-level security policy" an ownership problem gives — so RLS was
never even reached. The caller was properly authenticated (a real
`auth_user` in the log), not silenced, not area-banned, not locked out; all
four were checked directly.

The mechanism: publishing uses PostgREST's upsert, which compiles to

```sql
insert into market_listings (id, author_phone, author_username, payload, …)
values (…)
on conflict (id) do update set
  author_phone    = excluded.author_phone,   -- <<< this
  author_username = excluded.author_username, …
```

`excluded.author_phone` is a **read** of the column deliberately withheld
from clients so a seller's number stays private. Postgres resolves that at
PLAN time, so it failed even for a brand-new id that could never conflict —
which is why *every* publish failed, not just edits. Isolated empirically:
the identical upsert **succeeds** with `author_phone` dropped from the SET
list and **fails** with it present, on `market_listings` and
`market_reviews` alike. **`server_directory` has it too, and was nearly missed** — a first
probe upserted it WITHOUT `owner_phone` in the DO UPDATE (which passes) and
that was read as "unaffected", when what `publishServerDirectory` really
sends does name it. So toggling a server public never put it in Discover
either. The lesson is worth more than the fix: **probe the statement the
CLIENT actually sends, not a simplified stand-in.**

**Granting the column was never an option**, which is what makes this
different from the `public_forum_votes` fix that this file already
documents. There, the read policy was scoped to the caller's own row, so
granting the column revealed only a number the caller already had. Here the
read policy is `content_visible(author_phone)` — every listing is
world-readable by design — so granting it would publish **every seller's
phone number to anyone holding the publishable key.**

**The fix: the client stops sending the column, and the server fills it.**
`docs/market_upsert_fix.sql` defaults the withheld phone column to
`auth.jwt() ->> 'phone'` on all three tables; `publishMarketListing`,
`publishMarketReview` and `publishServerDirectory` drop the key from their
upsert bodies. The DO UPDATE
then never names the column, so nothing reads it. This is strictly *safer*
than what it replaced, not merely equivalent:

* A new row takes the phone from the JWT — a value the device **cannot
  forge** — instead of trusting whatever the client sent.
* An UPDATE never touches `author_phone`, so a later publish can never
  reassign a listing's owner.
* The insert policy is unchanged and still runs: an older build that DOES
  send the column is still refused if it names somebody else's number
  (verified — still "new row violates row-level security policy").
* `anon` has no session, so the default is null and NOT NULL refuses the
  row — a signed-out write cannot land even if RLS were loosened later.

**RUN + verified live 2026-08-13.** All three defaults applied to the real
project and read back from `information_schema`. The new client's exact
upsert was then run against the LIVE database as the reporting seller and
succeeded, with `author_phone` correctly filled from the JWT (rolled back
after). No privacy regression: `select author_phone` as `anon` still answers
**401**, and browsing `market_listings_view` still answers **200**.
`tool/check_sql.sh` gained ten assertions covering the half every existing
check missed — they all used a plain INSERT, and the bug lived only in the
UPSERT: publishing works, re-publishing an edit works (the conflict path),
the phone fills from the JWT, an edit really lands, and — as the regression
guard — naming the phone column in an upsert is *still* refused on all three
tables, so restoring the old client silently kills publishing again with a
test to catch it. Discover's own publish is pinned the same way. A Dart source pin holds the key out of all three functions.

**A fresh Codemagic build is REQUIRED — the live SQL alone fixes nothing for
an existing build, and an earlier draft of this section wrongly said it
would.** The column default only helps a client that has STOPPED sending the
column. A build that still sends it still names `excluded.author_phone` in
the DO UPDATE, so it is still refused with the identical 42501 — verified
against the live database AFTER the defaults were applied, by replaying the
old client's exact statement. The two halves are not independent: the
migration is what makes the client change safe, and the client change is what
makes publishing work. Until the build ships, the table stays empty.

**There is deliberately no server-only workaround, and the reason is the
whole point of the design.** The only way to make the old statement legal is
to grant SELECT on the phone column — which, because these rows are
world-readable, publishes every seller's number to anyone holding the
publishable key. That trade was declined rather than taken quietly.

## Two follow-ups to the publish fix: stranded old listings, and the email that only ever sent a link (2026-08-14)

Reported together: "if I post a new listing it shows, none of my old
listings show", "a review doesn't reflect", and "still can't verify my
email — Supabase sends an email that doesn't do anything."

**1. Old listings would have stayed invisible even after the fix.** Repairing
the write path only helps a listing somebody is actively posting or editing.
Publishing was refused for as long as the global table existed, so every
listing made before the fix lives ONLY on the device that made it — and
nothing re-publishes a listing nobody touches. A seller's back catalogue
would have stayed private forever while new listings worked, which is
exactly the reported shape. `_backfillOwnListings` runs after each
`fetchMarketListings` and upserts only the caller's OWN listings that the
fetch did NOT return, so once a seller is up to date it costs nothing. The
fetch now selects `id` alongside `payload` so there is something to compare
against. Sold and reserved listings go up too — a buyer looking at a
seller's shop should see their history, and `FeedStore.listings()` is what
decides visibility, not the publisher. Reviews ride the same repaired
`sendFeedPost` path and need no equivalent: unlike listings, a review that
matters is written after the fix ships.

**2. The verification email never contained a code — and this one needed no
build.** `signInWithOtp` is a CODE flow (`verifyOTP(type: OtpType.email)`),
and every email sign-in path in this app is, but the project's **Confirm
signup** and **Magic Link** templates both rendered `{{ .ConfirmationURL }}`
and nothing else. So the app asked for six digits the email did not carry,
and the link it did carry could not finish the app's flow — "an email that
doesn't do anything", precisely. Both templates now lead with
`{{ .Token }}` and carry no link at all, because a link in a code flow is
the thing that caused the confusion. **The link-based flow is untouched**:
changing the address on a phone account goes through `updateUser(email:)`,
which uses the separate *Change Email Address* template.

`site_url` was still `http://localhost:3000`, the source of the original
404 report — now the `pages/email-confirmed` function, so no Supabase email
can land on localhost again regardless of what a caller passes.

**RUN + verified live 2026-08-14** via the Management API, read back after:
both templates contain `{{ .Token }}`, `site_url` is the pages URL. This
half works on the CURRENT build — no Codemagic run needed for email.

## A gated screen replaces the app bar too — the AI tab lost its way into the sidebar (2026-08-13)

Reported with a screenshot: on **Okay AI**, a name-only (numberless) account
had no sidebar button at all.

`AiChatScreen.build` returns `PhoneGate` early for a numberless account —
*before* the `Scaffold` whose `AppBar` carries the `HomeDrawerButton`. The
gate draws its own `Scaffold`/`AppBar`, and that bar had no `leading`, so
Flutter's default applied: a back arrow when something can pop, and **nothing
at all** when nothing can. On the AI TAB nothing can pop, and home hides its
own app bar for tabs 5 and 6 — so the drawer became unreachable from that
screen entirely. Not cosmetic: the sidebar is the way to Settings, and
Settings is where a name-only account goes to add a number and undo the very
limit the gate is announcing.

`PhoneGate` gained an optional `leading`. Null keeps today's behaviour, which
is right for the only other caller — the **Wallet**, which is pushed and
should show a back arrow. `AiChatScreen` passes its own `HomeDrawerButton`
under exactly the condition its real app bar already uses
(`ModalRoute.of(context)?.canPop`, not `Navigator.canPop()` — see the comment
there for why the app-wide search makes the latter lie), so a PUSHED Okay AI
still gets an ordinary back arrow.

**The class of bug worth remembering: a full-screen gate replaces the app bar
as well as the body.** Any chrome the gated screen owns — a drawer button, an
action, a title — vanishes with it unless the gate is told to carry it.
Anything wrapped in `PhoneGate`/`VerifiedGate`/`ParentalGate` as a home TAB
needs its leading passed through.

Regression tests: a numberless AI tab shows the gate AND a `HomeDrawerButton`;
a numberless PUSHED Okay AI shows the gate with a `BackButton` and no drawer
button.

## Moderation upgrade, part 1: a report button on every surface (2026-08-14)

A moderation queue only ever sees what somebody could reach a button to
send it, so a missing button is a missing report. Reporting had grown on
four surfaces and stopped there — the public newsfeed (post and profile),
the server feed, a marketplace listing, and a contact card. **The public
FORUM had none at all**, posts and comments both, which is the worst place
to be missing it: that content is world-readable, anybody can find it, and
`moderation-screen` only ever sees a post's text at the moment it is
written. The in-server board and a server's channel messages had none
either.

`lib/widgets/report_action.dart` is the one shared piece: `ReportTarget`
(the console's vocabulary — `forum_post`, `forum_comment`,
`server_forum_post`, `channel_message`), `reportMenuRow` for a surface that
already has a menu, and `showReportOnlySheet` for one that doesn't. It
deliberately does NOT re-implement the sheet — `showReportSheet` already
collects a reason and files the row — so there is one vocabulary in the
console instead of six.

**The context string is a locator, never content**, and a test pins that
`report_action.dart` never touches `.text`. `forum_comment:42` says which
comment; it does not say what it said. A moderator can go and read a public
one because it is public; a server's own content they cannot, and must not
— it is end-to-end encrypted, and a report that smuggled the plaintext out
would break the promise the encryption exists to keep. That is the rule the
server-feed report already set: **who and where, never what.** A channel
report therefore carries `server:<id> channel:<id>` alongside the message
id, because a bare message id locates nothing a moderator could act on.

Small things that came with it: `_ForumAction` skips its gap as well as its
text when the label is empty, or the overflow icon sits off-centre in its
own tap target; the forum card's section label became `Flexible` so the new
overflow cannot overflow the row; and you are not offered a report on your
own channel message.

**Reporting a server's content goes to the APP's moderators, which is not
the same door as the server's own admins.** A server admin can already
delete, pin, lock and ban inside their own server — no help at all when the
server itself is the problem. Both routes now exist and they are different
routes on purpose.

Tests: every one of the seven surfaces offers a report (the four that
already did are pinned too, so none can quietly lose it); the four console
prefixes exist; a report carries the locator and never the body; a channel
report names its server and channel.

## Moderation part 2: the audit trail was write-only (2026-08-14)

Offered as "add an audit log", and the honest finding is that **most of it
already existed** — `moderation_log` has been a table since the console
shipped, `moderation-act` and `roles-set` both insert into it on every
sanction, takedown and role change, and `moderation-queue` already serves it
under `what: "log"`. What was missing sat entirely on the client: the Dart
side had no method to ask for it and the console had no place to show it.
So the record was **write-only** — a complete history of who did what, that
no moderator could read. Accountability nobody can inspect is not
accountability, and the defence-when-a-decision-is-challenged that an audit
log exists for only works if somebody can open it.

`ModerationLogEntry` + `PlatformModeration.auditLog()` (with a
`debugLogOverride` seam like `reports()`/`sanctions()`), and a **History**
segment in the console beside Reports and Sanctions.

Decisions worth keeping:
* **The ACTOR is shown as prominently as the target.** The Sanctions tab
  already says who is sanctioned; only this says who sanctioned them. A log
  that led with the target would just be the sanctions list again.
* **The actor's ROLE is read from the row, not looked up now.** It is
  recorded per action because roles change, and the question a challenge
  asks is always "what were they allowed to do THEN".
* **Every moderator can read it, not just the owner** — a record only the
  boss can see is not one the team is held to.
* **Read-only, deliberately.** An audit trail with an edit button is not an
  audit trail.
* An **unknown action still gets a row** with a neutral glyph rather than
  being hidden: the action string is the server's, and an older client must
  not silently drop an action it has not heard of.

Nothing server-side changed — no migration, no function re-paste. The rows
were always being written.

## Marketplace reviews: proved end to end, and the stranding closed (2026-08-14)

Asked to make sure reviews work — verified and unverified, buyer and seller.
What was found, stated separately because the answers differ:

**Buyer → seller reviews work, and now have tests that say so.** A buyer
rates a LISTING; `sellerRating` rolls every review of every listing up into
the seller's score. Six behavioural tests pin the parts that were only ever
argued from reading the code: an unverified review is real and counts
toward the rating (the chip says how a purchase was PROVED, not whether the
review is genuine); the right code under the right handle earns
`confirmedPurchase`; **the same code under somebody else's handle earns
nothing** — the binding is the whole point, a leaked or handed-on code must
not buy the chip for an account that never bought — while still posting as
an unproved opinion; you cannot review your own listing; and reviewing
twice corrects rather than stacking the rating.

**A second stranding, the same shape as the listings one.** Reviews ride
the repaired `sendFeedPost`, but nothing re-publishes a review nobody
edits, so any review written before the publish fix (or while offline) sat
on the reviewer's device forever. `_backfillOwnReviews` mirrors
`_backfillOwnListings`: after each fetch, upsert only the caller's own
reviews the table did not return. This matters more than the listing case —
a rating is the thing a stranger trusts a seller on, and it must not
quietly depend on which device the reviewer used.

## Seller → buyer reviews: the other direction (2026-08-14)

Until now every review in the app was a review OF A LISTING, so it only
ever pointed buyer → seller. A seller had nowhere to say a buyer was good
to deal with, and a buyer had nothing to show for it. Built at the owner's
"yes build it", on the anchor the sold-to handshake already provided.

**One field tells the two directions apart.** `FeedPost.buyerHandle` — the
handle of the person being reviewed — is empty on everything else, and
`isBuyerReview` is `rating > 0 && buyerHandle.isNotEmpty`. `isReview` stays
true for BOTH, because both carry a rating and both hang off the listing by
`parentId`; a separate post kind would have needed its own delete cascade,
its own moderation path and its own publish branch, all of which a review
already has.

**`reviewsFor` excludes buyer reviews, and that exclusion is the whole
correctness of the feature.** `sellerRating` reads `reviewsFor`, so without
it a seller rating their own buyer five stars would have raised THEIR OWN
seller score — a self-review with extra steps. The two aggregates are kept
apart on purpose (`buyerRating`/`buyerReviewsOf` are the mirror pair): being
good to buy from and being good to sell to are different claims, and
averaging them lets one launder the other.

**Who bought what stays on the seller's device — until they choose
otherwise.** `FeedStore._soldTo` (listing id → handle, persisted under
`'soldto'`, written by `mintSaleCode`) is LOCAL ONLY and deliberately not a
field on the listing: a listing is published to a world-readable table, so a
`soldTo` on the post would broadcast every sale's buyer to everyone, whether
or not anybody ever writes a review — exactly what the sale code's
hash-only design already refuses to do. It exists so the seller's own device
can answer "who was this sale for" when they come to review them.

`buyerHandle`, by contrast, DOES ride the wire, and that is a real
disclosure rather than an oversight: no other device can compute somebody's
buyer rating without knowing whose rating it is. So the sheet says it before
the button — "Posting names @ada publicly as the buyer of this listing." —
rather than leaving it to be discovered afterwards. Same bargain every
marketplace's two-way feedback makes; the difference is saying so.

**Permissions are the inverse of `addReview`, which is why it is a separate
function rather than a flag on that one.** `addBuyerReview` requires the
caller to OWN the listing (`addReview` refuses the owner), takes no sale
code (the seller does not prove the sale to themselves — `soldTo` already
recorded it), and refuses outright when no buyer was named, which is the
honest answer for a listing marked sold without naming anyone: there is
nobody to review. `confirmedPurchase` is true by construction, since the
person writing it is the one who marked the sale.

**UI, all in `marketplace_screen.dart`:** `_BuyerReviewBlock` sits UNDER the
listing's Reviews section rather than inside it — "Reviews" on a listing
means reviews of what is being sold, and folding a rating of the buyer into
that list would read as somebody rating the seller. It draws only when there
is something to show or something to do (the seller sees "Rate the buyer"
once a buyer is named; everyone sees a buyer review that exists), and
`_BuyerReviewSheet` is its own sheet for the same reason the store function
is: different words, no sale-code field, and a disclosure `_ReviewSheet`
does not need. On `SellerScreen` a buyer rating shows as its own line
("As a buyer: 4.8 · 3 ratings from sellers") rather than a fourth stat
beside the seller rating — a row of four reads as one score split up.

Tests pin the direction split (a buyer review never lands in
`sellerRating`, and vice versa), the owner-only permission, that `_soldTo`
never reaches `toJson`, and the whole seller-side flow end to end: no
button before the sold handshake, the disclosure sentence on screen before
the rating posts, and the score landing on the buyer.

## Planning a meeting in a chat (2026-08-14)

Asked for plainly: "allow users to plan meetings in chat." The attachment
panel gains **Meeting** (1:1 and group; not your own notes — a meeting is
something to agree on with somebody, and there is nobody there to say yes),
which sends a card carrying what, when and optionally where, with
**Going / Maybe / Can't** on it.

**A meeting IS a poll, and building it as one is the whole design.**
`Message.isMeeting` is set alongside `isPoll: true` with three fixed
options, so an RSVP is literally a poll vote: it rides the existing
`'poll'` event, which already seals, already mailboxes for an offline
recipient, already attributes the voter (`pollVotesBy`, added for weighted
polls), already lets somebody change their mind without duplicating, and is
already registered in all three places a community-or-inbox event has to be
— the live `.onBroadcast` chain, `applyInboxEvent`'s dispatch, and the
mailbox-drain roster. **A meeting-shaped event would have needed every one
of those again**, and this file's own history is that an event missing from
one of the three is silently dropped. `ChatStore.votePoll` /
`applyRemotePollVote` needed no change at all: both gate on `m.isPoll`,
which a meeting satisfies.

The cost of that reuse is one ordering rule, stated at three sites in the
code because getting it wrong is invisible: **`isMeeting` is checked BEFORE
`isPoll`** wherever a bubble or a label is chosen. `typeLabel` says
"📅 Meeting" before it can say "📊 Poll"; `MessageBubble` draws
`MeetingBubble` before it can draw `PollBubble`. A test pins the second one
by asserting `PollBubble` is ABSENT from a rendered meeting — the failure
mode is not an error, it is a nameless poll offering Going/Maybe/Can't.

**The headcount counts PEOPLE, never a weighted tally.** `pollVoteWeight`
(a group admin's vote counting double — "Decision Voting") is deliberately
not passed to a meeting, at both the chat-screen call site and inside
`MessageBubble`. A room can weigh the admin twice when it is DECIDING
something; "3 going" has to mean three people or the number is a lie about
how many chairs to find. `meetingRsvpCounts` (`lib/models/meeting.dart`,
pure) is the separate tally, and it ignores an option outside the three
rather than counting it.

**The reminder is real, and it is honest about being local.** Half an hour
before the start, this device asks the OS for a notification — via a new
`PushService.localNotifyAt` / `cancelLocalNotify` pair and a matching
`localNotifyAt` / `cancelLocalNotify` case in `AppDelegate.swift`
(`UNTimeIntervalNotificationTrigger`, iOS 10+, well under the iOS 15 floor,
so no `#available` needed). **Deliberately not the `Scheduler`**, whose own
doc says it delivers "while the app is running" — a meeting reminder that
only fires if you happen to have the app open is not a reminder. The
request is keyed by message id, so the same id REPLACES rather than stacks
(an RSVP changed twice must not queue two reminders) and `cancelLocalNotify`
takes it back. Whoever planned it is reminded without RSVPing to their own
meeting; everybody else gets one when they say Going and loses it when they
change to Maybe or Can't. A meeting less than the lead time away schedules
nothing — iOS delivers a past trigger instantly, which reads as a bug rather
than a reminder, and `meetingReminderAt` returns null for it.

**Nothing touches a calendar, and the composer says so** ("Nothing is added
to a calendar — the reminder is on this phone only"). A real calendar entry
needs a plugin, a new pod, and a device to verify it on; claiming one and
not writing it would be worse than saying plainly that there isn't one.

**Deliberately four fields and no more** — what, when, where, and that is
it. No end time, no repeat rule, no guest list: a meeting somebody plans in
a chat is "coffee, Thursday, that place on the corner", and every extra
field sits between the idea and the message. Who is invited is who is in
the conversation.

A past meeting keeps its card and loses its buttons — what happened last
Tuesday and who came is still worth scrolling back to, but it is a record,
not something left to answer.

**Channels: display only, on purpose.** There is no way to plan a meeting
in a channel — the option is in the chat attachment panel alone. But
`communities.dart`'s channel bubble branched on `isPoll` with no meeting
guard, so one arriving there would have drawn as that nameless poll, and
`relay_service.dart`'s `chmsg` whitelist (the hand-written field-by-field
rebuild that has now dropped voice audio, `threadRootId`/`viewOnce`, and
the sticker/location/contact fields on three separate occasions) did not
carry the four meeting fields either. Both are fixed defensively —
read-only, since a channel RSVP would need `votePollInChannel`, which
nothing sends.

**Unverified from this box, as always for Swift**: the two new
`AppDelegate` cases have never been compiled, and no device has seen a
scheduled reminder fire. The Dart half is proven in-process through
`PushService.debugScheduled`.

## The QR card can be customized, Telegram-style (2026-08-14)

Asked for as "customize their QR code like telegram". `MyQrScreen` was a
black-on-white square on a white box; it is now a card with a gradient, the
name and handle on it, the profile photo in the middle of the code, a row
of looks to pick from, a Squares/Dots switch, and a share button that hands
over the card as a **picture**.

**Every preset is authored as a PAIR — background and modules together —
and that is the whole safety of the feature.** A QR is not decoration: a
scanner needs real contrast between the light and dark squares, and a free
colour picker is exactly how somebody ends up with a beautiful code no
camera can read. So there is no picker. There are eight presets
(`lib/models/qr_style.dart`, pure), each a combination that stays
scannable, and **a test measures the WCAG contrast of every one of them**
rather than trusting the eye that chose them — held to 4.5:1, the text bar,
rather than the ~3:1 a scanner actually needs, because a code gets read in
bad light, at an angle, through a scratched lens. The default is deliberately
`classic`, plain black on white: somebody who never opens the picker still
gets the most scannable code there is.

**Nothing on the screen changes what the code SAYS.** The colours, the
shape and the photo are paint; `payloadFor` is untouched by all of it, and
a test pins that the payload is byte-identical before and after switching
presets. Worth stating because "customize your QR" is a phrase that could
just as easily have meant changing what it encodes, which would quietly
break every card somebody had already handed out.

**The photo in the middle is safe because of one line, and that line is
unconditional.** `errorCorrectionLevel: QrErrorCorrectLevel.H` — the ~30%
level — is set whether or not the photo is on, so turning it off can never
leave a code that had been relying on it, and a code that survives a
thumbprint and a crease is worth the extra modules anyway. The cut-out is
filled with the gradient's own start colour, so it reads as a hole in the
code rather than a sticker on top of it. A test pins the level in both
states.

**The ink on the card is chosen by the card, not the app theme** — the card
keeps its colours in dark mode and light mode alike, so the theme has no
say in what is readable on top of it. Same rule as "A bubble's contents
take the BUBBLE's colours"; a third instance of that class of bug avoided
by construction rather than found by a user.

**Share hands over a PNG, not the link.** A `RepaintBoundary` around the
card only (not the app bar, the hint sentence, or the account code below
it) → `toImage(pixelRatio: 3)` → `shareImageBytes`, a new sibling of
`exportBackupFile` in the same conditional-import trio, so web gets the
same Web-Share-first / download-fallback treatment the backup export
already needed for iOS Safari. A URL cannot be shown to a third person's
camera, printed, or put in a bio; the picture is the point.

`QrStyleStore` is account-scoped and wired into `account_wipe.dart`'s
reset-and-reload pair, like `ChatFolders`: the card is your identity card,
and the next account signing in on this handset should get its own rather
than inherit one. An unknown preset id (a look saved by a newer build)
falls back to `classic` rather than leaving somebody with no QR at all.

**Deliberately not applied to the Receive-money QR** (`receive_money_screen
.dart`). That code is a payment link rather than an identity, it is shown
once to get paid rather than kept as a card, and maximum scannability is
worth more there than a look. If that ever changes, the style and the store
are already shared code.

## A forwarded listing is a CARD now, and links are too (2026-08-14)

Three asks in one round: forwarding a marketplace listing should link the
real listing "like how Facebook does it"; URLs should preview and YouTube
should play in chat; and a profile should show when somebody joined and how
they are verified.

### The listing card

Forwarding used to send `listingShareText` — a title, a price and "Seen on
the marketplace — ask me about it!". Words somebody has to read and then go
and search for. `Message.listingCard` now carries a `ListingCard`
(`lib/models/listing_card.dart`) rendered as a photo-and-price card that
OPENS the listing, exactly as `serverInvite` has always carried a joinable
server. That only became possible when the marketplace went global
(2026-08-08): before then a listing id meant nothing on another device.

**It carries a SNAPSHOT as well as the id, and both halves earn their
place.** The id is what makes it tappable. The snapshot is what makes it
still say something on a device that has not fetched the marketplace yet,
and on the day the seller takes the item down — the card is a record of
what was shared, and blanking it because the listing ended would be worse
than a stale word. It is never refreshed for the same reason: silently
rewriting a message somebody sent is not an improvement. Tapping pushes the
real `ListingScreen`, which already draws "This listing was removed." for
an id it cannot resolve, so no second version of that sentence was written.

The forward still sends the old text alongside — it is what an older build
renders and what the chat list previews — so nothing regresses for a phone
that has not updated.

### Link cards, and YouTube playing in the app

`Message.linkPreview` carries a `LinkPreview` (`lib/models/link_preview.dart`,
pure) drawn under the words, never instead of them.

**Built on the SENDER's device, and that is the whole privacy argument
rather than an implementation detail.** If the RECIPIENT's phone fetched
the page to draw a card, opening a chat would tell that site — and anyone
watching that network — that the message had been read, and roughly when.
So the sender, who already chose to visit the link, does the fetching; the
result rides inside the same sealed envelope as the words; the receiving
device draws it having contacted nobody. The thumbnail is embedded as a
data URI for the same reason: a remote image URL on a card is a request to
the host every time somebody scrolls past it.

**It is built WHILE TYPING, not on send.** `_warmLinkPreview` runs off the
composer's existing `onChanged` (the one that saves the draft), so by the
time somebody has finished writing around a link the fetch has usually
landed — and if it has not, the message goes without a card rather than
pausing between tapping send and the message appearing. A slower answer for
a link the composer has since moved off is dropped, so the card always
describes the link actually sent.

**YouTube needs no page fetch and no key**: the id is in the URL and the
thumbnail is at a published address, so a YouTube card works from the URL
alone. Playing it is a WebView on YouTube's own embed page — the only way a
third-party app is permitted to play one — hosted in the app's own screen
(`VideoPlayerScreen`, `VideoEmbed`, the same native/stub conditional-import
pattern the Stripe Connect view uses so the web build never compiles
`webview_flutter`). Deliberately NOT a WebView inside the bubble: one
native view per bubble in a scrolling list is how a chat starts stuttering.

**Instagram and Facebook reels do NOT play, and the card says so.** They
serve reels behind a login and their oEmbed needs an app token; nothing
this app can do will play one. So a reel card reads "Open in
instagram.com" rather than showing a play button that hands you to another
app — a small lie told a hundred times a day is still a lie. A reel is
still given a card when the page cannot be read at all, because a login
wall is exactly the case that branch exists for; a plain page with nothing
readable gets NO card, since a rectangle saying only "example.com" is worse
than the blue link it replaced.

Open Graph is read with a regex rather than an HTML parser, deliberately:
this is the path that touches arbitrary untrusted pages, and a slightly
worse preview costs less than a parser dependency's attack surface. Pure,
so the awkward real-world markup (either attribute order, either quote
style, entities) is testable without a network. **On the web build previews
will mostly fail to CORS and fall back to a plain link** — no card is a
supported outcome everywhere in this path.

### Joined, and how they are verified

`AppUser` gains `joinedAt`, `phoneVerified` and `emailVerified`, riding the
sealed profile share ungated like `isBusiness`, applied AS SENT so a lapsed
verification clears on other people's devices — which meant touching every
full-rebuild site this file has warned about since business profiles
(`Session.signIn`/`updateProfile`/`setVerified`, `AppState.updateProfile`/
`setVerified`, `ChatStore.updateContactProfile`, relay `encode`/
`applyIncoming`/`applyProfileUpdate`/`broadcastProfile`). `joinedAt` is the
exception to as-sent: it is never zeroed, because a message from an older
build carries none of these and a contact must not lose their join date
because the last thing they sent came from a phone that had not updated.

`joinedAt` is stamped ONCE, at the first sign-in this device knows of, and
carried by every rebuild after — signing in again must not reset the day
somebody joined. An account that predates the field shows nothing: "we
don't know" is a fact, an invented date on somebody's profile is not.

**`ProfileTrust` only ever draws what this device can honestly answer.**
The username directory has no column for any of it, so a STRANGER's
profile shows the section not at all — three grey "not verified" chips
would read as a finding about them when they are really a finding about
us. That is the same rule `knownBusinessSeller` follows. On your own
profile it reads `AccountVerification`, which already owns all three
answers. Only verified things get a chip; the join line is a month and a
year, never a day.

**Why email verification can only work this way:** there is no server
column mapping an account to an email (a verified address lives only inside
the encrypted backup), so this flag riding the sealed profile share IS the
only way another device could ever know — and it must never reach the
public directory.

## The profile wears X's shape (2026-08-14, the owner's call)

Asked for as "make the user profile style more like x". Three changes, and
the interesting thing is that two of them make the header SHORTER — the X
layout is not a decoration, it is a compression.

**Metadata is one wrapped row, not three stacked ones.** Where you are,
your link and when you joined used to be three `Row`s in a `Column`, each
spending a whole line on a handful of words; they now flow together in a
`Wrap` (`_MetaItem`) exactly as X lays them out, dropping to a second line
only when the width runs out — which it does at 390pt with all three
present, and which is also what X does. A test in `type_metrics_test.dart`
measures the real claim rather than the flattering one: the first two share
a line, the third wraps to the LEFT EDGE rather than stacking, and the whole
block is under 56pt end to end — two lines, not three. Measured as a height,
because "it looks stacked" is a height and not a tree shape.

**The join date moved onto that row**, which meant splitting the widget
added hours earlier: `ProfileTrust` now draws the verification CHIPS only
and exposes `joinedFor`/`joinedLabel` as statics. One place still decides
who is allowed to know somebody's join date (nobody, for a stranger — the
directory has no such column) and one place decides how it reads; the
metadata row just asks. Splitting a widget rather than duplicating the rule
is the whole reason the privacy answer stays in one file.

**Counts read Following then Followers**, X's order — what you chose before
what chose you — with the post count last. `ProfileStat` was already the
inline "bold number, muted label on one line" shape X uses, so nothing about
it changed; only the order did.

**The collapsed app bar carries the post count** under the name, which is
where X keeps it and is worth repeating precisely because that bar is what
is left once the header has scrolled away. Absent, never "0 posts", until
the count is known — the same rule the stat itself follows.

**Round 2, same day: the header band is back, and that reverses this
file.** The first pass shipped the three changes above and recorded a
reason for NOT touching the header — the generated colour band was removed
on purpose in the 2026-08-09 less-generated-UI pass, so putting one back
looked like undoing a deliberate decision. The owner reported "The profile
stilll looks the same", which was fair: the metadata row draws NOTHING
without a location, a link or a join date, and `joinedAt` is null on every
account that already existed (it is stamped in one place, `Session.signIn`,
and `usernames` carries no `created_at` to backfill it from honestly); the
count order and the app-bar subtitle are real but quiet. Asked which way to
go, the owner chose the X header. **So the band is back at the owner's
direction (2026-08-14) — do not "restore" the flat row.**

What makes it not the thing that was removed: **it is not a saturated block
nobody chose.** With no banner colour picked the band is a
`surfaceContainerHighest → surfaceContainerHigh` gradient — the page's own
tint, a shelf rather than a colour — and only becomes the person's two
colours when they actually picked one. That was the whole complaint the
2026-08-09 pass was answering, and it is answered here rather than
overruled.

Proportions are X's: `_avatarRadius` 40, `_bandHeight` 68 (short for a
banner — X's is nearer 1:3 — because the fold is still a budget), and the
face hangs `_overhang` 30 below the band, ringed in
`scaffoldBackgroundColor` so it reads as sitting ON the page rather than
pasted on the band, and so it still reads when the band behind it is dark.
The band is **edge to edge with no rounding** (`Positioned(left: 0, right:
0)`): a rounded card floating inside a margin reads as a widget on the page
instead of the top of it. `_ProfileActions` moved INSIDE the header,
level with the overhang on the right, exactly where X keeps Edit
profile / Follow.

**It costs thirty-nine points, not a hundred and twenty** —
`type_metrics_test.dart`'s "a profile spends its first screen on the
person" guard caps the tab strip at 520pt, its own comment used to predict
a returning banner would land "near 570", and it measures **505** against
466 before, because the buttons that came inside the header stopped taking
a row of their own. That comment is corrected in place rather than deleted,
since the prediction being wrong is the useful part. Fifteen points of
headroom is not much, and the note says which knob to turn if it ever needs
to give: the band, since it is the only part of the header that is purely
decoration.

**Two real bugs in the first cut, and the first was caught by a test about
something else entirely.** The strip was sized to the AVATAR's overhang —
30 points, shorter than a tap target — so the action button standing in it
hung past the `Stack`'s own box. Under `Clip.none` an overhanging child
still DRAWS, while Flutter's hit test refuses anything outside a box's
size, so the button was **on screen and dead**; the avatar's ring overhung
for the same reason and painted over the display name under it. The button
landed exactly on the boundary, which is why it read as flaky rather than
broken. Nothing in the profile's own tests noticed — they measure and
count, and it looked perfect. What noticed was *The QR icon in Settings
opens the My QR code screen*, which tapped it. The strip is now as tall as
the tallest thing standing in it (`_AvatarRow._height` = band + gap +
`_actionsHeight`), the band paying the difference, and there is a
regression test that TAPS the header button rather than measuring it.

The second was found while chasing the first: `_ProfileActions` sat in a
`Positioned` with only a `right` edge, which hands a child **unbounded
width** — and it is a `Wrap`, which never wraps when it may be as wide as
it likes. A full creator (Message + Follow + Subscribe + Spark + Tip) would
have run off the right edge instead of dropping a line, undoing the round-2
`Wrap` from earlier the same day. Both edges are given now, `left` starting
clear of the avatar's ring.

Still not done, and still not an oversight: **no cover-photo UPLOAD**. A
real header image is a new upload surface, a new bucket path and a new
moderation question, none of which "style it like X" asked for.

## The dial pad (2026-08-14)

Asked for as "improve the dial pad in calls". `DialerScreen`
(`lib/screens/dialer_screen.dart`, reached from the Calls tab). Five things,
and the first two are defects rather than polish.

**The bottom row was unpressable on a 320-point phone.** The keypad was four
rows of fixed 72pt keys inside a plain `Column`, which overflowed by **33
points** at 320x568 — the SE 1st-gen, a device the iOS 15 floor deliberately
keeps ("everything that could run iOS 13 … also runs 15"). An overflowing
column clips, so 7, 8, 9, *, 0 and # were off the bottom of the screen: on
that phone you could not dial half the digits. The keypad is now a
`Flexible` + `FittedBox(scaleDown)`, so it shrinks in proportion — glyphs and
tap targets together — on a screen short enough to need it and is untouched
on one that is not. Chosen over computing a key size from the leftover
height, which would have meant a hard-coded constant for everything else on
the screen and a new overflow the next time a line was added. A test pumps
both sizes and asserts `#` is above the fold.

**The '+' under the 0 key had nothing behind it.** It has been printed there
since the screen was written and `_tap` only ever appended the digit, so the
one character an international number cannot be dialled without was
unreachable while being advertised. Long-pressing 0 now types it, **only at
the front** — '+' means "a country code follows", so a second one, or one in
the middle, is just a character the network refuses.

**Three more things every phone dialer has and this had not:** long-pressing
backspace clears the whole number (eleven taps to take back a mistyped one
was the complaint); the number is grouped as it is typed; and it keeps its
TAIL on screen when it outgrows the width. That last one was a real bug —
`TextOverflow.ellipsis` hides the END, which on a dial pad is the digits
just pressed, so you could not see what you had typed. It is a horizontal
`SingleChildScrollView` with `reverse: true` now, with a `minWidth` equal to
the viewport so a short number still centres rather than being shoved
against the right edge.

**`formatDialedNumber`** (`lib/util/phone_format.dart`, pure) is the
grouping, and it is deliberately narrower than it looks: it only ever groups
NANP numbers. The dial pad takes anything and there is no way to know which
country a bare run of digits belongs to — Apple and Google guess from the
SIM's region, which this app has no equivalent of — so `+`-prefixed numbers,
feature codes carrying `*`/`#`, and anything over 11 digits are handed back
exactly as typed. Inventing brackets for a number that turns out to be
German is worse than not grouping it. Separate from the existing
`formatPhoneForDisplay`, which only knows what to do with a number that is
already complete; this one has to say something sensible halfway through an
area code.

**The number's owner is resolved from this device's own chats and nothing
else.** `_knownContact` walks `ChatStore.allChats` with `samePhoneNumber`
(country-code-robust, the same helper the self-chat redirect uses) — no
directory call, so typing a number tells the server nothing about who is
about to be called. A number you have never spoken to stays a number, which
is the honest answer and the same rule `knownBusinessSeller` follows.

**Paste reads the clipboard on the TAP, never to decide whether to draw the
button.** Both platform dialers peek at the clipboard when they open so they
can offer a paste chip only when there is a number on it; that is a silent
read of whatever somebody last copied — a password, a message — by a screen
they opened to make a call. The button is unconditional here and says
"Nothing on the clipboard looks like a number." when there isn't one. A test
asserts the read count is **0** after the screen has drawn.

Smaller: backspace got the haptic every other key already had; each key is
one `Semantics` node ("2, A B C") instead of two unrelated `Text`s in a
column; and the `SizedBox(width: 24 + 56)` that centred the call button is
now named constants (`_callGap`, `_CallButton.plainSize`) rather than a
number nobody could check.

**Not done, and not an oversight: no DTMF tones.** Feeding digits into a
phone menu mid-call needs real audio, and the only sounds this app has ever
played are the two iOS System Sound IDs `okay/ringtone` already uses (see
the custom-message-sounds section for why inventing more IDs from memory is
not something this box can verify). The keypad also does not appear DURING a
call for the same reason — it would be a keypad that sends nothing.

## Money is one screen, and Settings got shorter (2026-08-14, the owner's call)

Two asks in one message: "combine get paid, earnings and wallet/payments"
and "try to combine a lot of stuff, the settings is getting too long". The
hub went from **31 rows across 9 sections to 22 across 7**, and nothing was
deleted — every destination is still reachable, several by one more tap.

### MoneyScreen

`lib/screens/money_screen.dart` — a `TabBar` of **Wallet · Get paid ·
Earnings**. The three were adjacent Settings rows, and the Wallet already
carried TWO doors into Get paid (the onboard card's "other ways", and the
row under the payout card), which is what a screen does when it is really a
tab of something.

**The gate is on the WALLET TAB, never on the screen, and that is the whole
reason this could be combined at all.** The comment that used to sit beside
the Get paid row said it: the Wallet needs a phone number to load, the
Lightning rail needs no account of any kind, and "putting the only door
inside the one room they cannot enter would have hidden that from exactly
the people it is for." A `PhoneGate` around `MoneyScreen` would have
recreated that fault across all three tabs. So the wallet keeps its own
three gates and they now take `scaffold: false` — `PhoneGate` and
`ParentalGate` already had that flag for tab bodies; `VerifiedGate` gained
it here. A test pumps a real numberless session, finds the gate on the
Wallet tab, taps across to Get paid, and asserts the Lightning field is
really there; a second pins `PhoneGate(` **out** of `money_screen.dart`
(matched as a constructor, because the file's own doc names the class while
explaining the rule — a bare-name check fails on the sentence that
documents it).

Each of the three keeps its own screen and its own standalone route — the
wallet is still pushed from a marketplace purchase, Get paid from the
"they can't receive money yet" sheet — they just also render with
`embedded: true`, which returns the body without a scaffold, app bar or
bottom bar.

**The wallet's app-bar actions follow it up.** Transactions, Payment
controls, Refresh and Check payments setup would have silently disappeared
the moment the wallet stopped owning an app bar. `_actions` became a public
`actions(BuildContext)` on an `abstract class WalletScreenActions extends
State<WalletScreen>`, which `MoneyScreen` reaches through a `GlobalKey` —
one copy, not two that drift. `Refresh` and `_openControls` both live on
that state and would have been impossible to lift any other way without
losing what they do after they return (the paused-banner epoch bump). The
key is not attached until the wallet tab has built once, so `initState`
schedules a single post-frame rebuild; without it the bar draws empty on
the first frame and is never asked again.

### StorageBackupScreen

Chat backup, Cloud storage and Storage-and-data were three rows answering
the same question in different words. `storage_backup_screen.dart` holds
all three. **The overdue-backup badge stays on the Settings row**, not one
level down: an overdue backup is the reason somebody would open this at
all. **The clear-all-chats confirmation did not move** — the hub takes an
`onClearChats` callback and calls Settings' own dialog, because two dialogs
offering to delete every message is one too many; a test pins
`showAppConfirmDialog`/`AlertDialog`/`ChatStore` out of the hub file.

### The rest of the shortening

* **Privacy & security: four rows → one.** Payment security, Permissions and
  Muted accounts moved INSIDE `PrivacySettingsScreen` — a mute is the same
  decision as a block and belongs beside it; permissions and the payment
  step-up are the same kind of decision as an app lock. A section heading
  over four rows that all say "privacy" is a heading doing no work.
* **"What the server can see" went to About & support**, beside the Privacy
  Policy and the Terms. It is the same disclosure in the app's own words,
  not a setting anybody changes, and the privacy SECTION is where somebody
  goes to change something.
* **The "Newsfeed" section is gone.** Bookmarks joined "Chats" (renamed
  **Chats & content**) and Muted accounts went to privacy — two rows were
  not a heading's worth of work between them.

Tests that walked the old paths were UPDATED, not deleted: the bookmarks/
muted test now navigates through Privacy and scrolls (that row is at the
bottom of a long LAZY `ListView`, so it is not merely off-screen, it is not
built — `find.text` reports zero rather than one it cannot reach); the
clear-chats test goes one level deeper; the sections test names the new
headings; the Earnings and Get paid source pins point at `MoneyScreen`.

**Not touched, deliberately:** the Account section's Account / Email /
Okay Score rows. Each is a different kind of identity and folding them into
one "Account" screen would have meant a hub inside a hub for three rows
that already say plainly what they are.

## The Notifications tab lost its filter chips (2026-08-14, the owner's call)

All / Messages / Calls / Servers, circled on a screenshot and removed.
`_Filter` and every `show*` guard went with them — the row was the only
thing that could set it, so leaving the enum would have left dead state
behind a deleted control.

The reason it was safe: **the list is already sectioned by exactly those
four headings** (NEW MESSAGES, MISSED CALLS, MENTIONS & REPLIES, and the
server posts), and it is short by construction — this is what happened
since you last looked, not an archive. So the chips spent a row of chrome
filtering something you can see all of anyway, and "All" was selected
essentially always, which is the shape of a control nobody needs.

The `Column`/`Expanded` that existed only to stack the chips above the list
went too — a `Column` with one `Expanded` child is just the child. A test
pins both halves: no `ChoiceChip` on the tab, AND the section headings still
drawing, since those are what the chips were duplicating and they are the
part that must not be lost with them.

## Chat composition: formatting buttons, bigger text, an optional subject (2026-08-14)

Asked for as "add more options for chat, add bold, make font bigger, allow
user to enable a subject bar". Three things, and the first one is smaller
than it sounds.

**Bold already worked. What was missing was any way to reach it.**
`RichMessageText.parse` has understood `*bold*`, `_italic_`, `~strike~` and
`` `mono` `` since the app shipped — WhatsApp's markers — so a formatted
message has always RENDERED formatted. Nothing anywhere told anybody the
syntax existed, which makes it a feature only its author can find. The new
`_FormatBar` is a B / I / S / M strip that wraps the current selection in
those same markers, opened by a `text_format` button in the composer row.

Three decisions in it:
* **It writes the EXISTING markers, not a richer format only this app could
  read.** A message is plain text on the wire either way, so a recipient on
  an older build sees `*world*` rather than nothing — the honest failure.
* **The selection stays selected** after a wrap, so a second marker stacks
  on the first (`_*world*_`) instead of landing somewhere else. With nothing
  selected it drops an empty pair with the caret between them.
* **It does NOT dismiss the keyboard**, unlike the emoji and attachment
  panels it otherwise copies. Those replace the keyboard; this one acts on
  the selection IN the field, and closing the keyboard would drop the
  selection it is about to wrap.

**Message text scales to 1.60**, up from 1.30, which was reported as not
big enough. Fifteen divisions keeps every step 5%. The clamp in
`persistence.dart` had to move with it or a saved 1.55 would come back as
1.30 — a test pins both numbers together for exactly that reason. Past 1.60
a short message wraps to three lines on a 320pt phone, and iOS's own
Dynamic Type is a separate multiplier on top, so somebody who needs more
has it system-wide.

**The subject bar is a real `Message.subject`, not a bold first line.**
`AppState.showSubjectBar` (persisted, OFF by default — a permanently empty
field above every composer is a row of chrome nobody asked for) draws a
one-line field above the composer, capped at 80 characters because a
subject is a label and the message already has somewhere to go.

The field rides the sealed payload as its own thing rather than being faked
into the body, which could never be told apart from somebody typing a bold
first line themselves. That meant the usual three places: `Message`
(toJson writes it only when non-empty, so nothing grows on the wire for the
overwhelming majority of messages that have none; fromJson defaults to `''`
so a message stored before the field decodes rather than throwing), the
relay's `encode`/`applyIncoming`, and — defensively — the `chmsg` channel
whitelist, which has now dropped a new field three times running. A channel
has no composer that can SET a subject; a message forwarded in from a chat
carries one.

**Stamped in `_deliver`**, the one funnel every send already passes
through, beside the protected/marketplace/thread flags — and cleared
immediately, because carrying it over would title the next message with
something written for this one. Only ever on a message that has words: a
subject with no body is a title for nothing.

Two smaller things worth not rediscovering: the composer's
`ValueListenableBuilder` on blocked contacts became a `ListenableBuilder`
merged with `showSubjectBar`, or flipping the switch in Settings would not
have grown the row until whatever rebuild happened to come next; and the
subject renders in the bubble in the BUBBLE's own `textColor`, never the
app accent — the third instance of the rule under "A bubble's contents take
the BUBBLE's colours", followed by construction this time rather than found
by a user.

## Undo send: taking a message back inside five minutes (2026-08-14)

Asked for as "allow users to undo a message within 5 min of sending it
without having to delete or edit it". The "without" is the whole feature:
there were already two things you could do to a sent message and **both of
them announce that something was there** — delete-for-everyone leaves a
"This message was deleted" tombstone, an edit leaves an "edited" mark.
Undo send leaves the conversation reading as though it was never sent.

`kUnsendWindow` (5 minutes) and `Message.canUnsendAt(now)` /
`unsendLeftAt(now)` are the rule, pure and clock-injected so a test does not
have to wait five minutes. Yours only, never a tombstone (nothing left to
take back), and the window closes AT five minutes rather than just after.

**Mechanically it is the delete-for-ME path run on BOTH devices**, which is
what makes it traceless: `ChatStore.unsendMessage` removes the message from
the list entirely and tombstones its id in `_deletedMessageIds` so a mailbox
replay cannot bring it straight back. It is a separate method from
`deleteMessage` rather than a flag on it because the intent is different and
each is worth changing on its own. A new sealed, mailboxed `unsend` event
(`RelayService.sendUnsend`) carries it to the peer.

**The window is the SENDER's gate, and the receiver honours the event
whenever it arrives.** A receiver has no trustworthy clock for when the
button was pressed, and putting a five-minute check on the receiving end
would only mean a slow network could make an undo silently fail. That is the
same trust model delete-for-everyone already has, and it is stated here
rather than implied: a modified client could unsend something old, exactly
as it could delete something old today.

**What it cannot do, said on screen rather than in a comment.** The snackbar
reads "Taken back. They may already have read it." — not "Message unsent".
The words may already have been read, and on a current build they may
already have been shown in a push notification, since encrypted previews put
the real text on the lock screen. Undo removes the message from being THERE;
it does not unsee it.

**A real gap found while wiring it.** `applyInboxEvent` (the sealed router)
and the mailbox-drain switch are two rosters this file has warned about
keeping in step — and `'locstop'` was in the first and NOT the second, added
when live location learned to stop (2026-08-13). A sealed stop was fine (it
arrives as `'sealed'` and routes through `applyInboxEvent`); a **legacy,
unsealed** one that had to wait in the mailbox was silently dropped. Both
`'locstop'` and `'unsend'` are in all three places now, and a test asserts
the mailbox roster carries `locstop` specifically.

The sheet entry sits ABOVE Edit — taking a message back is what somebody
reaches for in the seconds after sending, and it is the one that expires —
and carries the countdown ("4 min left", counting seconds under a minute,
which is when somebody is actually watching it run out). The window is
re-checked when the action fires, not only when the sheet was drawn: a sheet
left open on the table for six minutes would otherwise still offer it.

## Feed post actions: small, gathered bottom-left (2026-08-14, the owner's call)

"Make the comment, like and repost icons small on the bottom left hand side
for both newsfeed." Both timelines already draw the one `FeedPostActions`,
so this is a single widget and both changed together.

**This reverses the "evenly spread" note that used to sit in that file**,
which argued the spread put every target under a thumb rather than crowding
them into one corner. That reasoning is not wrong; it lost. Spread across a
full-width card the icons were the loudest thing on the post, and on a wide
screen a reply button ended up a long way from the words it answers. Do not
restore the spread. `MainAxisAlignment.spaceBetween` is gone; icon 17 → 15,
label 12.5 → 11.5, horizontal padding 8 → 5.

**Share keeps the right end**, via a `Spacer`. The three the owner named are
what somebody does TO the post and are the group that moved; share sends it
somewhere else, which is a different kind of act and is where a timeline of
this shape keeps it. Easy to change if that reading was wrong — one Spacer.

**The bug in the first cut, worth keeping because it is the whole trap in
"make it smaller".** It also set `tapTargetSize: MaterialTapTargetSize.
shrinkWrap`, which took the TOUCHABLE area down with the glyph: the button
measured **24** points tall instead of **40** (Material's padded 48, less
the 8 `VisualDensity.compact` takes back). Nothing on screen would have
looked wrong — the icons would have looked exactly as asked for, and the
buttons would simply have been harder to hit. `shrinkWrap` is gone and the
test asserts the height is 40 AND that `tapTargetSize` is not `shrinkWrap`,
so the difference between shrinking the look and shrinking the button is
pinned rather than remembered.

The same test measures the gather (the three sit together in the left half,
in order, within 150 points of each other) rather than trusting the
alignment constant, and that share still sits clear to the right of them.

## Photos and videos can be kept (2026-08-14)

`MediaSaver` (`lib/util/media_saver.dart`) writes to the device's own photo
library. **No new dependency** — `photo_manager` was already here for the
attachment sheet's recent-photos strip — and no new permission prompt beyond
the one it already asks for, asked only WHEN SAVING rather than at launch to
make a button look enabled.

Where Save appears:
* **The chat media viewer** (`ImageViewScreen`), beside Like and React. It is
  the same viewer the media gallery and a channel's view-once open, so all
  three answer the question.
* **A public post's photo** (`FeedPhotoScreen`, shared by both timelines) and
  **a public post's video** (`FeedVideo`) — a world-readable post has nothing
  to refuse.

**The two refusals, and why they live at the CALL SITES.** A view-once photo
is never saved — that is the entire point of view-once. And a chat with
"forward and copy off" already asks the other app not to let this leave;
keeping it in the photo library is exactly what that asks it not to do, so
Save follows `Message.protected` rather than being a hole beside it (same
honest limit the toggle itself states: a request their app honours, not a
guarantee about their device, and a screenshot was always possible).

`MediaSaver` itself knows nothing about either — a test bans `viewOnce` and
`protected` from the file. The rule lives at every `ImageViewScreen` call
site, so a surface added later has to make the choice out loud instead of
inheriting a permissive default. And when the answer is no the button is **not
drawn**, rather than drawn and then apologising: a Save that appears and then
refuses is a worse promise than one that was never offered.

**Five outcomes, five sentences** (`MediaSaveResult` + `MediaSaver.message`),
because one "Couldn't save" for all of them sends people to the wrong place:
saved, downloaded (no photo library — the web build, said in those words
rather than claiming Photos), denied (a Settings trip), empty (still
loading), failed. The wording lives in one place so three surfaces cannot
invent three phrasings for the same failure.

**BYTES are saved, never a capture.** A data URI decodes locally and a URL is
fetched once; what lands in the library is the file that arrived, at its own
resolution, not a screenshot of it scaled to this phone.
`photo_manager`'s `saveVideo` wants a `File`, so `tempFileFor` joined the
existing conditional-import shim beside `saveIncomingFile` — that is what
keeps `dart:io` out of `media_saver.dart` and the file importable on web.

**Not covered, stated rather than implied:** marketplace listing photos and
videos, and media received over Okay Drop (which already writes a real file
through `saveIncomingFile`). Neither was in the ask; both would need their own
call-site decision about what may be kept.

## The profile, third pass — and the guard was the reason it stayed cramped (2026-08-14)

"Redesign the user profile, it's too compact." The SECOND time the owner has
said that, and the reason the first pass only half-answered is worth naming:
`type_metrics_test.dart`'s "a profile spends its first screen on the person"
pinned the tab strip under **520 points**, and 520 was measured against a
header the owner had already called too compact. Every pass at the complaint
therefore re-decided that cramped was correct. That is a guard enforcing an
accident rather than its own intent.

**So the ceiling became the intent instead of a number.** The test now asserts
the strip's bottom is under **two thirds of the viewport**, plus at least 250
points left under it — which says the thing the test's own name says, and says
it at any device size. What it still refuses is a header that eats the screen;
what it no longer does is freeze one day's measurement as the design.

**Paid for in the right order.** The band — the ONE part of this header that
is decoration, and the part the guard's own note nominates as the first to
give — came down **68 → 58** (it had already gone 84 → 68 for the same
reason). Only what was left after that came out of the ceiling. Measured 505
before, 540 after: the extra 35 points are all type and rhythm, and 18 of the
35 were funded by the band.

What changed:
* **Rhythm 17 → 24** between primary blocks (name/handle, bio, meta, stats,
  score), 11 → 13 for the lighter detail lines that belong to the block above
  them. Outer padding 15/8 → 20/10.
* **The name is 22 → 26**, the badge 17 → 19, the handle 14.5 → 15.5, the bio
  15/1.45 → 15.5/1.5. The name is the largest thing on the screen and the one
  everything else is about; at 22 it read as a heading in a list of headings.
* **`ProfileStat`'s vertical padding 6 → 9** (it went 4 → 6 on the first
  complaint) — a stat is a tap target as well as a number.

**Width is still off-limits, and this is the third time it is worth writing
down.** The first wide pass grew the stat `Wrap`'s spacing and
`ProfileStat`'s horizontal padding as well, which tipped four counts from one
line to two — a whole extra line, not "a bit more room" — and the test caught
it. Vertical rhythm is free; horizontal is not.

## The You tab and the Newsfeed ended under the glass (2026-08-14)

Reported with a screenshot of the You tab: "can't scroll any further down to
view the last post". The last post was there — it just sat UNDER the floating
bottom bar with no scroll extent left to reach it.

This is the debt the floating bar came with, and the file already names it:
"a floating bar is laid out around by nothing, so each list pads itself by
`HomeNavBar.clearance(context)` … `extendBody` and the padding go together or
neither does." Two surfaces were still short of it:

* **The You tab** ended its slivers with a flat `SizedBox(height: 40)`. When
  the three home tabs were fixed, this one was not on the list — it is
  `PublicProfileScreen`, a profile screen SHARED with a pushed route, so it
  did not read as a tab. It now takes `HomeNavBar.clearance(context)` when
  `embedded` and keeps the plain 40 when pushed, where there is no bar to
  clear.
* **The Newsfeed timeline** still had `bottom: 96` — the exact hardcoded
  constant `chats_tab`/`calls_tab`/`activity_tab` were fixed for, and short of
  the bar's real height on a home-indicator iPhone. Now `clearance` as a tab,
  24 when pushed (that Scaffold sets no `extendBody`, so its own copy of the
  bar is laid out BELOW the body).

**One test now covers the class rather than the two instances**: every home
tab's source must clear the bar by MEASURING it — `HomeNavBar.clearance` or
`AppBottomNavBar.overlayHeightFor` — and no file may carry `bottom: 96)`,
the constant that stood in for it and was wrong every time. Asserted against
the source rather than by scrolling, because the failure is "the last pixel
is under the glass", which a widget test at an arbitrary viewport cannot see
and which a wrong constant passes as happily as a right one.

The You tab gets its OWN pin on top of that: it shares a file with the
Newsfeed, so a blanket "this file mentions clearance" would have passed on
the Newsfeed's line alone while the profile stayed broken — which is exactly
the state it was reported in.

## Chat rows swipe both ways (2026-08-14)

"Add left and right swiping actions like other social media's have." A chat
row already swiped ONE way — right-to-left, to archive, and nothing else.

`SwipeActions` + `SwipeAction` (`lib/widgets/swipe_actions.dart`) is the
shared shape, so the two lists that have it cannot drift:

* **Chats** — swipe RIGHT toggles read/unread, swipe LEFT archives.
* **Archive** — swipe RIGHT unarchives, swipe LEFT toggles read/unread. That
  closes a real gap rather than adding symmetry for its own sake: a chat
  could be archived with a swipe and only UNarchived through a long-press
  menu, so the gesture that put it there could not take it back.

**`dismisses` is the whole design, and it is about what the action DOES, not
how far the finger went.** An action that takes the row out of the list it is
in — archiving from the inbox, unarchiving from the archive — lets the row fly
away, because the row really is leaving. An action that changes something
ABOUT the row — read, unread — acts and SNAPS BACK, because the chat is still
in the list and animating it off screen would say otherwise.

**The two thresholds differ on purpose** and a test pins the ORDER rather than
the numbers: `actThreshold` 0.28 against `dismissThreshold` 0.45. Snapping
back costs a mistaken swipe one tap to undo; letting a row fly out of a list
on a half-gesture is the thing people complain about. So the reversible side
is easy to reach and the destructive one has to be meant.

Built on `Dismissible` rather than a package, because the two behaviours
needed are exactly `confirmDismiss` returning true or false — the trick
`chat_screen.dart`'s swipe-to-reply already uses ("snap back; we only use the
swipe to trigger reply"). A second gesture library beside the one already in
use is how two swipes in one app end up feeling different. The action fires in
`confirmDismiss`, not `onDismissed`, so a snap-back action happens at all —
and the haptic lands there too, so both kinds are felt.

Both sides carry an **icon AND a label**, glyph nearest the edge the finger
came from; a bare glyph mid-gesture asks somebody to recognise it in the
half-second they can see it. The read/unread action reads the ROW's own state,
so the side does not have a fixed meaning — a read chat's right swipe offers
"Unread". With BOTH actions null the row is returned untouched rather than
wrapped in a Dismissible that can only refuse, since a gesture that starts and
goes nowhere is worse than no gesture.

**Deliberately not touched: the message swipe inside a chat.** Swipe-right-to-
reply is the platform norm and has no established left-hand twin; adding one
would be inventing a gesture rather than matching one.

## Forms can ask for a signature and for money (2026-08-14)

Two new `FormFieldKind`s. Both round-trip by NAME and are additive on the
wire, so an older build reading a newer form falls through to a plain text
question rather than the wrong one.

### Signature

`FormFieldKind.signature`, `SignatureInk` (`lib/models/signature_ink.dart`,
pure) + `SignaturePad`/`SignaturePainter` (`lib/widgets/signature_pad.dart`).

**It is a drawn MARK, not a cryptographic signature**, and that sentence — "A
drawn mark, not proof of who drew it." — is printed under the pad to the
signer, again under the rendered mark to whoever reads the answer back, and a
third time in the BUILDER to the person asking for one (a form author who
thinks this is binding is who that one is for). A test pins it. This app has
real signatures — every server broadcast is signed with a per-sender key whose
private half never leaves the device — and conflating the two would be the
most misleading sentence in the product.

**Stored as STROKES, not an image**, for three reasons that all bite here: a
form answer is a `String` in a list riding the ordinary encrypted message
path, so it has to be small; strokes redraw crisply at any size, which a
thumbnail PNG does not; and normalised 0..1 points mean the signature drawn on
a 6.9" phone is the same signature on a 4.7" one rather than a differently
cropped picture. Encoded `x,y x,y;x,y x,y` — chosen over JSON because this
string is one entry in a list that is itself already JSON, and nesting encodes
every quote twice. `decode` never throws: it parses a string that arrived from
another device, so anything malformed comes back as an empty signature.
Off-box points are CLAMPED rather than dropped — a finger running off the edge
is ordinary, and dropping it would put a gap in the middle of somebody's name.
`maxPoints` (600) stops RECORDING rather than refusing the answer, so the tail
of a scribble degrades instead of the signature becoming ungiveable.

**A `Listener`, not a `GestureDetector`** — a pad sits inside a scrolling
form, and a pan recogniser spends the first points of every stroke in the
gesture arena arguing with the scroll view, which reads as strokes that start
late. Same reasoning the chat transcript's tap-off-to-dismiss already follows.

**A real bug a test caught:** the Listener defaulted to `deferToChild`, and
the pad's box is a `Container` with a DECORATION — a `DecoratedBox` does not
hit test itself. With an empty pad the only hittable child was the small
centred "Sign here" label, so most of the box was dead. It would have been
just as dead on a phone. `HitTestBehavior.opaque` fixes it.

### Payment

`FormFieldKind.payment` + `FormFieldSpec.amountCents`. A question that names
an amount and pays it to whoever SENT the form.

**Nothing about payments is reimplemented.** `payFormRequest` (beside
`offerTipTo` in `spark_sheet.dart`) runs every guard `offerTipTo` runs, in the
same order and for the same reasons — device can send, ID verified, and above
all `showCannotReceiveSheet`, the check almost every real transfer dies on.
What it does NOT do is ask for an amount: a form's payment question names one,
and letting the payer change it would answer a different question from the one
asked. It confirms in full first (who, how much, what for) because a form is
filled in quickly and money must never leave on a mis-tap.

**The answer is recorded from the TRANSFER, not the tap** — `payFormRequest`
returns true only when money actually moved, so a declined card or an
un-onboarded recipient leaves the question unanswered rather than marked paid.
Mark it required and the form cannot be sent back unpaid. Once paid it becomes
a plain line: there is no "unpay", because the money is gone and a control
offering to take it back would describe something the app cannot do.

`amountCents == 0` makes the question **unusable** — refused at build time
exactly like a choice with one option, since finding out at the far end is too
late. `FormFillScreen.payTo`/`payToName` come from the chat: in a group the
member who SENT it, like the answers themselves, and empty for your own copy —
where the question says the money can be sent from the chat rather than
drawing a dead button.

## The form builder folds, and grew real options (2026-08-14)

"Make each question in forms foldable, improve the UI, add more options and
settings." Three asks on `FormBuilderScreen`, plus the model and fill-screen
work the last two needed.

### Each question folds

`_FieldEditor` is a card with a tappable HEADER that stays put whether the
card is open or shut, so the number, the summary and the chevron are in the
same place either way and tapping twice returns you exactly where you were.
Folded, a question is one row: a numbered badge, its label (or an italic
"Untitled question"), and a summary line — kind · Required · N choices ·
range · Conditional. Not every field, because a folded row that lists
everything is not folded.

**A question that cannot be ANSWERED says so while folded** — an error ring on
the card and a tooltipped icon in the header. Otherwise the Save button is
disabled and the reason is inside a card that looks fine from the outside.

**Open by default depends on which form it is.** A NEW form opens with its one
blank question expanded: nothing to survey, everything to fill in. An EXISTING
one opens fully folded: coming back to a finished form, the shape is what you
want, and the question you came to change is one tap away rather than buried
under nine open cards. A question you ADD opens (it is about to be typed
into) and nothing else is folded shut to make room — closing somebody's other
work to serve a tidy default is a worse surprise than one extra open card.

`_open` is keyed by the STABLE question id, not the index, so folding survives
a reorder the way the editor's typed text already does; an index-keyed set
would silently transfer "open" to whichever question moved into the slot.
**`_useTemplate` rebuilds it** rather than leaving it — it replaces every id,
so every entry in the old set pointed at a question that no longer existed,
which folded the whole template shut. A test caught exactly that.

### The UI

The title is set as a HEADING (21pt, no box) rather than another boxed field —
a form's name is not another question to answer. Cards are on `AppRadius.md`,
the add button is a `FilledButton.tonalIcon`, and a header row above the
questions carries the count plus **Expand all / Collapse all** — both only
once there is more than one question, since a tally reading "1 question" and
a collapse control over a single card are chrome describing nothing.

### More options

Per question, all additive on the wire (`toJson` writes them only when set, so
a form built before these existed encodes byte-for-byte as it did):

* **Example answer** (`placeholder`) — greyed out inside the box until they
  type. Offered only on kinds that are typed into (`takesPlaceholder`); a
  placeholder on a row of chips or a star rating has nowhere to go, and a
  field that does nothing is worse than no field.
* **Least / Most** (`min`/`max`, `takesRange`, number only) — enforced in
  `FormResponse.formatProblem`, the ONE funnel the fill screen's live error
  and the send button's `isComplete` both already read, so the rule lands in
  both places without either growing a copy. The answer is still never parsed
  for STORAGE (a leading zero survives); it is parsed only to compare, and a
  value that will not parse is left alone — the keyboard is numeric and "that
  is not a number" is not a sentence worth showing somebody looking at what
  they typed. `rangeLabel` puts it under the box as a helper BEFORE the answer
  is wrong, and steps aside while there is a real error so the field never
  shows both.

**A bug the test caught, worth naming:** `copyWith(clearRange: true)` first
read `min: clearRange ? null : …`, which made the flag override the values
passed WITH it — so the builder's own range fields, which pass
`clearRange: true, min: x, max: y` to set one end and clear the other, could
never set anything. It now means "replace the range with EXACTLY what is
passed". Null is a real value for a range end, which is why it cannot double
as `copyWith`'s usual leave-alone.

### Form settings, and the one that is real

A folded **Form settings** card above the questions, closed by default (most
forms want none of it) and naming what is ON in its subtitle — a settings
block that hides whether anything inside it is set is a place people have to
open to find out, every time.

**Anonymous answers** (`Message.formAnonymous`) is the setting, and it is the
"Anonymous Feedback" item from the owner's own earlier three-part list (the
one "Decision Voting" came from). The RESPONDER's app is what honours it: it
puts neither a name nor a number in the response payload, and the author's app
shows "Anonymous". That makes it the same KIND of promise as
`Chat.protectContent` — a request the other app honours, not a guarantee about
their device — and the switch says so in three clauses that may not be
trimmed:

1. **Sealed sender is what makes it real** between up-to-date builds, because
   the envelope carrying the response names nobody either. Against a legacy
   peer the delivery still identifies them, and the copy says that.
2. **It means nothing in a 1:1** — there are only two of you.
3. **Nobody can change an answer they already sent.** With no name there is
   nothing to correct by; the alternative is keeping an identity on device to
   correct against, which is the thing the toggle says is not kept.

That third one is a REAL code consequence, not just copy:
`ChatStore.applyFormResponse` dedupes on `response.from`, so with every
response carrying `''` the second answer would have overwritten the first and
a form of forty people would have held one. It now skips the dedupe entirely
when `from` is empty — an unnamed response is always an addition.

The flag rides `Message` (field, ctor, toJson/fromJson, copyWith), the relay's
`encode` and `applyIncoming`, and `SavedForms` (a saved form that lost its
settings would go out named the next time it was used). The builder hands back
a **named** record field — `(title, fields, (anonymous: …))` — so a setting
added later reads as `$3.something` at the call site rather than an unlabelled
`$4`.

## Forms have a home, and the drawer shows five apps (2026-08-14, the owner's calls)

Two asks in one breath: put Forms in the sidebar so somebody can edit and
create them, and cap the Apps list at five with the rest folded under
"Other".

### Saved forms

A form used to exist only as a MESSAGE. `FormBuilderScreen` opened blank from
a chat's attachment panel, the questions went out, and nobody saw them again —
so anybody running the same RSVP every month rebuilt it every month, and
nothing in the app could edit a form at all.

`SavedForms` (`lib/state/saved_forms.dart`) holds `SavedForm` (id, title,
fields, updatedAt), newest first, capped at `maxForms` (50, with the OLDEST
dropped so the cap never eats what is in use). `save()` takes an optional
`id`: same id EDITS, no id creates — one method, because a Forms screen whose
whole reason to exist is that a form can be changed must not have a second
copy appear every time. `remove()` RETURNS the removed form so the screen can
offer an undo rather than a confirm dialog: this is the person's own work,
expensive to retype and cheap to put back. `save()` takes a `now` rather than
reading the clock, like every other store here — a test that has to sleep to
get two timestamps is a test that sleeps.

**On the device and nowhere else**, and a test bans `supabase`/`http`/
`relay_service`/`cloud_sync` from the file. `form_spec.dart`'s own rule is
that a form posting to a table would be the one feature in this app
collecting people's answers in the clear; the QUESTIONS are not the answers,
but "what this person keeps asking people" is its own statement about them,
and nothing a server could do with it the device cannot do alone.
**Account-scoped**, wired into `account_wipe.dart` and `main.dart` like
`ChatFolders` — and `reset()` drops the cached `SharedPreferences` HANDLE as
well as the list, which `ChatFolders.resetForTest` already does and which is
exactly what stops the next `load()` reading the previous account's blob back
in (two tests caught this in the same run).

**One editor, two words.** `FormBuilderScreen` gained `initialTitle` /
`initialFields` / `title` / `submitLabel` and is otherwise untouched: a chat
opens it saying **Send**, `FormsScreen` opens it saying **Save**, and the
builder never learns which — the caller decides what the returned `(title,
fields)` means. A second, thinner editor would have drifted from this one the
first time either changed, the same argument the thread screen made for
reusing `ChatScreen`. Its privacy line was reworded ("the chat you send this
from") because the old one named "this chat" and would be wrong on the Forms
screen.

**`FormsScreen` does not SEND**, deliberately. Sending needs a conversation,
and picking one here would be a second, worse chat picker beside the one
every share already uses. Instead the chat's attachment panel offers the
saved forms at the moment somebody is actually in a chat — a sheet listing
"New form" plus each saved one, shown ONLY when something is saved (a picker
offering one option is a tap nobody needed, so with none saved the panel goes
straight to a blank builder exactly as it always did). A picked form opens IN
the builder rather than sending on the tap: "the usual questions, plus one for
this week" is what reaching for a saved form usually means, and editing there
changes what is SENT, never the saved copy.

### Five apps, then "Other"

`SidebarPrefs.shownApps` = 5, with `topApps`/`moreApps` splitting `visible`.
Ten rows plus a header, Store, Settings and Sign out was a wall of type to
read rather than a list to scan.

It is a **CUT of the user's own order, not a fixed list**: the first five of
whatever they arranged show, everything after folds. So the way to promote a
row is the reorder screen that already exists, and nothing is unreachable —
the difference between folding a list and hiding half of it. The fold is a
plain `ExpansionTile`, closed by default and NOT remembered open, because the
point of the cut is that the drawer opens short EVERY time; it renders only
when `moreApps` is non-empty, since an "Other" that opens onto nothing is
worse than no fold.

**The default order became a PRIORITY, so it was reordered.** Before this all
ten drew and the sequence was just a sequence; now the first five are what
somebody sees, and leaving Weather and Sports on top while Servers and the
Wallet sat below the fold would have been a bad default rather than a neutral
one. Servers · Marketplace · Forms · Wallet · Forum lead — the destinations
with their own content and their own reasons to come back — and Maps ·
Weather · Sports · Okay Drop · History fold, the look-something-up half.
Existing users are untouched: `load()` returns early when nothing was ever
saved, and a stored order keeps its own sequence with `forms` appended at the
end like any new row.

The customize screen's own blurb now NAMES the cut ("The first 5 show in the
sidebar; the rest fold under Other"), because reordering silently deciding
which five are visible would read as a row that had vanished.

Three existing tests failed on this and all three were updated rather than
loosened — the weather/sports order test now asserts they are in the folded
half and says why, the sidebar-shortcuts test opens "Other" to find Maps, and
the every-destination-lays-out-at-320pt loop opens "Other" when a row is not
on top, so both halves are still covered.

## The feed action row is LIKE · COMMENT · REPOST (2026-08-14, the owner's call)

A correction to the order the three were first gathered in the same day, not
a new decision about where they sit — small, at the bottom left, share alone
on the right, all unchanged. Only the sequence moved: it was comment ·
repost · like and is now **like · comment · repost**.

Like leads because it is the one people reach for most and the cheapest to
give, so it is the one nearest the thumb; comment then repost is the rest in
ascending order of how much of their own name the reader is putting to it.
**Do not sort these back into the reply-first order most timelines use** —
that is the shape this deliberately is not.

Both feeds draw the one `FeedPostActions`, so this is one edit and one
measurement. Two tests pin the order by POSITION rather than by reading the
source: the layout test asserts `like.left < reply.left < repost.left` (and
that they are still gathered — `repost.right` inside the left half, the span
under 150pt, share past `repost.right + 100`), and the shared-strip test
asserts the same three centres in order. The tap-by-icon assertions in both
were already order-agnostic and needed nothing.

## The subject line is the composer's first line, not a strip above it (2026-08-14)

"Fix the subject line so it blends in even more." It was laid out as a
SIBLING above `_buildComposer`'s rounded card, which put it on the input
BAR's background rather than the card's — so it drew as a full-width flat
strip with its own visible edge, and read as a second control to fill in
before you got to the message. Its own doc comment had claimed it "reads as
the top half of one control"; on a real phone it did not, because it was
never in the same box.

It is now the card's first child, inside the `LiquidGlass`: same material,
same rounding, same left inset as the message under it (its padding is
right-only, so the card's own inset is what lines the two up), `filled:false`
for the reason the message field already sets it — the app-wide theme fills
every field, and a filled box inside this card is exactly the separate strip
this moved away from — and a 0.6pt hairline at 10% between them rather than a
border. A subject is part of the message; anything that draws a container
around it makes it a second thing. A test pins that the subject and the
message share a `LiquidGlass` ancestor and that the subject sits above the
message inside it — tree position, not just "both exist".

## The wallpaper picker gave no visible feedback, for the third time in the same way (2026-08-14)

Reported as "I change the wallpaper, it changes, but I have no visual
feedback of it being changed — it still shows the black is the wallpaper when
it's not". Two separate faults behind one sentence, and the first is the
**third instance of the rule in "A bubble's contents take the BUBBLE's
colours (2026-08-09)"**, whose own note ended "worth periodically
re-auditing for a third instance". This is it, and unlike the first two
(`VoiceNoteBubble`'s control, `_ReplyQuote`'s text) nobody was looking for it.

1. **Both selection marks were drawn in `AppColors.accentOn(context)`** — a
   colour chosen against the app BACKGROUND, i.e. near-white in dark mode.
   Six of the twelve wallpapers on offer are pale, so in dark mode picking
   one drew a white tick on a cream tile, and a white 3-point border *inside*
   that same cream tile (`Border.all` paints within a box's own bounds, so
   the "selection border" was landing on the wallpaper it was meant to be
   marking). The store was correct the whole time — a probe confirmed the tap
   persists and the check widget is built — the picker just never LOOKED like
   anything had happened.

   Fixed the way the rule says: the tick takes `onSwatch`, computed from that
   tile's own luminance (`computeLuminance() > 0.5`, the same test
   `MessageBubble` uses for a custom bubble colour) and sits in a filled disc
   of the swatch's opposite so it reads at a glance; the selection RING moved
   OUTSIDE the tile onto the page background, where the app accent is the
   right colour by definition; and the resting hairline is the tile's own
   contrast at 18% instead of a fixed `Colors.black12`, which gave the dark
   swatches no edge at all in dark mode.

2. **"Default" on a PER-CHAT screen does not mean the theme background** — it
   means "follow the app-wide wallpaper" (`chat_screen.dart`:
   `wallpaperFor(chatId) ?? globalWallpaper`). The tile painted
   `scaffoldBackgroundColor` regardless, so somebody who had already set a
   wallpaper app-wide was shown a black tile claiming to be their default.
   That is the literal "still shows the black is the wallpaper when it's not".
   `_Swatch.defaultFill` now carries the global colour on a per-chat screen,
   and the grid's builder listens to `Listenable.merge([AppState.chatWallpaper,
   ChatStore.instance])` rather than one or the other, because the tile now
   depends on both.

Also **said in words under the grid**, since a tick on a tile is easy to miss
even when it is visible: "Following the app-wide wallpaper." / "Wallpaper set
for this chat only." / "Wallpaper set. Every chat without its own follows
this." Two tests pin it — the pale-tile-in-dark-mode mark is asserted to have
luminance below 0.5 (the exact case that was invisible), and the per-chat
Default tile is asserted to paint the global colour.

## The moderation audit trail is append-only and tamper-evident (2026-08-14)

From a pasted enterprise security bullet list ("SOC 2 Type II · SSO/SCIM ·
AES-256 · immutable audit logs · 99.9% SLA · pen tests · GDPR/CCPA ready"),
scoped at the owner's direction to "build some of these". **Only one line on
it was real engineering this codebase could do**, and it is this one. The
rest is written down at the bottom of this section rather than left as an
implied to-do, because the honest answer to most of that list is "already
true", "not the app's layer", or "not a thing code can produce" — and a slide
claiming otherwise is the failure mode.

`moderation_log` has recorded every sanction, takedown and role change since
the console existed (`moderation-act` and `roles-set` both insert into it),
with RLS on and **no policies at all**, so no client ever reached it. What it
had no defence against was the only party that CAN reach it: whoever holds
the service-role key. A log the operator can quietly rewrite says whatever
the operator needs it to have said — and that is the entire threat model an
audit trail exists for. Nobody keeps one to defend against a stranger who
cannot see the table.

`docs/audit_log_immutable.sql` does two separate things, and the difference
is the whole design:

- **Prevention is a TRIGGER, not a revoke.** `BEFORE UPDATE` and
  `BEFORE DELETE` triggers raise. That was chosen over the obvious
  alternatives because neither binds the party in question: a GRANT does not
  bind a table's OWNER, and RLS does not bind BYPASSRLS. A trigger binds
  every role there is, service role included.
- **Detection is a HASH CHAIN**, and it is what makes the word "immutable"
  *checkable* rather than merely asserted. Each row carries `prev_hash` +
  `row_hash` (SHA-256 over id, created_at, actor, role, target, action,
  reason, until, plus the previous row's hash), so editing or removing any
  row breaks every hash after it. `moderation_log_verify()` walks the chain
  and returns the **first** entry that stops adding up — first, not all,
  because one altered row breaks two hundred hashes and a list of two hundred
  failures buries the one that matters.

Mechanics worth not rediscovering:

- **The hash is computed by the INSERT trigger, never accepted from the
  writer.** A hash the inserter supplies is a hash the inserter forges, which
  would make the chain decorative. `moderation-act` and `roles-set` insert
  exactly as they always did, naming neither column — nothing about the
  Edge Functions' write path changed.
- **`sha256()` is a Postgres BUILT-IN** (core since PG 11), so this needs no
  `pgcrypto` and no extension anywhere.
- **`pg_advisory_xact_lock` serialises appends.** Two moderators acting in
  the same instant would otherwise both read the same tail and both claim it
  as their predecessor — a forked chain, which reads exactly like tampering.
  Moderation is a handful of actions a day; the lock costs nothing.
- **Timestamps hash at a fixed UTC offset** (`to_char(… at time zone 'UTC',
  …)`), or the same instant would hash differently depending on the session's
  `TimeZone`, and the verifier would report tampering that never happened.
- **The verifier is NOT `SECURITY DEFINER`**, deliberately. It reads a table
  under RLS with no policies, so an invoker function returns nothing to a
  client even if the EXECUTE grant were reachable. A definer here would build
  a door into the log that exists only because the verifier needed one.
- **PUBLIC is revoked as well as `anon`/`authenticated`.** Postgres grants
  EXECUTE on a new function to PUBLIC itself, and Supabase's default
  privileges grant it to `anon` explicitly — revoking one leaves the other
  standing. This is the mirror of the `find_people_by_hashes` bug in
  "The directory stops handing out phone numbers", where revoking PUBLIC left
  the explicit anon grant. Both ends, or neither works.
- **The backfill hashes pre-existing entries** and says plainly what that
  buys: hashing an existing row proves nothing about whether it was ALREADY
  altered — a chain can only vouch for what happens after it is laid down.
  What it buys is that the old entries cannot be quietly changed from here on
  and that the chain is continuous rather than starting mid-log.

**Detection needs somebody to look, so the console looks.** The
`moderation-queue` function gains `what: "verify"` (asked there rather than
from the app because the RPC is reachable only by the service role — a client
that could run it would be a client that could read the log), and the
console's **History** tab runs it on every load and draws the answer above
the trail. `AuditChainStatus` / `PlatformModeration.verifyAuditLog()`.

**Three answers, and the third is the one that matters.** Verified, broken,
and **could not be checked** — a project that has not run the migration, or
whose deployed `moderation-queue` predates the `verify` action, has no
verifier, and `checked: false` draws as a grey "Tamper check unavailable"
rather than a tick. A check that could not run is not evidence of anything,
and rendering it as a pass would be the single most misleading thing this
screen could say. The verified banner also carries the entry COUNT, because a
chain over an emptied table verifies perfectly and "verified" alone would be
a tick over nothing. It is drawn in INK, not green — a passing check is the
ordinary state of the screen; the error case is where the loud colour
belongs.

**Honest about the ceiling, rather than letting "immutable" carry more than
it earns:** a superuser can `alter table … disable trigger` or drop it, and
nothing inside a database can stop that short of shipping the rows off it —
what it is instead is a deliberate, visible act that leaves the chain broken
behind it, which is exactly why prevention is paired with detection. It
covers **moderation actions**: it is not an access log and not a data log, so
it does not record who READ a report or opened the console.

`check_sql.sh` applies the migration right after `platform_moderation.sql`
and pins all of it — that an appended entry is hashed and linked, that UPDATE
and DELETE are both refused **as the table owner with no `set role` at all**
(proving it against a client role would prove nothing about the only party
that can reach the table), that an untouched chain verifies over a known
count, that an edit staged behind a disabled trigger is DETECTED and the
entry NAMED, and that no client role holds a privilege on either the table or
the verifier. The tamper assertion is deliberately last: it leaves the chain
broken behind it.

**RUN + verified live 2026-08-15** — applied with the owner's own token, then
read back rather than assumed. Installed: `moderation_log_hash`,
`moderation_log_append`, `moderation_log_immutable`, `moderation_log_verify`,
the `prev_hash`/`row_hash` columns, and all three triggers
(`moderation_log_append`, `moderation_log_no_update`, `moderation_log_no_delete`).
The behaviour was probed inside a `do $$ … $$` block that raises at the end so
it rolls back: an appended row came out with BOTH hashes stamped, and the
UPDATE and the DELETE against it were each refused. The rollback held — the
probe row is gone and the table still holds its 2 real entries, **0 of them
unhashed** (the guarded backfill hashed the rows that predated the migration),
and `moderation_log_verify()` answers `{ok: true, entries: 2, broken_id: null}`.
`moderation-queue` **DEPLOYED** with the `verify` action (v20 → **v21**,
ACTIVE, content hash moved) from the freshly generated paste copy, with
`verify_jwt` read first and carried through as **true** — the console reaches
it with a session, and letting the deploy default it would not have broken
anything here, but reading it first is the discipline that keeps the six
JWT-off functions safe on every redeploy. The console's tamper check is live;
do not re-raise either as pending.

**What was NOT built off that list, and why — so none of it becomes a slide
claim by default.** Verified by grep rather than memory before writing this:

- **AES-256 · TLS 1.3** — already true, and stronger than the bullet says.
  `lib/crypto/e2e.dart` is AES-256-GCM; TLS is Supabase's transport, not the
  app's layer, so the app can neither claim nor configure a version.
- **RBAC** — already true: `platform_roles` (owner/admin/moderator/member),
  re-checked server-side in every Edge Function, plus per-server custom roles.
- **SSO (SAML/OIDC) · SCIM provisioning** — zero occurrences in the codebase
  and architecturally out of reach: identity here is a phone number (or an
  account code), there is no tenant, no directory to sync from, and no
  organisation object for a seat to belong to. This is not a feature gap, it
  is a different product.
- **SOC 2 Type II · ISO 27001 · annual pen tests · quarterly vuln scans ·
  99.9% uptime SLA · 24-hr incident notification · GDPR/CCPA "ready"** — none
  of these is code. They are audits, contracts, retainers and processes, and
  the only thing an engineer can do toward them is not claim them.

The actual security story is both stronger and more distinctive than that
list: **we cannot read your messages** — E2E by default, Signal Double
Ratchet pairwise, sender keys for group broadcast, sealed sender, and no
message tables on the server at all. Every word of that is true and testable,
and almost none of the competition can say it.

## The profile counts are a card now — fourth pass, and the first structural one (2026-08-14)

"Improve the user profile still looks the same", after "Redesign the user
profile, it's to compact" and, before that, "too compact". Three passes had
answered it with spacing — 14 → 17 → 24 between blocks, bigger type, taller
buttons — and got the same sentence back each time. That is the signal worth
recording: **when more air keeps reading as the same screen, air was never
what was missing.**

What was actually wrong is that the profile had no solid element anywhere on
it. Name, handle, bio, a metadata row, four counts and the Okay Score were
all the same weight of small text down one left margin, so the counts —
"12 Following  4 Followers  1 Post  2 Servers" as loose number-beside-label
phrases in a `Wrap` — read as four more lines of that column rather than as
the profile's numbers. Spacing them further apart made the column longer, not
more structured.

**`_NumbersCard`** (`public_feed_screen.dart`) is the change: one tinted
surface holding the counts as **equal columns**, each number stacked over
what it counts, hairlines between them, and the **Okay Score inside the same
card** under a rule instead of adrift 24 points below it.

- **Equal columns, not a `Wrap`, and this is the load-bearing part.** A
  `Wrap` let every stat size itself, so the gaps moved with the numbers in
  them and four counts could tip onto a second line the moment anything got
  wider — `type_metrics_test.dart` caught exactly that twice, which is why
  the last two passes were forbidden from touching WIDTH at all. Columns
  cannot reflow, so the stacked form (number over label) is safe here and was
  not safe loose: `ProfileStat.stacked` exists only because the caller hands
  each one an equal column rather than letting it size itself. The old inline
  form is still the default and every other call site is untouched.
- **A FILL, not an outline.** `_ScoreRow`'s own note records why it lost its
  box: an outlined full-width rectangle in the middle of a profile reads as a
  text field waiting to be filled in. That still holds — the card is a tinted
  surface with no border, and the score is a ROW of it rather than a box of
  its own.
- **A `Material`, not a `Container`.** Everything in the card is tappable and
  ink draws on the nearest Material, so a coloured `DecoratedBox` over the
  scaffold would have swallowed every splash in it — the counts and the score
  row would have gone dead-looking on tap while still working.
- **It costs 2 points of height.** The score row's own 24-point gap pays for
  the card's padding, and the stacked stat's vertical padding drops 9 → 6
  because the label now has a line of its own. 540 → 542 against a 562
  ceiling.

`type_metrics_test.dart`'s width warning was rewritten rather than deleted:
the reflow trap it describes is genuinely closed now (columns cannot reflow),
but the ceiling still stands, because a taller card eats the fold just as
surely as a second line did. A new widget test pins the three structural
facts — the four columns are the same width whatever the numbers say, the
count sits above its label, and the score's innermost `Material` ancestor is
the same widget as the counts' — and the existing header test's left-margin
assertion moved from the score ROW (now indented by the card's padding) to
the CARD, plus a check that the row really is inside it.

**`.first`, not `.last`, when reaching for a card by Material ancestor** — a
mistake made twice while writing those two tests. The outermost Material
ancestor of anything on a screen is the Scaffold's own, which starts at the
screen edge, so `.last` passed a left-margin assertion for nothing.

## Profile, fifth pass: no band, marks beside the check, counts as glyphs (2026-08-15)

Five owner instructions in one message, all on the profile.

**The band is gone, and this is the second time it has been removed.** The
history matters because the two removals were for the same reason and the
round in between got it wrong: a GENERATED gradient mixed from the handle was
taken out on 2026-08-09 for being the loudest thing on screen and the only
saturated block in a black-and-white app; a SUBDUED band came back on
2026-08-14 on the theory that the objection had been to the COLOUR — the page's
own surface tint by default, somebody's own two colours only if they picked
some. It was not the colour. A shelf of nothing across the top of every profile
is still a shelf. **Do not put a third one back.** The avatar's ring went with
it (it existed to separate the face from a coloured band; on the page it is
scaffold colour on scaffold colour), and the header is now a plain row — face
left, actions right.

That left `AppUser.bannerColor` drawn by nothing, so Edit profile's **PROFILE
BANNER** picker went too: a colour picker whose colour nothing renders is the
"unenforceable control is worse than none" rule this file already applies to
Wi-Fi-only backup. The FIELD stays on the model and still rides the profile
share — an older build that draws a band should keep what somebody chose — and
a test walks `lib/screens/` asserting no screen but the editor reads it.

**Phone / email / ID moved from three chips to three glyphs beside the blue
check.** They were pill badges on a line of their own under the bio, each
spending a whole word on "verified" — a feature list stapled to a screen that
is about a person. `ProfileTrust` is now the icon cluster inside the name row.
The word is not lost: each glyph is a `Tooltip`, which is also its semantics
label, so a screen reader still says "Phone verified". The ID glyph does sit
beside a check that also means identity-verified, and that overlap is
deliberate — the check comes from the POST's `authorVerified` and the glyph
from a contact's own record, so they are not one fact from one place, and the
owner asked for all three.

**The counts are glyphs too** — `ProfileStat.icon`, with `label` still
REQUIRED because it becomes the tooltip. Posts and Servers reuse the exact
glyphs `ProfileTab` already gives them, so one idea does not get two symbols on
one screen. An icon alone IS less legible than the word for somebody meeting it
cold; the tooltip is what pays that back, and every test that used to find a
stat by its text now finds it by its tooltip — which is a better pin, since a
stat with no tooltip is a number beside an unexplained icon.

**"Add bio", and the placeholder that was hiding the gap.** Your own profile
with no bio showed nothing at all, so the one field that says who you are was
invisible unless you already knew Edit profile had it. Writing the prompt
surfaced the real reason it had never been noticed: **`AppUser.about` defaults
to "Hey there! I am using OkayMessenger."** — so every fresh account already
appeared to have a bio. That default is a sentence the APP wrote, not a fact
about the person, and `marketplace_screen.dart` had already decided so with the
literal inline. It is `AppUser.defaultAbout` now, both callers read it, and the
profile treats it as no bio: your own shows **Add bio** (→ Edit profile), a
stranger's shows nothing, because a placeholder is not a fact about them and
"Add bio" on somebody else's profile is an instruction they cannot follow.

Two guards had to be rewritten rather than deleted, and both kept their teeth.
`type_metrics_test.dart` measured the face against the band it overhung; with
no band it measures a whole face at the page margin with the name starting
under it, and its note records that the header just got 58 points back — slack
for the next round of type, not licence to stop measuring. The
band's own test kept its original 2026-08-09 job: it pins that nothing
full-width paints a gradient behind the header, measured by WIDTH so a person's
gradient avatar stays legal.

## Two marketplace bugs: deletes reached nobody, reviews reached nothing (2026-08-15)

Reported together: "when user leaves review on marketplace it only reflects
on their app, it doesn't show for other users" and "deleted posts still show
for other users — on marketplace."

**Probed before diagnosing, which is the rule this file keeps re-learning.**
With the publishable key: `market_listings_view` answers **2 rows**,
`market_reviews_view` answers **0**. So listings publish and reviews never
have. And this is NOT a stale build: both listings were written 2026-08-14,
and the upsert fix (`06b435e`) that made publishing possible at all has the
review commit (`40972cb`) as an ancestor — a build that can publish a listing
necessarily contains the review code. Do not blame the build again without
that check; it was wrong once already.

**The delete bug is proven and fixed.** Deleting a listing removes its row
and broadcasts `fdel` — but `fdel` rides the community bus, and a global
listing's `communityId` is `''`, so it reaches nobody. Meanwhile
`fetchMarketListings` only ever ADDED. Every other device that had once seen
the listing kept it forever, which is exactly the report. Convergence has to
come from the FETCH, because the fetch is the only thing the two devices
share: `_pruneDeletedMarket` drops local copies of global rows the server no
longer has, with two load-bearing guards.

* **Only when the whole table was seen.** The fetch is paged (300 listings,
  500 reviews). A row beyond the last page is absent while perfectly alive,
  and pruning then would delete real listings for anyone whose marketplace is
  bigger than one page — far worse than the bug being fixed. A short page
  means the whole table fitted, which is the only case where absent means
  gone.
* **Never your own.** A listing of yours missing from the table is the
  stranding `_backfillOwnListings` repairs, not a deletion. Somebody else's
  global row can only have reached this device through this table, so its
  absence really is a delete. A listing sealed to a real server
  (`communityId` non-empty) is skipped outright — that is the server's copy,
  not this table's.

**The review write is fixed by changing the VERB, and the reasoning matters.**
The refusal that once emptied `market_listings` was `excluded.author_phone`
in an upsert's `DO UPDATE` — a READ of the one column no client may SELECT.
The cure was to stop sending the column and let a server-side DEFAULT fill
it. But that makes every write depend on one `ALTER` having been applied, and
"listings have rows, reviews have none" is exactly the shape of that ALTER
having reached one table and not the other. Unprovable from here without a
token — so the fix removes the dependency instead of guessing: a review is
written with a plain **INSERT naming `author_phone`**. A plain insert
generates no `excluded.` clause, so naming the column is safe, and the row
lands whether or not the default exists. RLS still checks it against the JWT,
so a forged phone is refused exactly as before. Insert is also the honest
verb: `addReview` REPLACES a review by deleting the old row and posting a NEW
id, so a review id is written once and never conflicts; the upsert survives
only as the fallback for the one case that can (the backfill re-publishing a
row that was outside the fetch's page).

The source pin that banned `'author_phone'` in these functions was **narrowed
rather than deleted** — it now scopes to the upsert's own argument. The rule
was never "a client may not name its phone"; it is that an UPSERT may not.
Banning the string outright would have forbidden the fix and kept the bug.

**And the silent swallow is gone.** Every write on this path was a bare
`catch (_)`, which is why three separate rounds of "it only shows on my
phone" — the payment sheet, the listings, now the reviews — were each
debugged by guessing at a failure the device had already seen and thrown
away. `RelayService.lastMarketError` keeps it. If reviews still do not appear
after a build carrying this, that string is the answer and it is worth
reading before theorising again.

## The status line becomes a bio (2026-08-15, the owner's call)

"Remove the available, busy, etc feature. Add a bio."

**This also corrects a misreading earlier the same day.** "Remove the
available features" was taken to mean the three green verification chips;
it meant the Available/Busy feature. The chips moving to glyphs beside the
check was a separate instruction and stands — but the thing actually being
asked for was this.

`AppUser.about` was WhatsApp's **About**: a one-line state of availability
with a scrolling row of one-tap preset chips under the field. That is why
the profile had no bio — the one line that says who somebody is was occupied
by a line about their afternoon. Two things were wrong with it:

* **A status is a thing you have to keep true, and nobody does.** "At the
  gym" outlives the gym by a week, so the field decays into a small lie on a
  profile. A bio is written once and stays true.
* **The app invented one for people.** Every place that built a contact
  seeded `about: 'Available'` — main, session, the relay's incoming-profile
  path, contacts, new chat, People, chat, communities, the mesh — so a person
  who had never written a word appeared to have declared themselves
  available. That is the no-fake-data rule, in the one field that is supposed
  to be somebody's own words. And `applyIncoming` fell back to it when a
  contact had **withheld** their about, which inverts the meaning of
  withholding it. All of them are `''` now, and a test enumerates the files
  so a tenth site cannot reintroduce it.

The field is a **Bio**: three lines and 300 characters instead of two and
139, relabelled in Edit profile, on the contact card and in the
who-can-see-it audience list. The presets are gone.

**The old default stays readable, and that is deliberate.** `AppUser.about`
no longer defaults to "Hey there! I am using OkayMessenger." — a new account
simply has no bio — but every account made before today carries that exact
string, on the wire and on other people's devices. `AppUser.defaultAbout`
was renamed **`legacyAbout`** (it is not a default any more, and a constant
whose name lies is worse than no constant) and the profile and the
marketplace seller card still read it as "no bio", which is what puts **Add
bio** in front of the owner rather than a sentence the app wrote for them.

**Two prose traps, both the demo-seed one again.** The comment explaining
why the presets were removed NAMED the presets, and the test scanning the
file for them failed on the explanation. Reworded — the guard errs safe on
purpose. And two older tests pinned the `'Available'` fallback itself; those
were updated to assert emptiness with the reason recorded, not deleted.

## Watch: Twitch joins YouTube, and a way to open one yourself (2026-08-15)

Asked as "can you build a player that could play livestreams/videos from
twitch, YouTube", after establishing that an AVPlayer-based network-stream
player cannot play what VLC plays.

**Half of it already existed and the reading was worth doing first.** The app
has played YouTube since link previews shipped — `LinkKind.youtube`, a
thumbnail from a keyless published URL, and `VideoEmbed`: a WebView on
YouTube's own `/embed/` page. `youtubeIdOf` already handled `/live/<id>`, so
a YouTube LIVE stream was already playing. What was missing was Twitch, and
any way to open a link that nobody had sent you.

**Both play through the service's OWN embed, and that is not a shortcut.**
YouTube and Twitch each publish a player and each require it; pulling a
playable URL out of either breaks their terms and breaks the app the week
they change it. So the app hosts their player and never touches a stream. A
test bans `usher.ttvnw`, `googlevideo` and `get_video_info` from both files
so a later "improvement" cannot quietly cross that line.

**Twitch's `parent` is the one real cost.** Its embed refuses to play unless
the `parent` parameter matches the origin embedding it — a clickjacking guard
written for websites. A WebView told to `loadRequest` a URL has no origin to
match, so a Twitch embed is loaded as a one-line HTML page whose BASE URL is
the app's own web host (`AppPages.base`), with that same host named as
`parent`. It is a real host the app really serves pages from, not a string
invented to satisfy a check. YouTube needs none of this and keeps the plain,
proven `loadRequest` — the branch is on `parentHost` being non-empty, so the
path that already worked is untouched. With no backend configured the host is
empty and Twitch says it cannot play here, which is the honest failure.

`twitchTargetOf` resolves `channel/<name>`, `video/<id>` and `clip/<slug>`
from twitch.tv, m.twitch.tv and clips.twitch.tv. **The reserved-path list is
the whole care in it**: `twitch.tv/<anything>` is a channel, so without it
`twitch.tv/directory` becomes a player for a streamer who does not exist and
will never load. The result rides in the existing `videoId` field rather than
a new one, so nothing about the wire format or the rebuild sites changed.

**`WatchScreen`** (sidebar row, in the folded half) is the paste entry point:
a link field, a Paste button, and a refusal that names the reason. The
parser is `WatchScreen.previewFor`, static and public, because the parsing is
what decides whether the button does anything and a URL form is the thing
that gets got wrong — the test feeds it `rtsp://`, an `.mkv` and an `.m3u8`
and expects all three refused, which is exactly the conversation that led
here.

Two honest sentences sit on the screen rather than being discovered: what
plays (those two services, other links open as pages), and that watching
connects the device straight to them, so they see the address and what was
watched, and none of it goes through OkayMessenger. That is the opposite of
the app's usual promise and it is the user's to make knowingly.

**Not built, and stated rather than left implied:** arbitrary network
streams. HLS/MP4 via `video_player` would be easy and would still not be
VLC; RTSP/RTMP/MKV need libVLC, which means MobileVLCKit — the largest pod
the project would carry, unverifiable without an Xcode run, and LGPL. Worth
deciding on its own, not smuggled in beside this.

## Watch, round two: recents and full screen (2026-08-15)

"Improve watch even more." Two things were genuinely missing and one
tempting thing was deliberately not built.

**Recents.** `WatchHistory` (`lib/state/watch_history.dart`) — the last 20,
newest first, re-watching MOVES an entry rather than adding a second copy,
with remove-one and a confirmed Clear. Recorded by the PLAYER on open, not
by the screen that launched it, so a recent reopened from the list moves
back to the top by the same path a pasted link takes.

*Recorded on open, and that is the honest moment.* The embed is the
service's own player and reports nothing back, so there is no "watched
enough" signal to wait for; opening it is the only thing this app actually
knows happened.

*On the device, account-scoped, and nothing is fetched to build it.* A list
of what somebody watches is a fair description of them — the same reasoning
that keeps quick replies and saved places off any server and out of the
backup — so it is wired into `account_wipe.dart` and a test bans `supabase`,
`http` and `RelayService` from the file. No title lookup and no thumbnail
either: an entry knows only what the link itself carried, so opening this
screen tells YouTube and Twitch **nothing at all**. A row with no title
shows its URL rather than reaching out for a better one.

**Full screen.** A 16:9 box in a portrait phone is a third of the glass. The
player now has a fullscreen toggle that locks landscape and hides the system
UI, and the chrome is restored in **two** places: the toggle and `dispose`.
That second one is the whole care — an exit path that misses the restore
leaves every OTHER screen in the app sideways with no status bar. Back
LEAVES fullscreen rather than popping the screen out from under a phone
still held sideways (`PopScope`, the same reasoning the call overlay uses),
and landscape is not forced on the way out, so a phone held upright returns
to portrait by itself. A test reads the restore out of `dispose` directly.

**Deliberately NOT built: reading the clipboard on open.** It was the
obvious "improvement" — offer the link already copied — and it is exactly
the behaviour that got other apps written up. iOS surfaces a paste banner
for programmatic reads, and an app whose whole argument is that it does not
help itself to your things should not help itself to your clipboard. The
Paste button is explicit and one tap; that is the right cost.

Also not built, for want of an existing picker rather than on principle:
sending a watched link into a chat. There is no share-to-chat helper in the
app yet, so it would mean building a contact picker — worth its own round.

## The embedded player could never play on a phone — two WebKit defaults (2026-08-15)

Reported as "it doesn't properly play twitch or YouTube, the video player
doesn't display properly". A real bug with a definite cause, not a guess.

`_EmbedView` built a bare `WebViewController()`, which takes WebKit's own
defaults — and on iOS those are **`allowsInlineMediaPlayback` FALSE** and
**`mediaTypesRequiringUserAction` covering audio AND video**. Both off by
default, both invisible, and together they mean an embedded player cannot
draw video into the box it was handed no matter how correct the embed URL
is. YouTube has been reaching for this since link previews shipped; Twitch
inherited it the day it was added.

**`playsinline=1` was already on the YouTube URL, and that is the trap.**
The parameter is the PAGE asking to play in place. `allowsInlineMediaPlayback`
is the WebView granting it. The request means nothing without the
permission, and reading the URL makes it look handled — which is presumably
why it survived this long.

The fix is `WebViewController.fromPlatformCreationParams` with
`WebKitWebViewControllerCreationParams(allowsInlineMediaPlayback: true,
mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{})`, guarded on
`WebViewPlatform.instance is WebKitWebViewPlatform` — those params are
WebKit's, and constructing them on another platform throws, which would take
the player down everywhere instead of fixing it on iPhone. The user-action
set is emptied for the same reason a Twitch channel is asked to autoplay:
somebody who tapped Watch has already made the gesture, and demanding a
second one inside the iframe reads as a dead player.

Pinned by a SOURCE test, because nothing in a widget test builds a real
WKWebView: two invisible defaults are exactly what comes back silently. The
test holds both settings, the platform guard, and — the other half —
`playsinline=1` still being on the URL, since the permission is wasted if
the page stops asking.

**Unverifiable from this box, and honest about what is left.** No Xcode, no
device. If YouTube plays after this and TWITCH still shows a refusal, the
remaining suspect is the `parent` origin: `loadHtmlString(baseUrl:)` gives
WKWebView a document URL, but WebKit has been inconsistent about whether an
iframe's `ancestorOrigins` follows it. The robust fix for that is a real
route on the `pages` Edge Function — the app already serves HTML from its own
host — so the WebView loads a genuine URL on a genuine origin. That is a
deploy, so it is a separate round rather than a second guess stacked on this
one.

## Views on every card, both feeds (2026-08-15)

"Show the views for posts on both newsfeed like x does."

**The counting was already built on both sides; the DRAWING was the gap.**
`PublicPost.viewCount` comes off the feed view's `view_count` column (kept in
step by the dedupe in `docs/public_feed.sql`, so it moves on a genuinely new
viewer and not on a re-open) and `FeedPost.views` has existed on the server
feed since 2026. But views were rendered only in the opened post's stats
band — `FeedPostActions`, the row under every card in BOTH timelines, had no
views at all. So a number that exists for every post was visible on one
screen out of two.

It is now the fourth item in that row, after Like · Reply · Repost and
before the spark tally and share — X's position, and its reason: the number
that gives the other three their scale reads last, not first. Two likes on a
post nine hundred people saw is a different sentence from two likes on a
post nine saw.

Three decisions worth keeping:

* **A tally, never a button.** X opens post analytics from here. There is no
  such screen in this app, and an author who wants the names already has
  "Viewed by" on their own post. A control that leads nowhere is worse than a
  number that admits it is only a number — the same shape the spark tally
  took when sparking left posts.
* **Zero is not drawn**, like every other count in the row. "0 views" under a
  brand-new post is a fact nobody needs, and it would be under every post at
  the moment somebody first tries the feature.
* **`Icons.bar_chart`, not an eye.** The eye is the seen/ghost glyph this app
  already spends on read receipts, and the same symbol meaning two things on
  one screen is worse than a less obvious one.

A test pins the glyph, the count, the ORDER (like < repost < views), the
absent zero, both call sites feeding their own field, and that the block has
no `onTap`.

## Deleted listings, the OLD half: the durable server fetch never pruned (2026-08-15)

"Fix marketplace, old posts that have been deleted aren't deleted for other
users" — reported after the global prune shipped, and **"old" is the tell.**

The earlier fix covers listings with an EMPTY `communityId` — every listing
made since the marketplace went global. It deliberately skips a listing
sealed to a real server, on the grounds that that is the server's own copy.
But the server's copy converges by exactly ONE route: the live `fdel` event.
A member who was offline when it fired, or whose mailbox had already expired
it, keeps the listing **forever** — because `fetchCommunityPosts`, the only
other path, has always been purely additive. It did not even SELECT the id.

So the same treatment, per community: collect what the durable store still
has, and drop the local copies it does not. Deleting a post already removes
the durable row (`_deleteCommunityPost`), so absence really is a deletion.

**LISTINGS only, and that limit is the point.** `community_posts` is the
durable store for a server's whole feed, and pruning it wholesale would need
certainty that every ordinary post and reply lands there — a far bigger claim
than this bug needs, with a far worse failure if wrong. A listing is always a
top-level post, and no NEW listing is ever sealed to a community any more
(`sendFeedPost` returns early for one), so what this can touch is precisely
the stranded old listings being reported and nothing else. Both of the global
prune's guards come along for the same reasons: a full page cannot tell
"gone" from "on the next page", and your own row missing is a failed write
rather than a deletion.

**Two hypotheses checked and discarded before writing any of it**, recorded
so they are not re-checked:

* *The delete never reaches the server.* `postgrest`'s `delete()` REMOVES the
  `Prefer` header (`..remove('Prefer')`), so it runs `return=minimal` and
  never asks for a `RETURNING` the column grants would refuse. This is NOT
  another instance of the withheld-column trap.
* *The rows are still there.* They are — `market_listings_view` still holds
  the same two rows, unchanged since 2026-08-14 — but both are the owner's
  OWN listings, which the global prune skips by design and which their own
  device removed locally on delete. That is consistent with the bug being the
  community-sealed path, not the global one.
## Deleting a listing asks first (2026-08-16)

Reported as deleting a listing by accident. There were two doors onto the
same irreversible action and only one of them asked: `MyListingsScreen.
_delete` had always run `showAppConfirmDialog`, while the listing DETAIL
screen's own button went straight into `deletePost`.

**The unguarded one was the easier of the two to hit by mistake**, which is
what made this a real report rather than a nitpick: a bare red trash glyph,
no label, sharing a `bottomNavigationBar` row with **Mark as sold** and
**Bump** — both one-tap, both reversible, both about 10 points away. And
there is nothing to undo it with: `deletePost` writes the id into
`FeedStore`'s permanent deleted set, `sendFeedDelete` removes the global
`market_listings` row for everyone else, and the video bytes are gone from
the bucket.

`ListingScreen._confirmDelete` now asks the same question, and **the video
is deleted only AFTER the answer** — the old handler did `deleteVideo` and
`deletePost` in one uninterruptible go. The button also gained a `Tooltip`
('Delete listing'), so the one control on that row with no label at least
has an accessibility name.

**The Manage-listings copy was wrong and was fixed in the same pass**: it
said the listing "disappears for everyone on the server", which stopped
being true when the marketplace moved to its own world-readable table
(2026-08-08) — a listing is global, so it disappears for everyone whether or
not they share a server with you. Both dialogs now say the same accurate
sentence, naming the photos and video too.

The regression test asserts BOTH halves — that the dialog appears and the
listing survives it, and that **Cancel really cancels** (a confirm dialog
whose No still deletes is worse than none). It was confirmed to FAIL against
the old handler before the fix was kept, so it is a real guard rather than a
restatement of the new code.

## Email instead of a number: the gate seam (2026-08-16, step 1 of 2)

Asked for: "allow users to app fully if they verify their email and have no
number." **The premise is unreachable today, and that is the finding worth
recording before the code.** `AccountEmail._requestVerification` bails when
`auth.currentUser == null`, and a numberless account has no Supabase session
at all — so it can only ever reach `savedUnverified`. It cannot verify an
email. The email SIGN-IN paths go further on purpose: `verifyEmailCode` and
`signInWithPassword` both `signOut()` and return null when the user carries
no phone, discarding the half-made session rather than letting it into the
app.

**A session alone would not be enough either.** Counted rather than assumed:
**135 occurrences of `auth.jwt() ->> 'phone'` across 18 migrations**, plus
`_shared/http.ts`'s `callerPhone()`, which returns null for a phone-less
auth user — so every gated Edge Function reads such a caller as anonymous.
Opening the client gates without that claim would give screens that draw and
writes the database refuses with `42501`: the exact shape of the
"Couldn't reach the forum. Try again." lie recorded above.

**The fit that needs no migration.** `AccountCode` is 12 digits prefixed
`00`, a namespace real E.164 never occupies — which is why
`Session.isNumberless` can just ask `AccountCode.isCode(phone)`. So an auth
user whose **`phone` claim is an account code** satisfies all 135 policies
and `callerPhone()` unchanged. The remaining work is a service-role Edge
Function plus client wiring, not a rewrite of every policy.

**What step 1 (this change) actually does.** The three gates —
`PhoneGate`, `postNeedsPhone`, `PhoneOnlyHint` — asked
`Session.isNumberless` directly. They now ask
`AccountVerification.needsServerSession`, which is `isNumberless && !`
[`hasServerSession`], and `hasServerSession` asks the LIVE auth user for a
non-empty phone claim — the literal precondition the server imposes, not a
proxy for it.

Two properties are pinned by tests because they are what make this safe to
ship ahead of the server half:

* **It can only ever OPEN a gate, never close one.** The `isNumberless`
  term stays first and short-circuits, so an account with a real number
  never consults the claim at all and is untouched by every part of this.
* **It fails SAFE.** Reading the claim live (rather than caching a flag)
  means a missing Edge Function, a refused stamp or an expired session all
  land on "no claim", and the gate stays shut. The failure mode is the
  honest padlock, never a screen that opens onto writes that cannot work.
  In a relay-less build and the whole suite there is nothing to ask, so it
  is false and every existing gate behaves exactly as before.

`show Supabase` on the gotrue import is load-bearing: that package exports a
`Session` of its own, and this file's subject is the app's `Session`.

**Step 2, not built yet:** the Edge Function that mints the code and stamps
it. Two things it MUST do, recorded now so they are not rediscovered — the
code has to be derived server-side from the authenticated user id and
**never** taken from the caller, because account codes are PUBLIC (they are
how people address you) and a function that accepted one would hand anyone a
session as any numberless account; and verifying an email has to stop
`NumberlessGrace`, exactly as `attachNumberInPlace` does, or an account with
full access is erased on day 14.

**Honest consequence of the whole feature, stated rather than discovered
later:** it weakens ban enforcement. Bans key on the phone
(`is_phone_banned`), and `banned_emails` is a manually curated staff list
that does not auto-populate from a ban. An email is far cheaper to mint than
a number — which is why `DisposableEmails` exists — so ban evasion gets
materially easier. That is a cost of the ask, not a reason to refuse it.

## Email instead of a number: the Edge Function (2026-08-16, step 2)

`supabase/functions/email-account/` — `POST {what:'claim'}` with an email-OTP
session, answering `{code}`. It stamps an **account code into the auth user's
`phone` field**, which is what turns a do-nothing email session into one all
135 RLS conditions and `callerPhone()` accept. No migration: a code is 12
digits prefixed `00`, a namespace real E.164 never occupies, and the database
only ever compares that field for equality.

**The code is minted HERE and is never taken from the caller** — the security
property the function turns on. Account codes are PUBLIC (a code is how
somebody addresses you, printed in the app for sharing), so a function that
accepted one as a parameter would hand any caller a session as any numberless
account it named. It is derived from the authenticated user's own id
(SHA-256 over `id:salt`, salted so a collision has somewhere to go), checked
free against `listUsers`, and refused after three attempts rather than
looping on the signup path.

**There is no way to bind an EXISTING code, and that was checked rather than
assumed.** The obvious route — prove ownership through the email claim the
account already holds — cannot work: `claim_email` is granted `to
authenticated` and resolves the caller from the JWT phone, so a numberless
account, having no session, can never have claimed an email in the first
place. The binding cannot exist for exactly the accounts that need it. Nor
is there another proof: codes are public, the mailbox is anon-readable by
design, and the directory publishes no key to check a signature against.

**So an existing name-only account gets a DIFFERENT code and its address
changes** — contacts holding the old one learn the new address from the
profile broadcast. Stated rather than hidden, and accepted because it is the
SAME trade-off that already applies when a name-only account verifies a
NUMBER: identity moves off the code, and `Session.attachNumberInPlace` is the
same in-place upgrade, keeping every chat, server and note on the device.

Refusals, each for its own reason: no `Authorization` or a bad token → 401;
anything but `what:'claim'` → 400; an email that is set but **not confirmed**
→ 403 (an unconfirmed address proves nothing, and standing in for a phone
number is the whole job); a banned address → 403, re-checked here because the
client's check is a courtesy and this one is the rule. Already stamped →
returns the same code, so a retry after a dropped reply cannot mint a second.
The `is_email_banned` lookup fails OPEN, matching the app, so a project that
never applied `banned_signups.sql` is not locked out entirely.

`phone_confirm: true` because there is no number to send a code to — what was
verified is the EMAIL, and the field is carrying the account's identity
rather than a claim about a telephone. The caller must refresh its session
for the claim to reach the JWT; nothing server-side can push it a new token.

**Unverified from this box, and it cannot be otherwise** — there is no
service-role key here, `check_functions.sh` type-checks but never runs it,
and the suite cannot stand up Supabase Auth. It needs deploying and a real
device.

**Still owed:** the client wiring (email OTP for a numberless account →
`claim` → refresh → `attachNumberInPlace`), stopping `NumberlessGrace`, and
the ban-evasion migration — `banned_emails` stores the ADDRESS while
`email_claims` stores only a HASH, so a banned account's email cannot be
added to the existing list; that needs a hash-keyed companion table and an
`is_email_banned` that checks both.

## Email instead of a number: banning the address too (2026-08-16, step 3)

`docs/email_account_bans.sql`. Letting an email stand in for a phone number
makes **ban evasion cheap**, and this is the migration that closes it: a ban
lands on the account's CODE, and a code costs nothing to re-mint, so the same
person signs up again with the same inbox and is straight back in. A phone
number was what made evasion expensive; an email is not — which is why
`DisposableEmails` exists on the client in the first place.

**Why it could not just reuse `banned_emails`, which is the interesting
part.** That list is keyed by the ADDRESS in the clear, which is right for a
moderator typing one in. But `email_claims` deliberately stores only
`sha256(lower(trim(email)))` and never the address at all — so when a
moderator bans an ACCOUNT, the address is **not recoverable from anything
the server holds**. Adding it to `banned_emails` is impossible, not merely
awkward. `banned_email_hashes` is the hash-keyed twin, and each list is
checked by whoever holds the form they can check.

**No server-side hashing, deliberately.** Nothing in this project hashes in
Postgres — there is no pgcrypto dependency anywhere, and `claim_email`
already takes a digest computed by its caller. So `is_email_hash_banned`
takes a hash, and the one caller holding a plaintext address (the
`email-account` function, which has the confirmed email on the session)
computes it in three lines of TypeScript. Adding an extension dependency to
check a string the caller can already hash would buy nothing.

`ban_account_email(p)` / `unban_account_email(p)` are owner/admin only,
addressed **by the account** rather than by an address the server cannot
produce, and canonicalize both sides (a code is stored bare, a phone may
carry a '+'). Grants name `anon, authenticated` explicitly rather than
revoking the PUBLIC pseudo-role — the trap that cost a real hole once
already (`find_people_by_hashes`).

`check_sql.sh` applies it after `taken_signups.sql` and pins six things: the
list is neither readable nor writable by a client, an ordinary account
cannot ban (and its attempt bars nothing), the owner can and the hash then
reads as barred, an account with no email attached bans nothing rather than
erroring, and lifting frees it again. **It needed a staff account of its
own**: the file's usual owner is not granted the role until further down and
tests in between rely on it being non-staff, so seeding it early made one of
those pass for the wrong reason — caught by `check_sql.sh` itself, which is
exactly the job it exists for.

**RUN + verified live 2026-08-16**, applied with the owner's own token and
read back rather than assumed. `banned_email_hashes` exists with RLS ON and
**zero policies** — definer-only access, as designed — and **no table grant
at all** for `anon` or `authenticated`. EXECUTE came back exactly as
intended: `is_email_hash_banned` to anon+authenticated (a yes/no about a
hash the caller already holds), `ban_account_email` and
`unban_account_email` to **authenticated only, with anon excluded** — proof
the explicit `revoke ... from anon` did its job, which is the trap that cost
a real hole once (`find_people_by_hashes`) and does not show up unless you
look. Live anon probes: `is_email_hash_banned` answers `false`,
`ban_account_email` is refused `42501 permission denied for function`, and a
direct read of the table is refused `42501`.

**`email-account` DEPLOYED 2026-08-16** — v1, ACTIVE, `verify_jwt` **true**
(it needs a real user session; the platform gate is the outer door and the
function's own check is the inner one). Probed live, and the answers prove
it boots on this code rather than merely existing: no `Authorization` header
gets the platform's `UNAUTHORIZED_NO_AUTH_HEADER`, while the publishable key
— a valid key but not a user JWT — gets `{"error":"unauthorized"}`, which is
the FUNCTION'S OWN line, reached only if the whole file parsed and ran. A
wrong verb answers the same because the auth check runs first, matching the
source order.
**Still owed after that:** the client wiring (email OTP for a numberless
account -> `claim` -> session refresh -> `attachNumberInPlace`) and stopping
`NumberlessGrace` so an account with full access is not erased on day 14 —
both since done, in step 4 below. The console button for
`ban_account_email` is done too (2026-08-16): see "Banning an account can
bar its email, from the console".

## Email instead of a number: the client wiring (2026-08-16, step 4)

Reported as "still asking me to verify a number when I have email verified".
Three stacked reasons, and the first is the one that matters most:

1. **A name-only account's email was never actually verified, and could not
   be.** `AccountEmail._requestVerification` asks Supabase to send its
   confirmation through `updateUser`, which needs a session — which a
   name-only account does not have. So the address was stored and flagged
   `savedUnverified`. Whatever the screen showed, Supabase never confirmed
   it.
2. `email-account` was written but not deployed.
3. Nothing on the client called it, and the build on the phone predated all
   of it.

`EmailVerifyScreen` (`lib/screens/auth/email_verify_screen.dart`) is the
twin of `NumberlessVerifyScreen`, offered beside it on BOTH gates
(`PhoneGate` and the `postNeedsPhone` sheet) as "Use an email instead" — the
quieter of the two, because a number is still what makes an account
expensive to re-mint.

**It inverts the flow, which is what makes it work at all.** Instead of
adding an address and asking for confirmation (impossible with no session),
the emailed code IS the sign-in: `sendEmailSignupCode` passes
`shouldCreateUser: true` — the opposite of `sendEmailCode`'s `false`, and
the reason that distinction had to become explicit — so confirming the
address and gaining the session are one act.

`AccountService.verifyEmailForNumberless` is the three-step chain, and the
third step is the one that would be silently forgotten:

1. `verifyOTP` gives a session with **no phone claim**, which every RLS
   policy and `callerPhone()` read as anonymous — on its own it unlocks
   nothing.
2. `email-account` stamps a server-minted account code into that user's
   `phone`.
3. **`refreshSession`** is what puts the claim in the JWT. The stamp lands on
   the auth USER; the token this device holds was minted before it and still
   says nothing. Skip it and the app looks exactly as unverified as before,
   with the fault invisible on both sides.

Then `Session.attachNumberInPlace(code)` — the same in-place upgrade the
phone path uses, so the account keeps every chat, server and note, and the
14-day `NumberlessGrace` clock stops there for good (that call already does
it; nothing new was needed).

**A refused stamp returns null rather than throwing**, and the screen says
"your email is confirmed, but this account could not be upgraded" instead of
"wrong code" — the function not being deployed is the likeliest real
failure, and reporting it as a bad code sends somebody to re-check six
digits that were fine. Both halves are pinned by widget tests, which is why
`sendCode` and `verify` are injectable: both talk to Supabase Auth, and a
screen testable only up to its first network call is one whose success path
is never exercised.

**Needs the owner's action before any of this works on a device:** a
Codemagic build. `email-account` is deployed and `docs/email_account_bans.sql`
is applied (both verified live 2026-08-16), and **email was already enabled**
as a sign-in provider — see the OTP-length section for what was actually
wrong with it.

## Maps, Weather, Sports and Watch are admin-only (2026-08-16, owner's call)

`SidebarPrefs.adminOnly` = `{'maps','weather','sports','watch'}`, enforced in
`HomeScreen._appRow` against `PlatformModeration.instance.canAdminister` — a
server-verified role, not anything a client can set. A non-admin gets
`SizedBox.shrink()`; the rows do not exist for them.

**Unlisted, not padlocked**, and that is the difference from every other gate
here. The wallet, posting and the marketplace all show a padlock and name
what would unlock it, because those are doors a user can open for
themselves. An admin role is not, so a padlock would only advertise
something unreachable.

**The one check is the WHOLE gate, which is unusual here and was verified
rather than assumed.** The standing rule is to wrap the SCREEN, because a
drawer row is one way in of several. Grepped every construction site: all
four screens are built in exactly one place, `_appRow`. Maps' other entry
points are different classes (`LocationMapScreen` from chat and the media
gallery, `ExploreMapScreen`), and the chat Weather/Sports attachments call
the SERVICES, never these screens. A second route to any of them needs its
own check — at which point wrap the screen.

The drawer's `ListenableBuilder` now merges `PlatformModeration` with
`SidebarPrefs`: the role loads asynchronously, so listening to prefs alone
showed an admin no admin rows until something unrelated rebuilt the tree.

**The reorder screen still lists all four, deliberately.** Filtering its list
looked right and was wrong: `onReorderItem: prefs.reorder` hands the RENDERED
list's indices straight to the full order, so a shorter list makes every drag
move the wrong row — an index-corruption bug traded for a cosmetic leak. It
was written, caught before it shipped, and reverted with the reasoning left
in the file. Closing it properly means reordering by id rather than by index.

## Banning an account can bar its email, from the console (2026-08-16)

`docs/email_account_bans.sql` shipped and was verified live the same day it
was written, and then nothing called it: `ban_account_email` /
`unban_account_email` existed on the server with no button anywhere, so a ban
still had to be followed by a moderator typing the address into the separate
"Ban an email" list — which they usually cannot do, because **the address is
not recoverable from anything the server holds.** `email_claims` keeps only
`sha256(lower(trim(email)))`; the plaintext is never stored. That is the whole
reason there are two lists, and the reason this one is addressed BY ACCOUNT.

Why it matters at all: a ban lands on the account's CODE, and a code costs
nothing to re-mint, so an email-verified account with no phone number behind
it can be banned and back the same afternoon on the same inbox. A phone
number is what used to make evasion expensive.

**A checkbox on the ban, not a separate screen.** `_SanctionSheet` shows
"Also bar the email behind this account" only when the sanction is a **ban**
and the caller is **admin+** — the same gate the server puts on the RPC, and
the same reason the area scope is hidden from a moderator: drawing a control
the server will only refuse teaches somebody to distrust the console. A
timeout that quietly barred an inbox would reach far past what it says it
does.

**Default OFF, unlike the lift's checkbox, which is default ON.** Barring an
address reaches past the account in front of the moderator — an inbox can be
somebody's way back into an account they still legitimately hold — so it is a
decision to make. A lift is the mirror: it means the account gets its access
back, and an address left barred would quietly keep them from attaching it
again.

**The order is load-bearing in both directions**: the email is barred only
after the sanction is in force, and given back only after the lift landed. A
sanction the server refused must not leave a row on a list the console cannot
even show. A test drives a refused ban and asserts the email step never runs.

**`EmailBanOutcome` is an enum because two answers would lie.** The RPC
returns false for an account with no email attached — much the commonest
case, since an email is optional — and a call that THREW (the function was
never created, the project is offline) has to come back as something too.
Collapsing those into one false would have the console tell a moderator "that
account has no email" about a project that simply never ran the migration,
which is the exact class of message this file keeps recording fixes for.
`_emailTail` is the ONE place the three sentences live, shared by the ban and
the lift, because two hand-written copies of the same three outcomes drift.

Honest limit written into the wrapper rather than smoothed over: the RPC
*also* returns false (not raises) for a caller who is not owner/admin, so
`noEmail` only means what it says because the console reaches it immediately
after a sanction the server already accepted from that same account. A caller
without that behind it must not read the two as one.

## The public feed had to be ASKED whether anybody liked you (2026-08-16)

`lib/state/public_feed_alerts.dart`. Every other interaction in the app
arrives: a server feed's like is a relay event addressed to that server's
members, a channel mention rides the community bus, a chat reaction rides the
pairwise ratchet. The public timeline has none of that — it is a
world-readable table with **no per-user delivery**, so when a stranger likes
your post NOTHING reaches your device; a counter goes up on a server you are
not subscribed to. `public_feed_screen.dart` has said so since mentions
shipped ("a scan-on-load notifier would be a separate follow-up"). This is
that follow-up.

**Counts say THAT, one lookup says WHO.** A single `postsBy(me)` already
carries `likeCount`/`replyCount`/`repostCount`, so one round trip finds every
post that has been interacted with since the last scan. Only those posts cost
a second query to name the people — at most `maxLookupsPerScan` (4) of them,
newest first, and at most `maxNamedPerPost` (5) people each. Twelve likes
overnight is worth knowing; twelve rows in the tab all saying the same thing
about the same post is not.

**A post seen for the first time is a BASELINE, never an alert.** That is
what stops the first scan after an update from raising a notification for
every like the account has ever collected. It costs nothing on a genuinely
new post, which starts at zero anyway — so one rule covers both cases and
there is no "have I run before" flag to get wrong.

**What the cap drops is baselined, not held over.** Keeping the overflow
pending looks kinder and is worse: the cap always picks the same newest few,
so the tail starves anyway while being re-queried for as long as the account
lives. A bound that quietly never bounds is worse than one that says what it
drops. A test pins that every post is rebaselined, cap or no cap, and that
the next scan finds nothing to do.

**Likes are the awkward kind, and the failure direction is chosen.** A like
has no id anywhere in the schema, so there is nothing to dedupe on and no way
to ask which are new. `likersOf` answers NEWEST FIRST, so the first `delta`
of it are the people behind the rise. That is exact while likes accumulate
and degrades in ONE direction: if somebody unliked between scans, the count
moved less than the number of new likers and the oldest of them go unnamed.
It can never name somebody who has not liked the post — "Ada liked your post"
about somebody who did not is a far worse thing to show than a like that
passed quietly. Replies and reposts are posts, so they bring real ids and
real times, and their dedupe is exact.

**`null` from `likersOf` is "unavailable", never "nobody".** The existing
method already draws that distinction; inventing "Someone liked your post"
out of an unanswered lookup would be an alert with nobody behind it.

**One notification list, not a second one.** They land in `FeedStore` through
a new `notePublicInteraction`, so one tab, one badge, one mute list and one
swipe-to-dismiss serve every alert in the app — a public like and a server
like are the same sentence to whoever reads them. What that needed was
`FeedNotification.publicFeed`, an explicit flag rather than "the community id
is empty", which looks like it would do the job and does not: a marketplace
listing is global, so a **review** notification already carries an empty
community id while pointing at a server-feed post. The flag is what sends a
tap to `PublicThreadScreen` instead of `FeedPostScreen`, and a widget test
pins it — the wrong screen would draw "This post was removed" about a post
that is perfectly alive.

Scanned at launch, on resume, and on a pull-to-refresh of the Notifications
tab (tests pin all of them): iOS resumes the app far more often than it
launches it, and noticing what happened while it was closed is the entire
point — while pulling on that tab is somebody asking the question directly,
which for these surfaces only the scan can answer. The tab's EMPTY state is
pullable too and does the same thing, since nothing-to-show is exactly when
somebody reaches for refresh.

**Throttled to `minScanInterval` (2 minutes) unless forced**, because "on
resume" on iOS means constantly — switching away and back, or pulling a
notification down and dismissing it, would otherwise fire three round trips
each time for an answer that cannot have changed. A pull-to-refresh passes
`force`, since somebody who asks by hand has asked. The stamp is taken
BEFORE the work, so a scan that throws half way through cannot leave the
throttle open to a retry storm, and it is held in memory only — persisting
it would make a cold start skip the one moment somebody is most likely to be
looking for what they missed. Silent about its own failures — an unreachable
server means no alerts this time, not an error in front of somebody who asked
for nothing. Account-scoped (wired into `account_wipe.dart`), holds nothing
but integers about your own posts, and a test bans every network token from
the file: it reads counts and calls the store's existing lookups, and must
never grow a path of its own.

**Still not built, and stated rather than implied:** none of this is a PUSH.
A device that is closed learns nothing until it is next opened, because a
real push needs a phone to address and a public post names only a handle —
the same wall the marketplace-review notification hit. A server-side trigger
calling `push-send` is the honest fix and is its own piece of work.

## The follow graph was seeded one way only (2026-08-16)

Reported with two screenshots: the profile said **3 following**, the
Following list showed exactly those three people, and **every row's button
said "Follow"**. The owner read it as the app recommending strangers. It was
not — a live probe of `public_following('luckybreeze80')` answered with real
edges, so the account genuinely does follow them on the server graph.

**The bug is an asymmetry that had been there since the graph shipped.** The
COUNT has been seeded from the server (`noteServerFollowing`, added when two
devices on one account showed different numbers) and re-seeded on resume
(added when a follow made elsewhere stayed invisible until a cold start). The
**list** never was. So `FollowStore._following` — the local set every Follow
BUTTON reads through `isFollowing` — knew nothing about a follow this install
had not made itself, while the profile stat and the list screen both read the
server. A follow made on another device, or before a reinstall, lands in
exactly that state, and the screen says two contradictory things at once.
`pushLocalFollows` (local → server) exists and has no callers; the reverse
direction did not exist at all.

`FollowStore.noteServerFollowingList` closes it, and **adds without ever
removing**, for two independent reasons: `public_following` is `limit 100`,
so the answer is a floor rather than the whole truth; and a follow made
offline never reaches the graph at all (the write is fire-and-forget and is
not retried), so treating the server as complete would quietly delete it.
The cost, stated rather than hidden: an unfollow made on another device does
not remove it here — the count and the list both come off the server, so
what is left is a timeline still showing somebody another phone dropped.

**`syncFollowGraph()` in `main.dart` is now the one funnel**, called at launch
and on resume, doing both halves. The two call sites were already duplicated
copies of the count fetch, which is how the list half came to be missing from
both. `FollowListScreen` seeds from its own fetch as well — the screen that
exposed the bug is the screen that repairs it, without waiting for a resume —
but **only for your own list**, since somebody else's following list is not a
statement about you. A test pins that: seeding from a stranger's list would
invent follows.

## Notifications, app-wide: followers and public mentions (2026-08-16)

Asked for right after the public-feed scanner as "make sure notifications
works app wide". Two real gaps closed in the same scan, and the rest audited
and named below rather than left to be discovered.

**"X followed you" did not exist anywhere in the app** — the single most
standard social notification, and there was no `FeedNotificationType` for it.
Added, which made the compiler walk every exhaustive switch over that enum
(the alert verb, the tab's icon, the tab's verb) — the same safety net the
`review` type leaned on. It is the only kind that points at a PERSON rather
than a post, so `threadPostId` is empty and the Notifications tab routes it
to `PublicProfileScreen` instead of a thread. Found the same way likes are:
the follower COUNT is the cheap half and is asked every scan, `followersOf`
(newest first) is asked only when the number actually moved. Keyed by the
person, so a follow/unfollow/re-follow raises one notification rather than a
stream — the cost being that a genuine re-follow much later is silent.
**An unfollow is never announced**, and the baseline still comes down so the
next real follower is counted correctly.

**@mentions of you in other people's public posts** now alert too — the gap
`public_feed_screen.dart` has admitted since mentions shipped. It reads the
timeline **already in memory**: no query, no round trip, just a pass over
loaded posts, reusing `FeedStore.mentionsMe` so the matching rule is the one
the server feed already uses. The limit is the other side of being free —
there is no server-side search for a handle to call, so a mention in a post
this device never loads is never seen. Partial and honest beat none at all,
given the alternative was offering nothing.

**The first version of this had no baseline and would have flooded** — caught
while writing it, not by a user. A like has a counter to compare against; a
mention has nothing, so the first scan after an update would have announced
every mention already sitting in the loaded timeline, which is the exact
thing the post baseline exists to prevent. It now remembers the post ids it
has seen (capped at `maxRememberedMentions`, oldest dropped) and the first
scan fills that set silently. Remembered by ID rather than by a clock, so a
device whose time is wrong cannot be confused by it.

**The public FORUM was the third surface, and it is covered too** (same day,
after the two above). It raised nothing at all — its own tables, its own
board, no delivery of any kind. `PublicForumStore.postsBy` is new and exists
for exactly this: the loaded board is sorted hot/new/top across everybody, so
your own week-old thread is usually not in it and the timeline could not
answer "did anyone reply to me". The comment COUNT on your own posts says
that something happened, `commentsOf` (oldest first, so the new ones are at
the end) says who, and the same baseline rule keeps the first scan quiet.

**Forum VOTES are deliberately not covered**, and cannot be: the read policy
on `public_forum_votes` scopes SELECT to your own row — by design, so nobody
can see who voted — so a device cannot learn who upvoted anything. An alert
with nobody behind it is the thing this file refuses for likes, so a score
that moved is left to speak for itself on the post.

**`FeedNotification.publicFeed` became `FeedNotificationSource`** when the
forum arrived: one bool was right for two surfaces and would have grown a
second bool for the third, then a third — two mutually exclusive booleans
being exactly the shape that eventually lets both be true at once. Four
screens now hang off it (`_target` in `activity_tab.dart`), and a stored
alert written before the change still opens the screen it always opened —
`fromJson` reads the old `publicFeed: true` key, and a test pins that,
because an app update must not silently re-point somebody's saved
notifications.

**What still cannot notify, audited rather than assumed:**
- **Nothing is a PUSH.** Every alert above is `PushService.localNotify` on a
  device that is awake. A closed phone learns nothing until it is opened,
  because a real push needs a phone number to address and a public post names
  only a handle. Same wall the marketplace-review notification hit.
- **Community notes** on your post, and **marketplace reviews from an author
  the fetch has not loaded**, are silent.
- **Forum votes and newsfeed post views**, for the same reason as each other:
  the server deliberately will not say who.
- Chat, calls, servers, channels and the server feed all notify already and
  were left alone.

## An emailed code could not be typed in: 8 digits into a 6-digit field (2026-08-16)

Found with the owner's own short-lived token while checking the one setting
still listed as owed — and the setting turned out to be a red herring.
**`external_email_enabled` was already TRUE**, so email sign-in had been
switched on the whole time. What was wrong was next to it in the same config:
`mailer_otp_length` was **8**.

`phone_login_screen.dart`'s code field serves BOTH the SMS code and the
emailed sign-in code, and it carried three separate bare `6`s — a
`LengthLimitingTextInputFormatter(6)`, an auto-submit on `v.length == 6`, and
a row of six boxes. So an 8-digit emailed code could not be entered at all:
the formatter dropped the last two digits and the screen submitted the first
six the instant they were typed, answering **"That code is wrong or has
expired."** every single time. A settings mismatch that reads exactly like a
broken code, which is why the earlier rounds of "still can't verify my email"
looked like a deploy problem.

**Fixed on the server** (`mailer_otp_length` 8 → 6, applied and read back
live) rather than by widening the field, because the app is built around a
six-digit code end to end — the box row, the Telegram-style verify-when-full,
the copy. **And fixed in the client so it cannot drift again**:
`PhoneLoginScreen.otpLength` is the one number all three sites read, and a
test pins that none of them carries a bare 6. If it ever changes,
`mailer_otp_length` has to change with it — and so does the SMS length in
Twilio Verify, which is a separate setting this app cannot see.

The new `EmailVerifyScreen` (numberless email verify) was never affected: its
code field has no length limit at all, which is why that flow could work
while the older one silently could not.

Checked at the same time and found already correct, so nothing was changed:
`site_url` (the pages function, not localhost), and `{{ .Token }}` present in
both the Confirm-signup and Magic-Link templates. The Recovery template
carries only a URL and that is harmless — the app has no
password-recovery-by-email flow at all (`resetPasswordForEmail` appears
nowhere).

## Build-your-own avatars, Snapchat-shaped (2026-08-16)

Asked for as "avatars like Snapchat. Any sdks we can use". The app already
drew ILLUSTRATED avatars — generated Multiavatar characters, deterministic
from `avatarSeed` — but that is the other kind: one you pick off a grid, not
one you assemble. `AppUser.avatarFace` is the built kind.

**Bitmoji itself was refused, on three independent grounds.** Bitmoji Kit
needs the user to have a SNAPCHAT ACCOUNT and authorise through Snap; it
shows a face made elsewhere rather than offering a creator to embed; and it
needs Snap's own per-app approval. Snap is also folding Bitmoji inward — the
standalone app was retired 30 June 2026 and Snap Kit's Creative Kit SDK is
already frozen ("will continue to work, will no longer be updated"). For an
app whose whole argument is that it depends on nobody, a Snapchat login
before you get a face is the wrong trade. **Apple Memoji** is a non-starter
for a simpler reason: there is no API at all, so one can be neither created
nor drawn by a third-party app. **Ready Player Me** was refused for the same
reason link previews are built on the sender's device: its avatars live on
its servers and render from its CDN, so a third party would learn who has
which face and be asked for a picture every time a chat list scrolled.

**`avatar_maker` (MIT) is what shipped** — pure Dart, SVG, entirely offline,
and above all **no native pod**, which matters more than it sounds: every
dependency that has hurt this project (`google_mobile_ads`, `photo_manager`,
NFC) hurt it at the iOS archive, the one thing this box cannot check.

**It cost an `intl` bump, and that was checked before anything was built.**
At face value the package silently resolves to **0.0.0** — a stub — and drags
in GetX; pub named the reason when asked for 1.7.0 outright:
`avatar_maker >=0.2.1 depends on intl ^0.20.2` against this app's own
`intl ^0.19.0`. That pin is the app's, not the SDK's, so it was movable:
`intl` 0.19 → 0.20.2 brings `avatar_maker 1.7.0` + `provider` + `nested` +
`flutter_localizations`, no GetX. The suite was run against the bump alone,
before a line of avatar code existed, and passed.

**The SELECTION travels, never the drawing.** What sits on the profile and
rides the sealed profile share is the JSON recipe (which nose, which hair,
which colours) — a couple of hundred bytes. The SVG it draws is ~7KB, and
the profile bundle rides along with messages, so sending the picture would
put a drawing on the wire over and over for something the far end can redraw
exactly. `AvatarFace` (`lib/util/avatar_face.dart`) is the one place that
turns a recipe into a drawing, with an in-memory cache keyed by the recipe
because the answer is deterministic and a chat list draws the same few faces
repeatedly.

**Two package faults were found by probing, not by reading, and both are
silent failures.** They are the reason this section is long:

1. **Its own encode and decode disagree.** `getJsonOptionsSync()` writes
   three decorative keys — `AvatarBackground`, `AvatarEffect`,
   `AvatarEffectColor` — with labels its own decoder cannot find, so feeding
   its output straight back throws `Bad state: No element` and the face does
   not draw at all. Found by round-tripping every key on its own.
   `AvatarFace.faceKeys` is the allowlist that keeps the thirteen that
   survive; the cost is the effect layer, and what is kept is the person.
   It doubles as the guard on what arrives from another device.
2. **The constructor fires an `initController()` it never awaits, and that
   init ENDS BY REASSIGNING `selectedOptions`.** So a selection applied
   before it lands is thrown away, and every face draws as the default —
   Bald and Eyepatch came out byte-identical SVGs. Nothing raises; the
   avatars are simply all the same. Both `AvatarFace` and the builder screen
   now `await initController()` first, and a test pins that two different
   selections really produce two different drawings, because that is the
   property whose failure is invisible.

**The non-persistent controller, deliberately.** The package ships a
SharedPreferences-backed one that would keep the face under its own key —
a second, invisible copy outside the profile and outside `account_wipe`, so
the next account on this phone would inherit the last one's face. The
profile is the only store; `AvatarBuilderScreen` edits a value and hands it
back, and saves nothing itself (`autosave: false`, so backing out changes
nothing).

**Precedence: a built face beats a generated character beats emoji/initials**
— most deliberate wins. It is assigned to `core` inside `UserAvatar` rather
than returned early, or the presence dot and the hero animation would be
skipped for exactly the people who bothered to make one. Its fallback is the
ordinary avatar, so a recipe this build cannot draw is a normal circle
rather than a hole.

Rides the profile share gated on the AVATAR audience (`avatarColor.isEmpty`)
— the face IS the avatar, so withholding one withholds the other — and is
never-zeroed at the receiver like every other avatar field, so a message
from a build that predates faces cannot wipe a real one. That meant touching
every full-rebuild site again (`Session.signIn`/`updateProfile`/
`setVerified`, `AppState.updateProfile`/`setVerified`,
`ChatStore.updateContactProfile`, relay `encode`/`applyIncoming`/
`applyProfileUpdate`/`broadcastProfile`), and a test pins each.

**The screen was rebuilt the same day, and the first cut had a real hole:
no preview.** The package's customizer draws only the option grid — its own
docs say "it is advised that an avatar also be present in the same page to
show the user a preview of the changes being made" — so taking it as-is
meant building a face you could not see: tap a nose, nothing on screen
changes. `AvatarBuilderScreen` now leads with a big live
`AvatarMakerAvatar` on a tinted panel (`usePreview` left at its default, so
it follows the transient preview under the finger — the one avatar in the
app that SHOULD), the grid is dressed in the app's own tokens (`AppRadius`,
`AppColors.accentOn`, tiles that read as chosen in both themes) instead of
the package defaults, and Save became a real full-width primary button
reading "Use this avatar" rather than a bare `TextButton` in the app bar.

**A THIRD package fault, and this one crashes.** `AvatarMakerRandomWidget`
calls `randomizedSelectedOptions()`, which walks EVERY displayed category
and calls `nextInt(properties.length)` — and the same three cosmetic
categories that break the round trip carry NO properties, so it dies on
`RangeError (max): Not in inclusive range 1..4294967296: 0` the instant the
button is tapped. Found by writing a test that actually taps it, not by
reading. Shuffle is now ~8 lines of our own against the public
`selectedOptions` map (the same field the customizer's own tap handler
writes), rolling ONLY `AvatarFace.faceKeys` — so a shuffled face is always
one that can be saved and redrawn on somebody else's phone. A test pins that
the package's randomiser is not used.

**Drawn on a real device 2026-08-18**, once the concurrency bug below was
fixed — before that every built face on a list drew as whichever one rendered
last. The package adds no native code, so it carried none of the archive risk
the others did. What is still unseen from here is the customizer's look and
feel on a phone.

## The avatar gets a colour behind it, and three empty tabs go (2026-08-17)

"Add more options and customizations for build your avatar." What the
package actually offers was counted rather than guessed: **eleven** real
categories (35 hairstyles, 16 hair colours, 20 outfit colours, …), and
that is all there is — `Nose` carries a single option and its own
`Background` is deprecated (one hardcoded blue circle), so the package
hides both itself. The two things genuinely missing were an axis it does
not have at all, and three tabs that should never have been drawn.

**A backdrop is ours, not the package's.** Its cosmetic system ships NO
art — the three "cosmetic" categories come with **zero options**, because
an app is expected to supply them — and what it does support is drawn as a
WIDGET LAYER rather than baked into the SVG, so a background chosen there
would appear in the builder and **nowhere else in the app**.
`AvatarFace.backdrops` is nine colour pairs (None + eight gradients),
carried in the selection under `Backdrop` and painted by
`AvatarFacePainting` behind the face, so it shows in every chat list,
header and profile. The face itself is drawn on transparency (the
package's own Background category defaults to `Transparent`), which is
what leaves room for it.

Three things that make it safe to put in a string every contact receives:
* **`render` strips it before the package sees it.** That decoder throws on
  a key it does not know — the same fault that made `faceKeys` necessary —
  so ours never reaches it.
* **`None` removes the key rather than storing the word**, so a face with
  no backdrop is byte-identical to one built before backdrops existed.
* **`sanitize` drops an id this build does not know.** A backdrop named by
  a newer build is not carried to somebody else's phone to be ignored
  there.

**Painted in ONE place, and that is what makes the preview honest.**
`AvatarFacePainting` is now shared by `AvatarFaceView` (every avatar in the
app) and the builder's preview, which used to be the package's own
`AvatarMakerAvatar` — and that draws the face at 80% of the circle with a
margin around it, where the app draws it to fill. Without a backdrop the
difference was invisible; with a colour behind it, it would be a face
floating in the middle of a coloured circle in the builder and filling it
everywhere else. The preview still listens to the controller, so it keeps
carrying the transient preview of whatever is under the finger — that is
what makes tapping a nose feel like anything.

**A FOURTH package fault, found by trying to hide the empty tabs.** Asking
for `toDisplay: false` on those three categories throws
`ArgumentError: The default value of a category must be in its property
list` before the screen can draw at all: customizing a category runs that
check, and these three ship a default value with an EMPTY property list.
So each entry in `AvatarFace.hiddenCategories` also names the placeholder
the category already defaults to (`NoBackgroundItem` and friends, which
are exported) — it satisfies the check and changes nothing else. A test
constructs the controller, which is what proves the property lists are
still there, and asserts every tab that IS drawn has something in it.

Layout note: Shuffle moved beside the colour row rather than above it,
because a row of its own is a row the customizer below loses — and the
customizer is a tab bar over a grid on a 568pt phone.

**"Edit avatar doesn't work" — the backdrop's first cut broke reopening,
same day.** The package's decoder throws `Bad state: No element` on a key
it does not know, which `render` already stripped the backdrop to avoid —
and `_restore` did not. Its `catch` read the throw as "a selection this
build cannot read" and started from the defaults, so a saved face reopened
as a bald stranger every time. Only the web build carried it (Pages
deploys on every push to `main`); no iOS build has ever had avatars.

`AvatarFace.withoutBackdrop` is public now and is what BOTH hand-offs to
the package go through — drawing a face, and reopening one. **Reaching for
that decoder anywhere else means going through it too.**

The test that should have caught it is the lesson: *a face reopens on the
backdrop it was saved with* asserted only the backdrop id, which survived
precisely because it never reaches the package. It now builds a face
deliberately off the defaults (`builtFace(hairIndex:)`), reopens it, backs
straight out and asserts the WHOLE string comes back — confirmed to fail
against the old line before it was kept.

## The deletion banner had no email door, and a refused upgrade said nothing useful (2026-08-17)

Reported with two screenshots: the red countdown banner offers only a phone
number, and the gate sheet's "Use an email instead" "doesn't work when I try
to verify my email".

**The banner is a real, complete gap and is fixed.** `NumberlessGraceBanner`
is the one surface in the app that names an IRREVERSIBLE deletion, and its
only way out was `NumberlessVerifyScreen` — written before the email path
existed and never revisited. It now carries a **Use email** button beside
the text (the row itself still goes to the phone screen, since a number is
still the stronger identity), and the subtitle names both.

**The verification failure is NOT diagnosed, and this round makes it
diagnosable rather than guessing at it.** `verifyEmailForNumberless` is
three steps — `verifyOTP`, the `email-account` stamp, `refreshSession` — and
the middle one has **six** distinct named refusals (`unauthorized`,
`bad request`, `no email on this account`, `email not confirmed`, `banned`,
`could not stamp the code`). Every one of them was collapsed into
`catch (_) { return null; }` and shown as one vague sentence, so neither the
owner nor this box could tell which line refused. `AccountService.
lastEmailUpgradeError` keeps the server's own word for it — modelled on
`RelayService.lastMarketError`, which exists because this app has now spent
**three** separate rounds (the payment sheet, marketplace listings,
marketplace reviews) debugging a failure the device had already been told
about and thrown away. The screen prints it: "The server said: …".

**Two real faults found while reading the path, both fixed:**

1. **Two senders, one missing `emailRedirectTo`.** `sendEmailSignupCode` (the
   one this screen uses) and `sendNumberlessEmailCode` were the same call,
   and only the second passed the redirect — the omission that once sent
   Supabase's own mail to the project's Site URL, `http://localhost:3000`.
   The first delegates to the second now, so there is one sender.
2. **`email-account` would hand back a REAL phone number.** Its
   already-stamped branch returned `user.phone` unconditionally for
   idempotency — but if that address belongs to an account that signed up
   with a number, the value returned is that number, and
   `attachNumberInPlace` would move this device onto that identity. An
   account takeover by way of a shared inbox. It now returns the value only
   when it is an account code (`00` + 12 digits) and refuses by name
   otherwise. **DEPLOYED + verified live 2026-08-17** — v1 -> v2, ACTIVE,
   `verify_jwt` preserved as true; probed after, and an anon caller gets the
   function's OWN `{"error":"unauthorized"}` line, which is only reachable if
   the whole file parsed and booted.

**CORRECTION, same night: mail DOES arrive, so the SMTP finding below is
NOT the cause of "verify my email doesn't work".** The owner sent a
screenshot of the code (844276) typed into the screen from a real hotmail.ca
inbox, and `auth.users` confirms it: the address exists,
`email_confirmed_at` is set, and `last_sign_in_at` is the minute of the
attempt. So `verifyOTP` SUCCEEDED — the failure is entirely in step 2, the
`email-account` stamp, and the screen said so ("Your email is confirmed,
but this account could not be upgraded") on a build that predates the
diagnostics and therefore could not name which refusal it was.

**The live evidence narrows it to two lines**, and one of them is far more
likely: `takenByAnother` returning true for every salt (→ "could not mint a
code"), or `updateUserById({phone, phone_confirm})` refusing (→ "could not
stamp the code"). The second is the suspect, because it is the only place
in the project that hands an ACCOUNT CODE to a field GoTrue otherwise
treats as a telephone number — and GoTrue validates that field as E.164,
which forbids a leading zero. An account code is `00` + 10 digits. If that
is what is happening, the whole "stamp a code into `phone`" design cannot
work as written and needs a different namespace, not a patch.

**PROVEN 2026-08-17, and the diagnostics are what proved it.** The owner
retried on the current build and the screen said, in full:

> could not stamp the code: Invalid phone number format (E.164 required).

So the suspicion above was right and the design was wrong: GoTrue validates
`phone` as E.164 — grammar `[1-9]\d{1,14}` — and a leading zero is refused
outright. That is why a query of `auth.users` found ZERO accounts whose
phone begins `00`: the path had never once succeeded for anybody.

**The fix is the NAMESPACE, not a patch.** `AccountCode.serverPrefix` is
**`999`** + 12 digits, 15 total — the ITU reserves +999 for future global
service applications and assigns it to no country, so it can never collide
with a real subscriber number, which is exactly the property the leading
zeros were chosen for, in a shape GoTrue accepts. Fifteen digits is E.164's
ceiling. `email-account` mints that shape (**v4**, ACTIVE, `verify_jwt`
true) and `AccountCode.isCode` recognises BOTH — the app's own `00` form,
which never goes near GoTrue and keeps its leading zeros, and the
server-minted one.

**Recognising it as a code is what keeps the account honest.** An
email-verified account still has no phone number, so `Session.isNumberless`
stays true and `AccountVerification.phoneVerified` keeps saying — correctly
— that no number was ever proved; what opens the gates is the SESSION CLAIM
(`needsServerSession` is `isNumberless && !hasServerSession`). Treating the
stamped value as a real number instead would have quietly ticked
"phone verified" on the checklist for somebody who never verified one.

**And the deletion clock had to learn about it.** `enforceNumberlessGrace`
keyed purely on `isNumberless`, so an account that verified an email to STOP
the countdown would have been handed a fresh 14 days on the next launch. It
now exits for any account holding a server session, and the banner checks
the same thing so the countdown goes the moment the upgrade lands rather
than at the next launch. The reasoning is the feature's own: the clock
exists because a name-only account answers for nothing, and one that
verified an email answers for a confirmed inbox — ban-able through
`banned_email_hashes`, and not free to replace.

**The SMTP finding stands as a real, separate problem** — it is why mail is
slow and rate-limited, and it will bite again — but it is not this bug.

**THE PROJECT HAS NO SMTP SERVER.** `smtp_host` is null, so every
Supabase Auth email — the numberless email code, the email sign-in code, the
address-confirmation link — goes out over Supabase's **built-in, test-only**
sender, which is capped at `rate_limit_email_sent: 2` **per hour for the
whole project** and is not intended to deliver to arbitrary inboxes at all.
That is the whole reason "verify my email" never worked, and it is why no
amount of client-side debugging found it: the request SUCCEEDS, the API
answers 200, and the mail simply never arrives. Retrying makes it strictly
worse — attempts three and beyond in any hour are refused outright.

Everything else in that config is correct and was confirmed at the same
time: `external_email_enabled` true, `disable_signup` false,
`mailer_autoconfirm` false, `mailer_otp_length` **6** (matching
`PhoneLoginScreen.otpLength`), `mailer_otp_exp` 3600, `site_url` the pages
function, and **both** the Confirm-signup and Magic-Link templates carry
`{{ .Token }}`. So the only broken link in the chain is delivery.

**NEEDS THE OWNER, and nothing in this repo can do it:** set a real SMTP
provider in Dashboard → Project Settings → Authentication → SMTP Settings
(Resend, SendGrid, Postmark — any of them). Configuring it requires a
provider account and an API key, which is not something this box can create.
Until then, **the phone route is the only one that actually works**, because
it goes over Twilio Verify — a different provider entirely, configured and
live (`sms_provider: twilio_verify`).

Two client changes came out of knowing that:
* The rate-limit sentence no longer says "wait a minute". The cap is per
  PROJECT and per HOUR, so a minute is not enough and saying so sends
  somebody into a retry loop that cannot succeed.
* The code step carries **"No code? Verify a phone number instead"**, which
  is the exit that is unaffected by whatever is wrong with the mail.

If it still fails after SMTP is configured, **the sentence under the Confirm
button is the answer** — it now names the server's own refusal — and is
worth reading before theorising again.

## "Still can't like or repost" — liking was the one action that failed in silence (2026-08-17)

Both actions ARE gated by `postNeedsPhone` for a name-only account, and that
gate is correct — but it is not what this report was about, because the two
behave completely differently once past it. **Reposting has always surfaced
its refusals** (`toggleRepost` → `post()` throws `PublicFeedError`, and the
repost sheet shows it in a snackbar). **Liking swallowed everything**:
`toggleLike` ended in a bare `catch (_)` that rolled the optimistic heart
back and said nothing. So the heart flicked on, flicked off, and there was
no way — from the phone or from here — to find out why.

Three things, all the same lesson this file keeps re-learning:

* **`toggleLike` throws now**, matching `post()`'s contract, and the call
  site `await`s it and shows the reason. The roll-back is unchanged; what is
  new is that it is accompanied by a sentence.
* **Its session guard read the wrong field.** `phone.isEmpty` — and a
  name-only account's phone is its ACCOUNT CODE, which is not empty, so the
  check passed for exactly the accounts it existed to stop and the insert
  was refused 42501 as `anon`. It reads `RelayConfig.hasSession` now, the
  same fix the 42501-storm round applied across the relay.
* **`_explain`'s 42501 branch was the forum's old lie, verbatim.** It said
  "Pull to refresh, or try again in a moment" — naming the network and
  asking for a retry, when the commonest cause of a refused WRITE is a
  lapsed session: every write here is granted `to authenticated`, so a
  signed-out device is refused at the GRANT before RLS is consulted, and no
  amount of retrying changes it. The public forum corrected exactly this
  sentence on 2026-08-11; the feed still had it. It now answers
  "You're signed out of the server…" when there is no session and keeps a
  setup-gap message for when there is.

**What this does NOT do is guess which case the owner is in.** If the
account is still name-only, the gate is what they are hitting and verifying
a number is the way out. If it is a real account whose session has lapsed,
the next tap now says so instead of doing nothing. Either way the answer
arrives on screen rather than in a bare catch.

## A built face was cropped by its own circle (2026-08-17)

Reported as "the profile pictures don't show correctly", with the chat list
and the sidebar as evidence. `AvatarFacePainting` drew the face
`BoxFit.cover` into a square — and the artwork is **264 x 280**, head near
the top, shoulders along the bottom, so filling a square with it crops the
figure. At chat-list size that reads as a face zoomed in and cut off.

`BoxFit.contain` fits the height exactly and leaves the ~6% either side to
the backdrop, so the whole person is in the circle. The package's own widget
frames it smaller still (80% of the circle, with a margin); this is as close
to full-bleed as a circle gets without taking the top of somebody's head
off. One widget, so the builder's preview and every avatar in the app moved
together — which is the reason that widget was shared in the first place.

**The shelf is per-account now (same day).** Two contacts drawing the same
illustrated character was a SEED collision, not a rendering fault: the
"choose an avatar" shelf offered everybody `okay-$batch-$i`, so two people
who both tapped the first one genuinely ended up with the same avatar. The
seed folds in the account's handle (or its id) — different per person, and
still DETERMINISTIC, so the same account gets the same eighteen characters
every time and somebody can go away and come back for the one they liked. A
reshuffling shelf would be worse than a shared one.

## An email-verified account was still refused every write (2026-08-17)

Reported the moment the email path finally worked: **"I can't follow anyone
on an email only verified account."** A bug introduced by the fix before it,
and worth recording as a clean example of a decision having a consequence
somewhere else.

Making `AccountCode.isCode` recognise the server-minted `999` form was
deliberate and is still right: it keeps `Session.isNumberless` TRUE, so the
verification checklist goes on saying — accurately — that no phone number
was ever proved. What it also did was trip **every write backstop that read
the raw flag as a stand-in for "has no server session"**, which is exactly
the account the email path exists to let through.

Eight of them, and each one said "no session" in its own comment while
testing something else: `serverSetFollow` (the reported one),
`PublicFeedStore.post`, five refusals across `PublicForumStore`, the
marketplace's sell action AND its browse-only branch, the in-chat AI draft,
the assistant screen, `Get verified`, and `isOnApp`.

**`AccountVerification.needsServerSession` is the one reader now** — it is
literally `isNumberless && !hasServerSession`, and it is what the UI gates
(`PhoneGate`, `postNeedsPhone`) already used. The stores and screens ask the
same question the gates do. `account_service.dart` asks `RelayConfig.
hasSession` instead, because `account_verification.dart` reaches back into
that file.

The copy moved with it: "needs a phone number" became "needs a verified
phone number or email" wherever the email now qualifies.

**Two existing tests failed on this and both were UPDATED rather than
loosened** — one pinned `isNumberless` in `score_screen.dart`, the other in
`marketplace_screen.dart`. Each still asserts the refusal exists; what
changed is the condition it reads, and the reason is recorded in the test
so the next reader does not "restore" it.

## The Calls list drew a photograph of who somebody used to be (2026-08-17)

Reported as "profile picture still not updated", with two screenshots taken
a second apart — and the screenshots are what identified it: the same
contacts drew **different avatars on Calls than on Chats**. One person, two
answers, on one device. That rules out delivery and points at the drawing.

`CallRecord` holds a **frozen `AppUser`** captured when the call ended and
persisted to disk, and every surface drawing a call drew that copy. So the
Calls tab, the missed-call rows in Notifications, and the search results all
showed whoever that contact was at call time — a picture that could never
update, however many times they changed theirs. It is the mirror image of
the profile-broadcast bug fixed hours earlier: that one was a message that
never landed, this one is a message that landed everywhere except here.

`liveCallUser(record)` (in `call_log.dart` — state, not the model; a model
importing a store is backwards) resolves the contact from `ChatStore` by the
same tolerant lookup everything else uses, and **falls back to the frozen
copy** when there is no chat: somebody you called once and never messaged
still has to draw as somebody.

Applied at all three surfaces, and the source pin enumerates them so a
fourth cannot be added drawing `record.user` again. It also fixes more than
the avatar — the frozen copy carried a stale NAME and a stale PHONE, so
"call back" from an old entry dialled whatever number that contact had then.

## The notifications bell is on Chats and Calls too (2026-08-17)

Asked for plainly. The bell landed on the Newsfeed alone when Notifications
left the bottom bar (2026-08-11) — but the badge counts **messages, calls,
mentions and server posts**, so the count that matters most on Chats and on
Calls could only be reached by going to the Newsfeed first.

`NotificationsAction` (in `home_screen.dart`, beside `AppBottomNavBar`) is
the one widget all three carry, and the Newsfeed's inline copy was replaced
by it rather than left alongside. That is the `HomeDrawerButton` rule again:
a badge is exactly the kind of thing that gets a fix in one copy and not the
others, and this app has already spent rounds on that.

Placed FIRST in each tab's actions, so it holds the same relative position
everywhere. The brand-mark clipping guard in `type_metrics_test.dart` was
re-run deliberately — Chats now carries three actions beside a centred mark,
which is exactly what that test exists to catch — and it passes.

## A profile change reached nobody: two lookups for one question (2026-08-17)

Reported as "the profile picture doesn't update for other users when I
update it", and it was a real bug with a precise cause.
`RelayService.broadcastProfile` was sending correctly — the **receiver**
threw it away.

`applyProfileUpdate` gated on `target.chatById('chat_$from') == null`, an
EXACT string match, while `applyIncoming` — the path a normal message takes
— resolves with `chatWithContact(from)`, which matches on the contact id OR
on digits. The two disagree constantly, because **a chat's id depends on how
it was made**: `chat_${contact.id}` when this device started it (bare E.164
from the directory), against `chat_$from` when it was born from an incoming
message — and `from` is the sender's own `me.phone`, which the login screen
stores as `'$_dialCode $digits'`, **with a space**. Same person, two
strings. So a profile broadcast to any chat you had started YOURSELF missed,
silently, and the new picture only appeared when that person next sent a
message — which is exactly the reported symptom.

**Fixed in `ChatStore.updateContactProfile` rather than only at the call
site**, because the same exact-match lookup was in there too and every
caller shares it — `applyIncoming` passes the raw `from` as well. One
tolerant resolve now serves all of them. `applyProfileUpdate`'s own gate
went tolerant to match.

Both halves were confirmed to FAIL against the old code before being kept:
the profile update lands as `''` and the source pin misses.

## The login screen, and one motion scale (2026-08-17)

Two asks. **"Upgrade the login screen, UI overall"** — and most of it was
already the shape the owner chose (the real app tile rather than a lookalike,
Telegram-style filled fields, the code boxes, the welcome-back card). What it
carried was drift from the app's own rules, and **one real bug hiding inside
that drift**:

**The busy spinner was invisible in dark mode.** `_cta` set
`CircularProgressIndicator(color: Colors.white)` inside a button whose
background is `AppColors.accentOn` — and in dark mode that is `#E7E9EA`, a
near-white pill. So tapping Continue read as the button *emptying itself*.
**Fourth instance of the rule under "A bubble's contents take the BUBBLE's
colours"**, and the first one found by reading rather than by a user
reporting it. The spinner takes `AppColors.onAccent` now, and the test
measures it in both themes rather than only grepping the source.

The rest is drift, each with a reason:
* **Four hex panel colours** (`0xFF23262B`/`0xFFF4F6F7` on the welcome-back
  card, `0xFF2A2E34`/`0xFFF0F2F3` on the code boxes) were a second palette
  kept in step with the real one by hand. All four are
  `colorScheme.surfaceContainerHighest` now.
* **A raw `Colors.red` error box** sat six rows under the expired-account
  banner, which correctly uses `errorContainer` — two panels saying the same
  kind of thing in two different reds, one of them harsh on the dark
  scaffold. Both are the theme's error colours now, and so is the
  name-only warning, which had a fifth hardcoded colour (`0xFFE67E22`).
* **Radii 12, 18 and 26** went onto `AppRadius`; the CTA is a `StadiumBorder`
  by intent rather than a 26 that happens to be half of 52 and stops being
  half the moment the height changes. **The 112 × 0.224 icon tile stays** —
  that is Apple's own corner, so the square reads as the tile iOS masks on
  the home screen rather than as one of the app's cards, and a test pins it
  in as well as pinning the others out.

**"Better animations, smoother transitions."** Page transitions were already
handled (`ZoomPageTransitionsBuilder` on every platform, web included) and so
was the tab cross-fade. What was missing was a SCALE: **twelve** distinct
durations were in use across the app (150/200/220/250/300/400/420/500/650/
700/900/1200), which is the same problem the twelve radii were — two things
that should feel like one gesture taking different lengths of time, and
nothing telling you which one a new animation should match.

`AppMotion` (`lib/theme/app_motion.dart`) is `fast` 150 / `base` 240 /
`slow` 380, plus `enter`/`exit`/`move`/`pop` curves. Pick by what the motion
IS — a control answering a touch, one piece of content replacing another,
something crossing a distance — not by how big the thing moving is.
**Deliberately not a home for everything with a duration**: a ringtone pulse,
a typing indicator and a shimmer are LOOPS, timed by what they represent, and
forcing them onto a transition scale would make both worse.

**A message that arrives while you are reading now slides up and fades in**
rather than appearing between two frames — the one hard cut left in the most
looked-at screen in the app. `_arrivedLive` is seeded with everything already
in the transcript when the screen opens, so **scrolling back through history
animates nothing** and a thousand-message chat costs no motion at all. A SET
of ids, not a timestamp: a mailbox drain can deliver something sent minutes
ago, and "newer than when I opened" would animate a batch of old messages at
once. Same "note what was already here" shape as the sound and read-receipt
listeners beside it. The test pins both halves — that a live arrival animates,
that an existing message does not, and that the entrance FINISHES (an
animation that never settles hangs every `pumpAndSettle` after it).

## A 42501 storm in the Postgres log: doomed writes nobody could see (2026-08-17)

Found in the project's own Postgres log — a screenshot of it, not a user
report — and worth recording as the clearest example yet of why a bare
`catch` is a bug rather than tidiness. Hundreds of lines, every few seconds:

```
42501  permission denied for table direct_chats
42501  permission denied for table community_servers
42501  permission denied for table public_post_votes
42501  permission denied for table public_forum_votes
42501  permission denied for table push_tokens
```

**Cause: a name-only account has no Supabase session, so it reaches Postgres
as `anon`** — which holds no grant at all on any of those tables (Phase 1
revoked them explicitly) — and is refused at the GRANT, before RLS is ever
consulted. One line per chat, per server, per sync, on every launch and
every pull-to-refresh.

**Why every existing guard let it through, which is the part worth
remembering.** Each of those functions already had one, and each read
`digits(me.phone).isEmpty` — but a name-only account's digits are its
ACCOUNT CODE, twelve of them, not empty. So the check that was meant to say
"no real identity, don't publish" said "identity present, go ahead" for
exactly the accounts it was written to exclude. `publishCallPresence`'s doc
comment even claimed it "no-ops for a numberless account (no session)"; it
never did. Same shape as `markRead`'s aspirational comment, and the same
lesson: a guard that reads the wrong field is worse than no guard, because
it looks handled.

**`RelayConfig.hasSession` is the one check now**, and it lives in
`relay_config.dart` rather than beside the other session helpers because
`account_verification.dart` reaches `session.dart`, which imports the relay
— that file is the leaf both sides can see. It asks for a session carrying a
PHONE CLAIM, not merely a session: a claimless session passes the grant and
then fails RLS instead, which is a quieter version of the same doomed write.
It is false wherever there is nothing to ask (a relay-less build, the whole
suite), so reading it can never take a caller down and no existing test
changed behaviour.

Applied to fourteen writers and three readers — the whole central-authority
surface (community/chat structure, voice presence, call rosters), the push
token upload, and **both `_myVotes()` loaders**, which are SELECTs and were
refused just as hard as any insert, on every feed and board load.

**The public forum learned this exact lesson once already** — see
`signedOutOfServer` and "Couldn't reach the forum. Try again." was a lie —
and the central-authority phases shipped afterwards without it. A test now
enumerates every function by name and fails if one loses the guard or a new
one is added without it, which is the only thing that stops a fourth round.

## Leaving Edit profile with unsaved changes asks (2026-08-17)

Asked for as "ask if they want to save their changes before leaving or do
auto save for them". **Asked, not auto-saved, and the reason is specific to
this screen rather than a general preference:** `_save` calls
`RelayService.broadcastProfile()`, which pushes the profile to every 1:1
contact within seconds. Auto-saving on back would put a half-typed name or a
mistyped handle on everybody else's phone, not merely leave it on the device
until it was noticed. A username change also spends the once-per-cooldown
allowance, which cannot be taken back. Neither is something to do on
somebody's behalf because they tapped back.

`PopScope(canPop: false)` with the decision in the handler. Two things worth
not rediscovering:

* **`Navigator.pop` does NOT consult PopScope — only `maybePop` does** (the
  back button, the system gesture). That is what lets both branches pop
  directly without re-entering the guard, and why no `canPop`-flipping
  dance is needed.
* **Nothing changed means no dialog at all.** A guard that fires on every
  exit is one people learn to tap through, and then it stops protecting
  anything. A test pins the clean exit as well as the dirty one.

**Dismissing the dialog keeps editing.** Three actions — Keep editing,
Discard, Save — and the barrier/back returns null, which is treated as Keep
editing: the safe answer for the one choice that loses work.

**`_snapshot` is the dirty check and its list is a contract**, stated in the
code: a field added to this screen has to be added there too, or backing out
having changed only that field looks exactly like backing out having changed
nothing, and the edit is dropped without a word. Nothing can check that
automatically. A test covers the shape of the trap rather than the list — it
changes the BUSINESS PROFILE SWITCH, which touches no `TextField` at all, so
a snapshot that only watched text controllers would pass every other test
and fail this one.

## A GIF can be the profile picture (2026-08-17)

Asked for as "allow gifs as profile pictures". The finding worth recording
first: **this app had no photo profile picture at all.** An avatar was a
colour and initials, an emoji, a generated Multiavatar character, or a built
face — four things the app DRAWS, none of them a picture. So this is not a
format being allowed, it is the first real picture in the avatar stack.

`AppUser.avatarGif` is a URL from the GIF picker (the same
`showEmojiGifSheet` chat uses), offered at the top of the avatar sheet in
Edit profile.

**Why a URL rather than the bytes.** The profile bundle piggybacks on every
message; a GIF is hundreds of kilobytes to megabytes, so carrying the file
would put it on the wire over and over. A URL is what the feed already does
with GIFs, for the same reason: the provider serves it, and copying it into
a bucket would mean paying to serve it twice.

**And that URL is the whole cost of the feature, said plainly rather than
buried.** Every other avatar draws with no network at all — the reason a
hosted avatar service was refused when the face SDK was picked was that it
"would mean a third party learning who has which face and being asked for a
picture every time a chat list scrolled past it". A GIF avatar is exactly
that. Two things bound it, and neither is a guess:

* **It only ever arrives over the sealed profile share**, so the only people
  who can point your phone at a URL are people you have exchanged messages
  with — not a stranger in a feed, and not the username directory, which
  carries no avatar fields at all. Those same people can already send you a
  GIF MESSAGE that your phone fetches the same way; what this adds is that
  it is fetched when you look at a LIST rather than when you open their
  chat.
* **`AvatarGif.looksValid` is strict about the shape**, in the same spirit
  as `LightningAddress.parse`: https only (a `http:` avatar would announce
  to the network which picture — so which person — this phone just drew), no
  `data:` (that would carry megabytes inside the message bundle), no
  userinfo (`https://real.host@evil.example/x` reads as one host and
  resolves to another), a dotted host, and a real path.

**There is deliberately NO host allowlist**, and the reason is in this file
already: nothing in this repo has ever called the GIF provider's API live,
so the real media host is unknown here — the `media.klipy.com` in the tests
is an invented fixture, not an observed value. An allowlist built on that
guess fails CLOSED: every GIF avatar silently never appears, which is worse
than the exposure it would buy. If the host is ever confirmed against the
live API, adding it is a two-line change and worth making.

**It wins over all four others, and clears none of them.** It is the only
one that is a real picture, so it draws on top — but nothing underneath is
erased, which is what makes the fallback coherent: the face or the seed is
what shows while the fetch is in flight, if it fails, and the moment the GIF
is taken back off. Drawn through `ChatPhoto`, the same widget a GIF message
uses, so there is one loader and one error contract.

**A real bug the test caught, worth naming because it looks like nothing.**
The fallback was written `errorBuilder: (_) => core` — and a Dart closure
captures the VARIABLE, not its value, so by the time it ran, `core` was the
GIF that had just failed. It would have redrawn itself, failed, redrawn,
forever. Fixed by capturing `final under = core;` first. The
`AvatarFaceView(fallback: core)` line beside it is safe for the opposite
reason: that is a value passed at call time.

Rides the profile share gated on the AVATAR audience (`avatarColor.isEmpty`)
like `avatarFace` — the GIF IS the avatar, so withholding one withholds the
other — and is never-zeroed at the receiver, so a message from a build that
predates it cannot wipe a real one. Which meant touching every full-rebuild
site this file has been warning about since business profiles, and a test
pins each.

**Not built, and stated rather than implied: you cannot use your OWN GIF.**
`PhotoPrep.prepare` re-encodes to JPEG, which kills the animation, and there
is nowhere to put an animated file — avatars have never had an upload path
or a bucket. The picker is the only source that works today; a real upload
is its own piece of work (a bucket, a size cap, moderation, and a URL that
would then be the app's own to serve).

## A bio is what they wrote, pronouns and links are gone, and sign-out lets go (2026-08-17)

Three asks in one message, plus one report I could not reproduce.

**The bio showed the app's own sentence as if the person had written it.**
Every account made before the bio replaced the Available/Busy status carries
`AppUser.legacyAbout` ("Hey there! I am using OkayMessenger."). The public
profile already refused to draw it — and FIVE other surfaces drew it anyway:
the contact card, the group roster, the new-chat and add-members pickers, and
the marketplace seller card. `AppUser.bio` is now the one rule (their words,
trimmed, or nothing) and every one of those reads it. The contact card also
stops drawing a "Bio" heading over nothing. A test walks all seven files and
fails on a raw `.about`.

**Pronouns and links left the profile** (the owner's call). Removed from every
surface that drew them — the public profile header, the contact card, the
sidebar card, and Settings, which the test caught still doing it after the
first pass — and from Edit profile, so there is no field to type them into
either. **The FIELDS stay on the model and still ride the wire**, the same
call `bannerColor` got when its picker went: a profile arriving from a build
that still has them must not be rewritten, and Edit profile carries the
existing values through every save (`_carriedPronouns`/`_carriedLink`) rather
than blanking what other people's older builds still render.

Two `type_metrics_test.dart` guards failed on this and were UPDATED rather
than loosened: the profile metadata row used to wrap to two lines because of
the link, and now fits on one, so the test asserts one line instead of two.

**"I signed out of Tester, signed in to Iman, and my name is Tester" — NOT
reproduced, and one real defect found next door.** Both switch orders were
driven in a probe (sign in A → out → in B, and a full A/B/A round trip with
an edit in between) and each landed on the right name; `signIn`'s `prior`
lookup is guarded by digits on all three of its sources. What the probe DID
show is that **sign-out cleared `user` and left `AppState.profile` holding
the departed account** — so between signing out and the next sign-in landing,
the app's live profile was still the person who just left. On the numberless
route "in between" is a whole PIN dialog and a key adoption, and it is also
what the profile's own auto-save listener would write to disk if anything
nudged it once the next account's slot had been restored. `signOut` now
clears it. Whether that was the reported bug is unproven: the build on the
owner's phone predates all of this, so if it recurs on a fresh one, the next
thing to ask is which route was used (the Iman row needs a recovery PIN, so a
numberless account with no backup cannot sign in that way at all).

## Two built faces drawn at once came back as ONE face (2026-08-17)

**CONFIRMED FIXED on a real device 2026-08-18** — the owner reported the
avatars correct after a build carrying `3372969`, closing a report that had
been raised four times. Worth keeping as the shape of the whole episode: three
earlier rounds fixed real bugs on the SEED path (a shared shelf, a stale call
snapshot, a removal that could not propagate) and none of them was this one,
because the reporter's symptom — two contacts, one picture — was equally
consistent with all four. The thing that actually resolved it was the owner
saying WHEN it started.


**The actual bug behind "two contacts show the same profile picture", found
only when the owner said "this happened after you added the custom avatar and
gifs".** That sentence is what solved it: the fault arrived WITH the avatar
builder, in the builder's own render path, and every earlier round had been
looking at the SEED path instead.

`AvatarFace.render` drove **one shared, MUTABLE controller**:

```dart
final c = await _controller();
await c.saveAvatarSVG(jsonAvatarOptions: withoutBackdrop(selection));
final svg = c.getAvatarSVGSync();   // reads the state saved above
```

`saveAvatarSVG` sets the controller's state; `getAvatarSVGSync` reads it back.
Two renders in flight at the same time — **which is exactly a chat list
drawing several people in one frame** — interleave between those two calls, so
both return whichever face was written last. Two people, one face.

**And it does not flicker, it STICKS**, which is why it read as permanent and
why re-salting the seed never touched it: the wrong answer is then written to
`_svg[selection]` under BOTH keys, so the cache is poisoned for the life of
the app.

**The fix is to REMOVE the sharing, not to take turns on it.** Each render now
builds and awaits its own controller. Serializing onto a static queue was
tried first and was worse: it fixed the race and turned any abandoned render
into a permanent wedge — a chain of futures that nothing can recover. Two
guards were tried on top of it and both made things worse rather than better,
and are recorded so they are not retried:

* **A per-render `.timeout`.** It schedules a TIMER, and a pending timer is
  exactly what stops `pumpAndSettle` from settling — the builder test spun for
  its full ten-minute budget. The guard against a wedged queue became the
  thing that wedged it.
* **Resetting the cached controller in the test seam.** That forces the next
  caller to build a new one, and if that caller is inside a widget test the
  new controller is a future against a fake clock which never completes,
  hanging every render after it.

Owning the controller removes the shared state instead of scheduling around
it: no queue, no interleaving, nothing static to strand, and the whole
built-face test group went from hanging for ten minutes to passing in three
seconds. The cost is one controller per UNIQUE face, which the drawing cache
already bounds — a list has few distinct faces, and each is drawn once.

**Reproduced before fixing, at two levels**, which is the only reason this is
known to be the bug rather than a theory: `Future.wait([render(a), render(b)])`
on two genuinely different selections returns two IDENTICAL SVGs against the
old code, and a `ChatListTile` pair carrying two different built faces draws
one face. Both pass now and both were confirmed to fail with the queue removed.

**The lesson worth keeping: a package that hands out one shared controller and
splits "set" from "get" across an `await` is not concurrency-safe, and a list
is inherently concurrent.** Give it a controller per call rather than trying
to schedule access to one.

**Found alongside it:** `a message that arrives while you are looking animates
in` picked `store.chats.firstWhere(...)` — whichever 1:1 earlier tests had left
lying around — so it failed in isolation and passed only by luck of ordering.
It builds its own chat now. Worth checking for elsewhere: a test that reads the
shared store instead of seeding it is a test that passes for the wrong reason.

## Profile pictures, audited layer by layer (2026-08-17)

Asked for a deep dive after several rounds of point fixes. Every layer was
swept rather than the one being reported: the six avatar fields
(`avatarColor`, `avatarColor2`, `emoji`, `avatarSeed`, `avatarFace`,
`avatarGif`) traced through construction, persistence, the wire, the receive
paths and every drawing surface.

**Two more real bugs, both in GROUPS — which is why the 1:1 fixes kept not
being enough.**

1. **A group member drew the ROSTER's copy, not the person's real avatar.**
   `_memberSummary` — what a `gupd` puts on the wire — carries id, name,
   phone and `avatarColor`, and has never carried the emoji, seed, face or
   GIF. So a member drawn straight off the roster is a coloured initial even
   when this device has them as a contact with a real picture: right in the
   chat list, wrong inside the group. It reached the sender avatar beside
   every group message, the seen-by sheets, and the group-info member rows.
   `ChatStore.liveContact(rosterEntry)` resolves against this device's own
   contacts first, falling back to the roster entry for somebody never
   messaged — the same shape and reasoning as `liveCallUser`. **Widening the
   wire would NOT have fixed it**: the roster is a snapshot from whenever
   somebody last edited the group, so it would go stale the moment that
   person changed their avatar. The contact card is the live copy.
2. **A group's colour never reached anyone.** The group editor offers a name,
   a description and a colour — the colour IS the group's picture — and
   `gupd` carried none of it, nor did `applyGroupUpdate` apply one. One group
   was a different colour on every member's phone. Now sent as
   `groupAvatarColor` and applied; absent from an older build's payload, and
   `updateGroup` reads null as "leave it alone", so nobody is recoloured by a
   peer that cannot say.

**One latent trap closed:** `updateGroup` and `applyAuthoritativeChatStructure`
rebuilt a group's `AppUser` carrying emoji/seed/face/GIF but **not**
`avatarColor2`. Nothing sets a second colour on a group today, so it was
invisible — and invisible is exactly how the next one gets written.

**Two things checked and found CLEAN**, recorded so they are not re-audited:
* **Persistence.** `AppUser.toJson`/`fromJson` round-trip all six.
  (A first scan reported `avatarColor2`/`avatarFace`/`avatarGif` missing —
  that was wrong, the window had landed on `SubscriptionTier.toJson`. Read
  the actual function, not a fixed-size slice around the name.)
* **The drawing layer.** Every person-avatar goes through `UserAvatar`; the
  only `CircleAvatar` drawn for a person is a channel `Member`, which carries
  no avatar fields at all by design (`InitialsAvatar`).

The rebuild-site sweep is worth re-running when an avatar field is added —
it finds every `AppUser(...)` that copies fields off an existing user and
reports which of the six it forgot.

## Removing a profile picture could never propagate (2026-08-17)

Reported plainly: "Giti and Jon both removed their profile picture but it
hasn't updated." A REAL bug, and a different one from the seed collision
above — setting an avatar propagated fine; only CLEARING one could not.

**Never-zeroed, at both layers.** The avatar fields have always been
non-empty-wins: `applyIncoming`/`applyProfileUpdate` turned an empty
`fromAvatarSeed` into `null`, and `ChatStore.updateContactProfile` then read
`null` as "keep what you have". So a removal left the sender as an empty
string on the wire and every reader took it for silence. The rule exists for
a good reason — a message from a build that predates a field carries nothing,
and must not wipe a real avatar — but it made removal impossible rather than
merely lossy.

**The discriminator was already on the wire, so no new field was needed.**
The sender gates every avatar field behind the privacy audience using its own
`avatarColor` (`'fromAvatarSeed': avatarColor.isEmpty ? '' : me.avatarSeed`,
and the same for emoji/face/GIF). Every account HAS a colour — `colorForPhone`
assigns one — so a non-empty `fromAvatarColor` is exactly the signal that this
payload is speaking about the avatar at all. Now:

* `fromAvatarColor` non-empty → the bundle is present and AUTHORITATIVE.
  Empty seed/face/GIF/emoji means **removed**, and lands.
* `fromAvatarColor` empty → withheld by the audience, or a build too old to
  carry the field. Everything is left alone, exactly as before.

`updateContactProfile`'s four avatar fields therefore changed from
non-empty-wins to `?? keep`: **`''` is a real value meaning "they took it
off", `null` still means "said nothing".** Safe because the CALLER decides,
and the relay only ever passes `''` when the bundle really rode the payload.

**One flaw in the first cut, caught before it shipped:** an INVALID GIF url
would have read as a removal, since `sharedAvatarGif` collapsed "absent" and
"unparseable" to the same empty string. `RelayService.incomingAvatarGif` is
the one shared rule now — null for no bundle, `''` for a genuine removal, the
url when valid, and **null for an invalid one**, because being unable to draw
something is not the same as being told it is gone. Both receive paths call
it rather than carrying the rule twice.

Confirmed to FAIL against the old code before being kept: the removal test
reports the contact still holding `okay-3-9`, which is the report verbatim.

**Deliberately still never-zeroed:** `about`, `pronouns`, `link`, `location`
and the rest of the free-text fields. Only the avatar bundle has a gate that
says whether it is speaking; the others do not, so applying them as-sent
would let an older build blank them.

## A relayed call is held to a cheaper video cap (2026-08-17)

"I don't want it to go to relay, cause that will cost me money." The honest
answer first, because it shaped the fix: **the relay cannot simply be switched
off.** When both ends sit behind carrier-grade NAT — two phones on mobile
data, the common case — TURN is the only path there is, so removing it does
not save money, it stops calls connecting. The owner was offered that option
outright (along with audio-only-on-relay and a per-call setting) and chose the
cap.

**What actually costs money is VIDEO, not the relay.** Metered bills by the
byte; audio is tens of kilobits a second, video at the normal 2.5 Mbit ceiling
is roughly forty times that. So `CallMedia.relayVideoBitrate` (600 kbit) is
the ceiling while `mediaPath` says `relay` — about four times less relayed
data, and still a watchable call.

Mechanically it is a SECOND cap on `AdaptiveBitrate`, deliberately separate
from the loss-driven one, because the two answer different questions:
`sample` asks "what will this link carry", `setLimit` asks "what are we
willing to pay for". Congestion control alone would never bring it down — a
relayed link is usually perfectly capable of the full rate, so nothing about
the link is wrong.

Three details worth not rediscovering:

* **`setLimit` returns whether it moved the RATE**, and the caller re-applies
  on that. Waiting for the next loss sample would mean waiting forever: a
  clean link never produces one.
* **Both calls run, never `||`-short-circuited.** `capped || adapted` with
  `sample` on the right would stop the link adapting the moment the cap was
  in force.
* **Re-checked every sample, not set once.** An ICE restart mid-call can move
  a direct call onto the relay and back, and the cap follows it both ways —
  raising it again does not raise the rate, it just lets clean windows climb.

The cap sits well above `AdaptiveBitrate.floor` on purpose, so the link's own
congestion control still has room to move underneath it — a relayed call on a
bad link still backs off below 600 kbit.

## "via relay" could be a lie about a direct call (2026-08-17)

Reported as "when I call it shows via relay". The ICE config was checked
first and is not the cause: STUN is present (`stun.l.google.com` plus the
Metered servers `turn-credentials` hands out) and there is **no
`iceTransportPolicy: 'relay'`** anywhere, so nothing forces the relay — ICE
selects it. What was wrong is the READING of that selection.

`CallMedia.selectedLocalType` picks the candidate pair whose local type
becomes the label, in this order: the transport's `selectedCandidatePairId`,
then a `nominated` succeeded pair, then — the bug — **any succeeded pair, in
arbitrary map order**. Both of the first two fields are OPTIONAL in practice,
so real devices land in that last branch, and a DIRECT call very often has a
succeeded RELAY pair sitting beside the host one (ICE keeps checking both).
Picking whichever came first in a hash map therefore reported "via relay" for
a call going straight out.

Fixed by preferring the pair actually **carrying the media** —
`bytesReceived + bytesSent`, highest first — before falling back to the old
answer for the case where nothing is moving yet (the first seconds of a call,
or a platform that reports no byte counts, where answering something still
beats answering nothing).

**Confirmed to FAIL against the old code before the fix was kept**: the new
assertion returns `relay` for a pair set whose traffic is all on the host
pair. That is the difference between a guard and a restatement.

**What this does NOT claim.** It does not make a relayed call direct. If both
ends are behind carrier-grade NAT — two phones on mobile data, which is the
common case — the relay genuinely IS the only path and the label is then
correct and expected. What is fixed is the label lying about a call that was
never relayed; whether any particular call still says it is a fact about the
two networks, not about this code.

## A Codemagic build died on somebody else's rate limit (2026-08-17)

`Step 12 script 'Build IPA' exited with status code 1`, and it is **not a code
fault** — nothing in the repo was wrong. `pod install` failed with:

```
[!] CDN: trunk Repo update failed - 2 error(s):
CDN: trunk URL couldn't be downloaded: https://raw.githubusercontent.com/
  CocoaPods/Specs/.../StripePaymentSheet/23.17.0/... Response: 429 Too Many Requests
```

Resolving pods walks the CocoaPods CDN (jsdelivr), which **redirects to
raw.githubusercontent.com**, which rate-limits. Two podspec fetches came back
429 and CocoaPods failed the whole install. A third earlier fetch had already
timed out after 4 retries. The first answer is simply **re-run the build**.

**Why it fetched so much in the first place, which is the part worth fixing:
there is no committed `ios/Podfile.lock`.** It is not gitignored (`.gitignore`
only names `**/ios/**/Pods/`) — it has never existed, because there is no
CocoaPods on this Linux box to generate one. So every build re-resolves the
entire graph from scratch, and to SORT candidate versions the resolver fetches
the podspec of every published version of every transitive pod. The log shows
it walking StripePaymentSheet 23.0.0 through 25.17.0. That is what turns an
ordinary rate limit into a failed build.

Two changes, both in `codemagic.yaml`, on the two workflows that run
`pod install` (`ios-release` and `ios-simulator`):

* **A `cache:` block — there was NO caching of any kind before**, so the spec
  cache was thrown away every build, guaranteeing a full re-fetch. It now keeps
  `$HOME/.cocoapods`, `$HOME/Library/Caches/CocoaPods` and `$HOME/.pub-cache`.
  CocoaPods revalidates cached specs by ETag (the log shows `save ETag` on
  every download), so a warm cache is not a stale one.
* **`pod install` retries** three times with growing backoff (30s/60s), then
  fails for real rather than looping on a genuine error. The failure it guards
  against is remote and transient; losing a 20-minute build to it is not worth
  it.

**Unverified from this box, and it cannot be otherwise** — there is no way to
run Codemagic from here. What IS checked: the YAML parses, both workflows carry
the cache and the retry, and the retry script passes `sh -n`.

**The real fix is a committed `ios/Podfile.lock`**, which removes the
resolution step entirely and makes builds reproducible rather than
dependent on what the CDN serves that day. It cannot be generated here. A
successful Codemagic build produces one — take it from the build artifacts (or
run `pod install` once on a Mac) and commit it.

## Confirming an account has to leave a way back into it (2026-08-17)

Asked as "make sure when user confirms their account with an email or phone
number they have a way to login back in". Audited every route rather than
assumed; the phone side was already fine (a number signs in with an OTP over
Twilio, which is a different provider from the mail and unaffected by it). The
EMAIL side had a real hole and a wrong sentence.

**There were TWO ways to confirm an email, and only one of them let anybody
in.** Settings → Email offered its own send-a-code/verify pair
(`AccountEmail.sendNumberlessCode`/`verifyNumberlessCode` →
`AccountService.verifyNumberlessEmailCode`), which checked the code and then
**signed straight back out**. So the verification checklist ticked while the
account kept no session and kept its account CODE as its identity — and an
auth user carrying no phone is refused by BOTH `signInWithPassword` and
`verifyEmailCode` (each discards such a session by design). The address was
confirmed and useless as a credential: the worst of both, because it looks
like the answer to "how do I get back into this account" and is not one.

The weaker pair is **deleted, not unwired**, so it cannot come back as a
second flow: the tile now opens `EmailVerifyScreen`, which is the real thing —
verify the code, stamp the account code into the auth user, refresh the
session so the claim reaches the JWT, upgrade in place, and ask for a
password. `AccountEmail.markVerified()` replaces the pair as the one thing
left, called by that screen once the upgrade has actually landed. A test pins
both old names OUT of the source.

**Signing in by USERNAME told an email account it was locked out.** A
numberless handle routes to the recovery-PIN path, which answers "@x has no
recovery backup, so it can't be signed back into" — true for a name-only
account, wrong for one that confirmed an email and may never have made a PIN.
A **server-minted `999` code exists only because an email was confirmed**
(`email-account` stamps one and nothing else does), so that is a derivable
fact, not a guess: `AccountCode.isServerCode` now picks the sentence, and the
email one points at the identifier field they are already on. The PIN route is
untouched for accounts that really do depend on it.

Together with the password step below, every confirmed account now has a named
way in: a number signs in with an OTP; an email signs in with a password, or
with an emailed code; a name-only account still has its recovery PIN, and is
told so.

## A public post carries the author's face, and email signup asks for a password (2026-08-17)

Two reports in one message, from a build confirmed at `c1308f3` (the sidebar
footer prints the commit — `kBuildStamp`, injected by CI; that is the way to
date a build, and the chrome in a screenshot is a decent second-best).

### The newsfeed drew letter avatars for everybody

"It doesn't show the right profile pictures on my other phone", with a second,
name-only account showing a timeline of initials. **Not a rendering fault, and
not the shelf collision from earlier the same day.** `FeedAvatar` resolves a
face through `knownUserFor`, which answers only for YOURSELF or a chat
CONTACT — and the feed row carried nothing else to draw, because
`public_posts` has only ever held `author_username`, `author_name` and
`author_verified`. A stranger on a public timeline is exactly the person a
device cannot know, so the one surface built for meeting people was the one
that could never show a face.

`docs/public_feed_avatars.sql` adds six columns (colour, second colour, emoji,
seed, face, GIF) and re-creates `public_feed` as the new final word on its
shape — appended LAST, since create-or-replace can only add view columns at
the end.

* **On the POST, not in the directory.** `author_name` and `author_verified`
  are already snapshotted at post time — the author's own presentation,
  published because they chose to post in public. The avatar joins them on the
  same terms, so only somebody who posts publishes a face. Putting it in
  `usernames` instead would publish the avatar of everyone who has an account,
  including people who never post, to anyone who can guess a handle — and it
  would mean redefining `find_people`, which this file already records as
  defined THREE times with a trap in it.
* **No phone among the columns**, and none needed: the legacy-seed re-salt
  keys off the HANDLE, which a public post already carries.
* **A known contact still WINS** over the snapshot (`knownUserFor(username) ??
  published`), so somebody you have chatted with keeps a live face. That also
  answers the one cost of snapshotting — a changed avatar does not reach back
  into old posts, exactly as a changed display name already does not.
* **One `AppUser?` field on `PublicPost`, not six loose ones**, so there is one
  thing to thread through the copy sites rather than six that drift apart; the
  columns are unpacked once in `_avatarFromRow`. All-empty reads as **null**,
  never a blank avatar that would override the initial.
* **Both directions step down on 42703.** The read path gains a new top
  generation in `_columnSets` (that ladder already existed); the write path
  retries the insert without the avatar rather than refusing to post. A project
  that has not run the migration keeps working exactly as it does now.
* Column-level grants only, so `author_phone` stays unreadable, and UPDATE is
  still limited to `body`/`edited_at` — **an edit cannot swap the face on a
  post people have already read.** `check_sql.sh` pins all four.

**Needs the owner's action:** run `docs/public_feed_avatars.sql` (after
`public_feed.sql`, `creator_subscriptions.sql` and `public_feed_edit.sql`).
Until then the feed reads and posts exactly as before. **Deliberately the
newsfeed only** — the public forum, community notes and the marketplace have
the same gap and are not covered here.

### Registering by email now asks for a password

An account verified by email has **no phone number**, so the only other way
back in is another emailed code — the one part of that flow that can quietly
not arrive. `EmailVerifyScreen` gains a third step after the upgrade lands:
pick a password, so `signInWithPassword` works from then on (it returns the
`999` code in the phone field, which is non-empty, so that path already works
unchanged).

Asked, not forced: "Not now" pops, and the sentence above the field says what
skipping costs rather than leaving it to be found out. No back arrow and
`canPop: false` — the account is already verified and signed in, so there is
nothing behind that screen but steps already done. It runs the same
`passwordProblem` + `PasswordHistory` checks the Settings field does, so a
password set here is remembered and cannot be returned to later.

### The identity cooldown was the DEVICE's, not the account's

Found by the suite, not by reading: both new password-step tests passed alone
and failed together. `_identityChangedAt` was a single stamp, so one account
changing its address would refuse **the next account's very first verify on
the same handset** — a brand-new account told it had changed something
recently. `_identityChangedFor` records whose clock it is, and
`identityCooldownLeft()` returns zero for anyone else. Same lesson as
`NumberlessGrace` and `abuse_guard`: a clock about an account has to be keyed
to one.

## An avatar chosen off the old shared shelf is re-salted per person (2026-08-17)

Reported three times — two contacts drawing the same face in the chat list and
again in the call log. The first round fixed the CAUSE (the shelf offered
everybody the same eighteen strings, `okay-$batch-$i`, so two people who both
took the first character genuinely held the same seed; it is
`okay-$salt-$batch-$i` now, a different set per account). What that could not
do is repair a seed already chosen, and the third report is what made the
difference plain: **a contact's `avatarSeed` only ever arrives from what THEY
send** (`fromAvatarSeed`) — nothing on the reader's device derives, defaults or
heals it, so the two who had already collided were going to stay collided
until each of them re-picked.

**The screenshot dated the build, and corrected a claim I had made an hour
earlier.** I had said nothing from the session was compiled; the notifications
bell in the Chats app bar is `f0f3cba`, added that session, and the shelf fix
(`3c5f864`) is its ancestor — so the build already HAD the fix and the
duplicates were legacy data rather than a second bug. Worth remembering as a
technique: the chrome in a screenshot dates a build as well as the version row
does, and often faster.

`AvatarSeed` (`lib/util/avatar_seed.dart`, pure) re-salts a pre-fix seed at
**draw** time with the person's own identity. Chosen over the two alternatives
(leave it and wait for them to re-pick; retire legacy seeds to letter avatars)
at the owner's direction — it keeps everybody an illustrated avatar and needs
nobody to act.

* **The salt is the handle, else the phone's DIGITS** — values every device
  that can see that person already agrees on, their own included, since
  `UserAvatar` draws a profile the same way whether it is yours or somebody
  else's. So the re-salted face is the same on every phone AND in their own
  mirror; each device is not inventing its own answer. Digits specifically
  because the same number is written several ways across this app, and a salt
  that told `+1 555 0100` from `+15550100` would draw one person two faces.
* **Not Dart's built-in string hash.** It is an implementation detail free to
  differ between the VM and dart2js, which would draw one face on the phone
  and another on the web build. The hash here is plain arithmetic, staying
  inside 2^53 so JavaScript's doubles lose nothing. A test bans the built-in
  by name from the file — and the doc comment tripped it once, the same prose
  trap the demo seed has hit twice, so the comment now says so rather than
  naming the identifier.
* **Nothing to salt with is left alone.** A made-up salt would draw a
  different face on every device, which is worse than the duplicate.
* **Drawn, never stored.** The seed on the profile stays exactly as its owner
  chose it, so this is a repair the reader applies rather than a rewrite of
  somebody's profile behind their back. It also means the change is reversible
  by deleting one file's worth of code.
* **The picker had to move with it.** `_AvatarSeedPicker` drew the raw seed, so
  without this the ONE screen showing the old character would have been the
  one where somebody looks at their own.

The cost, said rather than buried: anyone who picked an avatar before the
shelf was salted sees their character change, once. Tests compare the ART the
renderer produces (`RandomAvatarString`) rather than just two different
strings — two seeds that differ can still land on the same character, and it
is the face that was reported.

## The address an account is reached at moves once every 30 days (2026-08-17)

"Don't allow user to consistently change email or number make it so they
gotta wait 30 days." **Half of it already existed and is untouched** —
`AccountEmail.changeCooldown` has been 30 days since email recovery shipped,
`setEmail` answers `EmailSaveResult.tooSoon` inside the window, and `clear()`
refuses too because remove-then-add would dodge the clock. What had no
cooldown at all was the identity the account is ADDRESSED by: the phone
number, or the server-minted `999` code a verified email earns. That is what
every contact holds, what every message is delivered to, and what a ban is
recorded against — so it is the one worth locking most, and it was free.

`Session.identityCooldown` (30 days) + `identityCooldownLeft()`, enforced
inside `attachNumberInPlace`, which is now a **`Future<bool>`** rather than a
`Future<void>`.

**Two exemptions, and both are for things that are not a change of address.**

* **A real phone number landing on an account that has none.** It is the
  strongest identity the app has and the thing every gate pushes people
  toward; a cooldown that could block it would be working against the rest of
  the product. This covers the whole normal path — a name-only account, and
  an email-verified one holding a `999` code, both read as `isNumberless`.
* **Re-attaching the SAME identity.** `email-account` answers a
  re-verification with the code it already stamped, so this is the ordinary
  "verify again" flow. Refusing it would report a cooldown to somebody who
  changed nothing — and it does not restart the clock either.

**The clock starts on the free first attach too**, or the second could follow
it the same afternoon.

**A boolean nobody reads is the silent failure this codebase keeps paying to
debug**, so both callers branch on it: `email_verify_screen` distinguishes it
from its existing "confirmed, but not upgraded" sentence (that one names a
server refusal; this one is a local lock, and blaming the server for it would
send somebody hunting a fault that isn't there), and
`numberless_verify_screen` reports rather than popping as though it worked —
wired even though the exemption above means it cannot fire there today.
`Session.identityCooldownMessage()` is the ONE sentence both read, so the two
screens cannot word the same rule differently.

## A password cannot go back to one this account has used (2026-08-17)

"Don't allow user to change there password to previous passwords they had or
anything similar." `PasswordHistory` (`lib/state/password_history.dart`),
checked in `account_email_screen`'s password section BEFORE the round trip —
the server would refuse a reused password for a different reason, if at all,
and this one can be explained.

**No password is stored, in any form that can be read back.** What is kept is
a PBKDF2-HMAC-SHA256 digest at 120k rounds over a random per-account salt —
the same derivation the chat lock and the encrypted backup use. A history file
lifted off the device is a set of slow hashes.

**Which is exactly why "anything similar" needed [skeletonOf].** You cannot
compare two hashes for similarity; that is what a hash is for. So a SECOND
digest is kept of a normalised form, and similarity is an equality test on
that. `Summer2024!` and `summer2025` both reduce to `summer`, and neither is
ever written down.

**The order inside `skeletonOf` is the whole thing, and getting it wrong is
what the test caught.** The first version folded leet substitutions first and
THEN stripped the trailing counter — which turned `2024` into `2o2a`, leaving
no counter to strip and `Summer2024!` coming out `summer2o2ai`. Decoration
comes off the END first (`[^a-z]+$` — a year, a counter, a `!`), and only then
are substitutions folded, **and only where the character sits BETWEEN two
letters**: the `0` in `passw0rd` is an o, the `0` in `2024summer` is a zero.
The same positional rule settles a symbol, so `P@ssw0rd1` → `password` while
`2024summer` is left alone.

Limits stated rather than implied, in the file and here:

* It catches the variation people actually make — a counter bumped, a symbol
  swapped, the case changed — not two unrelated passwords sharing a stem.
* **A skeleton shorter than 4 is not compared at all.** `x1y2` reduces to
  `xiy`, and matching on three letters would refuse half of what somebody
  could pick next; that password is caught only by an exact repeat.
* **It is per DEVICE.** Supabase holds the real password and offers no history
  API, and keeping one server-side would mean keeping more about somebody's
  passwords than this app should. So a password reused from another phone is
  not caught.
* **It fails OPEN, deliberately** — a corrupt history forgets itself rather
  than refusing every password somebody tries, which would lock an account out
  of its own password change.

Two derivations per check regardless of how much history there is (one salt
per account means the candidate is hashed once and compared against every
entry), run through `compute` for the same reason `ChatLock` does — 120k
rounds twice on the UI thread is a frozen screen mid-password. `debugRounds`
is the test seam, or the suite pays a second per assertion.

`keep` = 5, newest first, so a long-lived account is not eventually refused
everything. Recorded only once the change actually LANDED — remembering one
the server refused would refuse it again later for no reason.
**Account-scoped**, wired into `account_wipe.dart` like `ChatFolders`
(`reset()` drops the cached prefs handle as well as the list, or the next
`load()` reads the previous account's blob straight back): whose passwords
these were is a fact about that account, the salt is per-account, and the next
person on this phone must not be refused a password somebody else once had.

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

**`public_forum_comments_v` missing `security_invoker` — CRITICAL, fixed and
RUN live 2026-08-12.** Found by Supabase's own Security Advisor (Postgres
lints), not `check_sql.sh` — the first bug in this project caught that way
rather than by the project's own migration checks. Every other view in the
codebase declares `with (security_invoker = on)`; this one, added in
`docs/public_forum_comment_votes.sql`, was created without it, so it ran as
its OWNER rather than the querying role and silently bypassed
`public_forum_comments_read`'s ban-hiding policy
(`using (not is_locked_out(author_phone))`) — a banned author's forum
comments were readable through the view the whole time the base table's own
RLS was correct. Fixed in the migration file, and `check_sql.sh` now pins it
(seed a comment from the permanently-banned test phone, assert it's absent
from `public_forum_comments_v` for another caller — the check that would
have caught this had it existed). **Applied live** via the Management API
with the owner's own token: `reloptions` on the view read back as
`["security_invoker=on"]`, and an anon-key query against the view still
answers cleanly (no permission regression). Worth periodically re-checking
Security Advisor for this project rather than assuming `check_sql.sh`'s
existing assertions catch everything — this class of bug (a view silently
bypassing RLS) has no test unless someone thinks to write one, and nobody
had, for this specific view, until the advisor flagged it.

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
