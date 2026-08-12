-- Comment votes for the public forum — the piece that makes it read like
-- Reddit rather than a flat message board.
--
-- Run AFTER docs/public_forum.sql. Safe to re-run.
--
-- Posts have had up/down votes since the forum shipped; comments never did,
-- so a good answer three replies deep had no way to rise above a bad one at
-- the top. This adds the same shape one level down: one row per voter per
-- comment, a definer tally, and a phone-free view the client reads.
--
-- The author's phone is protected exactly as it is for comments themselves —
-- the vote table is never readable by a client at all, and the comments view
-- carries every column but author_phone.

create table if not exists public.public_forum_comment_votes (
  comment_id   text not null
    references public.public_forum_comments(id) on delete cascade,
  voter_phone  text not null,
  -- 1 or -1. A withdrawn vote is a deleted row, not a zero, so the tally
  -- never has to filter and an index stays useful.
  dir          smallint not null check (dir in (-1, 1)),
  created_at   timestamptz not null default now(),
  primary key (comment_id, voter_phone)
);

create index if not exists public_forum_comment_votes_comment_idx
  on public.public_forum_comment_votes (comment_id);

alter table public.public_forum_comment_votes enable row level security;

-- WHO voted is nobody's business but the voter's, so there is no read policy
-- and no select grant. The only way anyone learns anything about these rows
-- is the aggregate below, and their own row through the insert/delete
-- policies.
revoke select on table public.public_forum_comment_votes
  from anon, authenticated;
grant insert, delete, update on table public.public_forum_comment_votes
  to authenticated;

drop policy if exists public_forum_comment_votes_own
  on public.public_forum_comment_votes;
-- Vote as yourself or not at all. A silenced (timed-out) account cannot vote,
-- the same rule its posts and comments follow.
create policy public_forum_comment_votes_own
  on public.public_forum_comment_votes
  for all to authenticated
  using (voter_phone = (auth.jwt() ->> 'phone'))
  with check (
    voter_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(voter_phone)
  );

-- Own-row reads, so a device can show which way it voted. Scoped to the
-- caller's own rows; it reveals nobody else.
drop policy if exists public_forum_comment_votes_read_own
  on public.public_forum_comment_votes;
create policy public_forum_comment_votes_read_own
  on public.public_forum_comment_votes
  for select to authenticated
  using (voter_phone = (auth.jwt() ->> 'phone'));
grant select on table public.public_forum_comment_votes to authenticated;

-- The tally. Definer so it can read the whole table while clients cannot,
-- which is what lets a score exist without exposing who cast it.
create or replace function public.public_forum_comment_score(c text)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(v.dir), 0)::int
    from public.public_forum_comment_votes v
   where v.comment_id = c;
$$;

-- Named explicitly. Supabase's default privileges grant EXECUTE on every new
-- function in `public` to anon and authenticated outright, and revoking the
-- PUBLIC pseudo-role does NOT remove those — a lesson this project learned
-- the hard way with find_people_by_hashes. Reading a score is fine for both,
-- so both are granted deliberately rather than by accident.
grant execute on function public.public_forum_comment_score(text)
  to anon, authenticated;

-- The phone-free comments view the client reads. Same posture as the posts
-- view: every column except author_phone, plus the tally. security_invoker
-- keeps the caller's own RLS in force — every other view in this project has
-- it; this one was created without it, which meant `public_forum_comments_v`
-- ran as the view's OWNER rather than the querying role, silently bypassing
-- `public_forum_comments_read`'s ban-hiding (`not is_locked_out(author_phone)`)
-- — a banned author's comments were readable through the view the whole time,
-- caught by Supabase's own security advisor rather than by check_sql.sh.
create or replace view public.public_forum_comments_v
with (security_invoker = on) as
  select
    c.id,
    c.post_id,
    c.author_username,
    c.author_name,
    c.author_verified,
    c.body,
    c.gif_url,
    c.parent_id,
    c.created_at,
    public.public_forum_comment_score(c.id) as score
  from public.public_forum_comments c;

grant select on public.public_forum_comments_v to anon, authenticated;
