// The debit-card rules, pure so they can be executed without Stripe.
//
// WHY THESE EXIST. The debit card is where instant payouts LAND — whoever
// controls it walks away with the balance. The classic account-takeover
// drains in one motion: sign in, attach your own card, cash out in minutes.
// Two rules close it, both enforced server-side because a client-side rule
// is a suggestion:
//
//   * A newly attached card waits SEVEN BUSINESS DAYS before instant
//     payouts may land on it — long enough for the real owner to notice a
//     takeover and act, which is the entire point of the delay. Standard
//     bank payouts are untouched: they go to the bank account, which an
//     attacker's card swap does not redirect.
//   * Attaching cards too often locks the feature: the third card inside
//     thirty days is not somebody correcting a typo. The lock releases on
//     its own as the changes age out of the window.

export const CARD_HOLD_BUSINESS_DAYS = 7;
export const CARD_CHANGE_WINDOW_DAYS = 30;
export const CARD_CHANGE_LIMIT = 3;

/// Whole business days (Mon–Fri, UTC) elapsed from [from] to [to]. Partial
/// days do not count — "seven business days" must never round down to six
/// and a bit.
export function businessDaysBetween(from: Date, to: Date): number {
  if (to.getTime() <= from.getTime()) return 0;
  let days = 0;
  const cursor = new Date(Date.UTC(
    from.getUTCFullYear(),
    from.getUTCMonth(),
    from.getUTCDate(),
  ));
  const end = new Date(Date.UTC(
    to.getUTCFullYear(),
    to.getUTCMonth(),
    to.getUTCDate(),
  ));
  while (cursor.getTime() < end.getTime()) {
    cursor.setUTCDate(cursor.getUTCDate() + 1);
    const dow = cursor.getUTCDay();
    if (dow !== 0 && dow !== 6) days++;
  }
  return days;
}

/// The verdict on this account's card, from its attach history.
///
/// [attachedAts] is every recorded attach, any order. An account with no
/// recorded attaches is neither held nor locked: cards added before this
/// policy existed have already had their waiting period in the world.
export function cardPolicy(opts: { attachedAts: Date[]; now: Date }): {
  locked: boolean;
  held: boolean;
  businessDaysLeft: number;
} {
  const { attachedAts, now } = opts;
  const windowStart = now.getTime() -
    CARD_CHANGE_WINDOW_DAYS * 24 * 60 * 60 * 1000;
  const recent = attachedAts.filter((a) => a.getTime() > windowStart);
  const locked = recent.length >= CARD_CHANGE_LIMIT;
  if (attachedAts.length === 0) {
    return { locked, held: false, businessDaysLeft: 0 };
  }
  const latest = new Date(
    Math.max(...attachedAts.map((a) => a.getTime())),
  );
  const elapsed = businessDaysBetween(latest, now);
  const held = elapsed < CARD_HOLD_BUSINESS_DAYS;
  return {
    locked,
    held,
    businessDaysLeft: held ? CARD_HOLD_BUSINESS_DAYS - elapsed : 0,
  };
}
