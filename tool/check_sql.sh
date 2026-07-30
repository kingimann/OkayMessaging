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
  $$select id, author_username, body, like_count from public.public_feed$$,
  'the feed view reads fine');

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

-- Editing a public post is not offered to anyone.
select pg_temp.expect_fail(
  $$update public.public_posts set body = 'rewritten' where id = 't_p1'$$,
  'rewriting a public post is refused');
-- Belt and braces: even if the privilege were there, RLS grants no UPDATE
-- policy, so assert the text really is untouched rather than trusting the
-- statement to have errored. An UPDATE that matches no policy affects zero
-- rows *without* raising, which is how this check first passed while asserting
-- the wrong thing.
do $$ begin
  if (select body from public.public_feed where id='t_p1') <> 'hello' then
    raise exception 'SECURITY CHECK FAILED: a public post was rewritten';
  end if;
  raise notice '  ok   the post text is unchanged';
end $$;

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
SQL

DB=okaycheck
su pg -c "PATH=$PGBIN:\$PATH createdb -h $RUN -p $PORT $DB"
apply() {
  su pg -c "PATH=$PGBIN:\$PATH psql -h $RUN -p $PORT -d $DB -v ON_ERROR_STOP=1 -q -f $1" \
    2>&1 | grep -vE "^(psql:)?.*NOTICE:  (relation|policy|column|extension|database) " || true
}

echo "postgres $(su pg -c "PATH=$PGBIN:\$PATH psql -h $RUN -p $PORT -d $DB -tAc 'show server_version'")"
for f in "$WORK/harness.sql" supabase/schema.sql docs/platform_moderation.sql docs/public_feed.sql; do
  if apply "$f"; then
    echo "  applied $(basename "$f")"
  else
    echo "  FAILED  $(basename "$f")"; exit 1
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
