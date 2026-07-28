# Fees and unit economics — the honest version

Every number here is enforced by tests in `test/widget_test.dart`
(`lib/payments/storage_economics.dart` is the source of truth). If a price
changes to something that loses money, the suite fails.

## Peer-to-peer transfers (Stripe)

**The fee comes out of the transfer, not on top of it.** Send $20 and the
recipient gets $18.95. The send sheet says so before you confirm — "You pay /
Fee / They receive" — because the amount typed and the amount that lands are
different numbers.

| | |
|---|---|
| Platform fee | 3.4% + 35¢, floored at Stripe's worst-case cost + 1¢ |
| Stripe, domestic card | 2.9% + 30¢ |
| Stripe, card issued abroad | ~3.7% + 30¢ |

The floor exists because **the sender chooses the card and we only learn what
it cost afterwards.** A flat 3.4% + 35¢ crosses under an international card's
3.7% + 30¢ at about **$17.75**, so every larger transfer on a foreign card was
losing money — silently, since nothing about a charge announces its issuing
country. The floor makes that case break even instead of bleed and leaves
smaller transfers untouched.

| Transfer | Fee | Kept, domestic card | Kept, foreign card |
|---|---|---|---|
| $5 | 52¢ | +8¢ | +4¢ |
| $10 | 69¢ | +10¢ | +2¢ |
| $50 | $2.15 | +40¢ | +1¢ |
| $100 | $4.01 | +81¢ | +1¢ |

### What is NOT covered, and could still cost you

These are real and unmodelled — decide deliberately rather than discover them:

- **Disputes.** Stripe charges roughly **C$15 per chargeback**, and on a
  destination charge the *platform* is liable — the money already went to the
  recipient. One dispute wipes out the margin on well over a hundred $10
  transfers. This is the single biggest risk in the P2P product.
- **Refunds.** Stripe does not return its processing fee on a refund. A
  refunded $50 transfer costs you the $1.75 Stripe already took.
- **Connect account fees.** Stripe bills for active Express accounts and for
  payouts in some regions. Check your own Connect pricing page — the rates
  vary by country and I could not verify Canada's from here.
- **Currency conversion**, if you ever accept a currency other than CAD.

## Cloud storage (Apple IAP)

Sold at **$0.20/GB/month**. Apple keeps 30%, so you net $0.14/GB.

| Egress per stored GB / month | Cost to serve | Profit |
|---|---|---|
| 0.5× (what the model budgets) | $0.066 | **+$0.074** |
| 1.0× (the enforced fair-use cap) | $0.111 | **+$0.029** |
| 1.32× | $0.140 | **break-even** |
| 3.0× (the *old* cap) | $0.291 | **−$0.151** |

**Egress dominates.** Storage is $0.0213/GB; downloads are $0.09/GB. The
fair-use ceiling used to allow 3× stored bytes per month — 2.3× past the point
where a plan starts losing money. A user sitting at that ceiling on the 100 GB
plan cost about $15/month against a $19.99 price. The ceiling is now **1×**,
which still allows restoring everything you store, every month.

### What is NOT covered

- **The $25/month Supabase Pro base fee is not amortised** into the per-GB
  price. The model proves each GB is profitable *at the margin*, which is not
  the same as the business covering its fixed costs. You need to sell roughly
  **339 GB** before the base plan pays for itself.
- **The free tier is a cost centre.** 2 GB free per user costs about **$0.13
  per user per month** at the budgeted egress. 1,000 free users ≈ $133/month
  with no revenue against it. That is a deliberate acquisition cost, but it
  should be a decision, not a surprise.
- **Apple's Small Business Program** cuts their take from 30% to 15% under
  $1M/year. The model assumes 30%, so if you are enrolled every margin above
  is understated — the conservative direction.

## Tips

Consumables at $2.99 / $5.99 / $10.99 / $24.99. Apple keeps 30%; there is no
cost to serve them. Always profitable.
