#!/bin/sh
# Run the migrations against a real Postgres, then test what they enforce.
# =============================================================================
#     sh tool/check_sql.sh
#
# WHY THIS EXISTS. These files only ever ran in the Supabase dashboard, so the
# first reader was always a person pasting them, and two bugs shipped that way
# in one file:
#
#   * a SQL function's body is parsed at creation time, so functions placed
#     above the tables they read failed with "relation does not exist";
#   * `revoke select (col)` looks like it protects a column and does nothing
#     when the role holds a table-wide grant — which Supabase gives every new
#     table in public. Every poster's phone number was readable.
#
# Neither is visible by reading carefully. Both take seconds to catch here.
#
# Spins up a throwaway cluster in /tmp, applies a small Supabase-shaped harness
# (the anon/authenticated roles, an auth.jwt() stub, the default grants), then
# runs schema.sql and the migrations in order and asserts the security
# properties that matter.

set -e

PGBIN=/usr/lib/postgresql/16/bin
[ -d "$PGBIN" ] || PGBIN=$(dirname "$(command -v initdb 2>/dev/null || echo /nonexistent)")
if [ ! -x "$PGBIN/initdb" ]; then
  echo "postgres not installed — skipping SQL checks"
  echo "  (apt-get install -y postgresql to enable them)"
  exit 0
fi

DATA=/tmp/okay_pgdata
RUN=/tmp/okay_pgrun
PORT=5433
export PATH="$PGBIN:$PATH"

id pg >/dev/null 2>&1 || useradd -m pg
rm -rf "$DATA"; mkdir -p "$DATA" "$RUN"; chown -R pg "$DATA" "$RUN"

su pg -c "PATH=$PGBIN:\$PATH initdb -D $DATA -A trust" >/tmp/okay_initdb.log 2>&1
su pg -c "PATH=$PGBIN:\$PATH pg_ctl -D $DATA -o '-k $RUN -p $PORT -c listen_addresses=' -l /tmp/okay_pg.log start" >/dev/null 2>&1
trap 'su pg -c "PATH=$PGBIN:\$PATH pg_ctl -D $DATA -m immediate stop" >/dev/null 2>&1 || true' EXIT

# Wait for it rather than sleeping blind.
i=0
until su pg -c "PATH=$PGBIN:\$PATH pg_isready -h $RUN -p $PORT" >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 30 ] && { echo "postgres did not start"; cat /tmp/okay_pg.log; exit 1; }
  sleep 1
done

WORK=/tmp/okay_sqlcheck
rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/harness.sql" <<'SQL'
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end $$;
create schema if not exists auth;
create or replace function auth.jwt() returns jsonb
language sql stable as $$
  select coalesce(current_setting('request.jwt.claims', true), '{}')::jsonb;
$$;
grant usage on schema public, auth to anon, authenticated, service_role;
-- Supabase grants new public tables to these roles; the column checks below
-- only mean anything with this in place.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;

-- Enough of Supabase Storage for the bucket policies to apply.
create schema if not exists storage;
create table if not exists storage.buckets (
  id text primary key, name text, public boolean default false,
  file_size_limit bigint);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(), bucket_id text, name text,
  owner uuid, created_at timestamptz default now());
alter table storage.objects enable row level security;
grant usage on schema storage to anon, authenticated, service_role;
grant select, insert, update, delete on storage.objects to anon, authenticated;
grant select on storage.buckets to anon, authenticated;
SQL

# The assertions. Each raises on failure, so ON_ERROR_STOP fails the run.
cat > "$WORK/assert.sql" <<'SQL'
create or replace function pg_temp.expect_fail(stmt text, what text)
returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    raise notice '  ok   %', what;
    return;
  end;
  raise exception 'SECURITY CHECK FAILED: % was permitted', what;
end $$;

create or replace function pg_temp.expect_ok(stmt text, what text)
returns void language plpgsql as $$
begin
  execute stmt;
  raise notice '  ok   %', what;
exception when others then
  raise exception 'CHECK FAILED: % — %', what, sqlerrm;
end $$;

create or replace function pg_temp.as_user(p text) returns void
language sql as $$ select set_config('request.jwt.claims',
  json_build_object('phone', p)::text, false)::void; $$;

-- A banned account and a timed-out one.
insert into public.account_sanctions (phone, kind, reason) values
  ('15550009999', 'ban', 'test') on conflict (phone) do nothing;
insert into public.account_sanctions (phone, kind, until) values
  ('15550003333', 'timeout', now() + interval '1 hour')
  on conflict (phone) do nothing;

set role authenticated;
select pg_temp.as_user('15550001111');

select pg_temp.expect_ok(
  $$insert into public.public_posts (id, author_phone, author_username, body)
    values ('t_p1','15550001111','alice','hello')$$,
  'you can post as yourself');

select pg_temp.expect_fail(
  $$insert into public.public_posts (id, author_phone, author_username, body)
    values ('t_p2','15550002222','bob','impersonated')$$,
  'you cannot post as somebody else');

select pg_temp.expect_fail(
  $$select author_phone from public.public_posts$$,
  'a client cannot read an author phone');

select pg_temp.expect_fail(
  $$select * from public.public_posts$$,
  'select * is refused (it would include the phone)');

select pg_temp.expect_ok(
  $$select id, author_username, body, like_count, paid, sub_cents, edited_at
      from public.public_feed$$,
  'the feed view reads fine (incl. paid/sub_cents/edited_at — a '
  'security_invoker view fails wholesale if the caller lacks any column it '
  'selects)');

select pg_temp.expect_fail(
  $$select liker_phone from public.public_post_likes$$,
  'a client cannot read who liked something');

select pg_temp.expect_ok(
  $$insert into public.public_post_likes (post_id, liker_phone)
    values ('t_p1','15550001111')$$,
  'you can like a post');

select pg_temp.expect_fail(
  $$insert into public.public_post_likes (post_id, liker_phone)
    values ('t_p1','15550002222')$$,
  'you cannot like as somebody else');

-- WHO liked, as usernames. public_post_likers is the one window into the
-- likes table (a directory join): it must answer handles from anybody's
-- session, its shape must not even HAVE a phone column, and a hidden
-- (deactivated) account must leave the list.
reset role;
insert into public.usernames (phone, username, name)
  values ('15550001111','alice_dir','Alice') on conflict (phone) do update
  set username = excluded.username, name = excluded.name;
set role authenticated;
select pg_temp.as_user('15550002222');
do $$
declare n int; got text;
begin
  select count(*) into n from public.public_post_likers('t_p1');
  select username into got from public.public_post_likers('t_p1') limit 1;
  if n <> 1 or got is distinct from 'alice_dir' then
    raise exception 'SECURITY CHECK FAILED: who-liked answered % row(s), first %', n, got;
  end if;
  raise notice '  ok   who-liked answers usernames, from anybody''s session';
end $$;
select pg_temp.expect_fail(
  $$select liker_phone from public.public_post_likers('t_p1')$$,
  'the who-liked window has no phone column');
reset role;
update public.usernames set hidden = true where phone = '15550001111';
set role authenticated;
do $$ begin
  if (select count(*) from public.public_post_likers('t_p1')) <> 0 then
    raise exception 'SECURITY CHECK FAILED: a hidden account is still listed as a liker';
  end if;
  raise notice '  ok   a hidden account leaves the who-liked list';
end $$;
reset role;
update public.usernames set hidden = false where phone = '15550001111';
set role authenticated;
select pg_temp.as_user('15550001111');

-- Views: a tally with no viewer in it. The definer function is the only
-- door and adds exactly one; a direct write bounces off.
select pg_temp.expect_ok(
  $$select public.public_post_viewed('t_p1')$$,
  'a view can be counted');
do $$ begin
  if (select view_count from public.public_feed where id='t_p1') <> 1 then
    raise exception 'CHECK FAILED: the view did not count, or counted wrong';
  end if;
  raise notice '  ok   a view adds exactly one to the tally';
end $$;
do $$ begin
  begin
    update public.public_posts set view_count = 999 where id = 't_p1';
  exception when others then null; -- refused outright counts too
  end;
  if (select view_count from public.public_feed where id='t_p1') <> 1 then
    raise exception 'SECURITY CHECK FAILED: a client wrote the view tally directly';
  end if;
  raise notice '  ok   the view tally cannot be written directly';
end $$;
-- Deduped per viewer: the SAME reader opening the post again adds nothing.
select pg_temp.expect_ok(
  $$select public.public_post_viewed('t_p1')$$,
  'a repeat view is accepted (and quietly ignored)');
do $$ begin
  if (select view_count from public.public_feed where id='t_p1') <> 1 then
    raise exception 'SECURITY CHECK FAILED: a repeat view from one reader inflated the tally';
  end if;
  raise notice '  ok   a second view from the same reader adds nothing';
end $$;
-- A DIFFERENT reader does count: alice viewed above; now bob views.
select pg_temp.as_user('15550002222');
select pg_temp.expect_ok(
  $$select public.public_post_viewed('t_p1')$$, 'a new viewer is counted');
do $$ begin
  if (select view_count from public.public_feed where id='t_p1') <> 2 then
    raise exception 'CHECK FAILED: a distinct viewer did not add one';
  end if;
  raise notice '  ok   a distinct viewer adds exactly one';
end $$;
-- WHO viewed, as usernames — the author's window, same shape as who-liked:
-- handles only, no phone column, and the raw table is unreadable to a client.
select pg_temp.as_user('15550001111');
do $$
declare n int;
begin
  select count(*) into n from public.public_post_viewers('t_p1');
  if n <> 1 then
    raise exception 'CHECK FAILED: who-viewed answered % row(s), expected 1 (alice_dir has a handle)', n;
  end if;
  raise notice '  ok   who-viewed answers usernames';
end $$;
select pg_temp.expect_fail(
  $$select viewer_phone from public.public_post_viewers('t_p1')$$,
  'the who-viewed window has no phone column');
select pg_temp.expect_fail(
  $$select viewer_phone from public.public_post_views$$,
  'the views table itself is unreadable to a client');

-- Follows: the social graph keeps its phones to itself. The definer
-- functions are the only doors; both ends of an edge are stored by phone
-- so a rename never orphans it; the windows answer usernames only.
reset role;
insert into public.usernames (phone, username, name)
  values ('15550002222','bob_dir','Bob') on conflict (phone) do update
  set username = excluded.username, name = excluded.name;
set role authenticated;
select pg_temp.as_user('15550001111');
select pg_temp.expect_ok(
  $$select public.public_follow('bob_dir')$$, 'a follow can be made');
select public.public_follow('bob_dir'); -- twice: idempotent, not doubled
select public.public_follow('alice_dir'); -- yourself: refused silently
select public.public_follow('nobody_dir'); -- unknown handle: silent no-op
do $$
declare fs bigint; fg bigint;
begin
  select followers, following into fs, fg
    from public.public_follow_counts('bob_dir');
  if fs <> 1 then
    raise exception 'SECURITY CHECK FAILED: bob has % follower(s), not 1', fs;
  end if;
  select followers, following into fs, fg
    from public.public_follow_counts('alice_dir');
  if fg <> 1 or fs <> 0 then
    raise exception 'SECURITY CHECK FAILED: alice follows %, followed by %', fg, fs;
  end if;
  raise notice '  ok   follow counts once: no doubles, no self, no ghosts';
end $$;
do $$ begin
  if (select username from public.public_followers('bob_dir') limit 1)
      is distinct from 'alice_dir' then
    raise exception 'SECURITY CHECK FAILED: the follower list is wrong';
  end if;
  if (select username from public.public_following('alice_dir') limit 1)
      is distinct from 'bob_dir' then
    raise exception 'SECURITY CHECK FAILED: the following list is wrong';
  end if;
  raise notice '  ok   the follow windows answer usernames';
end $$;
select pg_temp.expect_fail(
  $$select follower_phone from public.public_followers('bob_dir')$$,
  'the follower window has no phone column');
select pg_temp.expect_fail(
  $$select * from public.public_follows$$,
  'the follows table itself is closed to clients');
-- Regression: the directory stores phones in E.164 (a leading '+'), but the
-- JWT's `phone` claim arrives WITHOUT it. A follower written straight from the
-- JWT could never join back to its own usernames row, so the FOLLOWING count
-- stayed 0. Carol's directory phone carries the '+'; her JWT does not.
reset role;
insert into public.usernames (phone, username, name)
  values ('+15550004444','carol_dir','Carol') on conflict (phone) do nothing;
set role authenticated;
select pg_temp.as_user('15550004444'); -- JWT: digits only, no '+'
select public.public_follow('bob_dir');
do $$
declare fg bigint;
begin
  select following into fg from public.public_follow_counts('carol_dir');
  if fg <> 1 then
    raise exception 'CHECK FAILED: E.164 follower not counted (following=%)', fg;
  end if;
  if (select username from public.public_following('carol_dir') limit 1)
      is distinct from 'bob_dir' then
    raise exception 'CHECK FAILED: E.164 follower missing from the window';
  end if;
  raise notice '  ok   a follower whose directory phone has a +'' still counts';
end $$;
-- Unfollow canonicalises the same way; this also restores bob to one follower
-- for the rename check below.
select public.public_unfollow('bob_dir');
do $$
declare fg bigint;
begin
  select following into fg from public.public_follow_counts('carol_dir');
  if fg <> 0 then
    raise exception 'CHECK FAILED: E.164 unfollow did not remove the edge (following=%)', fg;
  end if;
  raise notice '  ok   an E.164 follower can unfollow too';
end $$;
-- Restore the caller to alice for the checks that follow.
select pg_temp.as_user('15550001111');
-- A rename survives: the edge is phones underneath.
reset role;
update public.usernames set username = 'bob_renamed'
 where phone = '15550002222';
set role authenticated;
do $$
declare fs bigint; fg bigint;
begin
  select followers, following into fs, fg
    from public.public_follow_counts('bob_renamed');
  if fs <> 1 then
    raise exception 'SECURITY CHECK FAILED: the follow was lost to a rename';
  end if;
  raise notice '  ok   a follow survives the followed account renaming';
end $$;
-- A hidden follower leaves the list but not the count-keeping edge design:
-- the WINDOW filters, same as who-liked.
reset role;
update public.usernames set hidden = true where phone = '15550001111';
set role authenticated;
do $$ begin
  if (select count(*) from public.public_followers('bob_renamed')) <> 0 then
    raise exception 'SECURITY CHECK FAILED: a hidden account is still listed as a follower';
  end if;
  raise notice '  ok   a hidden account leaves the follower list';
end $$;
reset role;
update public.usernames set hidden = false where phone = '15550001111';
update public.usernames set username = 'bob_dir' where phone = '15550002222';
set role authenticated;
select pg_temp.expect_ok(
  $$select public.public_unfollow('bob_dir')$$, 'an unfollow can be made');
do $$
declare fs bigint; fg bigint;
begin
  select followers, following into fs, fg
    from public.public_follow_counts('bob_dir');
  if fs <> 0 then
    raise exception 'SECURITY CHECK FAILED: the unfollow did not take';
  end if;
  raise notice '  ok   an unfollow takes';
end $$;

-- The card-attach ledger is the waiting period: a row a client could read,
-- write or delete is a hold a thief could inspect or skip.
select pg_temp.expect_fail(
  $$select * from public.payment_card_events$$,
  'clients cannot read the card-attach ledger');
select pg_temp.expect_fail(
  $$insert into public.payment_card_events (phone) values ('15550001111')$$,
  'clients cannot forge a card-attach event');
select pg_temp.expect_fail(
  $$delete from public.payment_card_events$$,
  'clients cannot erase the card-attach history');

-- Sparks: the tally rows behind the amber bolt. The money itself moves over
-- Stripe; these assertions hold the tally to the same standards as likes.
select pg_temp.expect_ok(
  $$select id, spark_count, spark_cents from public.public_feed$$,
  'the feed view carries the spark tallies');

select pg_temp.expect_fail(
  $$select sparker_phone from public.public_post_sparks$$,
  'a client cannot read who sparked something');

-- A post by a SECOND user, so there is somebody else's post to spark.
select pg_temp.as_user('15550002222');
select pg_temp.expect_ok(
  $$insert into public.public_posts (id, author_phone, author_username, body)
    values ('t_ps','15550002222','bob','sparkable')$$,
  'the second user can post');
select pg_temp.as_user('15550001111');

select pg_temp.expect_ok(
  $$insert into public.public_post_sparks (post_id, sparker_phone, cents)
    values ('t_ps','15550001111', 500)$$,
  'you can spark somebody else''s post');

select pg_temp.expect_fail(
  $$insert into public.public_post_sparks (post_id, sparker_phone, cents)
    values ('t_ps','15550002222', 500)$$,
  'you cannot spark as somebody else');

select pg_temp.expect_fail(
  $$insert into public.public_post_sparks (post_id, sparker_phone, cents)
    values ('t_p1','15550001111', 500)$$,
  'you cannot spark your own post');

select pg_temp.expect_fail(
  $$insert into public.public_post_sparks (post_id, sparker_phone, cents)
    values ('t_ps','15550001111', 0)$$,
  'a spark of nothing is refused');

do $$ begin
  if (select spark_count from public.public_feed where id='t_ps') <> 1
     or (select spark_cents from public.public_feed where id='t_ps') <> 500 then
    raise exception 'spark tallies wrong';
  end if;
  raise notice '  ok   the tallies total what was sparked';
end $$;

-- A timed-out account is refused at the database, not merely in the UI.
select pg_temp.as_user('15550003333');
select pg_temp.expect_fail(
  $$insert into public.public_posts (id, author_phone, author_username, body)
    values ('t_p3','15550003333','carl','silenced')$$,
  'a timed-out account cannot post');

reset role;
update public.account_sanctions set until = now() - interval '1 minute'
  where phone = '15550003333';
set role authenticated;
select pg_temp.as_user('15550003333');
select pg_temp.expect_ok(
  $$insert into public.public_posts (id, author_phone, author_username, body)
    values ('t_p4','15550003333','carl','allowed again')$$,
  'an expired time-out lifts by itself');

-- A banned author disappears from the feed.
reset role;
insert into public.public_posts (id, author_phone, author_username, body)
  values ('t_p5','15550009999','banned','hidden');
set role authenticated;
select pg_temp.as_user('15550001111');
do $$ begin
  if (select count(*) from public.public_feed where author_username='banned') <> 0 then
    raise exception 'SECURITY CHECK FAILED: a banned author is still in the feed';
  end if;
  raise notice '  ok   a banned author leaves the feed';
end $$;

-- Editing a public post (docs/public_feed_edit.sql): the author may fix their
-- OWN post, but only within the window, only the text, and it is stamped.
select pg_temp.as_user('15550001111');
select pg_temp.expect_ok(
  $$update public.public_posts set body = 'edited', edited_at = now()
      where id = 't_p1'$$,
  'the author can edit their own recent post');
do $$ begin
  if (select body from public.public_feed where id='t_p1') <> 'edited' then
    raise exception 'CHECK FAILED: the author edit did not take';
  end if;
  if (select edited_at from public.public_feed where id='t_p1') is null then
    raise exception 'CHECK FAILED: an edit was not stamped';
  end if;
  raise notice '  ok   the author edits their own recent post, and it is stamped';
end $$;

-- A stranger cannot edit someone else's post. RLS filters the row out, so the
-- UPDATE affects zero rows WITHOUT raising — assert the text is untouched
-- rather than trusting the statement to have errored.
select pg_temp.as_user('15550002222');
do $$ begin
  update public.public_posts set body = 'hijacked' where id = 't_p1';
  if (select body from public.public_feed where id='t_p1') <> 'edited' then
    raise exception 'SECURITY CHECK FAILED: a stranger rewrote a post';
  end if;
  raise notice '  ok   a stranger cannot edit your post';
end $$;

-- Not even the author may touch anything but the body/stamp — the column grant
-- refuses it before RLS is consulted, so this one really does raise.
select pg_temp.as_user('15550001111');
select pg_temp.expect_fail(
  $$update public.public_posts set author_username = 'someoneelse'
      where id = 't_p1'$$,
  'an edit cannot change anything but the text');

-- And the window closes: a post older than 15 minutes is no longer editable.
-- RLS again filters it out silently, so assert the text is untouched.
reset role;
insert into public.public_posts (id, author_phone, author_username, body, created_at)
  values ('t_old','15550001111','alice','old post', now() - interval '20 minutes');
set role authenticated;
select pg_temp.as_user('15550001111');
do $$ begin
  update public.public_posts set body = 'too late' where id = 't_old';
  if (select body from public.public_feed where id='t_old') <> 'old post' then
    raise exception 'SECURITY CHECK FAILED: an out-of-window edit was allowed';
  end if;
  raise notice '  ok   the edit window closes after 15 minutes';
end $$;

-- The new shapes: reposts, quote posts, image-only posts, and the rules that
-- keep a row from being nonsense.
select pg_temp.as_user('15550001111');

select pg_temp.expect_ok(
  $$insert into public.public_posts (id, author_phone, author_username, repost_of)
    values ('t_rp','15550001111','alice','t_p1')$$,
  'a plain repost needs no text');

select pg_temp.expect_ok(
  $$insert into public.public_posts (id, author_phone, author_username, body, repost_of)
    values ('t_qp','15550001111','alice','my take','t_p1')$$,
  'a quote post is a repost with text');

select pg_temp.expect_ok(
  $$insert into public.public_posts (id, author_phone, author_username, image_path)
    values ('t_img','15550001111','alice','t_img.jpg')$$,
  'an image-only post needs no text');

select pg_temp.expect_fail(
  $$insert into public.public_posts (id, author_phone, author_username)
    values ('t_empty','15550001111','alice')$$,
  'a post with nothing in it is refused');

select pg_temp.expect_fail(
  $$insert into public.public_posts
      (id, author_phone, author_username, body, reply_to, repost_of)
    values ('t_both','15550001111','alice','x','t_p1','t_p1')$$,
  'a post cannot be both a reply and a repost');

select pg_temp.expect_fail(
  $$insert into public.public_posts (id, author_phone, author_username, body)
    values ('t_long','15550001111','alice', repeat('x', 501))$$,
  'over 500 characters is refused');

do $$ begin
  if (select repost_count from public.public_feed where id='t_p1') <> 2 then
    raise exception 'CHECK FAILED: repost_count is %, expected 2',
      (select repost_count from public.public_feed where id='t_p1');
  end if;
  raise notice '  ok   reposts are counted (quote posts included)';
end $$;

-- Deleting the original takes its reposts: a repost of nothing is not a post.
reset role; set role authenticated; select pg_temp.as_user('15550001111');
select pg_temp.expect_ok($$delete from public.public_posts where id='t_p1'$$,
  'you can delete your own post');
do $$ begin
  if (select count(*) from public.public_feed where id in ('t_rp','t_qp')) <> 0 then
    raise exception 'CHECK FAILED: a repost outlived the post it repeats';
  end if;
  raise notice '  ok   deleting a post removes its reposts';
end $$;

-- The image bucket is public (these are attachments on public posts) and
-- clients may add but never replace.
do $$ begin
  if not (select public from storage.buckets where id='public-media') then
    raise exception 'CHECK FAILED: public-media should be a public bucket';
  end if;
  raise notice '  ok   the image bucket is public, as a public feed implies';
end $$;

-- Push tokens. The app upserts its token on every launch, so the second
-- launch is the one that matters — and it is the one that was failing.
reset role; set role authenticated; select pg_temp.as_user('15550001111');

select pg_temp.expect_ok(
  $$insert into public.push_tokens (phone, token, platform)
    values ('15550001111','apns-aaa','ios')
    on conflict (phone) do update set token = excluded.token$$,
  'you can register a push token');
select pg_temp.expect_ok(
  $$insert into public.push_tokens (phone, token, platform)
    values ('15550001111','apns-bbb','ios')
    on conflict (phone) do update set token = excluded.token$$,
  'and register it again on the next launch');
select pg_temp.expect_fail(
  $$insert into public.push_tokens (phone, token, platform)
    values ('15550002222','apns-ccc','ios')$$,
  'you cannot register a token for somebody else');

-- Your own row, and only your own.
do $$ begin
  if (select count(*) from public.push_tokens) <> 1 then
    raise exception 'CHECK FAILED: your own token row should be visible';
  end if;
  raise notice '  ok   your own row is visible, which is what the upsert needs';
end $$;
reset role;
insert into public.push_tokens (phone, token) values ('15550007777','apns-ddd')
  on conflict (phone) do nothing;
set role authenticated; select pg_temp.as_user('15550001111');
do $$ begin
  if (select count(*) from public.push_tokens
        where phone = '15550007777') <> 0 then
    raise exception 'SECURITY CHECK FAILED: somebody else''s token row is visible';
  end if;
  raise notice '  ok   and nobody else''s is';
end $$;

-- Polls. Everything that makes a vote a vote is enforced in the database, so
-- a modified client gains nothing by asking differently.
reset role; set role authenticated; select pg_temp.as_user('15550001111');

select pg_temp.expect_ok(
  $$insert into public.public_posts
      (id, author_phone, author_username, body, poll_options, poll_closes_at)
    values ('t_poll','15550001111','alice','Tabs or spaces?',
            array['Tabs','Spaces'], now() + interval '1 day')$$,
  'you can post a poll');

select pg_temp.expect_fail(
  $$insert into public.public_posts
      (id, author_phone, author_username, body, poll_options, poll_closes_at)
    values ('t_p1o','15550001111','alice','One answer?', array['Yes'],
            now() + interval '1 day')$$,
  'a poll with one answer is refused');

select pg_temp.expect_fail(
  $$insert into public.public_posts
      (id, author_phone, author_username, body, poll_options, poll_closes_at)
    values ('t_p5o','15550001111','alice','Five?',
            array['a','b','c','d','e'], now() + interval '1 day')$$,
  'a poll with five answers is refused');

select pg_temp.expect_fail(
  $$insert into public.public_posts
      (id, author_phone, author_username, body, poll_options, poll_closes_at)
    values ('t_pblank','15550001111','alice','Blank?', array['Yes','  '],
            now() + interval '1 day')$$,
  'a blank answer is refused');

select pg_temp.expect_fail(
  $$insert into public.public_posts
      (id, author_phone, author_username, body, poll_options)
    values ('t_pnoend','15550001111','alice','Forever?', array['Yes','No'])$$,
  'a poll that never closes is refused');

select pg_temp.expect_fail(
  $$insert into public.public_posts
      (id, author_phone, author_username, poll_options, poll_closes_at)
    values ('t_pnoq','15550001111','alice', array['Yes','No'],
            now() + interval '1 day')$$,
  'a poll with no question is refused');

select pg_temp.expect_fail(
  $$insert into public.public_posts
      (id, author_phone, author_username, body, repost_of, poll_options,
       poll_closes_at)
    values ('t_prp','15550001111','alice','Q', 't_poll', array['Yes','No'],
            now() + interval '1 day')$$,
  'a repost cannot also be a poll');

-- Voting.
select pg_temp.as_user('15550002222');
-- Before any vote by this account lands, or the primary key would be what
-- refuses this and the bound in the policy would go untested.
select pg_temp.expect_fail(
  $$insert into public.public_post_votes (post_id, voter_phone, choice)
    values ('t_poll','15550002222',3)$$,
  'you cannot pick an answer the poll does not have');
select pg_temp.expect_ok(
  $$insert into public.public_post_votes (post_id, voter_phone, choice)
    values ('t_poll','15550002222',1)$$,
  'you can vote');
select pg_temp.expect_fail(
  $$insert into public.public_post_votes (post_id, voter_phone, choice)
    values ('t_poll','15550002222',0)$$,
  'you cannot vote twice');
select pg_temp.expect_fail(
  $$insert into public.public_post_votes (post_id, voter_phone, choice)
    values ('t_poll','15550001111',0)$$,
  'you cannot vote as somebody else');
select pg_temp.expect_fail(
  $$update public.public_post_votes set choice = 0 where post_id = 't_poll'$$,
  'a vote cannot be changed');
select pg_temp.expect_fail(
  $$delete from public.public_post_votes where post_id = 't_poll'$$,
  'a vote cannot be taken back');
select pg_temp.expect_fail(
  $$select voter_phone from public.public_post_votes$$,
  'a client cannot read who voted');

-- A post that is not a poll cannot be voted on, and a closed one cannot
-- either. Both are refusals the app must not be trusted with.
select pg_temp.as_user('15550001111');
select pg_temp.expect_fail(
  $$insert into public.public_post_votes (post_id, voter_phone, choice)
    values ('t_p4','15550001111',0)$$,
  'a post that is not a poll cannot be voted on');
reset role;
insert into public.public_posts
    (id, author_phone, author_username, body, poll_options, poll_closes_at)
  values ('t_shut','15550001111','alice','Over?', array['Yes','No'],
          now() - interval '1 minute');
set role authenticated; select pg_temp.as_user('15550002222');
select pg_temp.expect_fail(
  $$insert into public.public_post_votes (post_id, voter_phone, choice)
    values ('t_shut','15550002222',0)$$,
  'a closed poll takes no more votes');

-- The tally is true even though nobody can read the rows behind it.
reset role;
insert into public.public_post_votes (post_id, voter_phone, choice) values
  ('t_poll','15550003333',1), ('t_poll','15550009999',0);
set role authenticated; select pg_temp.as_user('15550002222');
do $$
declare got int[];
begin
  select poll_votes into got from public.public_feed where id = 't_poll';
  if got <> array[1,2] then
    raise exception 'CHECK FAILED: tally is %, expected {1,2}', got;
  end if;
  raise notice '  ok   the tally counts every vote, readable by nobody';
end $$;

do $$ begin
  if (select poll_votes from public.public_feed where id = 't_p4')
       <> '{}'::int[] then
    raise exception 'CHECK FAILED: a post with no poll has a tally';
  end if;
  raise notice '  ok   a post that is not a poll has no tally';
end $$;

-- Payment controls. The whole point of storing these server-side is that the
-- account cannot change them by talking to Postgres directly — only the Edge
-- Functions, on the service-role key, may. RLS is on with no policies, so
-- every one of these is refused or silently matches nothing.
reset role;
insert into public.payment_settings (phone, daily_send_limit_cents, paused)
  values ('15550001111', 10000, false)
  on conflict (phone) do update set daily_send_limit_cents = 10000;
insert into public.payment_blocks (phone, blocked_phone)
  values ('15550001111', '15550002222') on conflict do nothing;
set role authenticated;
select pg_temp.as_user('15550001111');

do $$ begin
  if (select count(*) from public.payment_settings) <> 0 then
    raise exception 'SECURITY CHECK FAILED: a client can read payment settings';
  end if;
  raise notice '  ok   a client cannot read payment settings';
end $$;

update public.payment_settings set daily_send_limit_cents = 200000
  where phone = '15550001111';
do $$ begin
  if (select daily_send_limit_cents from public.payment_settings) is not null then
    raise exception 'SECURITY CHECK FAILED: a client raised its own send limit';
  end if;
  raise notice '  ok   a client cannot raise its own send limit';
end $$;

update public.payment_settings set paused = false where phone = '15550001111';
delete from public.payment_blocks where phone = '15550001111';
reset role;
do $$ begin
  if (select count(*) from public.payment_blocks
      where phone='15550001111') <> 1 then
    raise exception 'SECURITY CHECK FAILED: a client unblocked itself';
  end if;
  raise notice '  ok   a client cannot unblock itself';
end $$;

-- The upgrade path put the v2 columns back. Without these the delayed-raise
-- rule has nowhere to store what is waiting, and every raise would apply at
-- once — silently, because the function reads null and carries on.
do $$
declare missing text;
begin
  select string_agg(c, ', ') into missing from unnest(array[
    'paused', 'max_send_cents',
    'pending_daily_send_limit_cents', 'pending_daily_effective_at',
    'pending_max_send_cents', 'pending_max_effective_at']) c
  where not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='payment_settings'
      and column_name = c);
  if missing is not null then
    raise exception 'CHECK FAILED: payment_settings is missing %', missing;
  end if;
  raise notice '  ok   an existing project gains the new limit columns';
end $$;
set role authenticated;
select pg_temp.as_user('15550001111');

-- The directory hides a banned account too (platform_moderation.sql).
reset role;
insert into public.usernames (phone, username, name)
  values ('15550009999','banned','Banned') on conflict (phone) do nothing;
set role authenticated;
select pg_temp.as_user('15550001111');
do $$ begin
  if (select count(*) from public.usernames where username='banned') <> 0 then
    raise exception 'SECURITY CHECK FAILED: a banned account is still in the directory';
  end if;
  raise notice '  ok   a banned account leaves the directory';
end $$;

-- Push tokens follow the device's CURRENT account. B's claim releases A's
-- row for the same token; a different token stays put; deleting your own
-- row works and deleting another's does not.
reset role;
insert into public.push_tokens (phone, token) values
  ('15550001111', 'tok_shared'), ('15550004444', 'tok_other')
  on conflict (phone) do update set token = excluded.token;
set role authenticated;
select pg_temp.as_user('15550002222');
select public.claim_push_token('tok_shared');
-- RLS makes a delete of somebody else's row a silent no-op; prove it stayed.
delete from public.push_tokens where phone = '15550004444';
reset role;
do $$ begin
  if exists (select 1 from public.push_tokens where phone = '15550001111') then
    raise exception 'SECURITY CHECK FAILED: the old account still holds the device token';
  end if;
  if not exists (select 1 from public.push_tokens where phone = '15550004444') then
    raise exception 'SECURITY CHECK FAILED: an account deleted another account''s push token';
  end if;
  raise notice '  ok   a device token follows the account that signs in';
end $$;
set role authenticated;
select pg_temp.as_user('15550004444');
select pg_temp.expect_ok(
  $$delete from public.push_tokens where token = 'tok_other'$$,
  'sign-out can delete this device''s own token row');
reset role;

-- Numberless push registration: codes only, first registration wins.
set role anon;
select public.register_numberless_push('001234567890', 'tok_ghost', false);
select public.register_numberless_push('15550005555', 'tok_real', false);
select public.register_numberless_push('001234567890', 'tok_hijack', false);
reset role;
do $$ begin
  if not exists (select 1 from public.push_tokens
                 where phone = '001234567890' and token = 'tok_ghost') then
    raise exception 'CHECK FAILED: a numberless account cannot register for push';
  end if;
  if exists (select 1 from public.push_tokens where phone = '15550005555') then
    raise exception 'SECURITY CHECK FAILED: anon registered push for a REAL number';
  end if;
  if exists (select 1 from public.push_tokens where token = 'tok_hijack') then
    raise exception 'SECURITY CHECK FAILED: a numberless push row was re-pointed with no proof';
  end if;
  raise notice '  ok   numberless push registers codes only, first claim wins';
end $$;

-- can_receive_payments: the courtesy pre-check answers what create-intent
-- would refuse anyway — no account, not enabled, or paused means no.
reset role;
insert into public.payment_accounts (phone, stripe_account_id, charges_enabled)
  values ('15550007777', 'acct_ok', true),
         ('15550008888', 'acct_off', false)
  on conflict (phone) do update
    set stripe_account_id = excluded.stripe_account_id,
        charges_enabled = excluded.charges_enabled;
set role authenticated;
select pg_temp.as_user('15550001111');
do $$ begin
  if not (select public.can_receive_payments('15550007777')) then
    raise exception 'CHECK FAILED: an onboarded account reads as unable to receive';
  end if;
  if (select public.can_receive_payments('15550008888')) then
    raise exception 'CHECK FAILED: charges-disabled account reads as able to receive';
  end if;
  if (select public.can_receive_payments('15550006666')) then
    raise exception 'CHECK FAILED: an account with no payments setup reads as able to receive';
  end if;
  raise notice '  ok   senders learn up front who cannot receive money';
end $$;
reset role;

-- Numberless directory (directory_numberless.sql): the RPCs are anon's only
-- door, and the claim only ever opens account-code rows.
reset role;
set role anon;
do $$ begin
  if not (select public.claim_numberless('001234567890', 'ghosty', 'Ghost')) then
    raise exception 'CHECK FAILED: a numberless account cannot claim its handle';
  end if;
  if (select public.claim_numberless('15550001111', 'realphone', 'X')) then
    raise exception 'SECURITY CHECK FAILED: anon claimed a REAL number''s directory row';
  end if;
  if (select public.claim_numberless('001234567890', 'ghosty2', 'G')) then
    raise exception 'SECURITY CHECK FAILED: a handle was changed with no proof the code is yours';
  end if;
  if (select public.claim_numberless('009999999999', 'ghosty', 'Z')) then
    raise exception 'SECURITY CHECK FAILED: a taken handle was claimed by a second code';
  end if;
  -- A PREFIX still finds people; it just no longer names their number
  -- (directory_phone_privacy.sql). Asserted on the handle, not the phone.
  if not exists (select 1 from public.find_people('gho') where username = 'ghosty') then
    raise exception 'CHECK FAILED: anon username search finds nothing';
  end if;
  raise notice '  ok   numberless accounts claim and search through the RPCs alone';
end $$;
reset role;

-- Identity backups (identity_backup.sql): your own row through your session,
-- '00' rows through the RPCs, nothing else through anything.
set role authenticated;
select pg_temp.as_user('15550001111');
select pg_temp.expect_ok(
  $$insert into public.identity_backups (inbox, blob)
    values ('15550001111', 'sealed_own')$$,
  'you can store your own identity backup');
select pg_temp.expect_fail(
  $$insert into public.identity_backups (inbox, blob)
    values ('15550002222', 'planted')$$,
  'you cannot plant a backup on somebody else''s number');
select pg_temp.expect_ok(
  $$update public.identity_backups set blob = 'sealed_own_2'
    where inbox = '15550001111'$$,
  'rotating your own backup works');
do $$ begin
  if exists (select 1 from public.identity_backups where inbox <> '15550001111') then
    raise exception 'SECURITY CHECK FAILED: a session can read another number''s backup';
  end if;
  raise notice '  ok   a session reads only its own backup row';
end $$;
reset role;
set role anon;
do $$ begin
  if not (select public.put_identity_backup('001234567890', 'sealed_ghost')) then
    raise exception 'CHECK FAILED: a numberless account cannot store its backup';
  end if;
  if (select public.put_identity_backup('001234567890', 'replaced')) then
    raise exception 'SECURITY CHECK FAILED: an anonymous caller replaced a numberless backup';
  end if;
  if (select public.put_identity_backup('15550001111', 'hijack')) then
    raise exception 'SECURITY CHECK FAILED: the anon RPC wrote to a REAL number';
  end if;
  if (select public.get_identity_backup('001234567890')) <> 'sealed_ghost' then
    raise exception 'CHECK FAILED: a numberless backup cannot be fetched back';
  end if;
  if (select public.get_identity_backup('15550001111')) is not null then
    raise exception 'SECURITY CHECK FAILED: anon fetched a REAL number''s blob';
  end if;
  raise notice '  ok   identity backups: own row via session, 00 rows via RPC, first write wins';
end $$;
do $$ begin
  begin
    perform blob from public.identity_backups;
    raise exception 'SECURITY CHECK FAILED: anon read identity_backups directly';
  exception when insufficient_privilege then
    raise notice '  ok   anon cannot touch the backup table directly';
  end;
end $$;
reset role;

-- Deactivation (account_lifecycle.sql): a hidden row answers no search but
-- keeps its handle, and only its own session can hide or unhide it.
set role authenticated;
select pg_temp.as_user('15550006111');
select pg_temp.expect_ok(
  $$insert into public.usernames (phone, username, name)
    values ('15550006111','sleeper','Sleeper')$$,
  'a deactivation test account can claim its row');
do $$ begin
  -- Asserted on the handle: a prefix search no longer names a number
  -- (directory_phone_privacy.sql). Findability is the thing under test here.
  if not exists (select 1 from public.find_people('slee')
                 where username = 'sleeper') then
    raise exception 'CHECK FAILED: the account is not findable before hiding';
  end if;
  raise notice '  ok   findable before deactivation';
end $$;
select pg_temp.expect_ok(
  $$update public.usernames set hidden = true where phone = '15550006111'$$,
  'you can hide your own row');
do $$ begin
  if exists (select 1 from public.find_people('slee')
             where username = 'sleeper') then
    raise exception 'SECURITY CHECK FAILED: a deactivated account still answers search';
  end if;
  raise notice '  ok   a deactivated account answers no search';
end $$;
-- The handle stays theirs while they are away.
select pg_temp.as_user('15550006222');
select pg_temp.expect_fail(
  $$insert into public.usernames (phone, username, name)
    values ('15550006222','sleeper','Squatter')$$,
  'a hidden handle cannot be taken by somebody else');
-- Another session's update silently matches nothing; prove the flag held.
update public.usernames set hidden = false where phone = '15550006111';
reset role;
do $$ begin
  if not (select hidden from public.usernames where phone='15550006111') then
    raise exception 'SECURITY CHECK FAILED: another account unhid a deactivated row';
  end if;
  raise notice '  ok   only your own session can reactivate you';
end $$;
set role authenticated;
select pg_temp.as_user('15550006111');
select pg_temp.expect_ok(
  $$update public.usernames set hidden = false where phone = '15550006111'$$,
  'signing back in can clear the flag');
do $$ begin
  if not exists (select 1 from public.find_people('slee')
                 where username = 'sleeper') then
    raise exception 'CHECK FAILED: a reactivated account is still unfindable';
  end if;
  raise notice '  ok   reactivation restores the search row';
end $$;
reset role;

-- Community posts (community_posts.sql): the durable sealed copy of server
-- feeds. Mailbox trust model — the app key reads and writes ciphertext.
set role anon;
select pg_temp.expect_ok(
  $$insert into public.community_posts (community_id, post_id, payload)
    values ('cm_test', 'p1', 'sealed_blob')$$,
  'the app key can store a sealed post');
select pg_temp.expect_ok(
  $$update public.community_posts set payload = 'sealed_blob_v2'
    where community_id = 'cm_test' and post_id = 'p1'$$,
  'a listing update replaces its row');
select pg_temp.expect_ok(
  $$select payload from public.community_posts
    where community_id = 'cm_test'$$,
  'members fetch by community id');
select pg_temp.expect_fail(
  $$insert into public.community_posts (community_id, post_id, payload)
    values ('cm_test', 'p_big', repeat('x', 400001))$$,
  'an oversized payload is refused');
select pg_temp.expect_ok(
  $$delete from public.community_posts
    where community_id = 'cm_test' and post_id = 'p1'$$,
  'deleting a post removes its durable copy');
reset role;

-- Creator subscriptions (creator_subscriptions.sql): a paid post's real text
-- lives in public_paid_bodies and is served by public_paid_body() to the
-- author or an active subscriber, and to NOBODY else — the client can neither
-- read it directly nor grant itself a pass.
set role authenticated;
select pg_temp.as_user('15550001111');  -- alice, the creator
select pg_temp.expect_ok(
  $$insert into public.public_posts
      (id, author_phone, author_username, body, paid, sub_cents)
    values ('t_paid','15550001111','alice','a teaser',true,499)$$,
  'a creator can post a paid post');
select pg_temp.expect_ok(
  $$insert into public.public_paid_bodies (post_id, author_phone, body)
    values ('t_paid','15550001111','the secret text')$$,
  'the creator writes the paid body as their own');
select pg_temp.expect_fail(
  $$insert into public.public_paid_bodies (post_id, author_phone, body)
    values ('t_paid','15550002222','forged')$$,
  'a paid body cannot be written under someone else''s phone');
select pg_temp.expect_fail(
  $$select body from public.public_paid_bodies$$,
  'a paid body cannot be selected directly');
do $$ begin
  if (select public.public_paid_body('t_paid'))
     is distinct from 'the secret text' then
    raise exception 'CHECK FAILED: author cannot read own paid body';
  end if;
  raise notice '  ok   the author reads their own paid body';
end $$;
select pg_temp.as_user('15550002222');  -- bob, not subscribed
do $$ begin
  if (select public.public_paid_body('t_paid')) is not null then
    raise exception 'CHECK FAILED: a non-subscriber read a paid body';
  end if;
  raise notice '  ok   a non-subscriber gets nothing back';
end $$;
select pg_temp.expect_fail(
  $$insert into public.creator_subscriptions
      (subscriber_phone, creator_phone, expires_at)
    values ('15550002222','15550001111', now() + interval '30 days')$$,
  'a client cannot grant itself a pass');
reset role;
-- The edge function (service role) records the verified pass.
insert into public.creator_subscriptions
    (subscriber_phone, creator_phone, expires_at)
  values ('15550002222','15550001111', now() + interval '30 days');
set role authenticated;
select pg_temp.as_user('15550002222');
do $$ begin
  if (select public.public_paid_body('t_paid'))
     is distinct from 'the secret text' then
    raise exception 'CHECK FAILED: an active subscriber cannot read the body';
  end if;
  raise notice '  ok   an active subscriber reads the paid body';
end $$;
reset role;
update public.creator_subscriptions set expires_at = now() - interval '1 day'
  where subscriber_phone = '15550002222';
set role authenticated;
select pg_temp.as_user('15550002222');
do $$ begin
  if (select public.public_paid_body('t_paid')) is not null then
    raise exception 'CHECK FAILED: an expired pass still read the body';
  end if;
  raise notice '  ok   an expired pass reads nothing';
end $$;
reset role;

-- AI rate limit: the tally increments per caller/day, and no client may call
-- the bump function or touch the table.
do $$
declare a int; b int;
begin
  select public.ai_note_usage('probe') into a;
  select public.ai_note_usage('probe') into b;
  if a <> 1 or b <> 2 then
    raise exception 'CHECK FAILED: ai usage did not increment (% then %)', a, b;
  end if;
  raise notice '  ok   the AI usage tally increments per caller/day';
end $$;
set role authenticated;
select pg_temp.as_user('15550001111');
select pg_temp.expect_fail(
  $$select public.ai_note_usage('sneaky')$$,
  'a client cannot bump the AI usage tally');
select pg_temp.expect_fail(
  $$select * from public.ai_usage$$,
  'the AI usage table is closed to clients');
-- The training corpus is closed to clients both ways: no read, no write.
select pg_temp.expect_fail(
  $$select * from public.ai_training_samples$$,
  'the AI training corpus cannot be read by a client');
select pg_temp.expect_fail(
  $$insert into public.ai_training_samples (prompt, reply, rating)
    values ('p','r',1)$$,
  'a client cannot write to the AI training corpus');
-- Legal documents: clients may READ the current text (fetched on launch) but
-- may never write it — only the owner-gated legal-set function does.
do $$ begin
  perform count(*) from public.legal_documents;
  raise notice '  ok   legal documents are readable by clients';
end $$;
select pg_temp.expect_fail(
  $$insert into public.legal_documents (id, terms, privacy)
    values (1, '[]'::jsonb, '[]'::jsonb)$$,
  'a client cannot publish legal documents');
select pg_temp.expect_fail(
  $$update public.legal_documents set version = 999 where id = 1$$,
  'a client cannot alter legal documents');

-- Owner-editable pricing: same shape as the legal documents. Every device
-- reads the published prices on launch; only the owner-gated pricing-set
-- function writes them. A client that could write here would set the numbers
-- the app quotes on every other device.
do $$ begin
  perform count(*) from public.app_pricing;
  raise notice '  ok   published prices are readable by clients';
end $$;
select pg_temp.expect_fail(
  $$insert into public.app_pricing (id, prices) values (1, '{}'::jsonb)$$,
  'a client cannot publish prices');
select pg_temp.expect_fail(
  $$update public.app_pricing set prices = '{"storagePerGbCents":1}'::jsonb
    where id = 1$$,
  'a client cannot alter published prices');

-- Taken numbers and emails (taken_signups.sql): a number that already has an
-- account, or an email another account holds, cannot be claimed twice.
set role authenticated;
select pg_temp.as_user('15550001111');
do $$ begin
  -- 'alice_dir' holds 15550001111, seeded above. Passed here in E.164 while
  -- the directory stores digits — the '+'-vs-digits trap this canonicalises.
  if not public.is_phone_taken('+1 555 000 1111') then
    raise exception 'a number that has an account must read as taken';
  end if;
  raise notice '  ok   an existing number reads as taken (E.164 in, digits stored)';
  -- And carol_dir is stored WITH a '+', queried without one — the trap the
  -- other way round.
  if not public.is_phone_taken('15550004444') then
    raise exception 'the digits form must match a stored E.164 row';
  end if;
  raise notice '  ok   and the check canonicalises both sides';
  if public.is_phone_taken('15559998888') then
    raise exception 'an unused number must be free';
  end if;
  raise notice '  ok   an unused number is free to sign up with';
end $$;

-- Email claims: only the definer functions touch the table, and one address
-- cannot be held by two accounts.
select pg_temp.expect_fail(
  $$select * from public.email_claims$$,
  'the email-claims list is not readable by a client');
select pg_temp.expect_fail(
  $$insert into public.email_claims (email_hash, phone)
    values ('deadbeef', '15550001111')$$,
  'a client cannot write an email claim directly');
do $$ begin
  if not public.claim_email('hash_of_ada') then
    raise exception 'an account must be able to claim a free address';
  end if;
  raise notice '  ok   an account claims a free email';
  -- Its own address is not "taken" for itself, or re-saving would refuse.
  if public.is_email_taken('hash_of_ada') then
    raise exception 'your own claim must not read as taken';
  end if;
  raise notice '  ok   your own address is not taken from you';
end $$;
-- A DIFFERENT account now finds it taken, and cannot steal it.
select pg_temp.as_user('15550007777');
do $$ begin
  if not public.is_email_taken('hash_of_ada') then
    raise exception 'another account must see the address as taken';
  end if;
  raise notice '  ok   another account sees the address as taken';
  if public.claim_email('hash_of_ada') then
    raise exception 'another account must not be able to steal the address';
  end if;
  raise notice '  ok   and cannot claim it out from under them';
end $$;
-- Releasing frees it for everyone again.
select pg_temp.as_user('15550001111');
select public.release_email();
select pg_temp.as_user('15550007777');
do $$ begin
  if public.is_email_taken('hash_of_ada') then
    raise exception 'a released address must be free again';
  end if;
  raise notice '  ok   a released address can be claimed by somebody else';
end $$;
reset role;

-- Shadow bans and area bans (moderation_scopes.sql).
-- alice_dir (15550001111) is shadow banned; bob_dir (15550002222) is not.
insert into public.account_sanctions (phone, kind, reason)
  values ('15550001111', 'shadow', 'test') on conflict (phone) do update
  set kind = excluded.kind, until = null;
insert into public.public_posts (id, author_phone, author_username, body)
  values ('shadow_p1', '15550001111', 'alice_dir', 'shadow post')
  on conflict (id) do nothing;
insert into public.public_posts (id, author_phone, author_username, body)
  values ('normal_p1', '15550002222', 'bob_dir', 'normal post')
  on conflict (id) do nothing;

set role authenticated;
-- The shadow-banned author still sees their own post exactly where it was:
-- being able to tell is the one thing a shadow ban must never allow.
select pg_temp.as_user('15550001111');
do $$
declare n int;
begin
  select count(*) into n from public.public_posts where body = 'shadow post';
  if n <> 1 then raise exception 'a shadow-banned author must still see their own post'; end if;
  raise notice '  ok   a shadow-banned author still sees their own post';
  -- And is NOT blocked from posting: being stopped is how you find out.
  insert into public.public_posts (id, author_phone, author_username, body)
    values ('shadow_p2', '15550001111', 'alice_dir', 'still posting');
  raise notice '  ok   and can still post (nothing tells them)';
end $$;

-- Everybody else sees nothing of theirs.
select pg_temp.as_user('15550002222');
do $$
declare n int;
begin
  -- author_phone is not selectable by a client (the phone-protection column
  -- grant), so identify the rows by their bodies instead.
  select count(*) into n from public.public_posts
   where body in ('shadow post', 'still posting');
  if n <> 0 then raise exception 'a shadow-banned author must be invisible to others'; end if;
  raise notice '  ok   nobody else sees a shadow-banned author''s posts';
  select count(*) into n from public.public_posts where body = 'normal post';
  if n <> 1 then raise exception 'an unsanctioned author must stay visible'; end if;
  raise notice '  ok   and everyone else is unaffected';
end $$;

-- Area bans: barred from ONE area, still a full user of the rest.
reset role;
insert into public.account_area_bans (phone, area, reason)
  values ('15550002222', 'marketplace', 'test') on conflict do nothing;
set role authenticated;
select pg_temp.as_user('15550002222');
select pg_temp.expect_fail(
  $$insert into public.market_listings (id, author_phone, author_username, title)
    values ('area_l1', '15550002222', 'bob_dir', 'nope')$$,
  'an area-banned seller cannot list in the marketplace');
do $$ begin
  -- The same account is untouched everywhere else.
  insert into public.public_forum_posts (id, author_phone, author_username, title)
    values ('area_f1', '15550002222', 'bob_dir', 'still allowed here');
  raise notice '  ok   and is still a full user of the forum';
  if not public.is_area_banned('15550002222', 'marketplace') then
    raise exception 'the area lookup must say so';
  end if;
  if public.is_area_banned('15550002222', 'forum') then
    raise exception 'an area ban must not leak into other areas';
  end if;
  raise notice '  ok   the area lookup is scoped to its own area';
end $$;
reset role;

-- Admin user roster (admin_users.sql): the owner/admin-only window onto the
-- whole directory, name-only accounts included. A non-staff caller is refused;
-- a staff caller sees the roster and the count, and name-only rows are marked.
set role authenticated;
select pg_temp.as_user('15550007777');            -- an ordinary account
select pg_temp.expect_fail(
  $$select public.admin_user_count()$$,
  'a non-staff account cannot count the directory');
select pg_temp.expect_fail(
  $$select * from public.admin_list_users(50, 0)$$,
  'a non-staff account cannot list the directory');
-- Make this caller an owner, and seed a name-only account.
reset role;
insert into public.platform_roles (phone, role)
  values ('15550007777', 'owner') on conflict (phone) do nothing;
insert into public.usernames (phone, username, name)
  values ('009000000001', 'codeonly', '') on conflict (phone) do update
  set username = excluded.username;
set role authenticated;
select pg_temp.as_user('15550007777');
do $$
declare c bigint; nm int;
begin
  select public.admin_user_count() into c;
  if c < 1 then
    raise exception 'CHECK FAILED: admin_user_count returned %', c;
  end if;
  select count(*) into nm from public.admin_list_users(500, 0)
    where numberless is true and username = 'codeonly';
  if nm <> 1 then
    raise exception 'CHECK FAILED: the name-only account is missing from the roster';
  end if;
  raise notice '  ok   an owner sees the whole roster, name-only accounts included';
end $$;
select pg_temp.expect_fail(
  $$select phone from public.admin_list_users(50, 0)$$,
  'the roster carries no phone column');
-- Last seen: the roster carries it, and an account can stamp its own.
select pg_temp.expect_ok(
  $$select last_seen from public.admin_list_users(50, 0)$$,
  'the roster carries a last_seen column');
reset role;
-- alice (15550001111) has a directory row; she can bump her own last_seen and
-- it lands, and the owner then sees it on the roster.
set role authenticated;
select pg_temp.as_user('15550001111');
select pg_temp.expect_ok(
  $$select public.touch_last_seen()$$,
  'an account can stamp its own last_seen');
reset role;
do $$
declare seen timestamptz;
begin
  select last_seen into seen from public.usernames where phone = '15550001111';
  if seen is null then
    raise exception 'CHECK FAILED: touch_last_seen did not stamp the row';
  end if;
  raise notice '  ok   touch_last_seen stamps the caller''s own row';
end $$;
set role authenticated;

-- Public forum (public_forum.sql): a world-readable board outside any server.
-- Same shape as the public feed — post as yourself only, phones never readable,
-- votes/comments own-only, a timed-out account refused, and the score/comment
-- tallies come off a phone-free view.
set role authenticated;
select pg_temp.as_user('15550001111');            -- alice again
select pg_temp.expect_ok(
  $$insert into public.public_forum_posts
      (id, author_phone, author_username, title, body)
    values ('t_f1','15550001111','alice','A title','hello forum')$$,
  'you can start a forum post as yourself');
select pg_temp.expect_fail(
  $$insert into public.public_forum_posts
      (id, author_phone, author_username, title)
    values ('t_f2','15550002222','bob','impersonated')$$,
  'you cannot post to the forum as somebody else');
select pg_temp.expect_fail(
  $$select author_phone from public.public_forum_posts$$,
  'a client cannot read a forum author phone');
select pg_temp.expect_fail(
  $$select * from public.public_forum_posts$$,
  'select * on forum posts is refused (it would include the phone)');
select pg_temp.expect_ok(
  $$select id, title, section, score, comment_count from public.public_forum$$,
  'the forum view reads fine, with section, score and comment_count');

-- Sections (subreddit-style boards): create one as yourself, browse it, and
-- never leak who made it.
select pg_temp.expect_ok(
  $$insert into public.public_forum_sections (slug, title, created_by_phone)
    values ('photography','Photography','15550001111')$$,
  'you can create a forum section');
select pg_temp.expect_fail(
  $$insert into public.public_forum_sections (slug, title, created_by_phone)
    values ('sneaky','X','15550002222')$$,
  'you cannot create a section as somebody else');
select pg_temp.expect_fail(
  $$select created_by_phone from public.public_forum_sections$$,
  'a client cannot read who made a section');
select pg_temp.expect_ok(
  $$insert into public.public_forum_posts
      (id, author_phone, author_username, title, section)
    values ('t_fs','15550001111','alice','In a board','photography')$$,
  'a post can name a section');

-- Votes: your own, and you can see only your own.
select pg_temp.expect_ok(
  $$insert into public.public_forum_votes (post_id, voter_phone, dir)
    values ('t_f1','15550001111',1)$$,
  'you can upvote a forum post');
do $$ begin
  if (select score from public.public_forum where id='t_f1') <> 1 then
    raise exception 'CHECK FAILED: the forum score did not tally the vote';
  end if;
  raise notice '  ok   the forum score tallies votes through the view';
end $$;
select pg_temp.expect_fail(
  $$insert into public.public_forum_votes (post_id, voter_phone, dir)
    values ('t_f1','15550002222',1)$$,
  'you cannot vote as somebody else');
-- Reading voter_phone is ALLOWED and has to be (the upsert below needs it),
-- but the read policy scopes it to your own row — so the only number it can
-- hand back is the one you already know.
select pg_temp.expect_ok(
  $$select voter_phone from public.public_forum_votes$$,
  'you can read your own vote row');
-- DOWN-voting, and CHANGING a vote. The app sends both as PostgREST's
-- upsert, which is INSERT ... ON CONFLICT DO UPDATE — a different statement
-- from the plain insert above, and one that has to satisfy the INSERT policy
-- and the UPDATE policy at once.
select pg_temp.expect_ok(
  $$insert into public.public_forum_votes (post_id, voter_phone, dir)
    values ('t_fs','15550001111',-1)
    on conflict (post_id, voter_phone) do update
      set post_id = excluded.post_id,
          voter_phone = excluded.voter_phone,
          dir = excluded.dir$$,
  'you can downvote a forum post');
select pg_temp.expect_ok(
  $$insert into public.public_forum_votes (post_id, voter_phone, dir)
    values ('t_f1','15550001111',-1)
    on conflict (post_id, voter_phone) do update
      set post_id = excluded.post_id,
          voter_phone = excluded.voter_phone,
          dir = excluded.dir$$,
  'you can change an upvote into a downvote');
do $$ begin
  if (select score from public.public_forum where id='t_f1') <> -1 then
    raise exception 'CHECK FAILED: the score did not follow the changed vote';
  end if;
  raise notice '  ok   the score follows a vote changed to a downvote';
end $$;
-- The guarantee the column grant was mistaken for: somebody ELSE's vote is
-- invisible, and that is the read POLICY's doing, not the grant's. Planted
-- with the role reset so RLS does not stop the setup.
reset role;
insert into public.public_forum_votes (post_id, voter_phone, dir)
  values ('t_f1','15550009999',1) on conflict do nothing;
set role authenticated;
do $$ begin
  if exists (select 1 from public.public_forum_votes
             where voter_phone <> '15550001111') then
    raise exception 'CHECK FAILED: somebody else''s forum vote is readable';
  end if;
  raise notice '  ok   another account''s forum vote stays invisible';
end $$;

-- Comments: your own only.
select pg_temp.expect_ok(
  $$insert into public.public_forum_comments
      (id, post_id, author_phone, author_username, body)
    values ('t_fc1','t_f1','15550001111','alice','nice post')$$,
  'you can comment on a forum post');
select pg_temp.expect_fail(
  $$insert into public.public_forum_comments
      (id, post_id, author_phone, author_username, body)
    values ('t_fc2','t_f1','15550002222','bob','as bob')$$,
  'you cannot comment as somebody else');
select pg_temp.expect_fail(
  $$select author_phone from public.public_forum_comments$$,
  'a client cannot read a forum commenter phone');
do $$ begin
  if (select comment_count from public.public_forum where id='t_f1') <> 1 then
    raise exception 'CHECK FAILED: the forum comment_count is wrong';
  end if;
  raise notice '  ok   the forum comment_count tallies through the view';
end $$;

-- Comment votes (public_forum_comment_votes.sql). Posts have had votes since
-- the forum shipped; comments never did, so a good answer three replies deep
-- had no way to rise. Same protections one level down.
select pg_temp.expect_ok(
  $$insert into public.public_forum_comment_votes (comment_id, voter_phone, dir)
    values ('t_fc1','15550001111',1)$$,
  'you can up-vote a comment');
select pg_temp.expect_fail(
  $$insert into public.public_forum_comment_votes (comment_id, voter_phone, dir)
    values ('t_fc1','15550002222',1)$$,
  'you cannot vote on a comment as somebody else');
-- A withdrawn vote is a deleted row; the constraint refuses a stored zero, so
-- the tally never has to filter.
select pg_temp.expect_fail(
  $$insert into public.public_forum_comment_votes (comment_id, voter_phone, dir)
    values ('t_fc1','15550001111',0)$$,
  'a zero is not a comment vote');
-- Who voted is the voter's business. A device may read its OWN vote (so the
-- arrow can show as chosen), and RLS FILTERS the rest rather than erroring —
-- so the check is that no other voter's row comes back, not that the query
-- is refused. Asserting a refusal here passed a leak once already in this
-- project, on the directory migration.
do $$
declare n int;
begin
  select count(*) into n from public.public_forum_comment_votes
    where voter_phone <> '15550001111';
  if n <> 0 then
    raise exception 'CHECK FAILED: a client read somebody else''s comment vote';
  end if;
  raise notice '  ok   a client sees only its own comment votes';
  select count(*) into n from public.public_forum_comment_votes
    where voter_phone = '15550001111';
  if n <> 1 then
    raise exception 'CHECK FAILED: a client cannot see its own comment vote';
  end if;
  raise notice '  ok   and can see its own, so the arrow can show as chosen';
end $$;
-- The score reaches the client only through the phone-free view.
select pg_temp.expect_ok(
  $$select id, body, score from public.public_forum_comments_v$$,
  'the comments view carries the score');
select pg_temp.expect_fail(
  $$select author_phone from public.public_forum_comments_v$$,
  'the comments view has no author phone');

-- A banned author's comment disappears through the view — this is the check
-- that would have caught the missing security_invoker: without it the view
-- ran as its owner and silently ignored public_forum_comments_read's
-- ban-hiding, so a banned author's comments stayed readable through the view
-- even though the base table's own RLS was correct all along.
reset role;
insert into public.public_forum_comments
    (id, post_id, author_phone, author_username, body)
  values ('t_fcban','t_f1','15550009999','banned','hidden');
set role authenticated;
select pg_temp.as_user('15550001111');
do $$ begin
  if (select count(*) from public.public_forum_comments_v where id='t_fcban') <> 0 then
    raise exception 'SECURITY CHECK FAILED: a banned author''s comment is still in the view';
  end if;
  raise notice '  ok   a banned author''s comment leaves the comments view';
end $$;


-- A timed-out account is silenced: it may read, but not post, vote or comment.
-- The public-feed block above cleared this account's timeout, so re-establish
-- one (as the table owner — account_sanctions is not client-writable).
reset role;
insert into public.account_sanctions (phone, kind, until)
  values ('15550003333', 'timeout', now() + interval '1 hour')
  on conflict (phone) do update
    set kind = excluded.kind, until = excluded.until;
set role authenticated;
select pg_temp.as_user('15550003333');            -- the timed-out account
select pg_temp.expect_ok(
  $$select id, title from public.public_forum$$,
  'a silenced account can still read the forum');
select pg_temp.expect_fail(
  $$insert into public.public_forum_posts
      (id, author_phone, author_username, title)
    values ('t_f3','15550003333','muted','while silenced')$$,
  'a silenced account cannot post to the forum');
reset role;

-- Community notes (community_notes.sql): reader fact-checks on a public post.
-- Add a note as yourself only, phones never readable, select * refused,
-- ratings own-only, and the helpful/total tallies come off a phone-free view.
set role authenticated;
select pg_temp.as_user('15550001111');            -- alice
select pg_temp.expect_ok(
  $$insert into public.public_posts (id, author_phone, author_username, body)
    values ('t_cnpost','15550001111','alice','a post to note')$$,
  'a post to attach a note to');
select pg_temp.expect_ok(
  $$insert into public.community_notes
      (id, post_id, author_phone, author_username, body)
    values ('t_cn1','t_cnpost','15550001111','alice','some context')$$,
  'you can add a community note as yourself');
select pg_temp.expect_fail(
  $$insert into public.community_notes
      (id, post_id, author_phone, author_username, body)
    values ('t_cn2','t_cnpost','15550002222','bob','as bob')$$,
  'you cannot add a note as somebody else');
select pg_temp.expect_fail(
  $$select author_phone from public.community_notes$$,
  'a client cannot read a note author phone');
select pg_temp.expect_fail(
  $$select * from public.community_notes$$,
  'select * on community notes is refused (it would include the phone)');
select pg_temp.expect_ok(
  $$select id, body, helpful_count, not_helpful_count
      from public.community_notes_view$$,
  'the notes view reads fine, with the tallies');
select pg_temp.expect_ok(
  $$insert into public.community_note_ratings (note_id, rater_phone, helpful)
    values ('t_cn1','15550001111',true)$$,
  'you can rate a note helpful');
select pg_temp.expect_fail(
  $$insert into public.community_note_ratings (note_id, rater_phone, helpful)
    values ('t_cn1','15550002222',true)$$,
  'you cannot rate a note as somebody else');
select pg_temp.expect_fail(
  $$select rater_phone from public.community_note_ratings$$,
  'a client cannot read who rated a note');
do $$ begin
  if (select helpful_count from public.community_notes_view where id='t_cn1')
       <> 1 then
    raise exception 'CHECK FAILED: the note helpful_count did not tally';
  end if;
  raise notice '  ok   the note helpful_count tallies through the view';
end $$;
reset role;

-- Global marketplace (public_market.sql): a world-readable listings table that
-- lives outside any server, so a brand-new account in no servers can still
-- browse. Same protections as the public feed/forum — post as yourself only,
-- phones never readable, select * refused, a listing editable only by its
-- author, a banned seller hidden, and a phone-free view anyone (anon included)
-- can read.
set role authenticated;
select pg_temp.as_user('15550001111');            -- alice
select pg_temp.expect_ok(
  $$insert into public.market_listings (id, author_phone, author_username, payload)
    values ('t_ml1','15550001111','alice','{"id":"t_ml1","priceCents":500}')$$,
  'you can list an item as yourself');
select pg_temp.expect_fail(
  $$insert into public.market_listings (id, author_phone, author_username, payload)
    values ('t_ml2','15550002222','bob','{"id":"t_ml2"}')$$,
  'you cannot list as somebody else');
select pg_temp.expect_fail(
  $$select author_phone from public.market_listings$$,
  'a client cannot read a seller''s phone');
select pg_temp.expect_fail(
  $$select * from public.market_listings$$,
  'select * on listings is refused (it would include the phone)');
select pg_temp.expect_ok(
  $$select id, author_username, payload from public.market_listings_view$$,
  'the listings view reads fine');
select pg_temp.expect_ok(
  $$update public.market_listings
      set payload = '{"id":"t_ml1","listingSold":true}' where id = 't_ml1'$$,
  'the seller can edit their own listing');
-- A stranger's UPDATE matches no row under RLS and silently changes nothing.
select pg_temp.as_user('15550002222');
do $$ begin
  update public.market_listings set payload = '{"hijacked":true}'
    where id = 't_ml1';
  if (select payload from public.market_listings_view where id='t_ml1')
       = '{"hijacked":true}' then
    raise exception 'SECURITY CHECK FAILED: a stranger edited a listing';
  end if;
  raise notice '  ok   a stranger cannot edit your listing';
end $$;
-- A banned seller's listing leaves the marketplace the moment the ban lands.
reset role;
insert into public.market_listings (id, author_phone, author_username, payload)
  values ('t_mlban','15550009999','banned','{"id":"t_mlban"}');
set role authenticated;
select pg_temp.as_user('15550001111');
do $$ begin
  if (select count(*) from public.market_listings_view where id='t_mlban') <> 0
  then
    raise exception 'SECURITY CHECK FAILED: a banned seller is still listed';
  end if;
  raise notice '  ok   a banned seller leaves the marketplace';
end $$;
-- World-readable: the anon key (a name-only browser, a brand-new account) can
-- read the listings view — the whole point of the global marketplace.
reset role;
set role anon;
do $$ begin
  if (select count(*) from public.market_listings_view where id='t_ml1') <> 1 then
    raise exception 'CHECK FAILED: anon cannot browse the marketplace';
  end if;
  raise notice '  ok   anyone (anon included) can browse the marketplace';
end $$;
reset role;

-- PUBLISHING ITSELF (market_upsert_fix.sql) — the bug that made the whole
-- global marketplace dead on arrival, and the one thing none of the checks
-- above could see. They all use a PLAIN insert; the app uses PostgREST's
-- UPSERT, which compiles to `on conflict (id) do update set <every column
-- sent>`. Naming author_phone there becomes `= excluded.author_phone`, a READ
-- of the one column deliberately withheld from clients — and Postgres refuses
-- the entire statement at PLAN time (42501), even for a brand-new id that
-- could never conflict. Every publish failed; the table never held a row.
set role authenticated;
select pg_temp.as_user('15550001111');            -- alice
-- What the app sends NOW: no author_phone at all.
select pg_temp.expect_ok(
  $$insert into public.market_listings
      (id, author_username, payload, updated_at)
      values ('t_mlup','alice','{"id":"t_mlup","v":1}', now())
    on conflict (id) do update set
      author_username = excluded.author_username,
      payload         = excluded.payload,
      updated_at      = excluded.updated_at$$,
  'publishing a listing works (the real upsert, not a plain insert)');
-- Re-publishing the same id (an edit, a price drop, marking it sold) is the
-- conflict path — the half a fresh-insert test can never reach.
select pg_temp.expect_ok(
  $$insert into public.market_listings
      (id, author_username, payload, updated_at)
      values ('t_mlup','alice','{"id":"t_mlup","v":2}', now())
    on conflict (id) do update set
      author_username = excluded.author_username,
      payload         = excluded.payload,
      updated_at      = excluded.updated_at$$,
  'and re-publishing an edit works too (the conflict path)');
-- The regression guard: the exact statement that was broken must STAY broken,
-- or somebody "simplifying" the client back to sending author_phone silently
-- kills publishing again with no test to catch it.
select pg_temp.expect_fail(
  $$insert into public.market_listings
      (id, author_phone, author_username, payload)
      values ('t_mlup','15550001111','alice','{}')
    on conflict (id) do update set author_phone = excluded.author_phone$$,
  'naming author_phone in an upsert is still refused (the original bug)');
reset role;
do $$ begin
  -- Read as the owner: a client still cannot see this column at all.
  if (select author_phone from public.market_listings where id='t_mlup')
       is distinct from '15550001111' then
    raise exception 'CHECK FAILED: author_phone did not fill from the JWT';
  end if;
  raise notice '  ok   author_phone fills from the caller''s own JWT, unforgeably';
  if (select payload from public.market_listings where id='t_mlup')
       <> '{"id":"t_mlup","v":2}' then
    raise exception 'CHECK FAILED: the edit did not land';
  end if;
  raise notice '  ok   and an edit really updates the row';
end $$;
-- market_reviews carries the identical column grant and the identical bug.
set role authenticated;
select pg_temp.as_user('15550001111');
select pg_temp.expect_ok(
  $$insert into public.market_reviews
      (id, listing_id, author_username, payload, updated_at)
      values ('t_mrup','t_mlup','alice','{"id":"t_mrup"}', now())
    on conflict (id) do update set
      payload    = excluded.payload,
      updated_at = excluded.updated_at$$,
  'publishing a review works (the real upsert)');
select pg_temp.expect_fail(
  $$insert into public.market_reviews
      (id, listing_id, author_phone, author_username, payload)
      values ('t_mrup','t_mlup','15550001111','alice','{}')
    on conflict (id) do update set author_phone = excluded.author_phone$$,
  'naming author_phone in a review upsert is still refused');
-- server_directory is the THIRD table with this bug, and it was nearly missed:
-- a first probe upserted it without owner_phone in the DO UPDATE (which
-- passes) and that was read as "unaffected". What publishServerDirectory
-- really sends names the column, so publishing a public server was refused
-- and Discover stayed empty. Pin the statement the CLIENT actually sends.
select pg_temp.expect_ok(
  $$insert into public.server_directory
      (id, name, description, member_count, payload, updated_at)
      values ('t_sd_up','Room','d',2,'{"id":"t_sd_up"}', now())
    on conflict (id) do update set
      name         = excluded.name,
      description  = excluded.description,
      member_count = excluded.member_count,
      payload      = excluded.payload,
      updated_at   = excluded.updated_at$$,
  'publishing a public server to Discover works (the real upsert)');
select pg_temp.expect_fail(
  $$insert into public.server_directory
      (id, owner_phone, name, member_count, payload)
      values ('t_sd_up','15550001111','Room',2,'{}')
    on conflict (id) do update set owner_phone = excluded.owner_phone$$,
  'naming owner_phone in a directory upsert is still refused');
reset role;
do $$ begin
  if (select owner_phone from public.server_directory where id='t_sd_up')
       is distinct from '15550001111' then
    raise exception 'CHECK FAILED: owner_phone did not fill from the JWT';
  end if;
  raise notice '  ok   owner_phone fills from the caller''s own JWT too';
end $$;

-- Marketplace reviews (market_reviews.sql): the fix for reviews never
-- reaching anyone but the reviewer's own device. Same shape of protections
-- as the listings table above.
set role authenticated;
select pg_temp.as_user('15550001111');            -- alice
select pg_temp.expect_ok(
  $$insert into public.market_reviews (id, listing_id, author_phone, author_username, payload)
    values ('t_mr1','t_ml1','15550001111','alice','{"id":"t_mr1","rating":5}')$$,
  'you can review a listing as yourself');
select pg_temp.expect_fail(
  $$insert into public.market_reviews (id, listing_id, author_phone, author_username, payload)
    values ('t_mr2','t_ml1','15550002222','bob','{"id":"t_mr2"}')$$,
  'you cannot post a review as somebody else');
select pg_temp.expect_fail(
  $$select author_phone from public.market_reviews$$,
  'a client cannot read a reviewer''s phone');
select pg_temp.expect_fail(
  $$select * from public.market_reviews$$,
  'select * on reviews is refused (it would include the phone)');
select pg_temp.expect_ok(
  $$select id, listing_id, author_username, payload from public.market_reviews_view$$,
  'the reviews view reads fine');
-- A stranger's UPDATE matches no row under RLS and silently changes nothing.
select pg_temp.as_user('15550002222');
do $$ begin
  update public.market_reviews set payload = '{"hijacked":true}'
    where id = 't_mr1';
  if (select payload from public.market_reviews_view where id='t_mr1')
       = '{"hijacked":true}' then
    raise exception 'SECURITY CHECK FAILED: a stranger edited a review';
  end if;
  raise notice '  ok   a stranger cannot edit your review';
end $$;
-- A banned reviewer's review leaves the marketplace the moment the ban lands.
reset role;
insert into public.market_reviews (id, listing_id, author_phone, author_username, payload)
  values ('t_mrban','t_ml1','15550009999','banned','{"id":"t_mrban"}');
set role authenticated;
select pg_temp.as_user('15550001111');
do $$ begin
  if (select count(*) from public.market_reviews_view where id='t_mrban') <> 0
  then
    raise exception 'SECURITY CHECK FAILED: a banned reviewer''s review is still visible';
  end if;
  raise notice '  ok   a banned reviewer''s review leaves the marketplace';
end $$;
-- World-readable: the anon key (a name-only browser, a brand-new account)
-- can read reviews — the whole point of the fix.
reset role;
set role anon;
do $$ begin
  if (select count(*) from public.market_reviews_view where id='t_mr1') <> 1 then
    raise exception 'CHECK FAILED: anon cannot read marketplace reviews';
  end if;
  raise notice '  ok   anyone (anon included) can read marketplace reviews';
end $$;
reset role;

-- Discover directory (public_servers.sql): a world-readable list of PUBLIC
-- servers anyone can find and join. Same protections as the marketplace — list
-- as yourself only, the owner's phone never readable, select * refused, editable
-- only by its owner, a banned owner hidden, and a phone-free view anyone (anon
-- included) can read.
set role authenticated;
select pg_temp.as_user('15550001111');            -- alice
select pg_temp.expect_ok(
  $$insert into public.server_directory (id, owner_phone, name, description, member_count, payload)
    values ('t_sd1','15550001111','Alice''s Server','come in','3','{"id":"t_sd1","secret":"aa"}')$$,
  'you can list a server you own');
select pg_temp.expect_fail(
  $$insert into public.server_directory (id, owner_phone, name, payload)
    values ('t_sd2','15550002222','Bob''s','{"id":"t_sd2"}')$$,
  'you cannot list a server as somebody else');
select pg_temp.expect_fail(
  $$select owner_phone from public.server_directory$$,
  'a client cannot read a server owner''s phone');
select pg_temp.expect_fail(
  $$select * from public.server_directory$$,
  'select * on the directory is refused (it would include the phone)');
select pg_temp.expect_ok(
  $$select id, name, payload from public.server_directory_view$$,
  'the directory view reads fine');
select pg_temp.expect_ok(
  $$update public.server_directory set member_count = 4 where id = 't_sd1'$$,
  'the owner can update their own directory row');
-- A stranger's UPDATE matches no row under RLS and silently changes nothing.
select pg_temp.as_user('15550002222');
do $$ begin
  update public.server_directory set name = 'hijacked' where id = 't_sd1';
  if (select name from public.server_directory_view where id='t_sd1') = 'hijacked'
  then
    raise exception 'SECURITY CHECK FAILED: a stranger edited a directory row';
  end if;
  raise notice '  ok   a stranger cannot edit your directory row';
end $$;
-- A banned owner's server leaves the directory the moment the ban lands.
reset role;
insert into public.server_directory (id, owner_phone, name, payload)
  values ('t_sdban','15550009999','Banned','{"id":"t_sdban"}');
set role authenticated;
select pg_temp.as_user('15550001111');
do $$ begin
  if (select count(*) from public.server_directory_view where id='t_sdban') <> 0
  then
    raise exception 'SECURITY CHECK FAILED: a banned owner is still listed';
  end if;
  raise notice '  ok   a banned owner leaves the directory';
end $$;
-- World-readable: the anon key (a name-only browser, a brand-new account) can
-- read the directory view — the whole point of Discover.
reset role;
set role anon;
do $$ begin
  if (select count(*) from public.server_directory_view where id='t_sd1') <> 1 then
    raise exception 'CHECK FAILED: anon cannot browse Discover';
  end if;
  raise notice '  ok   anyone (anon included) can browse Discover';
end $$;
reset role;

-- Server-authoritative structure (community_structure.sql): community
-- identity/channels/roster/roles move from pure client gossip to a durable,
-- RLS-scoped copy the server can actually enforce. Join is gated by an RPC
-- comparing a client-computed secret hash — never a permissive insert policy
-- — because Community.id ('c_${name.hashCode}_${count}') is low-entropy and
-- guessable; the roster stays readable only to actual members; and a direct
-- self-insert into community_members must fail (only the RPC path works).
set role authenticated;
select pg_temp.as_user('15550001111');            -- alice, the owner
select pg_temp.expect_ok(
  $$insert into public.community_servers (id, owner_phone, secret_hash, name)
    values ('t_cs1','15550001111','deadbeef','Alice''s Server')$$,
  'you can create a server you own');
select pg_temp.expect_fail(
  $$insert into public.community_servers (id, owner_phone, secret_hash, name)
    values ('t_cs2','15550002222','beefdead','Bob''s')$$,
  'you cannot create a server as somebody else');
select pg_temp.expect_fail(
  $$select secret_hash from public.community_servers where id='t_cs1'$$,
  'a client cannot read a server''s secret hash');
select pg_temp.expect_fail(
  $$select * from public.community_servers where id='t_cs1'$$,
  'select * on community_servers is refused (it would include the hash)');
select pg_temp.expect_ok(
  $$select id, name from public.community_servers where id='t_cs1'$$,
  'the owner can read their own server''s safe columns');
do $$ begin
  if not public.is_community_member('t_cs1', '15550001111') then
    raise exception 'CHECK FAILED: the owner-seed trigger did not add the owner to their own roster';
  end if;
  raise notice '  ok   creating a server seeds the owner''s own roster row';
end $$;

-- A stranger cannot self-insert into the roster directly — this is the exact
-- bug caught and fixed while writing this policy: community_members_insert
-- is admin-only, and self-join can ONLY happen through community_join(),
-- which runs as security definer and needs no client insert privilege.
select pg_temp.as_user('15550002222');            -- bob, a stranger
select pg_temp.expect_fail(
  $$insert into public.community_members (community_id, member_phone, role)
    values ('t_cs1','15550002222','member')$$,
  'a stranger cannot self-insert into a server''s roster');
do $$ begin
  if (select count(*) from public.community_channels where community_id='t_cs1') <> 0 then
    raise exception 'SECURITY CHECK FAILED: a non-member can read a server''s channels';
  end if;
  raise notice '  ok   a non-member cannot read a server''s channels';
end $$;

-- community_join() with the wrong hash is a silent no-op — same contract as
-- every other RPC here guarding a real secret.
do $$ begin
  perform public.community_join('t_cs1', 'wrongvalue', 'Bob');
  if public.is_community_member('t_cs1', '15550002222') then
    raise exception 'SECURITY CHECK FAILED: joined with the wrong secret hash';
  end if;
  raise notice '  ok   community_join with the wrong secret hash does nothing';
end $$;

-- The right hash joins for real.
do $$ begin
  perform public.community_join('t_cs1', 'deadbeef', 'Bob');
  if not public.is_community_member('t_cs1', '15550002222') then
    raise exception 'CHECK FAILED: community_join with the right secret hash did not join';
  end if;
  raise notice '  ok   community_join with the right secret hash joins';
end $$;
select pg_temp.expect_ok(
  $$select id, name from public.community_servers where id='t_cs1'$$,
  'a real member can read the server once joined');
select pg_temp.expect_ok(
  $$select member_phone, role from public.community_members where community_id='t_cs1'$$,
  'a real member can read the roster once joined');

-- A per-server ban refuses the join even with the right secret (distinct from
-- a platform-wide ban — carol here is not otherwise sanctioned at all).
reset role;
insert into public.community_bans (community_id, member_phone, member_name)
  values ('t_cs1','15550004444','Carol');
set role authenticated;
select pg_temp.as_user('15550004444');            -- carol, banned from THIS server only
do $$ begin
  perform public.community_join('t_cs1', 'deadbeef', 'Carol');
  if public.is_community_member('t_cs1', '15550004444') then
    raise exception 'SECURITY CHECK FAILED: a banned account joined anyway';
  end if;
  raise notice '  ok   a server ban refuses the join even with the right secret';
end $$;

-- A paid server refuses the join without an active pass, and admits one with
-- a pass. community_passes has NO client grants at all (docs/paid_servers.sql),
-- so seeding one for the test goes through the table owner, exactly like the
-- account_sanctions seeds above.
select pg_temp.as_user('15550001111');
select pg_temp.expect_ok(
  $$insert into public.community_servers (id, owner_phone, secret_hash, name, paid, price_cents)
    values ('t_cspaid','15550001111','cafebabe','Alice''s Paid Server',true,499)$$,
  'the owner can create a paid server');
select pg_temp.as_user('15550005555');            -- dave, no pass yet
do $$ begin
  perform public.community_join('t_cspaid', 'cafebabe', 'Dave');
  if public.is_community_member('t_cspaid', '15550005555') then
    raise exception 'SECURITY CHECK FAILED: joined a paid server with no active pass';
  end if;
  raise notice '  ok   joining a paid server with no active pass does nothing';
end $$;
reset role;
insert into public.community_passes (subscriber_phone, server_id, expires_at)
  values ('15550005555','t_cspaid', now() + interval '30 days');
set role authenticated;
select pg_temp.as_user('15550005555');
do $$ begin
  perform public.community_join('t_cspaid', 'cafebabe', 'Dave');
  if not public.is_community_member('t_cspaid', '15550005555') then
    raise exception 'CHECK FAILED: an active pass did not let the join through';
  end if;
  raise notice '  ok   an active pass lets the paid-server join through';
end $$;
reset role;

-- anon must never reach any of these five tables — asserted on the GRANT
-- rather than by a query, same reason as find_people_by_hashes above: a
-- live Supabase project grants table-wide privileges to anon on every NEW
-- table by default, and this throwaway Postgres has no such default, so it
-- can never reproduce the bug this pins. Found live on this exact file:
-- community_servers was correctly revoked (it has a sensitive column), but
-- community_members/_channels/_roles/_bans had no revoke at all, so anon
-- quietly held full SELECT/INSERT/UPDATE/DELETE on all four — RLS still
-- blocked every one of them in practice (every policy here is scoped `to
-- authenticated` only), but that is exactly the "RLS alone" gap this
-- codebase already learned costs something the day a policy changes.
do $$ begin
  if has_table_privilege('anon', 'public.community_servers', 'select')
      or has_table_privilege('anon', 'public.community_members', 'select')
      or has_table_privilege('anon', 'public.community_channels', 'select')
      or has_table_privilege('anon', 'public.community_roles', 'select')
      or has_table_privilege('anon', 'public.community_bans', 'select')
  then
    raise exception 'SECURITY CHECK FAILED: anon can read server structure';
  end if;
  if has_table_privilege('anon', 'public.community_members', 'insert')
      or has_table_privilege('anon', 'public.community_channels', 'insert')
  then
    raise exception 'SECURITY CHECK FAILED: anon can write server structure';
  end if;
  raise notice '  ok   anon has no privilege at all on the structure tables';
end $$;

-- Voice channel presence (community_voice.sql): a ground-truth read of who
-- is actually in a voice channel, reusing t_cs1 (alice owns it, bob joined
-- earlier in this file) rather than standing up a fresh server.
set role authenticated;
select pg_temp.as_user('15550001111');            -- alice, the owner
select pg_temp.expect_ok(
  $$insert into public.community_voice_presence
      (channel_id, member_phone, community_id, member_name)
    values ('t_vc1','15550001111','t_cs1','Alice')$$,
  'a member can announce their own voice presence');
select pg_temp.expect_fail(
  $$insert into public.community_voice_presence
      (channel_id, member_phone, community_id, member_name)
    values ('t_vc1','15550002222','t_cs1','Bob')$$,
  'you cannot announce presence as somebody else');
select pg_temp.as_user('15550006666');            -- a stranger, never joined t_cs1
select pg_temp.expect_fail(
  $$insert into public.community_voice_presence
      (channel_id, member_phone, community_id, member_name)
    values ('t_vc1','15550006666','t_cs1','Stranger')$$,
  'a non-member cannot announce presence in a server they are not in');
do $$ begin
  if (select count(*) from public.community_voice_presence where channel_id='t_vc1') <> 0 then
    raise exception 'SECURITY CHECK FAILED: a non-member can read voice presence';
  end if;
  raise notice '  ok   a non-member cannot read a channel''s voice presence';
end $$;

select pg_temp.as_user('15550002222');            -- bob, a real member
select pg_temp.expect_ok(
  $$insert into public.community_voice_presence
      (channel_id, member_phone, community_id, member_name)
    values ('t_vc1','15550002222','t_cs1','Bob')$$,
  'a fellow member can announce their own presence');
select pg_temp.expect_ok(
  $$select member_phone from public.community_voice_presence where channel_id='t_vc1'$$,
  'a member can read who else is in the channel');
select pg_temp.expect_ok(
  $$update public.community_voice_presence set muted = true
    where channel_id='t_vc1' and member_phone='15550002222'$$,
  'a member can update their own mic state');
-- Bob's UPDATE against alice's row matches no row under RLS and silently
-- changes nothing — same "stranger's UPDATE is a no-op" pattern as every
-- other table in this codebase.
do $$ begin
  update public.community_voice_presence set muted = true
    where channel_id='t_vc1' and member_phone='15550001111';
  if (select muted from public.community_voice_presence
        where channel_id='t_vc1' and member_phone='15550001111') then
    raise exception 'SECURITY CHECK FAILED: a member rewrote another member''s mic state';
  end if;
  raise notice '  ok   a member cannot rewrite another member''s presence row';
end $$;
select pg_temp.expect_ok(
  $$delete from public.community_voice_presence
    where channel_id='t_vc1' and member_phone='15550002222'$$,
  'a member can leave voice themself (delete their own row)');

-- A moderator+ (alice, the owner) can force-disconnect someone else — the
-- eviction capability the old broadcast-only model literally could not
-- offer, since there was nothing to delete.
reset role;
insert into public.community_voice_presence
  (channel_id, member_phone, community_id, member_name)
  values ('t_vc1','15550002222','t_cs1','Bob');
set role authenticated;
select pg_temp.as_user('15550001111');
select pg_temp.expect_ok(
  $$delete from public.community_voice_presence
    where channel_id='t_vc1' and member_phone='15550002222'$$,
  'a moderator can force-disconnect someone else from voice');

-- A plain member (not a moderator) cannot evict anyone else — alice's own
-- row has sat untouched since the very first insert above; bob (a plain
-- member, no moderation power) tries to delete it and must match nothing.
select pg_temp.as_user('15550002222');            -- bob, still a plain member
do $$ begin
  delete from public.community_voice_presence
    where channel_id='t_vc1' and member_phone='15550001111';
  if (select count(*) from public.community_voice_presence
        where channel_id='t_vc1' and member_phone='15550001111') <> 1 then
    raise exception 'SECURITY CHECK FAILED: a plain member evicted the owner from voice';
  end if;
  raise notice '  ok   a plain member cannot evict anyone else from voice';
end $$;
reset role;

-- anon has no privilege on this table either — same closed-from-the-start
-- posture as every table in community_structure.sql.
do $$ begin
  if has_table_privilege('anon', 'public.community_voice_presence', 'select') then
    raise exception 'SECURITY CHECK FAILED: anon can read voice presence';
  end if;
  raise notice '  ok   anon has no privilege at all on voice presence';
end $$;

-- Chat structure (chat_structure.sql), Phase 3 of "central authority": a
-- group's roster gets the same owner-seed-trigger bootstrap as a server, and
-- ANY existing member may add another (matches the shipped app — only
-- REMOVAL is admin-gated, adding/renaming is not).
set role authenticated;
select pg_temp.as_user('15550001111');            -- alice
select pg_temp.expect_ok(
  $$insert into public.direct_chats (id, is_group, owner_phone, name)
    values ('t_grp1', true, '15550001111', 'Trail Runners')$$,
  'you can create a group you own');
select pg_temp.expect_fail(
  $$insert into public.direct_chats (id, is_group, owner_phone, name)
    values ('t_grp2', true, '15550002222', 'Bob''s Group')$$,
  'you cannot create a group as somebody else');
do $$ begin
  if not public.is_chat_member('t_grp1', '15550001111') then
    raise exception 'CHECK FAILED: creating a group did not seed the owner''s own roster row';
  end if;
  raise notice '  ok   creating a group seeds the owner''s own roster row';
end $$;

select pg_temp.as_user('15550002222');            -- bob, a stranger to t_grp1
select pg_temp.expect_fail(
  $$insert into public.chat_members (chat_id, member_phone) values ('t_grp1','15550002222')$$,
  'a stranger cannot self-insert into a group''s roster');
do $$ begin
  if (select count(*) from public.direct_chats where id='t_grp1') <> 0 then
    raise exception 'SECURITY CHECK FAILED: a non-member can read a group they are not in';
  end if;
  raise notice '  ok   a non-member cannot read a group''s structure';
end $$;

select pg_temp.as_user('15550001111');
select pg_temp.expect_ok(
  $$insert into public.chat_members (chat_id, member_phone) values ('t_grp1','15550002222')$$,
  'an existing member (the owner) can add another member');
select pg_temp.as_user('15550002222');
select pg_temp.expect_ok(
  $$select id, name from public.direct_chats where id='t_grp1'$$,
  'a real member can read the group once added');
select pg_temp.expect_ok(
  $$insert into public.chat_members (chat_id, member_phone) values ('t_grp1','15550004444')$$,
  'a plain (non-owner) member can also add someone — matches the shipped app''s ungated add');
select pg_temp.expect_ok(
  $$update public.direct_chats set name='Trail Runners Club', about='hills' where id='t_grp1'$$,
  'a plain member can rename/edit the group — matches the shipped app''s ungated editor');
-- A DELETE that matches no row under RLS does not raise — it just deletes
-- zero rows, same "stranger's write is a silent no-op" shape
-- community_voice_presence's own test above already relies on — so these
-- are row-count checks, not expect_fail (which would pass on a real success
-- too, since no exception is ever thrown either way).
do $$ begin
  delete from public.chat_members where chat_id='t_grp1' and member_phone='15550004444';
  if (select count(*) from public.chat_members
        where chat_id='t_grp1' and member_phone='15550004444') <> 1 then
    raise exception 'SECURITY CHECK FAILED: a plain (non-owner) member removed someone';
  end if;
  raise notice '  ok   a plain (non-owner) member cannot remove anyone';
end $$;
select pg_temp.expect_fail(
  $$update public.direct_chats set owner_phone='15550002222' where id='t_grp1'$$,
  'nobody can rewrite a group''s owner_phone — it is not in the update column grant');

select pg_temp.as_user('15550001111');            -- alice, the real owner
select pg_temp.expect_ok(
  $$delete from public.chat_members where chat_id='t_grp1' and member_phone='15550004444'$$,
  'the owner can remove a non-owner member');
do $$ begin
  delete from public.chat_members where chat_id='t_grp1' and member_phone='15550001111';
  if (select count(*) from public.chat_members
        where chat_id='t_grp1' and member_phone='15550001111') <> 1 then
    raise exception 'SECURITY CHECK FAILED: the owner removed themselves';
  end if;
  raise notice '  ok   the owner can never remove themselves — matches the shipped app''s i != 0 guard';
end $$;

-- A 1:1 (owner_phone = ''): bootstrap is name-checked against phone_a/phone_b
-- instead of a trigger, since there is no single owner identity to seed from.
select pg_temp.expect_ok(
  $$insert into public.direct_chats (id, is_group, phone_a, phone_b)
    values ('t_dm1', false, '15550001111', '15550004444')$$,
  'either named party can create a 1:1''s structure row');
select pg_temp.expect_fail(
  $$insert into public.direct_chats (id, is_group, owner_phone, phone_a, phone_b)
    values ('t_dm2', false, '15550001111', '15550002222', '15550004444')$$,
  'a 1:1 cannot be created with a real owner_phone set');
select pg_temp.as_user('15550002222');            -- bob, not a party to t_dm1
select pg_temp.expect_fail(
  $$insert into public.direct_chats (id, is_group, phone_a, phone_b)
    values ('t_dm3', false, '15550001111', '15550004444')$$,
  'you cannot create a 1:1 naming two OTHER people, even if you are signed in');
select pg_temp.expect_fail(
  $$insert into public.chat_members (chat_id, member_phone) values ('t_dm1','15550002222')$$,
  'a stranger cannot self-insert into a 1:1 they are not named in');

select pg_temp.as_user('15550001111');            -- alice, named phone_a
select pg_temp.expect_ok(
  $$insert into public.chat_members (chat_id, member_phone) values ('t_dm1','15550001111')$$,
  'a 1:1''s own named party (phone_a) can self-register');
select pg_temp.as_user('15550004444');            -- carol, named phone_b
select pg_temp.expect_ok(
  $$insert into public.chat_members (chat_id, member_phone) values ('t_dm1','15550004444')$$,
  'a 1:1''s own named party (phone_b) can self-register');
do $$ begin
  delete from public.chat_members where chat_id='t_dm1' and member_phone='15550001111';
  if (select count(*) from public.chat_members
        where chat_id='t_dm1' and member_phone='15550001111') <> 1 then
    raise exception 'SECURITY CHECK FAILED: a 1:1''s party was removed by someone';
  end if;
  raise notice '  ok   nobody can remove a 1:1''s party — owner_phone is '''' and can never match a real phone';
end $$;

reset role;
do $$ begin
  if has_table_privilege('anon', 'public.direct_chats', 'select')
      or has_table_privilege('anon', 'public.chat_members', 'select')
  then
    raise exception 'SECURITY CHECK FAILED: anon can read chat structure';
  end if;
  raise notice '  ok   anon has no privilege at all on chat structure';
end $$;

-- Call presence (call_presence.sql), Phase 4 of "central authority": no
-- durable parent row to gate against (a call_id is a client-minted
-- signaling correlation id, not a real identity — see the file header), so
-- eligibility is DIAL-LIST-based: whoever founds a call names who they
-- dialed, and only those names (or the founder themself) may ever touch it.
set role authenticated;
select pg_temp.as_user('15550001111');            -- alice, the initiator
select pg_temp.expect_ok(
  $$insert into public.call_rosters
      (call_id, member_phone, initiator_phone, dial_phones, member_name)
    values ('t_call1','15550001111','15550001111',
            array['15550002222'],'Alice')$$,
  'the founder of a brand-new call can claim it, naming the real dial list');
select pg_temp.expect_fail(
  $$insert into public.call_rosters
      (call_id, member_phone, initiator_phone, dial_phones)
    values ('t_call2','15550001111','15550002222',array['15550003333'])$$,
  'you cannot found a call claiming somebody ELSE as its initiator');

select pg_temp.as_user('15550006666');            -- a stranger, never dialed
select pg_temp.expect_fail(
  $$insert into public.call_rosters (call_id, member_phone)
    values ('t_call1','15550006666')$$,
  'a stranger not on the dial list cannot join an already-founded call');
do $$ begin
  if (select count(*) from public.call_rosters where call_id='t_call1') <> 0 then
    raise exception 'SECURITY CHECK FAILED: a non-eligible caller can read the roster';
  end if;
  raise notice '  ok   a non-eligible caller cannot read a call''s roster';
end $$;

select pg_temp.as_user('15550002222');            -- bob, really on the dial list
select pg_temp.expect_ok(
  $$insert into public.call_rosters (call_id, member_phone, member_name)
    values ('t_call1','15550002222','Bob')$$,
  'someone actually on the dial list can join the call');
select pg_temp.expect_ok(
  $$select member_phone from public.call_rosters where call_id='t_call1'$$,
  'a real, eligible member can read the roster');
select pg_temp.expect_ok(
  $$update public.call_rosters set video=true
    where call_id='t_call1' and member_phone='15550002222'$$,
  'a member can update their own row (heartbeat / video toggle)');
do $$ begin
  update public.call_rosters set video=true
    where call_id='t_call1' and member_phone='15550001111';
  if (select video from public.call_rosters
        where call_id='t_call1' and member_phone='15550001111') then
    raise exception 'SECURITY CHECK FAILED: a member rewrote another member''s row';
  end if;
  raise notice '  ok   a member cannot rewrite another member''s roster row';
end $$;
select pg_temp.expect_ok(
  $$delete from public.call_rosters
    where call_id='t_call1' and member_phone='15550002222'$$,
  'a member can leave the call themself (delete their own row)');

-- No moderator-delete, unlike voice presence's force-disconnect — a call has
-- no owner/moderator concept. Even the founder cannot evict someone else.
reset role;
insert into public.call_rosters (call_id, member_phone, member_name)
  values ('t_call1','15550002222','Bob');
set role authenticated;
select pg_temp.as_user('15550001111');            -- alice, the founder
do $$ begin
  delete from public.call_rosters where call_id='t_call1' and member_phone='15550002222';
  if (select count(*) from public.call_rosters
        where call_id='t_call1' and member_phone='15550002222') <> 1 then
    raise exception 'SECURITY CHECK FAILED: the founder evicted another member — there is no moderator-delete on calls';
  end if;
  raise notice '  ok   nobody, not even the founder, can evict another member from a call';
end $$;

-- The initiator's own re-insert/heartbeat eligibility does not depend on
-- being named in their own dial list (dial_phones lists who they CALLED,
-- excluding themself) — is_call_eligible's second branch covers this.
do $$ begin
  if not public.is_call_eligible('t_call1', '15550001111') then
    raise exception 'CHECK FAILED: the initiator is not eligible for their own call';
  end if;
  if public.is_call_eligible('t_call1', '15550006666') then
    raise exception 'SECURITY CHECK FAILED: a stranger reads as eligible';
  end if;
  raise notice '  ok   is_call_eligible: the initiator always qualifies, a stranger never does';
end $$;

reset role;
do $$ begin
  if has_table_privilege('anon', 'public.call_rosters', 'select') then
    raise exception 'SECURITY CHECK FAILED: anon can read call presence';
  end if;
  raise notice '  ok   anon has no privilege at all on call presence';
end $$;

-- Directory phone privacy (directory_phone_privacy.sql). The leak was that
-- find_people answered anon with a phone per row, so ~1,300 prefix queries
-- with the publishable key walked the handle space collecting real numbers —
-- and that any signed-in account could simply select the whole table.
reset role;
set role anon;
do $$
declare n int;
begin
  -- A PREFIX is a browsing result: handles and names, nothing to dial.
  select count(*) into n from public.find_people('gho') where phone <> '';
  if n > 0 then
    raise exception 'SECURITY CHECK FAILED: a prefix search handed out % phone number(s)', n;
  end if;
  if not exists (select 1 from public.find_people('gho') where username = 'ghosty') then
    raise exception 'CHECK FAILED: a prefix search stopped finding people entirely';
  end if;
  -- An EXACT handle still answers with one, because signing in by username
  -- happens signed OUT and needs the number to send itself a code.
  if not exists (select 1 from public.find_people('ghosty') where phone = '001234567890') then
    raise exception 'CHECK FAILED: an exact handle no longer resolves — sign-in by username is broken';
  end if;
  -- The handle check never names who holds one.
  if public.username_status('ghosty') <> 'taken' then
    raise exception 'CHECK FAILED: a taken handle does not read as taken';
  end if;
  if public.username_status('nobody_at_all') <> 'available' then
    raise exception 'CHECK FAILED: a free handle does not read as available';
  end if;
  raise notice '  ok   a prefix search names no numbers; an exact handle still does';
end $$;

-- The table itself: anon could never read it, and now neither can another
-- account. This is the one that made fixing the RPC alone theatre.
-- RLS answers anon with zero rows rather than an error (the read policy is
-- `to authenticated`), so emptiness IS the assertion here.
do $$
declare n int;
begin
  select count(*) into n from public.usernames;
  if n > 0 then
    raise exception 'SECURITY CHECK FAILED: anon read % directory row(s)', n;
  end if;
  raise notice '  ok   anon reads no directory row at all';
exception
  when insufficient_privilege then
    raise notice '  ok   anon cannot even select the directory table';
end $$;
reset role;

-- Contact sync turns phone HASHES back into numbers, so it must never answer
-- a signed-out caller: 500 guesses a call is an oracle. Asserted on the GRANT
-- rather than by calling it, because this bit cannot be reproduced here —
-- a Supabase project's default privileges grant EXECUTE on every new function
-- to anon, and `revoke ... from public` does not take that away. It came out
-- anon-callable on the live project and nowhere else.
do $$ begin
  if has_function_privilege('anon', 'public.find_people_by_hashes(text[])', 'execute') then
    raise exception 'SECURITY CHECK FAILED: anon can turn phone hashes into numbers';
  end if;
  if not has_function_privilege('authenticated', 'public.find_people_by_hashes(text[])', 'execute') then
    raise exception 'CHECK FAILED: contact sync cannot run at all';
  end if;
  raise notice '  ok   the hash lookup answers a session and nobody else';
end $$;

set role authenticated;
select pg_temp.as_user('15550001111');
do $$
declare n int;
begin
  select count(*) into n from public.usernames where phone <> '15550001111';
  if n > 0 then
    raise exception 'SECURITY CHECK FAILED: a signed-in account read % other people''s directory row(s)', n;
  end if;
  raise notice '  ok   the directory table answers only your own row';
end $$;
reset role;

-- Banned signups (banned_signups.sql): a banned NUMBER is refused at the door,
-- and only an owner/admin can ban an EMAIL the signup path then refuses.
set role authenticated;
select pg_temp.as_user('15550001111');
do $$ begin
  if not public.is_phone_banned('15550009999') then
    raise exception 'CHECK FAILED: a banned number is not seen as banned';
  end if;
  if public.is_phone_banned('15550001111') then
    raise exception 'CHECK FAILED: a clean number reads as banned';
  end if;
  raise notice '  ok   a banned number is refused at signup';
end $$;
-- A non-staff account cannot ban an email.
do $$ begin
  if public.ban_email('spam@x.com') then
    raise exception 'SECURITY CHECK FAILED: a non-staff account banned an email';
  end if;
  if public.is_email_banned('spam@x.com') then
    raise exception 'SECURITY CHECK FAILED: an email was banned by a non-staff caller';
  end if;
  raise notice '  ok   only staff can ban an email';
end $$;
-- The owner (made owner earlier in this script) can, and the check is
-- case/space-insensitive; unban lifts it.
select pg_temp.as_user('15550007777');
do $$ begin
  if not public.ban_email('Spam@X.com ') then
    raise exception 'CHECK FAILED: an owner cannot ban an email';
  end if;
  if not public.is_email_banned('spam@x.com') then
    raise exception 'CHECK FAILED: a banned email is not seen as banned';
  end if;
  if not public.unban_email('spam@x.com') then
    raise exception 'CHECK FAILED: an owner cannot lift an email ban';
  end if;
  if public.is_email_banned('spam@x.com') then
    raise exception 'CHECK FAILED: an unbanned email is still banned';
  end if;
  raise notice '  ok   an owner bans/unbans an email; the check ignores case and spaces';
end $$;
-- The list itself is closed to clients.
select pg_temp.as_user('15550001111');
select pg_temp.expect_fail(
  $$select * from public.banned_emails$$,
  'the banned-emails list is not enumerable by a client');
reset role;
SQL

DB=okaycheck
su pg -c "PATH=$PGBIN:\$PATH createdb -h $RUN -p $PORT $DB"
# Status first, output second — for the third time in this file, piping psql
# into grep hands the pipeline grep's exit code and turns a failure into a pass.
apply() {
  set +e
  su pg -c "PATH=$PGBIN:\$PATH psql -h $RUN -p $PORT -d $DB -v ON_ERROR_STOP=1 -q -f $1" \
    >"$WORK/apply.txt" 2>&1
  rc=$?
  set -e
  grep -vE "NOTICE:" "$WORK/apply.txt" | grep -v "^$" || true
  return $rc
}

echo "postgres $(su pg -c "PATH=$PGBIN:\$PATH psql -h $RUN -p $PORT -d $DB -tAc 'show server_version'")"
for f in "$WORK/harness.sql" supabase/schema.sql docs/platform_moderation.sql docs/public_feed.sql docs/creator_subscriptions.sql docs/payment_controls.sql docs/directory_numberless.sql docs/identity_backup.sql docs/account_lifecycle.sql docs/admin_users.sql docs/community_posts.sql docs/ai_usage.sql docs/ai_training.sql docs/legal_documents.sql docs/public_feed_edit.sql docs/public_forum.sql docs/public_forum_comment_votes.sql docs/community_notes.sql docs/public_market.sql docs/market_reviews.sql docs/paid_servers.sql docs/banned_signups.sql docs/public_servers.sql docs/market_upsert_fix.sql docs/community_structure.sql docs/community_voice.sql docs/chat_structure.sql docs/call_presence.sql docs/app_pricing.sql docs/taken_signups.sql docs/moderation_scopes.sql docs/directory_phone_privacy.sql; do
  if apply "$f"; then
    echo "  applied $(basename "$f")"
  else
    echo "  FAILED  $(basename "$f")"; exit 1
  fi
done

# UPGRADING A PROJECT THAT ALREADY RAN AN EARLIER VERSION
#
# Every file here claims to be safe to run twice, and a fresh database cannot
# check that claim: it never holds the *older* shape there is to migrate from.
# A bug reached the dashboard for exactly this reason —
#
#   42P16: cannot change name of view column "created_at" to "repost_of"
#
# — because `create or replace view` may only append columns to the end, and a
# first run has no previous view to collide with. Nothing here could see it.
#
# So put the old shape back: v1's table columns, v1's body CHECK, v1's view with
# its own column order. Then run the file again and require it to succeed. The
# assertions below then run against the *migrated* database, so the upgrade path
# has to arrive at the same guarantees the fresh one does.
cat >"$WORK/v1shape.sql" <<'SQL'
drop view if exists public.public_feed;
drop table if exists public.public_post_votes;
alter table public.public_posts drop constraint if exists public_posts_poll_shape;
alter table public.public_posts drop column if exists poll_options cascade;
alter table public.public_posts drop column if exists poll_closes_at cascade;
alter table public.public_posts drop column if exists repost_of cascade;
alter table public.public_posts drop column if exists image_path cascade;
alter table public.public_posts drop constraint if exists public_posts_not_empty;
alter table public.public_posts drop constraint if exists public_posts_reply_xor_repost;
alter table public.public_posts drop constraint if exists public_posts_body_check;
alter table public.public_posts
  add constraint public_posts_body_check check (char_length(body) between 1 and 500);
create view public.public_feed with (security_invoker = on) as
select p.id, p.author_username, p.author_name, p.author_verified, p.body,
       p.reply_to, p.created_at,
       public.public_post_like_count(p.id)  as like_count,
       public.public_post_reply_count(p.id) as reply_count
from public.public_posts p;
grant select on public.public_feed to anon, authenticated;

-- payment_controls.sql v1: the limits table before pausing, per-transfer caps
-- and delayed raises existed. Its ALTERs are the upgrade path, and a fresh
-- database never runs them.
alter table public.payment_settings drop column if exists paused;
alter table public.payment_settings drop column if exists max_send_cents;
alter table public.payment_settings
  drop column if exists pending_daily_send_limit_cents;
alter table public.payment_settings
  drop column if exists pending_daily_effective_at;
alter table public.payment_settings drop column if exists pending_max_send_cents;
alter table public.payment_settings drop column if exists pending_max_effective_at;
SQL

if apply "$WORK/v1shape.sql"; then
  echo "  rolled back to the previous shape"
else
  echo "  FAILED  could not rebuild the previous shape"; exit 1
fi

for f in supabase/schema.sql docs/platform_moderation.sql docs/public_feed.sql docs/creator_subscriptions.sql docs/payment_controls.sql docs/directory_numberless.sql docs/identity_backup.sql docs/account_lifecycle.sql docs/admin_users.sql docs/community_posts.sql docs/ai_usage.sql docs/ai_training.sql docs/legal_documents.sql docs/public_feed_edit.sql docs/public_forum.sql docs/public_forum_comment_votes.sql docs/community_notes.sql docs/public_market.sql docs/market_reviews.sql docs/paid_servers.sql docs/banned_signups.sql docs/public_servers.sql docs/market_upsert_fix.sql docs/community_structure.sql docs/community_voice.sql docs/chat_structure.sql docs/call_presence.sql docs/app_pricing.sql docs/taken_signups.sql docs/moderation_scopes.sql docs/directory_phone_privacy.sql; do
  if apply "$f"; then
    echo "  re-applied $(basename "$f")"
  else
    echo "  FAILED  $(basename "$f") is not safe to run twice"; exit 1
  fi
done

# Status first, output second: piping psql into grep hands the pipeline grep's
# exit code, and this script would print "passed" over a failed assertion.
set +e
su pg -c "PATH=$PGBIN:\$PATH psql -h $RUN -p $PORT -d $DB -v ON_ERROR_STOP=1 -q -f $WORK/assert.sql" \
  >"$WORK/out.txt" 2>&1
status=$?
set -e
grep -E "NOTICE:|ERROR:" "$WORK/out.txt" | sed -E 's/^.*(NOTICE|ERROR):  ?//' || true
if [ "$status" -ne 0 ]; then
  echo "SQL checks FAILED"
  exit 1
fi
echo "SQL checks passed"
