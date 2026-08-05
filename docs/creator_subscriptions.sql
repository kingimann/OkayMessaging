-- Creator subscriptions (2026-08-05): a creator may publish subscribers-only
-- posts to the public feed, and a reader pays a monthly pass to read them.
--
-- WHY ACCESS-CONTROL, NOT END-TO-END SEALING. The public feed is world-readable
-- and SERVER-MODERATED (every post's text is screened). A paid post is therefore
-- gated by ACCESS, not sealed: a sealed body could never be screened, and
-- unscreenable pay-walled content is exactly the abuse vector that has burned
-- other creator platforms. True sealing is reserved for paid SERVERS, whose feed
-- is already private by design. So the public row carries only a teaser; the
-- real text lives in `public_paid_bodies`, which NOTHING may select directly —
-- `public_paid_body()` is the one door, and it opens only for the author or an
-- account holding an active pass.
--
-- WHY THE CLIENT CANNOT GRANT ITSELF A PASS. The entitlement in
-- `creator_subscriptions` is written ONLY by the `creator-subscribe` Edge
-- Function, which verifies the App Store receipt first (the same trust model as
-- the storage subscription). There are no client-facing writes on that table.
--
-- Idempotent: safe to run more than once. Apply after docs/public_feed.sql
-- (it extends public_posts and the public_feed view, both defined there).

-- ---------------------------------------------------------------------------
-- 1. Post columns: whether it's a paid post, and the monthly price.
-- ---------------------------------------------------------------------------
-- sub_cents is denormalised onto the row so the locked card can show a price
-- to a stranger who holds no profile for the creator.
alter table public.public_posts
  add column if not exists paid boolean not null default false;
alter table public.public_posts
  add column if not exists sub_cents int not null default 0;

-- The feed view reads by COLUMN grant (author_phone is deliberately withheld),
-- so a new column the view returns has to be granted here too, or it reads back
-- null with nothing to say why.
grant select (paid, sub_cents) on public.public_posts to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The feed view, now carrying paid + sub_cents.
-- ---------------------------------------------------------------------------
-- The `body` it returns is already the public teaser for a paid post — the
-- composer writes only the teaser to public_posts.body and the real text to
-- public_paid_bodies below — so the private text never enters this view.
create or replace view public.public_feed
with (security_invoker = on) as
select
  p.id,
  p.author_username,
  p.author_name,
  p.author_verified,
  p.body,
  p.reply_to,
  p.repost_of,
  p.image_path,
  p.gif_url,
  p.video_path,
  p.poll_options,
  p.poll_closes_at,
  p.created_at,
  p.view_count,
  public.public_post_like_count(p.id)   as like_count,
  public.public_post_reply_count(p.id)  as reply_count,
  public.public_post_repost_count(p.id) as repost_count,
  public.public_post_vote_counts(p.id)  as poll_votes,
  public.public_post_spark_count(p.id)  as spark_count,
  public.public_post_spark_cents(p.id)  as spark_cents,
  p.paid,
  p.sub_cents
from public.public_posts p;

grant select on public.public_feed to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The paid bodies — the private text, readable by nobody directly.
-- ---------------------------------------------------------------------------
create table if not exists public.public_paid_bodies (
  post_id      text primary key
                 references public.public_posts(id) on delete cascade,
  author_phone text not null,
  body         text not null,
  created_at   timestamptz not null default now()
);

alter table public.public_paid_bodies enable row level security;

-- Take back the table-wide SELECT Supabase grants every new public table: the
-- whole point of this table is that its body is never world-readable. The
-- security-definer reader below bypasses this; a direct `select body` does not.
revoke select on table public.public_paid_bodies from anon, authenticated;
-- No update or delete for anyone — a paid body swapped under readers who
-- already paid is the same trick as editing a public post after the fact.
revoke update, delete on table public.public_paid_bodies from anon, authenticated;
grant insert on public.public_paid_bodies to authenticated;

-- A creator inserts only their OWN row, vouched by the JWT phone.
drop policy if exists paid_bodies_insert on public.public_paid_bodies;
create policy paid_bodies_insert on public.public_paid_bodies
  for insert to authenticated
  with check (author_phone = (auth.jwt() ->> 'phone'));

-- ---------------------------------------------------------------------------
-- 4. The passes. Both ends by phone (like follows); NO client grants at all —
--    the entitlement is written only by the receipt-verifying edge function
--    (service role, which bypasses RLS), and read only through the functions
--    below. last_txn_id dedupes a receipt so one purchase grants one month.
-- ---------------------------------------------------------------------------
create table if not exists public.creator_subscriptions (
  subscriber_phone text not null,
  creator_phone    text not null,
  expires_at       timestamptz not null,
  product_id       text not null default '',
  last_txn_id      text not null default '',
  updated_at       timestamptz not null default now(),
  primary key (subscriber_phone, creator_phone)
);

alter table public.creator_subscriptions enable row level security;
revoke all on table public.creator_subscriptions from anon, authenticated;

-- One row per consumed receipt, so the same signed transaction can't be
-- replayed to buy a month of a dozen different creators.
create table if not exists public.creator_sub_receipts (
  txn_id     text primary key,
  created_at timestamptz not null default now()
);
alter table public.creator_sub_receipts enable row level security;
revoke all on table public.creator_sub_receipts from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Read gates (security definer — the only doors).
-- ---------------------------------------------------------------------------

-- The one door to a paid body: the author, or an account with an active pass.
-- Anyone else (or anon, which has no phone) gets null.
create or replace function public.public_paid_body(p text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me     text := (auth.jwt() ->> 'phone');
  author text;
  txt    text;
begin
  select author_phone, body into author, txt
    from public.public_paid_bodies where post_id = p;
  if author is null then return null; end if;
  if me is not null and me = author then return txt; end if;
  if me is null then return null; end if;
  if exists (
    select 1 from public.creator_subscriptions s
     where s.subscriber_phone = me
       and s.creator_phone = author
       and s.expires_at > now()
  ) then
    return txt;
  end if;
  return null;
end;
$$;

-- Whether the caller holds an active pass to a creator (by handle).
create or replace function public.creator_sub_active(u text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.creator_subscriptions s
      join public.usernames t on t.phone = s.creator_phone
     where s.subscriber_phone = (auth.jwt() ->> 'phone')
       and lower(t.username) = lower(u)
       and s.expires_at > now()
  );
$$;

-- The caller's own active passes — creator handle + expiry — for reconciling
-- the local list on start. Only ever your own rows; no phone ever returned.
create or replace function public.creator_my_subs()
returns table(creator text, expires_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select t.username, s.expires_at
    from public.creator_subscriptions s
    join public.usernames t on t.phone = s.creator_phone
   where s.subscriber_phone = (auth.jwt() ->> 'phone')
     and s.expires_at > now();
$$;

-- How many active subscribers a creator has, for their own dashboard. A count
-- only — who is subscribed is nobody's business but the counter's.
create or replace function public.creator_subscribers_count(u text)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select count(*)
    from public.creator_subscriptions s
    join public.usernames t on t.phone = s.creator_phone
   where lower(t.username) = lower(u)
     and s.expires_at > now();
$$;

grant execute on function public.public_paid_body(text) to anon, authenticated;
grant execute on function public.creator_sub_active(text) to authenticated;
grant execute on function public.creator_my_subs() to authenticated;
grant execute on function public.creator_subscribers_count(text)
  to anon, authenticated;
