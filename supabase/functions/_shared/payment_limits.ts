// The numbers a transfer is checked against, and what changing one does.
//
// Kept here rather than inside the functions because these are the rules, and
// rules that nobody runs drift. `payment_limits_test.mjs` executes every branch
// below without Supabase in the picture — this file is pure: no I/O, no Deno
// globals, no clock of its own (callers pass `nowMs`).

/// What may leave an account in a rolling 24 hours when it has never chosen.
export const DEFAULT_DAILY_LIMIT_CENTS = 50000; // $500

/// The ceiling on the ceiling. An account may not hand itself a bigger day
/// than this, whatever it asks for.
export const MAX_DAILY_LIMIT_CENTS = 200000; // $2,000

/// The largest a single transfer may be. Same ceiling, different question:
/// a day's worth of small mistakes and one big one are not the same failure.
export const MAX_PER_SEND_CENTS = 200000;

/// Zero means "no cap of this kind" — never "nothing may be sent". Both limits
/// use it, so the two read the same way, and so lifting a cap sorts as the
/// loosening it is rather than as the tightest possible setting.
const NO_CAP = 0;

/// Loosening a limit waits this long before it means anything. Tightening one
/// is immediate.
///
/// Without this the limits are advice. Someone holding an unlocked phone holds
/// the session too, so they can call payments-settings and raise the day to its
/// ceiling before sending — the limit stops nothing it was written to stop.
/// With the delay, what they can move is whatever the owner chose while calm.
export const RAISE_DELAY_MS = 24 * 60 * 60 * 1000;

/// The `payment_settings` columns this file cares about.
export interface LimitRow {
  daily_send_limit_cents?: number | null;
  max_send_cents?: number | null;
  pending_daily_send_limit_cents?: number | null;
  pending_daily_effective_at?: string | null;
  pending_max_send_cents?: number | null;
  pending_max_effective_at?: string | null;
}

/// A raise that has been asked for but has not arrived yet.
export interface PendingLimit {
  cents: number;
  at: string;
}

export interface EffectiveLimits {
  dailyCents: number;
  maxSendCents: number;
  pendingDaily: PendingLimit | null;
  pendingMax: PendingLimit | null;
}

/// Ordering that understands zero. A cap of 0 is no cap, so it sorts above
/// every real number rather than below all of them.
function rank(cents: number): number {
  return cents <= NO_CAP ? Infinity : cents;
}

function clamp(cents: number, ceiling: number): number {
  return Math.min(Math.max(Math.round(cents), 0), ceiling);
}

/// A number that can be a limit. `typeof x === "number"` is true of NaN and of
/// Infinity, and clamping either one lands on zero — which means *no cap*, so
/// the worst possible input would quietly buy the most permissive setting.
/// Garbage is ignored instead.
function asked(cents: number | undefined): cents is number {
  return typeof cents === "number" && Number.isFinite(cents);
}

/// Whether a pending value has come due. A row with no timestamp has nothing
/// pending; an unparseable one is treated as not due, which errs toward the
/// tighter number.
function due(at: string | null | undefined, nowMs: number): boolean {
  if (!at) return false;
  const t = Date.parse(at);
  return Number.isFinite(t) && t <= nowMs;
}

/// What the limits actually are right now, matured raises included.
///
/// Maturing is computed, not written: a raise takes effect on the first read
/// after its moment passes, so nothing depends on a job having run.
export function effectiveLimits(
  row: LimitRow | null | undefined,
  nowMs: number,
): EffectiveLimits {
  const r = row ?? {};

  let dailyCents = r.daily_send_limit_cents ?? DEFAULT_DAILY_LIMIT_CENTS;
  let pendingDaily: PendingLimit | null = null;
  if (r.pending_daily_effective_at != null &&
      r.pending_daily_send_limit_cents != null) {
    if (due(r.pending_daily_effective_at, nowMs)) {
      dailyCents = r.pending_daily_send_limit_cents;
    } else {
      pendingDaily = {
        cents: r.pending_daily_send_limit_cents,
        at: r.pending_daily_effective_at,
      };
    }
  }

  let maxSendCents = r.max_send_cents ?? NO_CAP;
  let pendingMax: PendingLimit | null = null;
  if (r.pending_max_effective_at != null && r.pending_max_send_cents != null) {
    if (due(r.pending_max_effective_at, nowMs)) {
      maxSendCents = r.pending_max_send_cents;
    } else {
      pendingMax = {
        cents: r.pending_max_send_cents,
        at: r.pending_max_effective_at,
      };
    }
  }

  return { dailyCents, maxSendCents, pendingDaily, pendingMax };
}

export interface LimitRequest {
  dailySendLimitCents?: number;
  maxSendCents?: number;
}

/// The columns to write for a requested change.
///
/// A tightening lands in the live column and clears any raise still waiting —
/// so asking for the number you already have is how you call off a raise you
/// changed your mind about. A loosening lands in the pending column with the
/// moment it starts counting.
export function limitPatch(
  row: LimitRow | null | undefined,
  req: LimitRequest,
  nowMs: number,
): Record<string, unknown> {
  const now = effectiveLimits(row, nowMs);
  const patch: Record<string, unknown> = {};
  const effectiveAt = new Date(nowMs + RAISE_DELAY_MS).toISOString();

  if (asked(req.dailySendLimitCents)) {
    const next = clamp(req.dailySendLimitCents, MAX_DAILY_LIMIT_CENTS);
    if (rank(next) > rank(now.dailyCents)) {
      // Asking again for the raise already waiting must not restart its clock,
      // or a second tap costs another day and looks like nothing happened.
      if (now.pendingDaily?.cents !== next) {
        patch.pending_daily_send_limit_cents = next;
        patch.pending_daily_effective_at = effectiveAt;
      }
    } else {
      patch.daily_send_limit_cents = next;
      patch.pending_daily_send_limit_cents = null;
      patch.pending_daily_effective_at = null;
    }
  }

  if (asked(req.maxSendCents)) {
    const next = clamp(req.maxSendCents, MAX_PER_SEND_CENTS);
    if (rank(next) > rank(now.maxSendCents)) {
      if (now.pendingMax?.cents !== next) {
        patch.pending_max_send_cents = next;
        patch.pending_max_effective_at = effectiveAt;
      }
    } else {
      patch.max_send_cents = next;
      patch.pending_max_send_cents = null;
      patch.pending_max_effective_at = null;
    }
  }

  return patch;
}

/// Why a transfer is being refused, or null if nothing here refuses it.
///
/// `spentCents` is what has already left in the rolling window; the caller sums
/// it, because only the caller knows which rows counted.
export function refusalFor(
  limits: EffectiveLimits,
  amountCents: number,
  spentCents: number,
): { error: string; limitCents: number; spentCents?: number } | null {
  if (limits.maxSendCents > NO_CAP && amountCents > limits.maxSendCents) {
    return { error: "over_send_limit", limitCents: limits.maxSendCents };
  }
  if (limits.dailyCents > NO_CAP &&
      spentCents + amountCents > limits.dailyCents) {
    return {
      error: "daily_limit_reached",
      limitCents: limits.dailyCents,
      spentCents,
    };
  }
  return null;
}
