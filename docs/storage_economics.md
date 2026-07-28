# Storage pricing & profit

Prices for the paid storage plans are derived from real costs, not guessed —
see `lib/payments/storage_economics.dart` (and the test "every paid plan
profits after Apple's cut and Supabase cost", which fails the build if a plan
would lose money on the intended backend).

## The two costs

1. **Store cut** — Apple / Google keep **30%** of every in-app purchase, so you
   net **70%** of the sticker price. (Apple's Small Business Program drops this
   to 15% under $1M/year — if you enrol, margins roughly double.)
2. **Supabase Pro**, beyond what the $25/mo plan already includes:
   - Storage buckets (file storage): **$0.0213 / GB** ← the right backend
   - Postgres disk: **$0.125 / GB** ← where backups live *today*
   - Egress: **$0.09 / GB** (250 GB/mo included)

The model budgets **0.5× stored bytes/month of egress** — conservative, and
well inside the 3× fair-use cap.

## Margins (on Storage buckets, 30% store cut)

| Plan | Size | Price | You net (70%) | Supabase cost | **Profit/mo** |
|---|---|---|---|---|---|
| Personal | 15 GB | $9.99 | $6.99 | ~$0.99 | **~$6.00** |
| Plus | 100 GB | $19.99 | $13.99 | ~$6.63 | **~$7.36** |

The first 100 GB of bucket storage and 250 GB of egress are **included** in the
$25 base, so early on your marginal cost is effectively $0 and margins are even
fatter — the table is the steady-state at scale.

## Important: move backups to Storage buckets

Chat backups are currently stored as text rows in the Postgres `sync_blobs`
table, which bills as **database disk at $0.125/GB** — about 6× the bucket
rate. At that rate the numbers change sharply:

| Plan | Profit on buckets | Profit on Postgres disk |
|---|---|---|
| Personal 15 GB | ~$6.00 | ~$4.44 |
| Plus 100 GB | ~$7.36 | **−$3.01 (loss)** |

So Plus (and anything bigger) only profits once backups live in Storage
buckets. That's also the correct backend for large blobs — Postgres is for the
small sync metadata. **Recommended next step:** migrate the chat-backup blob
from `sync_blobs` to a Storage bucket. I can wire that (client upload path +
bucket + RLS) on request; until then, keep paid plans at/below ~15 GB to stay
safely profitable on disk, or raise the Plus price.

## Going bigger

Apple requires **fixed** product sizes, so "add more GB" is a set of set-price
plans, not a free-form slider. To add a larger plan later, pick a size, set the
price so `StorageEconomics.isProfitable(price, gb)` holds on buckets, add the
tier + product ID, and the test will confirm the margin.
