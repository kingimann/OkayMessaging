-- Promoted posts (2026-08-18): a user pays to have one of their own public
-- posts carried further up the timeline, labelled as an ad.
--
-- The owner's ask was "a custom ad system... so I can allow users to pay to
-- advertise their post". This is that: the app's OWN ad inventory, sold to
-- its own users, separate from the AdMob banners that already run on the two
-- public surfaces.
--
-- WHY THE CLIENT CANNOT PROMOTE ITSELF. There are no client writes on
-- `post_promotions` at all. The row is written ONLY by the `promote-post`
-- Edge Function, which verifies the App Store receipt (JWS) first and dedupes
-- the transaction — the same trust model as creator subscriptions and the
-- storage subscription. A modified client can change what it DRAWS; it cannot
-- buy itself reach.
--
-- WHY IT IS READ THROUGH A VIEW WITH NO PHONE. A promotion names the account
-- that paid for it, and the phone-hiding rule every public table here follows
-- applies: the table-wide select is revoked, every column but `promoter_phone`
-- is granted back, and clients read `promoted_posts_view`. A buyer of ad space
-- is not thereby publishing their phone number.
--
-- WHY A SANCTIONED ACCOUNT'S PROMOTION DISAPPEARS. `content_visible` is the
-- same gate the public feed itself uses, so a shadow-banned promoter's paid
-- placement is visible to them and nobody else — a ban that money could buy
-- its way past would not be a ban.
--
-- Idempotent: safe to run more than once. Apply AFTER
-- docs/moderation_scopes.sql — the read policy calls `content_visible`, and a
-- policy body is parsed at creation, so applying this first fails with
-- "function content_visible(text) does not exist" rather than quietly
-- deferring. (`check_sql.sh` caught exactly that; it is the same class as the
-- functions-above-their-tables bug this repo has hit before.)

-- ---------------------------------------------------------------------------
-- 1. The promotions table.
-- ---------------------------------------------------------------------------
create table if not exists public.post_promotions (
  post_id        text primary key,
  promoter_phone text not null,
  -- When the placement stops. Extended, never duplicated: buying again while
  -- one is running stacks onto whatever is left, the same as every 30-day
  -- pass in this app.
  until          timestamptz not null,
  -- What has been spent on this placement, for the promoter's own screen.
  -- Never used to rank: paying more buys more DAYS, not a better slot, so
  -- there is no auction to game and no reason to read this at serve time.
  spent_cents    int not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

alter table public.post_promotions enable row level security;

-- The default grants Supabase gives a NEW table reach `anon` explicitly, and
-- revoking the PUBLIC pseudo-role does not take them away — the lesson from
-- find_people_by_hashes. Name the roles.
revoke all on table public.post_promotions from anon, authenticated;
grant select (post_id, until, spent_cents, created_at, updated_at)
  on public.post_promotions to anon, authenticated;

-- Readable by everyone, because everyone has to agree on which post is an ad
-- — a promotion nobody but the buyer could see would be a placement that
-- never ran. Sanctioned promoters are filtered here rather than in the view,
-- so a direct column-select cannot see round it.
drop policy if exists post_promotions_read on public.post_promotions;
create policy post_promotions_read on public.post_promotions
  for select to anon, authenticated
  using (content_visible(promoter_phone));

-- No insert/update/delete policy of ANY kind: the Edge Function runs as the
-- table owner and is the only writer. This is not an omission.

create index if not exists post_promotions_until_idx
  on public.post_promotions (until desc);

-- ---------------------------------------------------------------------------
-- 2. Receipt dedupe — one App Store transaction buys one placement.
-- ---------------------------------------------------------------------------
create table if not exists public.promote_receipts (
  txn_id     text primary key,
  created_at timestamptz not null default now()
);
alter table public.promote_receipts enable row level security;
revoke all on table public.promote_receipts from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The phone-free view every client reads.
-- ---------------------------------------------------------------------------
-- security_invoker so the read policy above actually applies — the one thing
-- `public_forum_comments_v` was missing, which silently bypassed ban-hiding
-- until Supabase's own advisor caught it.
create or replace view public.promoted_posts_view
with (security_invoker = on) as
select
  p.post_id,
  p.until,
  p.created_at
from public.post_promotions p
where p.until > now();

grant select on public.promoted_posts_view to anon, authenticated;
