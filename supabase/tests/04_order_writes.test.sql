-- The order write path: tenant scoping, the checks RLS would have made, the
-- concurrency guard, and the three things that are supposed to be impossible —
-- overselling, a reprice reaching into a past order, and an allergen correction
-- rewriting what a buyer was told.
begin;

-- pgTAP is test-only tooling. Creating it inside the transaction means it is
-- rolled back with everything else, so `supabase test db` needs no setup step
-- and no deployed database ever carries a thousand assertion functions it will
-- never call. `search_path` covers both placements: a fresh install lands in
-- `public`, while a project that enabled pgTAP from the dashboard has it in
-- `extensions`.
create extension if not exists pgtap;
set local search_path to public, extensions;

select plan(18);

-- --- Fixtures ---------------------------------------------------------------
-- Written directly rather than through an impersonated session: these tests are
-- about the service_role path, which is what the edge function uses. As
-- `postgres` with no JWT claims, app.is_service_role() is true.

insert into auth.users (id, email) values
  ('33333333-4444-4000-a000-000000000001', 'writer@test.local');

insert into public.organizations (id, slug, name, created_by)
values ('33333333-4444-4000-b000-000000000001', 'write-test', 'Write Test Co',
        '33333333-4444-4000-a000-000000000001');

insert into public.organization_members values
  ('33333333-4444-4000-b000-000000000001', '33333333-4444-4000-a000-000000000001', 'owner');

insert into public.ingredients (id, organization_id, sku, name, unit)
values ('33333333-4444-4000-c000-000000000001', '33333333-4444-4000-b000-000000000001',
        'SPONGE-MIX', 'Sponge mix', 'g');

insert into public.products (id, organization_id, sku, name, price_cents, status)
values ('33333333-4444-4000-d000-000000000001', '33333333-4444-4000-b000-000000000001',
        'CAKE', 'Sponge cake', 500, 'active');

insert into public.product_ingredients (product_id, ingredient_id, organization_id, quantity)
values ('33333333-4444-4000-d000-000000000001', '33333333-4444-4000-c000-000000000001',
        '33333333-4444-4000-b000-000000000001', 50);

-- Exactly enough for two cakes. The arithmetic is deliberately tight so that
-- the overselling test has only one way to pass.
insert into public.inventory_movements (organization_id, ingredient_id, kind, quantity)
values ('33333333-4444-4000-b000-000000000001', '33333333-4444-4000-c000-000000000001',
        'receipt', 100);

insert into public.customers (id, organization_id, email, full_name)
values ('33333333-4444-4000-e000-000000000001', '33333333-4444-4000-b000-000000000001',
        'buyer@test.local', 'Buyer');

-- --- Placing ----------------------------------------------------------------

create temporary table first_order on commit drop as
  select public.place_order(
    '33333333-4444-4000-b000-000000000001',
    '33333333-4444-4000-e000-000000000001',
    '[{"sku": "CAKE", "quantity": 1}]'::jsonb) as payload;

select is(
  (select payload ->> 'total_cents' from first_order),
  '500', 'an order totals its lines');

select is(
  (select payload ->> 'status' from first_order),
  'confirmed', 'and is confirmed once the stock is reserved');

select is(
  (select count(*) from public.orders
    where organization_id = '33333333-4444-4000-b000-000000000001'),
  1::bigint, 'it lands in the calling organization');

-- There is no quantity_on_hand column to read. This is the ledger summed.
select is(
  public.ingredient_available('33333333-4444-4000-c000-000000000001'),
  50::numeric, 'the sale consumed stock through the ledger');

select throws_ok(
  $$select public.place_order('33333333-4444-4000-b000-000000000001',
      '33333333-4444-4000-e000-000000000001',
      '[{"sku": "NO-SUCH-SKU", "quantity": 1}]'::jsonb)$$,
  'P0002', null, 'an unknown sku is refused');

-- A sku belonging to another tenant must not resolve, even though service_role
-- bypasses RLS. The scoping is in the function's WHERE clause, not the policy.
select throws_ok(
  $$select public.place_order('33333333-4444-4000-b000-000000000001',
      '33333333-4444-4000-e000-000000000001',
      '[{"sku": "RYE-SOUR", "quantity": 1}]'::jsonb)$$,
  'P0002', null, 'another organization''s sku is invisible to this one');

select throws_ok(
  $$select public.place_order('33333333-4444-4000-b000-000000000001',
      '33333333-4444-4000-e000-000000000001',
      '[{"sku": "CAKE", "quantity": 0}]'::jsonb)$$,
  '23514', null, 'a zero quantity is refused');

select throws_ok(
  $$select public.place_order('33333333-4444-4000-b000-000000000001',
      '33333333-4444-4000-e000-000000000001', '[]'::jsonb)$$,
  '23514', null, 'an empty order is refused');

-- --- Overselling ------------------------------------------------------------
-- 50 g left, 50 g per cake: one more fits, two do not. The failure is
-- insufficient_resources (53000), which the API layer maps to 409 rather than
-- a 500 that would look like a bug in the server.

select throws_ok(
  $$select public.place_order('33333333-4444-4000-b000-000000000001',
      '33333333-4444-4000-e000-000000000001',
      '[{"sku": "CAKE", "quantity": 2}]'::jsonb)$$,
  '53000', null, 'an order larger than the stock on hand is refused');

select is(
  public.ingredient_available('33333333-4444-4000-c000-000000000001'),
  50::numeric, 'and the refused order consumed nothing');

-- --- The price snapshot -----------------------------------------------------

update public.products set price_cents = 900
 where id = '33333333-4444-4000-d000-000000000001';

select is(
  (select unit_price_cents from public.order_items
    where organization_id = '33333333-4444-4000-b000-000000000001'),
  500, 'repricing the product does not reprice a past order');

-- --- The allergen correction ------------------------------------------------
-- The ingredient was entered as allergen-free and is not. One write to the
-- ingredient is enough: the product's list is derived.

select is(
  (select allergens from public.products
    where id = '33333333-4444-4000-d000-000000000001'),
  '{}'::text[], 'the product starts out declaring no allergens');

update public.ingredients set allergens = array['cereals_containing_gluten']
 where id = '33333333-4444-4000-c000-000000000001';

select is(
  (select allergens from public.products
    where id = '33333333-4444-4000-d000-000000000001'),
  array['cereals_containing_gluten'], 'correcting the ingredient relabels the product');

select is(
  (select allergens_disclosed from public.order_items
    where organization_id = '33333333-4444-4000-b000-000000000001'),
  '{}'::text[], 'but the order line still records what the buyer was actually told');

-- Which is the whole point: the gap between the two is answerable.
select is(
  jsonb_array_length(public.orders_missing_allergen(
    '33333333-4444-4000-b000-000000000001', 'cereals_containing_gluten')),
  1, 'the recall query finds the order placed under the old label');

-- --- Cancelling -------------------------------------------------------------
-- Stock comes back as a `release` movement. The consumption row is not deleted,
-- so the history of what happened survives the undo.

select lives_ok(
  format($$select public.cancel_order('33333333-4444-4000-b000-000000000001', %L,
            'Test cancellation')$$,
         (select (payload ->> 'id')::uuid from first_order)),
  'an order can be cancelled');

select is(
  public.ingredient_available('33333333-4444-4000-c000-000000000001'),
  100::numeric, 'cancelling returns the stock it had consumed');

-- --- The checks RLS would have made -----------------------------------------
-- service_role bypasses RLS, so app.assert_org_writable has to make them.

update public.subscriptions set status = 'canceled'
 where organization_id = '33333333-4444-4000-b000-000000000001';

select throws_ok(
  $$select public.place_order('33333333-4444-4000-b000-000000000001',
      '33333333-4444-4000-e000-000000000001',
      '[{"sku": "CAKE", "quantity": 1}]'::jsonb)$$,
  '23514', null, 'a lapsed subscription blocks writes even for service_role');

select * from finish();
rollback;
