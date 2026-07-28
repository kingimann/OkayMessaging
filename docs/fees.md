# Fees and unit economics — the honest version

Every number here is enforced by tests in `test/widget_test.dart`
(`lib/payments/storage_economics.dart` is the source of truth). If a price
changes to something that loses money, the suite fails.

## Peer-to-peer transfers (Stripe)

**You never hold anyone's money.** Transfers are Stripe *direct charges*: the
PaymentIntent is created on the recipient's connected account, so funds go
straight there and never pass through your balance. You are not the merchant
of record and not in the flow of funds.

**Two fees come out of the transfer, not on top of it.** Send $20 and about
$18.37 lands. The send sheet shows all three lines before you confirm.

| | Paid by | Rate |
|---|---|---|
| Platform fee | recipient (out of the transfer) | 3.4% + 10¢ — **all of it yours** |
| Stripe processing | recipient's account | 2.9% + 30¢ domestic, ~3.7% + 30¢ on a foreign card |

Because Stripe bills the recipient's account rather than yours, **the
application fee is pure revenue and a transfer cannot cost you money**,
whatever card the sender used. That retired the old fee floor, so senders pay
slightly less than they did under destination charges.

| Transfer | Your fee | You keep | Recipient gets ≈ | Total taken |
|---|---|---|---|---|
| $5 | 27¢ | 27¢ | $4.29 | 14.2% |
| $10 | 44¢ | 44¢ | $8.97 | 10.3% |
| $50 | $1.80 | $1.80 | $46.45 | 7.1% |
| $100 | $3.50 | $3.50 | $93.30 | 6.7% |

The fixed part is 10¢, not the 35¢ it started at. Fixed components dominate
small amounts: at 35¢ the platform fee alone was **10.4% of a $5 transfer**,
and with Stripe's 30¢ on top nearly a fifth of it vanished. Since a direct
charge costs the platform nothing to carry, there is no floor to respect and
the fee can simply be fair.

**Your fee covers no per-transaction cost.** It is not processing — that is
Stripe's separate line, charged to the recipient. It funds the service:
Supabase, the Apple developer account, Stripe Identity checks, and the work.
Worth saying that way rather than implying it covers the payment.

Very small transfers are still poor value, and that is Stripe's 30¢, not
yours: at the $0.50 Stripe minimum, 30¢ of it is processing however little
you charge. A minimum send amount is the only real fix if that matters.

### Chargebacks

**A chargeback bans the sender from sending money.** A dispute here is not a
billing disagreement with a merchant — the money reached another person who
has already been paid, and clawing it back leaves them carrying the loss. The
ban is enforced server-side in `payments-create-intent`, so it is not a
suggestion the app can be talked out of.

It protects the platform too: Stripe closes accounts whose dispute ratio
climbs, and that ratio counts disputes **whether they are won or lost**.

Prevention, in the order it does the most good:

1. **A recognisable statement descriptor.** Set `STATEMENT_DESCRIPTOR` (it
   defaults to `OKAYMSG`). "STRIPE* SOMETHING" on a statement is a leading
   cause of friendly fraud — people dispute what they do not recognise
   instead of asking.
2. **A real receipt.** Stripe emails one when the account has an address on
   file. A charge with no record attached is a charge worth disputing.
3. **An acknowledgement at send time.** The sender must tick a box saying the
   transfer is final and that reversing it will block them. Recorded in the
   PaymentIntent metadata with a timestamp, so the evidence exists before it
   is needed.
4. **Stripe Radar.** Rules live in your Stripe dashboard, not in this repo.
   Worth configuring — it costs more per transaction and less than a dispute.
5. **Fight every dispute you have documentation for.** Winning keeps the ratio
   down even when the fee is gone either way.

### What is NOT covered, and could still cost you

- **Disputes now land on the recipient**, not you — that is a direct
  consequence of direct charges and was the single biggest P2P risk under the
  old model. Worth telling recipients plainly during onboarding, because it is
  a real obligation they are taking on.
- **Refunds.** Stripe does not return its processing fee. That cost falls on
  the recipient's account, and your application fee is refunded with it.
- **Connect account fees.** Stripe bills for active Express accounts and for
  payouts in some regions. Check your own Connect pricing page — the rates
  vary by country and I could not verify Canada's from here.
- **Currency conversion**, if you ever accept a currency other than CAD.

## Identity verification (the blue check)

The badge requires a Stripe Identity document check with a selfie match. It
used to be a free toggle.

**Stripe Identity is billed per verification session** — around **$1.50** at
list price, charged whether or not the person passes. That is a real cost per
attempt, so:

- an already-verified account never starts a second session;
- the badge is currently offered free to the user, which means each one costs
  you. If verification is popular, this becomes a line item worth watching.

Verify the current rate on your own Stripe pricing page rather than trusting
the number here.

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
- ~~The free tier is a cost centre.~~ **Removed.** There is no free
  allowance: backup requires a subscription. It previously cost about $0.13
  per signed-up account per month whether or not that account ever paid.
- **Apple's Small Business Program** cuts their take from 30% to 15% under
  $1M/year. The model assumes 30%, so if you are enrolled every margin above
  is understated — the conservative direction.

## Tips

Consumables at $2.99 / $5.99 / $10.99 / $24.99. Apple keeps 30%; there is no
cost to serve them. Always profitable.
