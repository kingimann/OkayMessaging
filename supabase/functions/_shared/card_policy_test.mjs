// The card rules, executed. These decide whether a freshly attached card can
// drain a balance, so the boundaries have to be exact — a hold that is six
// days and a bit is not the seven the screen promised.
//
//     deno run --allow-read supabase/functions/_shared/card_policy_test.mjs

const {
  CARD_HOLD_BUSINESS_DAYS,
  CARD_CHANGE_LIMIT,
  businessDaysBetween,
  cardPolicy,
} = await import('./card_policy.ts');

let pass = 0, fail = 0;
const eq = (n, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  const ok = g === w;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${n}${ok ? '' : `  got ${g} want ${w}`}`);
  ok ? pass++ : fail++;
};

const d = (s) => new Date(s);

// --- business-day arithmetic ---
// Mon 2026-01-05 → Fri 2026-01-09 is four business days.
eq('mon to fri', businessDaysBetween(d('2026-01-05'), d('2026-01-09')), 4);
// Fri → Mon crosses a weekend and is one business day.
eq('fri to mon', businessDaysBetween(d('2026-01-09'), d('2026-01-12')), 1);
// Same day is zero, and so is going backwards.
eq('same day', businessDaysBetween(d('2026-01-05'), d('2026-01-05')), 0);
eq('backwards', businessDaysBetween(d('2026-01-09'), d('2026-01-05')), 0);
// A partial eighth day still counts the seventh as complete.
eq('partial days do not round up',
  businessDaysBetween(d('2026-01-05T23:00:00Z'), d('2026-01-14T01:00:00Z')), 7);

// --- the hold ---
// Attached Monday the 5th: Wednesday the 14th is the seventh business day.
eq('held on day six',
  cardPolicy({ attachedAts: [d('2026-01-05')], now: d('2026-01-13') }).held,
  true);
eq('six leaves one day',
  cardPolicy({ attachedAts: [d('2026-01-05')], now: d('2026-01-13') })
    .businessDaysLeft,
  1);
eq('free on day seven',
  cardPolicy({ attachedAts: [d('2026-01-05')], now: d('2026-01-14') }).held,
  false);
// A weekend inside the window does not shorten it.
eq('weekends do not count toward the hold',
  cardPolicy({ attachedAts: [d('2026-01-09')], now: d('2026-01-16') }).held,
  true);

// --- legacy cards ---
// No recorded attach: added before the policy existed, already waited in
// the world. Not held, not locked.
eq('legacy card is not held',
  cardPolicy({ attachedAts: [], now: d('2026-01-05') }),
  { locked: false, held: false, businessDaysLeft: 0 });

// --- the change lock ---
const burst = [d('2026-01-01'), d('2026-01-10'), d('2026-01-20')];
eq('third change in thirty days locks',
  cardPolicy({ attachedAts: burst, now: d('2026-01-21') }).locked, true);
eq('two changes do not',
  cardPolicy({ attachedAts: burst.slice(1), now: d('2026-01-21') }).locked,
  false);
// The lock releases as changes age past the window.
eq('the lock ages out',
  cardPolicy({ attachedAts: burst, now: d('2026-02-15') }).locked, false);
// The most recent attach still holds even while locked.
eq('locked is also held while fresh',
  cardPolicy({ attachedAts: burst, now: d('2026-01-21') }).held, true);

eq('constants say what the screens promise',
  [CARD_HOLD_BUSINESS_DAYS, CARD_CHANGE_LIMIT], [7, 3]);

console.log(`card_policy: ${pass} passed, ${fail} failed`);
if (fail > 0) Deno.exit(1);
