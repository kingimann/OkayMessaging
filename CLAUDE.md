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
session — the Newsfeed (its RLS inserts need a JWT) and the Wallet — around
the screen, never the row, for the same reason as `VerifiedGate`.
**Servers OPENED for numberless on 2026-08-04** (a correction, not a
loosening): the community bus is sealed broadcast + the anon-key mailbox +
the sealed `community_posts` store — the same transports numberless chat
already rides — so the gate's stated reason had stopped being true, and it
was why a numberless member's server posts existed for nobody. A test pins
the gate out. Marketplace is browse-only for numberless (selling needs the
ID check), Okay Drop and Maps are open. Notes and Settings stay
open: Notes is local-only and locking it would protect nobody, and Settings is
the way out. There is **no owner waiver** — an owner without a number has no
session either, so letting them through would show a screen that cannot load.
`PhoneOnlyHint` puts a padlock on the drawer row; `_GateHint` in
`home_screen.dart` shows one padlock for a row behind both gates.

**There is no in-place upgrade.** The number *is* the account, so adding one
means a new account, and the gate says so rather than offering a button that
would sign somebody out. A test asserts chat is not gated.

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

0d. **Admin power pack (2026-08-04)** — needs two pastes to go live:
   re-paste `docs/edge_functions_paste/moderation-act.ts` (adds the
   `takedown` action: moderators+ remove any public post, author must be
   outranked) and paste `docs/edge_functions_paste/roles-set.ts` as a NEW
   function named exactly `roles-set` (JWT verification ON) — the owner's
   in-app Team tab (Moderation console) that grants/revokes admin and
   moderator roles without the SQL editor. Owner-only server-side; 'owner'
   is never assignable from the app. Until pasted, the Team tab says so
   and takedowns are refused; everything else is unaffected. Also new,
   no server work: the login screen remembers up to 5 profiles
   (`Session.knownAccounts`, kept across the account wipe — identity only)
   with one-tap sign-back-in per profile (long-press removes one).

0. **NEW since 2026-08-03 late session** (needed for delete/deactivate
   account to work live; everything is built, tested and pushed):
   - Run `docs/account_lifecycle.sql` in the SQL editor (adds the
     `usernames.hidden` column + the find_people filter behind Deactivate).
   - Paste `docs/edge_functions_paste/delete-account.ts` as a new Edge
     Function named exactly `delete-account` (JWT verification ON — it must
     only answer signed-in callers). Until pasted, Delete account fails
     with a clear error and deletes nothing, by design.

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
