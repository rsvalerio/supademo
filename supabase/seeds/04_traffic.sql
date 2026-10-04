-- ---------------------------------------------------------------------------
-- Seed 4 · Customers, orders and the allergen correction
--
-- Applied by `supabase db reset`, which picks these up through the glob in
-- [db.seed] sql_paths. Files run in filename order, so the numeric prefix is
-- load-bearing: this one depends on everything before it.
--
-- Runs as `postgres`. Two consequences worth knowing: RLS is bypassed, and
-- app.is_service_role() is true, which is why this file can call
-- public.place_order() rather than inserting order rows by hand. That matters —
-- orders written directly would have no matching ledger movements, and the
-- fixture would contradict the invariant it is meant to illustrate.
-- ---------------------------------------------------------------------------

-- The column guard on public.orders decides by reading the request's JWT role,
-- and `postgres` with no claims is not service_role as far as auth.role() is
-- concerned. Without this, the backdating below would be silently reverted and
-- every order would land at "now" — no error, just a worse fixture, which is
-- the failure mode worth guarding against. Claiming service_role here is
-- honest: this file *is* the server.
set request.jwt.claims to '{"role":"service_role"}';

-- --- Customers --------------------------------------------------------------
-- A customer is not an auth.users row. They never sign in; they are data the
-- organization holds about someone, which is also why they can be anonymized
-- without taking their order history with them.

insert into public.customers (id, organization_id, email, full_name, phone, marketing_opt_in)
values
  ('00000000-0000-4000-c000-000000000001', '00000000-0000-4000-b000-000000000001',
   'hana@example.test', 'Hana Okafor', '+33 6 12 34 56 78', true),
  ('00000000-0000-4000-c000-000000000002', '00000000-0000-4000-b000-000000000001',
   'marco@example.test', 'Marco Beltrán', null, false),
  ('00000000-0000-4000-c000-000000000003', '00000000-0000-4000-b000-000000000001',
   'office@bigco.test', 'BigCo office manager', '+33 1 98 76 54 32', true),
  ('00000000-0000-4000-c000-000000000004', '00000000-0000-4000-b000-000000000002',
   'other@tenant.test', 'Globex buyer', null, false)
on conflict (id) do nothing;

-- --- Thirty days of orders --------------------------------------------------
-- Placed through the RPC, so every one of them locked its ingredients, checked
-- stock and wrote consumption rows. The lines carry the price and the allergen
-- list as they were at the moment of sale.

do $$
declare
  day      timestamptz;
  customer uuid;
  lines    jsonb;
  placed   jsonb;
  n        integer := 0;
begin
  for day in
    select d from generate_series(now() - interval '30 days', now() - interval '1 day', interval '1 day') as d
  loop
    for i in 1..3 loop
      n := n + 1;
      customer := (array[
        '00000000-0000-4000-c000-000000000001',
        '00000000-0000-4000-c000-000000000002',
        '00000000-0000-4000-c000-000000000003'
      ])[1 + (n % 3)]::uuid;

      -- Every third order includes a Paris-Brest, which is the product whose
      -- allergen list is about to change.
      lines := case when n % 3 = 0
        then '[{"sku": "CROISSANT", "quantity": 2}, {"sku": "PARIS-BREST", "quantity": 1}]'::jsonb
        else '[{"sku": "CROISSANT", "quantity": 3}, {"sku": "PAIN-CHOC", "quantity": 2}]'::jsonb
      end;

      placed := public.place_order(
        '00000000-0000-4000-b000-000000000001', customer, lines);

      -- place_order stamps "now". Backdating is a fixture concern, not a
      -- domain one, so it happens here rather than as a parameter nobody
      -- should have in production.
      update public.orders
         set placed_at = day + (i * interval '3 hours'),
             confirmed_at = day + (i * interval '3 hours'),
             created_at = day + (i * interval '3 hours')
       where id = (placed ->> 'id')::uuid;

      update public.inventory_movements
         set created_at = day + (i * interval '3 hours')
       where order_id = (placed ->> 'id')::uuid;

      update public.usage_events
         set occurred_at = day + (i * interval '3 hours')
       where subject_id = (placed ->> 'id')::uuid
         and metric = 'order_placed';
    end loop;
  end loop;
end;
$$;

-- One cancellation, so the ledger has a `release` in it and the recall query
-- has a row it is supposed to ignore.
select public.cancel_order(
  '00000000-0000-4000-b000-000000000001',
  (select id from public.orders
    where organization_id = '00000000-0000-4000-b000-000000000001'
    order by placed_at limit 1),
  'Customer changed their mind.');

select public.rollup_usage(d::date)
  from generate_series(now() - interval '30 days', now(), interval '1 day') as d;

-- --- The correction ---------------------------------------------------------
-- The praline paste was entered with no allergens. It is hazelnut. Fixing the
-- ingredient is the only write needed: the trigger recomputes every product
-- that uses it, so Paris-Brest gains `nuts` without anyone touching it.
--
-- What does not change is the orders already placed. Their lines keep the
-- allergen list the buyer was shown, which is the point — and it is what makes
-- public.orders_missing_allergen() able to answer "who do we have to call".
--
--   select * from public.orders_missing_allergen(
--     '00000000-0000-4000-b000-000000000001', 'nuts');

update public.ingredients
   set allergens = array['nuts']
 where id = '00000000-0000-4000-d000-000000000006';

-- --- The other tenant -------------------------------------------------------
-- One order in Globex, so the tenancy tests have something that must not leak.

select public.place_order(
  '00000000-0000-4000-b000-000000000002',
  '00000000-0000-4000-c000-000000000004',
  '[{"sku": "RYE-SOUR", "quantity": 1}]'::jsonb);

reset request.jwt.claims;
