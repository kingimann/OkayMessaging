-- Server-side rate limit for Okay AI (2026-08-06). Real cost control on top of
-- the client's free-tier UX: a per-caller daily message count the `ai-chat`
-- Edge Function checks BEFORE calling OpenRouter, so a modified client can't
-- run the token bill past the cap.
--
-- Written ONLY by the `ai-chat` function through `ai_note_usage` (service
-- role). No client grants at all — a client can neither read another caller's
-- usage nor reset its own. The cap itself is the function's `AI_DAILY_CAP`
-- env var; this just keeps the tally.
--
-- Run this in the SQL editor. Until it exists the function fails OPEN (no
-- limit), so a missing migration never breaks the assistant — it just leaves
-- the ceiling off.
-- ---------------------------------------------------------------------------

create table if not exists public.ai_usage (
  usage_key text not null,   -- the caller: their phone, or an IP fallback
  day       date not null default current_date,
  count     int  not null default 0,
  primary key (usage_key, day)
);

alter table public.ai_usage enable row level security;
revoke all on table public.ai_usage from anon, authenticated;

-- Atomically bump today's count for a caller and return the new value. The
-- function checks it against the cap; the increment is harmless for a refused
-- request because the refusal happens before any model call, so no tokens are
-- spent — the counter simply keeps climbing while every over-cap request is
-- turned away.
create or replace function public.ai_note_usage(k text)
returns int
language sql
volatile
security definer
set search_path = public
as $$
  insert into public.ai_usage (usage_key, day, count)
  values (k, current_date, 1)
  on conflict (usage_key, day)
    do update set count = public.ai_usage.count + 1
  returning count;
$$;

-- Only the service role (the Edge Function) may call it — never a client.
-- Postgres grants EXECUTE to PUBLIC on a new function, so revoke that too, or
-- anon/authenticated inherit it no matter what the named revokes say.
revoke execute on function public.ai_note_usage(text)
  from public, anon, authenticated;
