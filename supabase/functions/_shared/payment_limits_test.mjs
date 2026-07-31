// The limit rules, executed. These decide whether somebody's money moves, and
// the delay on a raise is only real if the branch that schedules it runs.
//
//     deno run --allow-read supabase/functions/_shared/payment_limits_test.mjs

const {
  DEFAULT_DAILY_LIMIT_CENTS,
  MAX_DAILY_LIMIT_CENTS,
  MAX_PER_SEND_CENTS,
  RAISE_DELAY_MS,
  effectiveLimits,
  limitPatch,
  refusalFor,
} = await import('./payment_limits.ts');

let pass = 0, fail = 0;
const eq = (n, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  const ok = g === w;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${n}${ok ? '' : `  got ${g} want ${w}`}`);
  ok ? pass++ : fail++;
};

const NOW = Date.parse('2026-01-01T00:00:00.000Z');
const LATER = new Date(NOW + RAISE_DELAY_MS).toISOString();
const iso = (ms) => new Date(ms).toISOString();

// --- an account that has never chosen ---
eq('default day', effectiveLimits(null, NOW).dailyCents, DEFAULT_DAILY_LIMIT_CENTS);
eq('no per-send cap by default', effectiveLimits(null, NOW).maxSendCents, 0);
eq('missing row is the same as an empty one',
  effectiveLimits(undefined, NOW), effectiveLimits({}, NOW));

// --- stored values win over the defaults ---
eq('stored day', effectiveLimits({ daily_send_limit_cents: 10000 }, NOW).dailyCents, 10000);
eq('stored per-send', effectiveLimits({ max_send_cents: 2500 }, NOW).maxSendCents, 2500);
eq('a stored zero is no cap, not a stop',
  effectiveLimits({ daily_send_limit_cents: 0 }, NOW).dailyCents, 0);

// --- a raise that has not arrived yet ---
const waiting = {
  daily_send_limit_cents: 10000,
  pending_daily_send_limit_cents: 100000,
  pending_daily_effective_at: iso(NOW + 60_000),
};
eq('a waiting raise does not apply', effectiveLimits(waiting, NOW).dailyCents, 10000);
eq('a waiting raise is reported',
  effectiveLimits(waiting, NOW).pendingDaily,
  { cents: 100000, at: iso(NOW + 60_000) });
eq('a raise applies the moment it is due',
  effectiveLimits(waiting, NOW + 60_000).dailyCents, 100000);
eq('a matured raise stops being pending',
  effectiveLimits(waiting, NOW + 60_000).pendingDaily, null);
eq('a raise applies long after it is due',
  effectiveLimits(waiting, NOW + 999_999_999).dailyCents, 100000);
eq('an unparseable moment never arrives',
  effectiveLimits({ ...waiting, pending_daily_effective_at: 'soon' }, NOW).dailyCents,
  10000);
eq('a timestamp with no value behind it is ignored',
  effectiveLimits({ pending_daily_effective_at: iso(NOW - 1) }, NOW).dailyCents,
  DEFAULT_DAILY_LIMIT_CENTS);

const waitingMax = {
  max_send_cents: 5000,
  pending_max_send_cents: 50000,
  pending_max_effective_at: iso(NOW + 60_000),
};
eq('a waiting per-send raise does not apply',
  effectiveLimits(waitingMax, NOW).maxSendCents, 5000);
eq('a due per-send raise applies',
  effectiveLimits(waitingMax, NOW + 60_000).maxSendCents, 50000);

// --- tightening is immediate, loosening waits ---
eq('lowering the day applies at once',
  limitPatch({ daily_send_limit_cents: 50000 }, { dailySendLimitCents: 10000 }, NOW),
  { daily_send_limit_cents: 10000, pending_daily_send_limit_cents: null,
    pending_daily_effective_at: null });
eq('raising the day is scheduled',
  limitPatch({ daily_send_limit_cents: 10000 }, { dailySendLimitCents: 50000 }, NOW),
  { pending_daily_send_limit_cents: 50000, pending_daily_effective_at: LATER });
eq('the first choice from the default is measured against the default',
  limitPatch(null, { dailySendLimitCents: 100000 }, NOW),
  { pending_daily_send_limit_cents: 100000, pending_daily_effective_at: LATER });
eq('choosing less than the default applies at once',
  limitPatch(null, { dailySendLimitCents: 5000 }, NOW),
  { daily_send_limit_cents: 5000, pending_daily_send_limit_cents: null,
    pending_daily_effective_at: null });
eq('setting the day to what it already is clears a waiting raise',
  limitPatch(waiting, { dailySendLimitCents: 10000 }, NOW),
  { daily_send_limit_cents: 10000, pending_daily_send_limit_cents: null,
    pending_daily_effective_at: null });
eq('removing the day cap entirely is a raise, so it waits',
  limitPatch({ daily_send_limit_cents: 10000 }, { dailySendLimitCents: 0 }, NOW),
  { pending_daily_send_limit_cents: 0, pending_daily_effective_at: LATER });
eq('putting a cap on an uncapped day applies at once',
  limitPatch({ daily_send_limit_cents: 0 }, { dailySendLimitCents: 10000 }, NOW),
  { daily_send_limit_cents: 10000, pending_daily_send_limit_cents: null,
    pending_daily_effective_at: null });
eq('a raise measured against a raise still waiting uses the live number',
  limitPatch(waiting, { dailySendLimitCents: 20000 }, NOW),
  { pending_daily_send_limit_cents: 20000, pending_daily_effective_at: LATER });
// Asking twice for the same raise must not restart the clock — a second tap
// would silently cost another day.
eq('asking again for the raise already waiting changes nothing',
  limitPatch(waiting, { dailySendLimitCents: 100000 }, NOW + 30_000), {});
eq('asking again for the waiting per-send raise changes nothing',
  limitPatch(waitingMax, { maxSendCents: 50000 }, NOW + 30_000), {});
eq('a different raise does restart the clock',
  limitPatch(waiting, { dailySendLimitCents: 150000 }, NOW),
  { pending_daily_send_limit_cents: 150000, pending_daily_effective_at: LATER });
eq('lowering the per-send cap applies at once',
  limitPatch({ max_send_cents: 50000 }, { maxSendCents: 5000 }, NOW),
  { max_send_cents: 5000, pending_max_send_cents: null,
    pending_max_effective_at: null });
eq('putting the first per-send cap on applies at once',
  limitPatch(null, { maxSendCents: 5000 }, NOW),
  { max_send_cents: 5000, pending_max_send_cents: null,
    pending_max_effective_at: null });
eq('raising the per-send cap is scheduled',
  limitPatch({ max_send_cents: 5000 }, { maxSendCents: 50000 }, NOW),
  { pending_max_send_cents: 50000, pending_max_effective_at: LATER });
eq('lifting the per-send cap is scheduled',
  limitPatch({ max_send_cents: 5000 }, { maxSendCents: 0 }, NOW),
  { pending_max_send_cents: 0, pending_max_effective_at: LATER });
eq('asking for nothing writes nothing', limitPatch(null, {}, NOW), {});
eq('both limits at once', limitPatch(
  { daily_send_limit_cents: 50000, max_send_cents: 5000 },
  { dailySendLimitCents: 10000, maxSendCents: 50000 }, NOW),
  { daily_send_limit_cents: 10000, pending_daily_send_limit_cents: null,
    pending_daily_effective_at: null,
    pending_max_send_cents: 50000, pending_max_effective_at: LATER });

// --- the ceilings, and values that are not numbers ---
eq('the day is capped at the ceiling',
  limitPatch({ daily_send_limit_cents: 0 }, { dailySendLimitCents: 9_999_999 }, NOW)
    .daily_send_limit_cents,
  MAX_DAILY_LIMIT_CENTS);
eq('the per-send cap is capped at the ceiling',
  limitPatch({ max_send_cents: 1 }, { maxSendCents: 9_999_999 }, NOW)
    .pending_max_send_cents,
  MAX_PER_SEND_CENTS);
eq('a negative day is zero, not a negative limit',
  limitPatch({ daily_send_limit_cents: 100 }, { dailySendLimitCents: -5 }, NOW)
    .pending_daily_send_limit_cents,
  0);
eq('fractions of a cent are rounded',
  limitPatch(null, { dailySendLimitCents: 4999.6 }, NOW).daily_send_limit_cents, 5000);
// Infinity and NaN are both `typeof "number"`, and both clamp to zero — which
// means NO cap. Garbage must not be the way to the most permissive setting.
eq('an infinite request writes nothing',
  limitPatch({ daily_send_limit_cents: 100 }, { dailySendLimitCents: Infinity }, NOW),
  {});
eq('NaN writes nothing',
  limitPatch({ daily_send_limit_cents: 100 }, { dailySendLimitCents: NaN }, NOW), {});
eq('NaN on the per-send cap writes nothing',
  limitPatch({ max_send_cents: 100 }, { maxSendCents: NaN }, NOW), {});

// --- what refuses a transfer ---
const limits = (d, m) => ({ dailyCents: d, maxSendCents: m,
  pendingDaily: null, pendingMax: null });
eq('a transfer inside both limits passes',
  refusalFor(limits(50000, 10000), 5000, 1000), null);
eq('a transfer over the per-send cap is refused',
  refusalFor(limits(50000, 10000), 10001, 0),
  { error: 'over_send_limit', limitCents: 10000 });
eq('a transfer exactly at the per-send cap passes',
  refusalFor(limits(50000, 10000), 10000, 0), null);
eq('no per-send cap means no per-send refusal',
  refusalFor(limits(50000, 0), 50000, 0), null);
eq('the day is what is left, not what one transfer is',
  refusalFor(limits(50000, 0), 10000, 45000),
  { error: 'daily_limit_reached', limitCents: 50000, spentCents: 45000 });
eq('filling the day exactly passes',
  refusalFor(limits(50000, 0), 5000, 45000), null);
eq('no day cap means no daily refusal',
  refusalFor(limits(0, 0), 999999, 999999), null);
eq('the per-send cap is answered first',
  refusalFor(limits(50000, 1000), 40000, 45000).error, 'over_send_limit');

console.log(`${pass} passed, ${fail} failed`);
if (fail > 0) Deno.exit(1);
