-- The verified legal name, for card-holder matching.
-- ============================================================================
-- Run this AFTER docs/identity_verification.sql.
--
-- WHY THIS COLUMN EXISTS. Sending money requires that the card belongs to the
-- person sending it. The only trustworthy name to compare against is the one
-- Stripe read off a government ID, so it has to be stored to be compared.
--
-- This is a deliberate exception to keeping server-side data minimal, and it
-- is the narrowest one that makes the rule work: a name, nothing else. No
-- document images, no number, no date of birth, no address — those stay with
-- Stripe and are never requested by this project.

alter table public.identity_verifications
  add column if not exists verified_name text;

-- RLS is already enabled with no policies by identity_verification.sql, so
-- this column is no more readable than the rest of the row: only the Edge
-- Functions, using the service-role key, can see it.
