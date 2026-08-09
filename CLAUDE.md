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
- **The Newsfeed and AI TABS carry a ☰ of their own** (`HomeDrawerButton` in
  `sidebar_menu_button.dart`, beside `homeScaffoldKey`): they hide home's app
  bar (and its drawer hamburger), so without it the sidebar would be
  unreachable from them. It opens home's drawer IN PLACE (the tabs live inside
  home's Scaffold — no navigation, no bounce). This is NOT the deleted
  pushed-destination ☰: it exists only where the drawer is already present.
  Pushed instances of both screens keep the normal back arrow (`canPop`
  branches). The feed's old avatar-leading is gone — your own profile is the
  drawer's profile card.

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
free. **Needs the user's action:** re-paste `ai-chat` for the `style` field to
take effect (inert, ignored, until then).

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

## Owner-editable prices (2026-08-09)

Settings → **Prices** (owner-only, beside the legal editor): the storage
per-GB rate, the four subscription tier levels, the four tip amounts —
published to every device via the owner-gated `pricing-set` function into the
world-readable `app_pricing` row, cached locally, read by `PricingStore`.

**The invariant that makes this safe: a real StoreKit price ALWAYS wins.**
What is published fills only the gaps a store price cannot — web,
payments-test mode, the frame before StoreKit answers — plus the tier ladder a
creator picks from (a choice the app must offer before any purchase exists).
So nothing set here can advertise a price different from the charge. An
editor that could override a live store price would be a way to promise one
number and bill another; do not "improve" it into one. **To change what people
pay it is still App Store Connect** — the in-app banner says so.

`StorageStore.priceCentsFor` derives the whole ladder from the one rate. The
tier ladder is validated TWICE — in the function and again in `_apply` — so a
ladder that goes backwards is ignored rather than rendered, even by an older
build. The cache is device-scoped like `legal_store.dart` (app-wide config, no
account data); the account-switch test pins that classification.

**RUN + verified live 2026-08-09** — `app_pricing` created (RLS on, 1 policy,
**zero** client write grants, anon+authenticated SELECT), and `pricing-set`
deployed ACTIVE with `verify_jwt=true`. Probed: no-JWT → 401, anon `what=get`
→ `{"prices":{}}` (it boots), anon `publish` → `unauthorized`, anon INSERT on
the table → 42501. Do not re-raise as pending.

**Deploying a function from this box**: the Management API's JSON
`POST /v1/projects/{ref}/functions` stores a body with NO entrypoint and the
function answers `BOOT_ERROR`. Use the multipart
`POST /v1/projects/{ref}/functions/deploy?slug=<slug>` with
`metadata={"entrypoint_path":"index.ts",...}` + a `file=@index.ts` part, and
deploy the **paste copy** (self-contained; the sources' `_shared` imports do
not resolve there).

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

## Both newsfeeds match (2026-08-08)

The **server feed** (`feed_screen.dart`) now offers the SAME **For you /
Following** control the public newsfeed has, top-right in the app bar (a
`PopupMenuButton<FeedFilter>`, `FeedFilter` reused from `public_feed_store.dart`)
— the old Latest/Top/Saved `FeedTabStrip` is gone. Following keeps posts by
`FollowStore.following` (+ yourself); For you is the whole server timeline. The
trending row stays. (Saved-post filtering went with the strip; the bookmark
action on a post remains.)

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

## Sidebar destinations show a ☰, not a back arrow (2026-08-08) — SUPERSEDED

Reverted 2026-08-09 at the owner's direction: every pushed sidebar destination
shows a **normal back arrow** again (see "Navigation model (settled
2026-08-09)"). The `fromSidebar` flags still ride the constructors (callers
pass them) but no longer change the leading. Do not reintroduce the ☰.

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

Separately, App Store now WARNS that min-iOS 13 must become **15** by Spring
2027 (not blocking yet; bumping `IPHONEOS_DEPLOYMENT_TARGET`/Podfile is its own
device-tested change).

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
