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

## ⚠️ Required before selling big sizes: move backups to Storage buckets

Chat backups are currently text rows in the Postgres `sync_blobs` table, which
bills as **database disk at $0.125/GB** — ~6× the bucket rate. On disk,
break-even is **$0.243/GB**, which is *above* the $0.20/GB retail rate:

| Size | Profit on buckets | Profit on Postgres disk |
|---|---|---|
| 10 GB | +$0.73 | −$0.31 |
| 50 GB | +$3.67 | −$1.51 |
| 100 GB | +$7.36 | −$3.01 |

**Every size loses money on Postgres disk.** The pricing above is only valid
once the chat-backup blob moves to a Supabase Storage bucket — which is also
the correct backend for large blobs (Postgres is for small sync metadata).

Until that migration lands, either keep sizes small and raise the rate, or
treat the current paid storage as launch-only. Ask and I'll wire the bucket
path (client upload, bucket + RLS, migration of existing blobs).

## Capacity watch

`docs/storage_usage_setup.sql` gives a `storage_totals` view — accounts, total
bytes, egress this month. Since every GB is profitable, hitting 100 GB total is
a *revenue* milestone, not a cost problem; watch it to know when to size up the
Supabase plan (which is itself covered by the margin).
