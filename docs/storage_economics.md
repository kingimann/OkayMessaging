# Storage pricing & profit

Users choose how much storage they want, up to **100 GB**. Prices are derived
from real costs — see `lib/payments/storage_economics.dart` and the test
"every size profits after Apple's cut — including as overage", which fails the
build if any purchasable size would lose money.

## The two costs

1. **Store cut** — Apple / Google keep **30%**, so you net **70%** of the
   sticker price. (Apple's Small Business Program drops this to 15% under
   $1M/year — enrolling roughly doubles these margins.)
2. **Supabase Pro**, at the rates that apply *past* the included allowances:
   - Storage buckets: **$0.0213 / GB** ← the right backend
   - Postgres disk: **$0.125 / GB** ← where backups live today
   - Egress: **$0.09 / GB** (250 GB/mo included)

The model budgets **0.5× stored bytes/month of egress** — conservative, and
well inside the 3× fair-use cap.

**Break-even is $0.095/GB** (cost $0.0663 ÷ 0.70). The retail rate is
**$0.20/GB** — a little over 2× break-even.

## How going past your 100 GB is covered

You asked for users to be charged extra once total usage passes the 100 GB the
Pro plan includes. The App Store **cannot** bill a variable surcharge — IAP
sells fixed price points only, and you can't retroactively charge someone
because *other* users grew. So the overage is handled the only way that
actually works, and it's strictly better for you:

> **Every GB is sold above its own overage rate.** A GB costs $0.0663/mo at the
> beyond-included rate; you charge $0.20 and keep $0.14 after Apple. So a GB
> that pushes the project past 100 GB has *already paid for its own overage*,
> with ~2× margin left over.

In other words there's no cliff at 100 GB — the 101st GB is exactly as
profitable as the 1st. Growth never costs you money; it makes money. The
`coversOverage()` check in the economics module asserts this for every size on
the ladder, and the test suite enforces it.

## The ladder

Apple sells fixed price points, so "custom amount" is a slider that snaps to
10 GB steps (10 → 100 GB). Prices are ~$0.20/GB landed on an x.99 point:

| Size | Price | You net | Supabase cost | **Profit/mo** |
|---|---|---|---|---|
| 10 GB | $1.99 | $1.39 | $0.66 | **$0.73** |
| 30 GB | $5.99 | $4.19 | $1.99 | **$2.20** |
| 50 GB | $9.99 | $6.99 | $3.32 | **$3.67** |
| 100 GB | $19.99 | $13.99 | $6.63 | **$7.36** |

Free tier: 2 GB, no charge.

Your first 100 GB of bucket storage and 250 GB of egress are **included** in
the $25 base, so early on marginal cost is effectively $0 and margins are
fatter than the table — this is the steady state once you're past the
allowance.

## ✅ Backups live in Storage buckets

Chat backups upload to the **`chat-backups` Storage bucket** ($0.0213/GB), not
the Postgres `sync_blobs` table ($0.125/GB). That 6× difference is what makes
the table above real — on database disk, break-even is $0.243/GB, *above* the
$0.20/GB retail rate, and every size would lose money:

| Size | On buckets (actual) | On Postgres disk (avoided) |
|---|---|---|
| 10 GB | **+$0.73** | −$0.31 |
| 50 GB | **+$3.67** | −$1.51 |
| 100 GB | **+$7.36** | −$3.01 |

The small communal sync blob (servers, feed, follows) stays in the table, where
it's free and its size is irrelevant. Privacy is unchanged — the bucket holds
the same AES-256-GCM ciphertext, named by an unguessable HMAC of the user's
key.

**Deploy step:** run `docs/chat_backup_bucket.sql` once. Until you do, chat
backup reports "Chat storage isn't provisioned yet" rather than silently
failing.

## Peer-to-peer transfers (Stripe)

Separate revenue line, and it *was* losing money: the platform fee defaulted to
**1.5% + 0¢** while Stripe charges the platform **2.9% + 30¢** on a destination
charge — a loss on every single transfer.

Now **3.4% + 35¢**, with a hard floor so a bad env var can't drop it below
Stripe's cut:

| Transfer | Fee in | Stripe takes | **You keep** |
|---|---|---|---|
| $10 | $0.69 | $0.59 | **+$0.10** |
| $50 | $2.05 | $1.75 | **+$0.30** |
| $250 | $8.85 | $7.55 | **+$1.30** |

Margins are thin by nature on card processing — the fixed 30¢ dominates small
transfers. Raise `PLATFORM_FEE_PERCENT` / `PLATFORM_FEE_FIXED_CENTS` if you
want more. Enforced by the test "peer-to-peer transfers profit after Stripe
takes its cut".

## The free tier is the one thing that isn't profitable — by design

2 GB × every user, at $0 revenue, is customer acquisition, not a business line.
Two things keep it cheap:

- Chat backup is **opt-in** and requires setting an encryption key, so most
  free users store **zero bytes** — the allowance costs nothing until used.
- A fully-used free account costs **$0.043/month** on buckets. 1,000 of them is
  ~$43/mo, and your first 100 GB is included in the $25 base anyway.

Watch `storage_totals` / `chat_backup_totals`; if free usage ever becomes a
real line item, cut the allowance or require a paid plan for cloud backup
(local iCloud backup stays free either way).

## Capacity watch

`docs/storage_usage_setup.sql` gives a `storage_totals` view — accounts, total
bytes, egress this month. Since every GB is profitable, hitting 100 GB total is
a *revenue* milestone, not a cost problem; watch it to know when to size up the
Supabase plan (which is itself covered by the margin).
