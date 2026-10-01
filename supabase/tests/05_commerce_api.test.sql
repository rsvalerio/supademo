-- The machine API over the commerce domain.
--
-- Run as `postgres`, with no JWT claims, which is the service_role path these
-- functions are written for: RLS is bypassed, so what is under test is whether
-- the tenant boundary and the domain invariants hold without it. Every call
-- goes through the `api_*` surface rather than the tables, the same way the
-- edge function reaches them.
begin;

-- pgTAP is test-only tooling. Creating it inside the transaction means it is
-- rolled back with everything else, so `supabase test db` needs no setup step
-- and no deployed database ever carries a thousand assertion functions it will
-- never call. `search_path` covers both placements: a fresh install lands in
-- `public`, while a project that enabled pgTAP from the dashboard has it in
-- `extensions`.
create extension if not exists pgtap;
set local search_path to public, extensions;

select plan(23);

-- --- Fixtures ---------------------------------------------------------------

insert into auth.users (id, email) values
  ('55555555-6666-4000-a000-000000000001', 'apiwriter@test.local');

insert into public.organizations (id, slug, name, created_by)
values ('55555555-6666-4000-b000-000000000001', 'api-commerce', 'API Commerce Co',
        '55555555-6666-4000-a000-000000000001');

insert into public.organization_members values
  ('55555555-6666-4000-b000-000000000001', '55555555-6666-4000-a000-000000000001', 'owner');

-- Addressed by sku from here on. No uuid of ours appears in a single call
-- below, which is the property the surface is built for.
select public.api_upsert_ingredient(
  '55555555-6666-4000-b000-000000000001', 'FLOUR', 'Wheat flour', 'g');

-- --- Products ---------------------------------------------------------------

create temporary table created on commit drop as
  select public.api_upsert_product(
    '55555555-6666-4000-b000-000000000001', 'CAKE', 'Sponge cake', 500,
    null, 'eur', 'active') as payload;

select is(
  (select payload ->> 'sku' from created),
  'CAKE', 'a product can be created through the API');

select is(
  public.api_upsert_product(
    '55555555-6666-4000-b000-000000000001', 'CAKE', 'Renamed cake', 500,
    null, 'eur', 'active') ->> 'name',
  'Renamed cake', 'a second call with the same sku updates rather than duplicating');

select is(
  (select count(*) from public.products
    where organization_id = '55555555-6666-4000-b000-000000000001'),
  1::bigint, 'so a sync job that re-runs converges instead of accumulating');

select throws_ok(
  $$select public.api_upsert_product(
      '55555555-6666-4000-b000-000000000001', 'CAKE', 'Free cake', -1)$$,
  '23514', null, 'a negative price is refused');

-- --- Recipes ----------------------------------------------------------------

select throws_ok(
  $$select public.api_set_recipe('55555555-6666-4000-b000-000000000001', 'CAKE',
      '[{"ingredient_sku": "NO-SUCH-ING", "quantity": 10}]'::jsonb)$$,
  'P0002', null, 'a recipe naming an unknown ingredient is refused');

-- `sellable` is derived from the recipe and the ledger, so with a recipe and no
-- stock the answer is zero rather than null or absent.
select is(
  (public.api_set_recipe('55555555-6666-4000-b000-000000000001', 'CAKE',
     '[{"ingredient_sku": "FLOUR", "quantity": 50}]'::jsonb)
   ->> 'sellable')::numeric,
  0::numeric, 'a product with a recipe and no stock is sellable zero times');

-- --- Inventory --------------------------------------------------------------

-- Consumption and release are written by the order functions. An endpoint that
-- could forge one would let the ledger drift from the orders it explains.
select throws_ok(
  $$select public.api_record_movement('55555555-6666-4000-b000-000000000001',
      'FLOUR', 'consumption', -10)$$,
  '23514', null, 'the API cannot write a consumption movement directly');

select is(
  (public.api_record_movement('55555555-6666-4000-b000-000000000001',
     'FLOUR', 'receipt', 100, 25, 'First delivery') ->> 'available')::numeric,
  100::numeric, 'a receipt raises the available quantity');

-- Raise the reorder level above what is on hand; the low-stock filter should
-- then return exactly this ingredient.
select public.api_upsert_ingredient(
  '55555555-6666-4000-b000-000000000001', 'FLOUR', 'Wheat flour', 'g', '{}', 500);

select is(
  jsonb_array_length(public.api_stock_levels(
    '55555555-6666-4000-b000-000000000001', true)),
  1, 'the low-stock filter returns what is below its reorder level');

select is(
  jsonb_array_length(public.api_stock_levels(
    '55555555-6666-4000-b000-000000000001', false)),
  1, 'and the unfiltered list returns the same one ingredient');

-- --- Customers --------------------------------------------------------------

select is(
  public.api_upsert_customer('55555555-6666-4000-b000-000000000001',
    'buyer@test.local', 'Buyer') ->> 'email',
  'buyer@test.local', 'a customer can be registered through the API');

-- --- Orders -----------------------------------------------------------------

-- An order is not a place to register a customer: a typo in an email would
-- otherwise silently create a second customer record rather than failing.
select throws_ok(
  $$select public.api_place_order('55555555-6666-4000-b000-000000000001',
      'nobody@test.local', '[{"sku": "CAKE", "quantity": 1}]'::jsonb)$$,
  'P0002', null, 'an order for an unknown customer is refused');

create temporary table placed on commit drop as
  select public.api_place_order(
    '55555555-6666-4000-b000-000000000001', 'buyer@test.local',
    '[{"sku": "CAKE", "quantity": 2}]'::jsonb) as payload;

select is(
  (select payload ->> 'status' from placed),
  'confirmed', 'an order is placed and confirmed in one call');

select is(
  (public.api_get_order('55555555-6666-4000-b000-000000000001',
    (select payload ->> 'order_number' from placed)) ->> 'total_cents')::integer,
  1000, 'and is readable back by its order number');

-- The tenant boundary with RLS switched off: a real sku from the seeded second
-- organization, which simply does not resolve here. An id that matches nothing
-- could not demonstrate this.
select ok(
  public.api_get_product('55555555-6666-4000-b000-000000000001', 'RYE-SOUR') is null,
  'another organization''s sku does not resolve against this one');

-- 100 g received, 100 g sold: three more cakes need 150 g that do not exist.
select throws_ok(
  $$select public.api_place_order('55555555-6666-4000-b000-000000000001',
      'buyer@test.local', '[{"sku": "CAKE", "quantity": 3}]'::jsonb)$$,
  '53000', null, 'an order the ledger cannot cover is refused');

-- --- The allergen correction, end to end ------------------------------------

select public.api_upsert_ingredient(
  '55555555-6666-4000-b000-000000000001', 'FLOUR', 'Wheat flour', 'g',
  array['cereals_containing_gluten'], 500);

select is(
  public.api_get_product('55555555-6666-4000-b000-000000000001', 'CAKE')
    -> 'allergens',
  '["cereals_containing_gluten"]'::jsonb,
  'correcting the ingredient relabels the product on the read surface too');

select throws_ok(
  $$select public.api_recall_report('55555555-6666-4000-b000-000000000001', 'gluten')$$,
  'P0002', null, 'an allergen outside the vocabulary is refused, not reported as empty');

select is(
  jsonb_array_length(public.api_recall_report(
    '55555555-6666-4000-b000-000000000001', 'cereals_containing_gluten')
    -> 'affected'),
  1, 'the recall report names the order placed under the old label');

-- --- Cancelling -------------------------------------------------------------

select is(
  public.api_cancel_order('55555555-6666-4000-b000-000000000001',
    (select payload ->> 'order_number' from placed), 'Test cancellation')
    ->> 'status',
  'cancelled', 'an order can be cancelled by its order number');

-- Nobody needs calling about an order that was never delivered.
select is(
  jsonb_array_length(public.api_recall_report(
    '55555555-6666-4000-b000-000000000001', 'cereals_containing_gluten')
    -> 'affected'),
  0, 'and a cancelled order drops out of the recall report');

select throws_ok(
  format($$select public.api_cancel_order('55555555-6666-4000-b000-000000000001', %L)$$,
         (select payload ->> 'order_number' from placed)),
  '23514', null, 'cancelling twice is refused');

-- Changing a unit would silently reinterpret every recipe quantity and every
-- ledger row already recorded against it.
select throws_ok(
  $$select public.api_upsert_ingredient('55555555-6666-4000-b000-000000000001',
      'FLOUR', 'Wheat flour', 'unit')$$,
  '23514', null, 'an ingredient''s unit cannot be changed once it is in use');

select * from finish();
rollback;
