-- ---------------------------------------------------------------------------
-- 1800 · The commerce domain: ingredients → products → orders
--
-- The shape that matters: a product is not a thing you count, it is a recipe
-- over things you count. Stock lives on ingredients; how many of a product you
-- can sell is derived. That one decision is what makes the rest of this file
-- worth reading.
--
-- Four invariants are enforced structurally rather than by convention:
--
--   1. Stock is an append-only ledger, never a mutable column, so there is no
--      `qty = qty - 1` to lose under concurrency.
--   2. Allergens propagate up from ingredients by trigger, so a product cannot
--      be mislabelled by forgetting; and they are frozen onto the order line at
--      the moment of sale, because that is the legal record of what the buyer
--      was told.
--   3. Price is snapshotted onto the line. Repricing never rewrites history.
--   4. An ingredient has exactly one unit of measure and quantities everywhere
--      are expressed in it, so there is no unit to mismatch. You cannot add
--      500 g to 2 units because there is nowhere to write the wrong unit down.
--
-- Same tenancy pattern as the rest of the schema: child tables carry a
-- denormalized `organization_id`, and a composite foreign key against
-- (id, organization_id) makes it impossible to forge or drift.
-- ---------------------------------------------------------------------------

-- Base units only. Kilograms and litres are a presentation concern; storing a
-- single canonical unit per dimension means no conversion ever runs inside a
-- constraint, a trigger, or the sell path.
create type public.unit_of_measure as enum ('g', 'ml', 'unit');

create type public.product_status as enum ('draft', 'active', 'discontinued');

create type public.order_status as enum ('pending', 'confirmed', 'fulfilled', 'cancelled');

-- `release` returns stock a cancelled order had consumed. It is a separate kind
-- from `receipt` so that "what did we actually buy this month" stays answerable.
create type public.stock_movement_kind as enum
  ('receipt', 'consumption', 'waste', 'adjustment', 'release');

-- Orders are a billable event, so the meter needs a name for them. The new
-- label is only ever resolved inside a function body, which is parsed at call
-- time rather than now, so adding it here is safe in the same transaction.
alter type public.usage_metric add value if not exists 'order_placed';

-- --- Allergens: a closed vocabulary ----------------------------------------
-- The fourteen allergens EU FIC 1169/2011 requires to be declared. Modelled the
-- same way as public.api_scopes: a table, not free text, so a typo fails at
-- write time instead of quietly producing a label that is missing a warning.

create table public.allergens (
  code        text primary key,
  label       text not null,
  created_at  timestamptz not null default now(),

  constraint allergens_code_format check (code ~ '^[a-z][a-z0-9_]{1,40}$')
);

comment on table public.allergens is
  'Regulated allergen vocabulary (EU FIC 1169/2011 Annex II). Global, not per-organization.';

insert into public.allergens (code, label) values
  ('celery',                    'Celery'),
  ('cereals_containing_gluten', 'Cereals containing gluten'),
  ('crustaceans',               'Crustaceans'),
  ('eggs',                      'Eggs'),
  ('fish',                      'Fish'),
  ('lupin',                     'Lupin'),
  ('milk',                      'Milk'),
  ('molluscs',                  'Molluscs'),
  ('mustard',                   'Mustard'),
  ('nuts',                      'Tree nuts'),
  ('peanuts',                   'Peanuts'),
  ('sesame',                    'Sesame'),
  ('soybeans',                  'Soybeans'),
  ('sulphur_dioxide',           'Sulphur dioxide and sulphites')
on conflict (code) do nothing;

-- --- Ingredients ------------------------------------------------------------

create table public.ingredients (
  id              uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  sku             extensions.citext not null,
  name            text not null,
  unit            public.unit_of_measure not null,
  allergens       text[] not null default '{}',
  reorder_level   numeric(14,3) not null default 0,
  archived_at     timestamptz,
  created_by      uuid references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  unique (organization_id, sku),
  unique (id, organization_id),
  constraint ingredients_name_length check (char_length(name) between 1 and 160),
  constraint ingredients_reorder_level_positive check (reorder_level >= 0)
);

comment on column public.ingredients.unit is
  'Every quantity for this ingredient — recipe lines, stock movements — is in this unit.';

create index ingredients_organization_id_idx on public.ingredients (organization_id)
  where archived_at is null;
create index ingredients_allergens_idx on public.ingredients using gin (allergens);

select private.attach_updated_at('public.ingredients');

-- Rejects an allergen code that is not in the vocabulary. Mirrors
-- private.tg_validate_api_scopes: the failure lands on the person writing the
-- typo, not on the customer reading the label.
create or replace function private.tg_validate_allergens()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  unknown text[];
begin
  select array_agg(a) into unknown
    from unnest(new.allergens) as a
   where not exists (select 1 from public.allergens x where x.code = a);

  if unknown is not null then
    raise exception 'unknown allergen(s): %', array_to_string(unknown, ', ')
      using errcode = 'check_violation',
            hint = 'See public.allergens for the permitted codes.';
  end if;

  return new;
end;
$$;

create trigger validate_allergens
  before insert or update of allergens on public.ingredients
  for each row execute function private.tg_validate_allergens();

-- --- Products ---------------------------------------------------------------

create table public.products (
  id              uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  sku             extensions.citext not null,
  name            text not null,
  description     text,
  price_cents     integer not null,
  currency        text not null default 'eur',
  status          public.product_status not null default 'draft',
  -- Derived from the recipe by trigger. Guarded below so a client cannot write
  -- a label that disagrees with what the product is made of.
  allergens       text[] not null default '{}',
  archived_at     timestamptz,
  created_by      uuid references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  search_vector tsvector generated always as (
    setweight(to_tsvector('english'::regconfig, coalesce(name, '')), 'A') ||
    setweight(to_tsvector('english'::regconfig, coalesce(description, '')), 'B')
  ) stored,

  unique (organization_id, sku),
  unique (id, organization_id),
  constraint products_name_length check (char_length(name) between 1 and 200),
  constraint products_price_non_negative check (price_cents >= 0),
  constraint products_currency_format check (currency ~ '^[a-z]{3}$')
);

comment on column public.products.price_cents is
  'Minor units of `currency`. Integers only — money is never a float here.';
comment on column public.products.allergens is
  'Server-owned. The union of the allergens of every ingredient in the recipe.';

create index products_organization_id_idx on public.products (organization_id)
  where archived_at is null;
create index products_search_idx on public.products using gin (search_vector);
create index products_allergens_idx on public.products using gin (allergens);
create index products_active_idx on public.products (organization_id, sku)
  where status = 'active' and archived_at is null;

select private.attach_updated_at('public.products');

create trigger guard_server_columns
  before update on public.products
  for each row execute function private.tg_guard_columns(
    'id', 'organization_id', 'created_by', 'created_at');

-- `allergens` is derived, and the column guard is the wrong tool for it. The
-- guard decides by looking at the request's JWT role, so it cannot tell a
-- client writing the column apart from the recompute function below writing it
-- from inside a trigger — both arrive with the same `authenticated` claim, and
-- both would be reverted. Column-level privilege can tell them apart: the
-- recompute function runs as the table's owner and is unaffected, while a
-- member cannot name the column in an UPDATE at all. The error is also better
-- than a silent revert — the write is refused, not quietly ignored.
revoke update on public.products from authenticated;
grant update (sku, name, description, price_cents, currency, status, archived_at)
  on public.products to authenticated;

create or replace function private.tg_enforce_product_quota()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  used integer;
begin
  new.created_by := coalesce(new.created_by, (select auth.uid()));

  select count(*) into used
    from public.products p
   where p.organization_id = new.organization_id
     and p.archived_at is null;

  perform app.assert_quota(new.organization_id, 'products', used, 1);
  return new;
end;
$$;

create trigger enforce_product_quota
  before insert on public.products
  for each row execute function private.tg_enforce_product_quota();

-- --- The recipe -------------------------------------------------------------
-- No unit column: the quantity is in the ingredient's own unit, which is the
-- whole reason units cannot be mixed up here.

create table public.product_ingredients (
  product_id      uuid not null,
  ingredient_id   uuid not null,
  organization_id uuid not null,
  quantity        numeric(14,3) not null,
  created_at      timestamptz not null default now(),

  primary key (product_id, ingredient_id),
  foreign key (product_id, organization_id)
    references public.products (id, organization_id) on delete cascade,
  -- restrict, not cascade: an ingredient that something is made of cannot be
  -- deleted out from under the recipe. Archive it instead.
  foreign key (ingredient_id, organization_id)
    references public.ingredients (id, organization_id) on delete restrict,
  constraint product_ingredients_quantity_positive check (quantity > 0)
);

comment on table public.product_ingredients is
  'Bill of materials. `quantity` is expressed in the ingredient''s unit_of_measure.';

create index product_ingredients_ingredient_idx on public.product_ingredients (ingredient_id);

-- --- Allergen propagation ---------------------------------------------------

create or replace function private.recompute_product_allergens(p_product_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.products p
     set allergens = coalesce(
       (select array_agg(distinct a order by a)
          from public.product_ingredients pi
          join public.ingredients i on i.id = pi.ingredient_id
          cross join lateral unnest(i.allergens) as a
         where pi.product_id = p.id),
       '{}'::text[]
     )
   where p.id = p_product_id;
$$;

create or replace function private.tg_recipe_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform private.recompute_product_allergens(old.product_id);
    return old;
  end if;

  perform private.recompute_product_allergens(new.product_id);
  -- An ingredient moved between products: the product it left has to be
  -- recomputed too, or it keeps an allergen it no longer contains.
  if tg_op = 'UPDATE' and old.product_id <> new.product_id then
    perform private.recompute_product_allergens(old.product_id);
  end if;

  return new;
end;
$$;

create trigger recipe_changed
  after insert or update or delete on public.product_ingredients
  for each row execute function private.tg_recipe_changed();

-- The other direction, and the one that makes a recall possible: discovering
-- that an ingredient contains something undeclared relabels every product that
-- uses it, immediately.
create or replace function private.tg_ingredient_allergens_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  affected uuid;
begin
  for affected in
    select distinct pi.product_id
      from public.product_ingredients pi
     where pi.ingredient_id = new.id
  loop
    perform private.recompute_product_allergens(affected);
  end loop;

  return new;
end;
$$;

create trigger ingredient_allergens_changed
  after update of allergens on public.ingredients
  for each row
  when (old.allergens is distinct from new.allergens)
  execute function private.tg_ingredient_allergens_changed();

-- --- Stock: an append-only ledger -------------------------------------------
-- There is deliberately no `quantity_on_hand` column anywhere. Stock is
-- sum(quantity) over this table, which means two concurrent sales cannot both
-- read the same "before" value and write the same "after".

create table public.inventory_movements (
  id              uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null,
  ingredient_id   uuid not null,
  kind            public.stock_movement_kind not null,
  quantity        numeric(14,3) not null,
  order_id        uuid,
  unit_cost_cents integer,
  note            text,
  created_by      uuid references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),

  foreign key (ingredient_id, organization_id)
    references public.ingredients (id, organization_id) on delete restrict,
  constraint inventory_movements_quantity_non_zero check (quantity <> 0),
  -- The sign is not the client's to choose: it follows from the kind.
  constraint inventory_movements_sign_matches_kind check (
    (kind in ('receipt', 'release') and quantity > 0) or
    (kind in ('consumption', 'waste') and quantity < 0) or
    (kind = 'adjustment')
  ),
  constraint inventory_movements_cost_only_on_receipt check (
    unit_cost_cents is null or kind = 'receipt'
  )
);

comment on table public.inventory_movements is
  'Append-only. Available stock is sum(quantity) per ingredient; there is no column to overwrite.';

create index inventory_movements_ingredient_idx
  on public.inventory_movements (ingredient_id, created_at desc);
create index inventory_movements_order_idx
  on public.inventory_movements (order_id) where order_id is not null;

create or replace function public.ingredient_available(p_ingredient_id uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(m.quantity), 0)::numeric
    from public.inventory_movements m
   where m.ingredient_id = p_ingredient_id;
$$;

comment on function public.ingredient_available(uuid) is
  'Current stock for one ingredient, in its own unit. Read-only; the sell path locks before it counts.';

-- How many of a product the recipe can currently cover. The binding ingredient
-- is whichever runs out first.
create or replace function public.product_sellable(p_product_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    min(floor(public.ingredient_available(pi.ingredient_id) / pi.quantity))::integer,
    0
  )
    from public.product_ingredients pi
   where pi.product_id = p_product_id;
$$;

comment on function public.product_sellable(uuid) is
  'Units of this product the current ingredient stock covers. A product with no recipe is 0.';

-- --- Customers --------------------------------------------------------------
-- A customer is a record belonging to a merchant, not an auth user. They never
-- authenticate to this database; nothing here is reachable with their identity.
-- That is the third identity in this schema, after org members and API keys.

create table public.customers (
  id               uuid primary key default extensions.gen_random_uuid(),
  organization_id  uuid not null references public.organizations (id) on delete cascade,
  email            extensions.citext not null,
  full_name        text,
  phone            text,
  marketing_opt_in boolean not null default false,
  notes            text,
  anonymized_at    timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  unique (organization_id, email),
  unique (id, organization_id),
  constraint customers_email_shape check (email ~ '^[^@[:space:]]+@[^@[:space:]]+$')
);

comment on table public.customers is
  'Buyers. Deliberately unrelated to auth.users — a customer is data, not a login.';

create index customers_organization_id_idx on public.customers (organization_id)
  where anonymized_at is null;

select private.attach_updated_at('public.customers');

-- Erasure without breaking the books. Orders keep pointing at a row, so totals
-- and the allergen record survive, but nothing identifying remains.
create or replace function public.anonymize_customer(p_customer_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  target public.customers;
begin
  select * into target from public.customers c where c.id = p_customer_id;

  if target.id is null then
    raise exception 'customer not found' using errcode = 'no_data_found';
  end if;

  if not (app.is_service_role() or app.has_org_role(target.organization_id, 'admin')) then
    raise exception 'admin required' using errcode = 'insufficient_privilege';
  end if;

  update public.customers
     set email = 'anonymized+' || id::text || '@invalid',
         full_name = null,
         phone = null,
         notes = null,
         marketing_opt_in = false,
         anonymized_at = coalesce(anonymized_at, now())
   where id = p_customer_id;
end;
$$;

comment on function public.anonymize_customer(uuid) is
  'Erases a customer''s personal data in place. The row survives so orders stay referentially intact.';

-- --- Orders -----------------------------------------------------------------

create table public.orders (
  id              uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  order_number    text not null unique default app.short_id(10),
  customer_id     uuid not null,
  status          public.order_status not null default 'pending',
  currency        text not null,
  total_cents     integer not null default 0,
  placed_at       timestamptz not null default now(),
  confirmed_at    timestamptz,
  cancelled_at    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  unique (id, organization_id),
  -- restrict: a customer with orders cannot be deleted. Anonymize instead.
  foreign key (customer_id, organization_id)
    references public.customers (id, organization_id) on delete restrict,
  constraint orders_currency_format check (currency ~ '^[a-z]{3}$'),
  constraint orders_total_non_negative check (total_cents >= 0),
  constraint orders_cancelled_has_timestamp
    check (status <> 'cancelled' or cancelled_at is not null)
);

create index orders_organization_id_idx on public.orders (organization_id, placed_at desc);
create index orders_customer_idx on public.orders (customer_id, placed_at desc);

select private.attach_updated_at('public.orders');

create trigger guard_server_columns
  before update on public.orders
  for each row execute function private.tg_guard_columns(
    'id', 'organization_id', 'order_number', 'customer_id', 'currency',
    'total_cents', 'placed_at', 'created_at');

-- Everything that must not change when the catalogue does is copied here at the
-- moment of sale. `product_id` is a convenience link, nullable on purpose: the
-- line stays meaningful after the product is gone.
create table public.order_items (
  id                   uuid primary key default extensions.gen_random_uuid(),
  order_id             uuid not null,
  organization_id      uuid not null,
  product_id           uuid,
  sku_at_purchase      extensions.citext not null,
  name_at_purchase     text not null,
  unit_price_cents     integer not null,
  quantity             integer not null,
  allergens_disclosed  text[] not null default '{}',
  line_total_cents     integer generated always as (unit_price_cents * quantity) stored,

  foreign key (order_id, organization_id)
    references public.orders (id, organization_id) on delete cascade,
  foreign key (product_id, organization_id)
    references public.products (id, organization_id) on delete set null,
  constraint order_items_quantity_positive check (quantity > 0),
  constraint order_items_price_non_negative check (unit_price_cents >= 0)
);

comment on column public.order_items.allergens_disclosed is
  'What the buyer was told at the time of sale. The legal record, and what a recall is measured against.';

create index order_items_order_idx on public.order_items (order_id);
create index order_items_product_idx on public.order_items (product_id);
create index order_items_allergens_idx on public.order_items using gin (allergens_disclosed);

-- --- Placing an order -------------------------------------------------------

create or replace function public.place_order(
  p_organization_id uuid,
  p_customer_id uuid,
  p_lines jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  line          jsonb;
  product       public.products;
  v_order_id    uuid;
  v_currency    text;
  v_customer    public.customers;
  v_qty         integer;
  requirement   record;
  v_available   numeric;
  v_total       integer := 0;
  v_resolved    jsonb := '[]'::jsonb;
begin
  if not (app.is_service_role() or app.has_org_role(p_organization_id, 'member')) then
    raise exception 'not authorized for this organization'
      using errcode = 'insufficient_privilege';
  end if;

  perform app.assert_org_writable(p_organization_id);

  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'an order needs at least one line'
      using errcode = 'check_violation';
  end if;

  select * into v_customer
    from public.customers c
   where c.id = p_customer_id and c.organization_id = p_organization_id;

  if v_customer.id is null then
    raise exception 'customer not found in this organization'
      using errcode = 'no_data_found';
  end if;

  -- Resolve the whole order against the catalogue before writing anything.
  -- The obvious shape is to insert a blank header, add the lines, then update
  -- the header with the currency and the total — and it does not work here:
  -- `currency`, `total_cents` and `placed_at` are server-owned columns, and the
  -- column guard silently reverts a client's edit to them. A SECURITY DEFINER
  -- function does not change the caller's role, so for an ordinary member that
  -- update would be reverted and every order would be stored as 0 xxx. Writing
  -- the header once, already correct, is both safer and simpler.
  for line in select * from jsonb_array_elements(p_lines)
  loop
    v_qty := coalesce((line ->> 'quantity')::integer, 0);

    if v_qty <= 0 then
      raise exception 'quantity must be positive for sku "%"', line ->> 'sku'
        using errcode = 'check_violation';
    end if;

    select * into product
      from public.products p
     where p.organization_id = p_organization_id
       and p.sku = (line ->> 'sku')::extensions.citext
       and p.status = 'active'
       and p.archived_at is null;

    if product.id is null then
      raise exception 'no active product with sku "%"', line ->> 'sku'
        using errcode = 'no_data_found';
    end if;

    -- Currency comes from the first product and is then held against the rest.
    v_currency := coalesce(v_currency, product.currency);

    if product.currency <> v_currency then
      raise exception 'order mixes currencies: % and %', v_currency, product.currency
        using errcode = 'check_violation',
              hint = 'Split this into one order per currency.';
    end if;

    v_total := v_total + product.price_cents * v_qty;

    -- Price and allergens are read once, here, and carried to the line. Even
    -- if the product is repriced a millisecond later, this order was agreed at
    -- the value in this array.
    v_resolved := v_resolved || jsonb_build_object(
      'product_id', product.id,
      'sku', product.sku,
      'name', product.name,
      'unit_price_cents', product.price_cents,
      'quantity', v_qty,
      'allergens', to_jsonb(product.allergens)
    );
  end loop;

  insert into public.orders (
    organization_id, customer_id, currency, total_cents, status, confirmed_at
  )
  values (
    p_organization_id, p_customer_id, v_currency, v_total, 'confirmed', now()
  )
  returning id into v_order_id;

  insert into public.order_items (
    order_id, organization_id, product_id,
    sku_at_purchase, name_at_purchase, unit_price_cents, quantity,
    allergens_disclosed
  )
  select v_order_id,
         p_organization_id,
         (l ->> 'product_id')::uuid,
         (l ->> 'sku')::extensions.citext,
         l ->> 'name',
         (l ->> 'unit_price_cents')::integer,
         (l ->> 'quantity')::integer,
         coalesce(array(select jsonb_array_elements_text(l -> 'allergens')), '{}'::text[])
    from jsonb_array_elements(v_resolved) as l;

  -- Lock every ingredient this order touches, in ascending id order, before
  -- reading any balance. Two orders racing for the last of something therefore
  -- queue instead of both concluding there is enough; ordering the locks the
  -- same way every time is what keeps them from deadlocking against each other.
  for requirement in
    select pi.ingredient_id,
           sum(pi.quantity * oi.quantity) as required
      from public.order_items oi
      join public.product_ingredients pi on pi.product_id = oi.product_id
     where oi.order_id = v_order_id
     group by pi.ingredient_id
     order by pi.ingredient_id
  loop
    perform 1 from public.ingredients i
      where i.id = requirement.ingredient_id
      for update;

    select coalesce(sum(m.quantity), 0) into v_available
      from public.inventory_movements m
     where m.ingredient_id = requirement.ingredient_id;

    if v_available < requirement.required then
      raise exception 'insufficient stock: ingredient % needs % but has %',
        requirement.ingredient_id, requirement.required, v_available
        using errcode = 'insufficient_resources',
              hint = 'Receive more stock or reduce the order.';
    end if;

    insert into public.inventory_movements
      (organization_id, ingredient_id, kind, quantity, order_id)
    values
      (p_organization_id, requirement.ingredient_id, 'consumption',
       -requirement.required, v_order_id);
  end loop;

  insert into public.usage_events
    (organization_id, metric, quantity, subject_type, subject_id)
  values
    (p_organization_id, 'order_placed', 1, 'order', v_order_id);

  return public.get_order(p_organization_id, v_order_id);
end;
$$;

comment on function public.place_order(uuid, uuid, jsonb) is
  'Places one order: snapshots price and allergens, then consumes ingredient stock under a lock.';

-- Cancelling returns what the order consumed, as `release` movements rather
-- than by deleting the consumption rows — the ledger stays append-only, so the
-- history of what happened survives the undo.
create or replace function public.cancel_order(
  p_organization_id uuid,
  p_order_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  target public.orders;
  consumed record;
begin
  if not (app.is_service_role() or app.has_org_role(p_organization_id, 'member')) then
    raise exception 'not authorized for this organization'
      using errcode = 'insufficient_privilege';
  end if;

  select * into target
    from public.orders o
   where o.id = p_order_id and o.organization_id = p_organization_id;

  if target.id is null then
    raise exception 'order not found' using errcode = 'no_data_found';
  end if;

  if target.status = 'cancelled' then
    raise exception 'order is already cancelled' using errcode = 'check_violation';
  end if;

  if target.status = 'fulfilled' then
    raise exception 'a fulfilled order cannot be cancelled'
      using errcode = 'check_violation',
            hint = 'Refund it instead.';
  end if;

  for consumed in
    select m.ingredient_id, -sum(m.quantity) as returning_quantity
      from public.inventory_movements m
     where m.order_id = p_order_id and m.kind = 'consumption'
     group by m.ingredient_id
  loop
    insert into public.inventory_movements
      (organization_id, ingredient_id, kind, quantity, order_id, note)
    values
      (p_organization_id, consumed.ingredient_id, 'release',
       consumed.returning_quantity, p_order_id, p_reason);
  end loop;

  update public.orders
     set status = 'cancelled', cancelled_at = now()
   where id = p_order_id;

  return public.get_order(p_organization_id, p_order_id);
end;
$$;

-- --- Reading ----------------------------------------------------------------

create or replace function public.get_order(p_organization_id uuid, p_order_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', o.id,
    'order_number', o.order_number,
    'status', o.status,
    'currency', o.currency,
    'total_cents', o.total_cents,
    'placed_at', o.placed_at,
    'customer', jsonb_build_object('id', c.id, 'email', c.email, 'name', c.full_name),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'sku', i.sku_at_purchase,
        'name', i.name_at_purchase,
        'quantity', i.quantity,
        'unit_price_cents', i.unit_price_cents,
        'line_total_cents', i.line_total_cents,
        'allergens', i.allergens_disclosed
      ) order by i.name_at_purchase)
        from public.order_items i
       where i.order_id = o.id
    ), '[]'::jsonb)
  )
    from public.orders o
    join public.customers c on c.id = o.customer_id
   where o.id = p_order_id and o.organization_id = p_organization_id;
$$;

-- --- The recall -------------------------------------------------------------
-- The query the whole design exists to answer. An ingredient turns out to
-- contain something undeclared; adding it relabels every product by trigger.
-- This then finds the orders that already shipped with a label that did not
-- say so — because the line kept what the buyer was actually told.

create or replace function public.orders_missing_allergen(
  p_organization_id uuid,
  p_allergen text,
  p_since timestamptz default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(hit order by hit ->> 'placed_at' desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
        'order_number', o.order_number,
        'placed_at', o.placed_at,
        'status', o.status,
        'customer_email', c.email,
        'sku', oi.sku_at_purchase,
        'product_name', oi.name_at_purchase,
        'quantity', oi.quantity,
        'disclosed', oi.allergens_disclosed
      ) as hit
        from public.order_items oi
        join public.orders o on o.id = oi.order_id
        join public.customers c on c.id = o.customer_id
        join public.products p on p.id = oi.product_id
       where o.organization_id = p_organization_id
         and o.status <> 'cancelled'
         and p_allergen = any (p.allergens)
         and not (p_allergen = any (oi.allergens_disclosed))
         and (p_since is null or o.placed_at >= p_since)
    ) hits;
$$;

comment on function public.orders_missing_allergen(uuid, text, timestamptz) is
  'Recall query: orders whose label omitted an allergen the product is now known to contain.';

-- --- RLS --------------------------------------------------------------------
-- Reads follow membership; writes additionally require 'member' and an
-- organization in good standing. The ledger and the order lines are readable
-- but never directly writable: they are written by the functions above, which
-- is what keeps the invariants from being routed around.

alter table public.allergens enable row level security;
alter table public.ingredients enable row level security;
alter table public.products enable row level security;
alter table public.product_ingredients enable row level security;
alter table public.inventory_movements enable row level security;
alter table public.customers enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

create policy "allergens: readable by everyone"
  on public.allergens for select
  to anon, authenticated
  using (true);

create policy "ingredients: read as member"
  on public.ingredients for select
  to authenticated
  using (app.is_org_member(organization_id));

create policy "ingredients: write as member"
  on public.ingredients for insert
  to authenticated
  with check (app.has_org_role(organization_id, 'member') and app.is_org_active(organization_id));

create policy "ingredients: update as member"
  on public.ingredients for update
  to authenticated
  using (app.has_org_role(organization_id, 'member'))
  with check (app.has_org_role(organization_id, 'member') and app.is_org_active(organization_id));

create policy "ingredients: delete as admin"
  on public.ingredients for delete
  to authenticated
  using (app.has_org_role(organization_id, 'admin'));

create policy "products: read as member"
  on public.products for select
  to authenticated
  using (app.is_org_member(organization_id));

-- The catalogue is the public face of the shop: anyone may read what is active.
create policy "products: read active catalogue"
  on public.products for select
  to anon, authenticated
  using (status = 'active' and archived_at is null);

create policy "products: write as member"
  on public.products for insert
  to authenticated
  with check (app.has_org_role(organization_id, 'member') and app.is_org_active(organization_id));

create policy "products: update as member"
  on public.products for update
  to authenticated
  using (app.has_org_role(organization_id, 'member'))
  with check (app.has_org_role(organization_id, 'member') and app.is_org_active(organization_id));

create policy "products: delete as admin"
  on public.products for delete
  to authenticated
  using (app.has_org_role(organization_id, 'admin'));

create policy "product_ingredients: read as member"
  on public.product_ingredients for select
  to authenticated
  using (app.is_org_member(organization_id));

create policy "product_ingredients: write as member"
  on public.product_ingredients for all
  to authenticated
  using (app.has_org_role(organization_id, 'member'))
  with check (app.has_org_role(organization_id, 'member') and app.is_org_active(organization_id));

create policy "inventory_movements: read as member"
  on public.inventory_movements for select
  to authenticated
  using (app.is_org_member(organization_id));

-- Insert only, and only forwards. There is deliberately no update or delete
-- policy: a ledger you can edit is not a ledger.
create policy "inventory_movements: append as member"
  on public.inventory_movements for insert
  to authenticated
  with check (app.has_org_role(organization_id, 'member') and app.is_org_active(organization_id));

create policy "customers: read as member"
  on public.customers for select
  to authenticated
  using (app.is_org_member(organization_id));

create policy "customers: write as member"
  on public.customers for insert
  to authenticated
  with check (app.has_org_role(organization_id, 'member') and app.is_org_active(organization_id));

create policy "customers: update as member"
  on public.customers for update
  to authenticated
  using (app.has_org_role(organization_id, 'member'))
  with check (app.has_org_role(organization_id, 'member') and app.is_org_active(organization_id));

create policy "customers: delete as admin"
  on public.customers for delete
  to authenticated
  using (app.has_org_role(organization_id, 'admin'));

create policy "orders: read as member"
  on public.orders for select
  to authenticated
  using (app.is_org_member(organization_id));

create policy "orders: update as member"
  on public.orders for update
  to authenticated
  using (app.has_org_role(organization_id, 'member'))
  with check (app.has_org_role(organization_id, 'member') and app.is_org_active(organization_id));

create policy "order_items: read as member"
  on public.order_items for select
  to authenticated
  using (app.is_org_member(organization_id));

-- --- Grants -----------------------------------------------------------------

revoke execute on function
  public.place_order(uuid, uuid, jsonb),
  public.cancel_order(uuid, uuid, text),
  public.anonymize_customer(uuid),
  public.orders_missing_allergen(uuid, text, timestamptz)
from public, anon;

grant execute on function
  public.place_order(uuid, uuid, jsonb),
  public.cancel_order(uuid, uuid, text),
  public.anonymize_customer(uuid),
  public.get_order(uuid, uuid),
  public.orders_missing_allergen(uuid, text, timestamptz)
to authenticated, service_role;

grant execute on function
  public.ingredient_available(uuid),
  public.product_sellable(uuid)
to authenticated, service_role;

-- --- Audit ------------------------------------------------------------------

select private.attach_audit('public.products');
select private.attach_audit('public.ingredients');
select private.attach_audit('public.orders');
select private.attach_audit('public.customers');
