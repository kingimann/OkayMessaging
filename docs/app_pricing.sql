-- Owner-editable pricing (2026-08-09). The prices the APP assumes — the
-- storage ladder, the four subscription tier levels, and the four tip
-- amounts — so the owner can keep them in step with App Store Connect from
-- inside the app instead of shipping a build. A single row (id = 1).
--
-- WHAT THIS IS NOT: it is not what anybody is charged. Apple charges whatever
-- the SKU says in App Store Connect, and the app always shows the store's own
-- localized price when StoreKit has answered (see lib/payments/store_prices.
-- dart). These numbers fill in only where there is no store price to show —
-- web, payments-test mode, the frame before StoreKit replies — and they set
-- the tier ladder a creator picks a price from. So a mistake here can never
-- advertise a price different from the charge on a real purchase.
--
-- READABLE BY EVERYONE — every device fetches it on launch, like the legal
-- documents. WRITABLE ONLY by the `pricing-set` Edge Function (service role),
-- which checks the caller is the platform owner first. No client write grants.
--
-- Run this in the SQL editor, then paste the `pricing-set` function. Until
-- then the app uses its built-in defaults and the editor says so.
-- ---------------------------------------------------------------------------

create table if not exists public.app_pricing (
  id         int primary key default 1,
  -- { storagePerGbCents, tierCents: [4], tipCents: {id: cents} }
  prices     jsonb not null default '{}'::jsonb,
  edited_at  timestamptz not null default now(),
  constraint app_pricing_singleton check (id = 1)
);

alter table public.app_pricing enable row level security;

-- Anyone may READ the current prices (fetched on launch, like legal docs).
drop policy if exists app_pricing_read on public.app_pricing;
create policy app_pricing_read on public.app_pricing
  for select using (true);
grant select on table public.app_pricing to anon, authenticated;

-- Nobody writes through the API. The pricing-set function (service role,
-- which bypasses RLS) is the only writer, and it checks ownership first.
revoke insert, update, delete on table public.app_pricing
  from anon, authenticated;
