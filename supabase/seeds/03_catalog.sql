-- ---------------------------------------------------------------------------
-- Seed 3 · Ingredients, products and recipes
--
-- Applied by `supabase db reset`, which picks these up through the glob in
-- [db.seed] sql_paths. Files run in filename order, so the numeric prefix is
-- load-bearing: this one depends on everything before it.
--
-- Runs as `postgres`, which bypasses RLS. The seed is not a test of the
-- policies — that is what supabase/tests is for.
--
-- A bakery, because baking is the domain where allergens are not a hypothetical
-- compliance feature: flour, butter, eggs and nuts cover four of the fourteen
-- declarable allergens between them, and the interesting query — "who bought
-- something containing nuts before we knew it did" — is a real recall.
-- ---------------------------------------------------------------------------

-- --- Ingredients ------------------------------------------------------------
-- Note the units: grams for solids, millilitres for liquids, `unit` for things
-- you count. There is deliberately no kilogram — one canonical unit per
-- ingredient is what makes a unit mismatch unrepresentable rather than merely
-- forbidden.

insert into public.ingredients (
  id, organization_id, sku, name, unit, allergens, reorder_level, created_by
)
values
  ('00000000-0000-4000-d000-000000000001', '00000000-0000-4000-b000-000000000001',
   'FLOUR-T55', 'Wheat flour T55', 'g', array['cereals_containing_gluten'], 20000,
   '00000000-0000-4000-a000-000000000001'),
  ('00000000-0000-4000-d000-000000000002', '00000000-0000-4000-b000-000000000001',
   'BUTTER-82', 'Butter 82% fat', 'g', array['milk'], 10000,
   '00000000-0000-4000-a000-000000000001'),
  ('00000000-0000-4000-d000-000000000003', '00000000-0000-4000-b000-000000000001',
   'EGG-L', 'Eggs, large', 'unit', array['eggs'], 120,
   '00000000-0000-4000-a000-000000000001'),
  ('00000000-0000-4000-d000-000000000004', '00000000-0000-4000-b000-000000000001',
   'SUGAR-CAST', 'Caster sugar', 'g', array[]::text[], 15000,
   '00000000-0000-4000-a000-000000000001'),
  ('00000000-0000-4000-d000-000000000005', '00000000-0000-4000-b000-000000000001',
   'MILK-WHOLE', 'Whole milk', 'ml', array['milk'], 20000,
   '00000000-0000-4000-a000-000000000002'),
  -- The one that matters for the recall story. It starts out mislabelled as
  -- allergen-free; seed 4 corrects it, and the correction propagates.
  ('00000000-0000-4000-d000-000000000006', '00000000-0000-4000-b000-000000000001',
   'PRALINE', 'Hazelnut praline paste', 'g', array[]::text[], 2000,
   '00000000-0000-4000-a000-000000000002'),
  ('00000000-0000-4000-d000-000000000007', '00000000-0000-4000-b000-000000000001',
   'CHOC-70', 'Dark chocolate 70%', 'g', array['soybeans'], 5000,
   '00000000-0000-4000-a000-000000000002'),
  -- The other tenant. Acme must never see this row.
  ('00000000-0000-4000-d000-000000000008', '00000000-0000-4000-b000-000000000002',
   'FLOUR-RYE', 'Rye flour', 'g', array['cereals_containing_gluten'], 5000,
   '00000000-0000-4000-a000-000000000003')
on conflict (id) do nothing;

-- --- Products ---------------------------------------------------------------
-- `allergens` is omitted on purpose: it is a server-owned column, recomputed
-- from the recipe by trigger. Writing it here would be writing a value the
-- database is about to overwrite.

insert into public.products (
  id, organization_id, sku, name, description, price_cents, currency, status, created_by
)
values
  ('00000000-0000-4000-e000-000000000001', '00000000-0000-4000-b000-000000000001',
   'CROISSANT', 'Butter croissant',
   'Laminated with 82% butter, proved overnight.', 320, 'eur', 'active',
   '00000000-0000-4000-a000-000000000001'),
  ('00000000-0000-4000-e000-000000000002', '00000000-0000-4000-b000-000000000001',
   'PAIN-CHOC', 'Pain au chocolat',
   'Two batons of 70% dark chocolate.', 380, 'eur', 'active',
   '00000000-0000-4000-a000-000000000001'),
  ('00000000-0000-4000-e000-000000000003', '00000000-0000-4000-b000-000000000001',
   'PARIS-BREST', 'Paris-Brest',
   'Choux ring, praline crème mousseline.', 650, 'eur', 'active',
   '00000000-0000-4000-a000-000000000002'),
  ('00000000-0000-4000-e000-000000000004', '00000000-0000-4000-b000-000000000001',
   'GALETTE', 'Galette des rois',
   'Seasonal. Not on sale yet.', 2400, 'eur', 'draft',
   '00000000-0000-4000-a000-000000000002'),
  ('00000000-0000-4000-e000-000000000005', '00000000-0000-4000-b000-000000000002',
   'RYE-SOUR', 'Rye sourdough',
   'Belongs to the other tenant.', 450, 'eur', 'active',
   '00000000-0000-4000-a000-000000000003')
on conflict (id) do nothing;

-- --- Recipes ----------------------------------------------------------------
-- Quantities are in the ingredient's own unit, so there is no unit column here
-- and nothing to keep in sync. Inserting these is what populates each product's
-- allergen list.

insert into public.product_ingredients (product_id, ingredient_id, organization_id, quantity)
values
  -- Croissant: flour, butter, sugar, milk → gluten, milk
  ('00000000-0000-4000-e000-000000000001', '00000000-0000-4000-d000-000000000001',
   '00000000-0000-4000-b000-000000000001', 55),
  ('00000000-0000-4000-e000-000000000001', '00000000-0000-4000-d000-000000000002',
   '00000000-0000-4000-b000-000000000001', 30),
  ('00000000-0000-4000-e000-000000000001', '00000000-0000-4000-d000-000000000004',
   '00000000-0000-4000-b000-000000000001', 6),
  ('00000000-0000-4000-e000-000000000001', '00000000-0000-4000-d000-000000000005',
   '00000000-0000-4000-b000-000000000001', 20),
  -- Pain au chocolat: the croissant dough plus chocolate → adds soybeans
  ('00000000-0000-4000-e000-000000000002', '00000000-0000-4000-d000-000000000001',
   '00000000-0000-4000-b000-000000000001', 55),
  ('00000000-0000-4000-e000-000000000002', '00000000-0000-4000-d000-000000000002',
   '00000000-0000-4000-b000-000000000001', 30),
  ('00000000-0000-4000-e000-000000000002', '00000000-0000-4000-d000-000000000004',
   '00000000-0000-4000-b000-000000000001', 6),
  ('00000000-0000-4000-e000-000000000002', '00000000-0000-4000-d000-000000000007',
   '00000000-0000-4000-b000-000000000001', 16),
  -- Paris-Brest: choux plus praline. Nuts are missing from its allergen list
  -- right now, which is exactly the bug seed 4 discovers.
  ('00000000-0000-4000-e000-000000000003', '00000000-0000-4000-d000-000000000001',
   '00000000-0000-4000-b000-000000000001', 70),
  ('00000000-0000-4000-e000-000000000003', '00000000-0000-4000-d000-000000000002',
   '00000000-0000-4000-b000-000000000001', 50),
  ('00000000-0000-4000-e000-000000000003', '00000000-0000-4000-d000-000000000003',
   '00000000-0000-4000-b000-000000000001', 2),
  ('00000000-0000-4000-e000-000000000003', '00000000-0000-4000-d000-000000000005',
   '00000000-0000-4000-b000-000000000001', 120),
  ('00000000-0000-4000-e000-000000000003', '00000000-0000-4000-d000-000000000006',
   '00000000-0000-4000-b000-000000000001', 40),
  -- Galette: still a draft, so it has a recipe but no sales.
  ('00000000-0000-4000-e000-000000000004', '00000000-0000-4000-d000-000000000001',
   '00000000-0000-4000-b000-000000000001', 200),
  ('00000000-0000-4000-e000-000000000004', '00000000-0000-4000-d000-000000000002',
   '00000000-0000-4000-b000-000000000001', 150),
  ('00000000-0000-4000-e000-000000000004', '00000000-0000-4000-d000-000000000003',
   '00000000-0000-4000-b000-000000000001', 3),
  -- The other tenant's product.
  ('00000000-0000-4000-e000-000000000005', '00000000-0000-4000-d000-000000000008',
   '00000000-0000-4000-b000-000000000002', 400)
on conflict (product_id, ingredient_id) do nothing;

-- --- Opening stock ----------------------------------------------------------
-- There is no `quantity_on_hand` to set. Stock is the sum of the ledger, so
-- opening stock is a receipt like any other.

insert into public.inventory_movements (
  organization_id, ingredient_id, kind, quantity, unit_cost_cents, note, created_by
)
select '00000000-0000-4000-b000-000000000001',
       i.id,
       'receipt',
       case i.unit when 'unit' then 600 else 60000 end,
       case i.unit when 'unit' then 32 else 1 end,
       'Opening stock',
       '00000000-0000-4000-a000-000000000001'
  from public.ingredients i
 where i.organization_id = '00000000-0000-4000-b000-000000000001';

insert into public.inventory_movements (
  organization_id, ingredient_id, kind, quantity, note, created_by
)
values
  ('00000000-0000-4000-b000-000000000002', '00000000-0000-4000-d000-000000000008',
   'receipt', 25000, 'Opening stock', '00000000-0000-4000-a000-000000000003');
