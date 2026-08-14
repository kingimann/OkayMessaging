-- Publishing a marketplace listing (or a review) was refused outright, and the
-- phone-hiding column grant was the reason.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor, AFTER docs/public_market.sql and
-- docs/market_reviews.sql (it alters columns those two create).
--
-- THE BUG, exactly. Both tables deliberately withhold the author's phone from
-- clients: the table-wide SELECT is revoked and every column BUT author_phone
-- is granted back, so a seller's number can never be read by a browser. That
-- part was correct and stays.
--
-- What nobody checked is what the app actually SENDS. It publishes with
-- PostgREST's upsert, which becomes:
--
--   insert into market_listings (id, author_phone, author_username, payload, …)
--   values (…)
--   on conflict (id) do update set
--     author_phone    = excluded.author_phone,   -- <<< this line
--     author_username = excluded.author_username,
--     …
--
-- `excluded.author_phone` is a READ of the withheld column. Postgres checks
-- that at PLAN time — before any row exists, so it fails even on a brand-new
-- listing that could never conflict — and refuses the whole statement with
-- `42501 permission denied for table market_listings`, hinting at exactly the
-- table-wide SELECT grant that must never be given here. Every single publish
-- has been failing this way; the table has never held a row.
--
-- Confirmed live rather than reasoned about: the same upsert with
-- `author_phone` REMOVED from the DO UPDATE list succeeds, and with it present
-- fails, on both tables.
--
-- WHY NOT JUST GRANT SELECT ON THE COLUMN. That is what fixed the same class
-- of bug on public_forum_votes (see the note in CLAUDE.md), and it was safe
-- THERE because that table's read policy is scoped to the caller's own row —
-- the only number the column could hand back was one the caller already knew.
-- Here the read policy is `content_visible(author_phone)`: every listing is
-- world-readable by design, so granting the column would publish every
-- seller's phone number to anyone holding the publishable key. Not an option.
--
-- THE FIX: the client stops sending author_phone at all, and the column fills
-- itself from the caller's own JWT. Then the DO UPDATE never names the column,
-- so nothing reads it and no SELECT is required.
--
-- This is strictly SAFER than what it replaces, not merely equivalent:
--   * A fresh row takes the phone from `auth.jwt() ->> 'phone'`, which a
--     client cannot forge — it is no longer trusting a value the device sent.
--   * An UPDATE never touches author_phone, so a listing's owner can never be
--     reassigned by a later publish.
--   * The insert policy (`author_phone = auth.jwt() ->> 'phone'`) is unchanged
--     and still runs, so an older build that DOES send the column is refused
--     if it names somebody else's number — verified, still errors with
--     "new row violates row-level security policy".
--   * anon has no session, so the default is null and NOT NULL refuses the
--     row — a signed-out write cannot land even if RLS were ever loosened.

-- ---------------------------------------------------------------------------
-- 1. market_listings
-- ---------------------------------------------------------------------------
alter table public.market_listings
  alter column author_phone set default (auth.jwt() ->> 'phone');

-- ---------------------------------------------------------------------------
-- 2. market_reviews — the identical shape, and the identical bug
-- ---------------------------------------------------------------------------
alter table public.market_reviews
  alter column author_phone set default (auth.jwt() ->> 'phone');

-- ---------------------------------------------------------------------------
-- 3. server_directory — the SAME bug, found only because it was re-checked
-- ---------------------------------------------------------------------------
-- This file first claimed server_directory was fine. It is not, and the way
-- that mistake happened is worth recording: the first probe upserted it
-- WITHOUT owner_phone in the DO UPDATE list, which of course succeeded, and
-- that was read as "this table is unaffected". What the app actually sends
-- (`publishServerDirectory`) DOES name owner_phone — so publishing a public
-- server to the Discover directory was refused with the identical
-- `permission denied for table server_directory`, and a server toggled public
-- never appeared for anyone.
--
-- Test the statement the CLIENT really sends, not a simplified stand-in.
alter table public.server_directory
  alter column owner_phone set default (auth.jwt() ->> 'phone');
