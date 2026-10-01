-- ---------------------------------------------------------------------------
-- 2000 · The machine API over the commerce domain
--
-- Same rule as 1500 and 1600, and it is the only rule that matters here: the
-- caller is an edge function running as `service_role`, so RLS is switched off.
-- The tenant boundary is therefore not a policy — it is the *signature* of every
-- function below. Each takes `p_organization_id` as its first argument and
-- filters by it, and that id comes from the API key the caller presented, never
-- from the request body. There is no route that lets a caller name an
-- organization.
--
-- Two further conventions, both load-bearing:
--
--   1. Nothing is addressed by uuid. Products are addressed by `sku`, orders by
--      `order_number`, customers by `email` — handles the customer already has
--      in their own system. A customer's automation should not have to store
--      our uuids, and a handle that is only unique *within* an organization
--      cannot be used to probe across one.
--
--   2. Writes go through the domain functions from 1800 rather than touching
--      tables. public.place_order() holds a lock ordering and a stock check
--      that an endpoint must not be able to skip, so the endpoint does not get
--      the option.
--
-- Error codes are the interface. The edge function maps them, so these RAISEs
-- are worded for a caller to read:
--
--   P0002  no_data_found         → 404
--   23514  check_violation       → 402 when the message says "plan limit", else 422
--   23505  unique_violation      → 409
--   53000  insufficient_resources → 409 (not enough stock)
--   42501  insufficient_privilege → 403
-- ---------------------------------------------------------------------------

-- --- Shared projections -----------------------------------------------------
-- One shape per resource, so the same product looks the same whether it came
-- back from a list, a create, or a recipe update. Clients break on fields that
-- move.

create or replace function private.api_product_json(p_product public.products)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'sku', p_product.sku,
    'name', p_product.name,
    'description', p_product.description,
    'price_cents', p_product.price_cents,
    'currency', p_product.currency,
    'status', p_product.status,
    -- Derived from the recipe, never set by the caller. It is in the response
    -- precisely so a client can see what the server decided.
    'allergens', to_jsonb(p_product.allergens),
    'sellable', public.product_sellable(p_product.id),
    'recipe', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ingredient_sku', i.sku,
               'ingredient_name', i.name,
               'quantity', pi.quantity,
               'unit', i.unit
             ) order by i.sku)
        from public.product_ingredients pi
        join public.ingredients i on i.id = pi.ingredient_id
       where pi.product_id = p_product.id
    ), '[]'::jsonb),
    'created_at', p_product.created_at,
    'updated_at', p_product.updated_at
  );
$$;

-- --- Products: read ---------------------------------------------------------

create or replace function public.api_list_products(
  p_organization_id uuid,
  p_status public.product_status default null,
  p_limit integer default 25,
  p_before timestamptz default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(product order by product ->> 'created_at' desc), '[]'::jsonb)
    from (
      select private.api_product_json(p) as product
        from public.products p
       where p.organization_id = p_organization_id
         and p.archived_at is null
         and (p_status is null or p.status = p_status)
         and (p_before is null or p.created_at < p_before)
       order by p.created_at desc
       limit least(coalesce(p_limit, 25), 100)
    ) page;
$$;

create or replace function public.api_get_product(
  p_organization_id uuid,
  p_sku text
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select private.api_product_json(p)
    from public.products p
   where p.organization_id = p_organization_id
     and p.sku = p_sku::extensions.citext
     and p.archived_at is null;
$$;

-- --- Products: write --------------------------------------------------------

-- Upsert by sku, because that is the handle the caller owns. A sync job that
-- re-runs should converge, not accumulate duplicates or fail on the second
-- pass. `allergens` is absent from the signature on purpose: it is derived, and
-- offering it would only produce a refusal the caller cannot act on.
create or replace function public.api_upsert_product(
  p_organization_id uuid,
  p_sku text,
  p_name text,
  p_price_cents integer,
  p_description text default null,
  p_currency text default 'eur',
  p_status public.product_status default 'draft'
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  saved public.products;
begin
  perform app.assert_org_writable(p_organization_id);

  if coalesce(trim(p_sku), '') = '' then
    raise exception 'sku is required' using errcode = 'check_violation';
  end if;

  if coalesce(trim(p_name), '') = '' then
    raise exception 'name is required' using errcode = 'check_violation';
  end if;

  if p_price_cents is null or p_price_cents < 0 then
    raise exception 'price_cents must be zero or more'
      using errcode = 'check_violation';
  end if;

  select * into saved
    from public.products p
   where p.organization_id = p_organization_id
     and p.sku = trim(p_sku)::extensions.citext;

  if saved.id is null then
    -- The product quota trigger fires here; exceeding the plan raises 23514
    -- with "plan limit reached", which the edge function turns into a 402.
    insert into public.products (
      organization_id, sku, name, description, price_cents, currency, status
    )
    values (
      p_organization_id, trim(p_sku), trim(p_name), p_description,
      p_price_cents, lower(coalesce(p_currency, 'eur')), coalesce(p_status, 'draft')
    )
    returning * into saved;
  else
    update public.products
       set name = trim(p_name),
           description = p_description,
           price_cents = p_price_cents,
           currency = lower(coalesce(p_currency, 'eur')),
           status = coalesce(p_status, saved.status),
           archived_at = null
     where id = saved.id
    returning * into saved;
  end if;

  return private.api_product_json(saved);
end;
$$;

-- The recipe is replaced wholesale rather than patched line by line. A partial
-- recipe is not a meaningful intermediate state — it would mean a product
-- briefly declaring fewer allergens than it contains — so the whole set is
-- swapped inside one transaction and the allergen trigger recomputes once.
create or replace function public.api_set_recipe(
  p_organization_id uuid,
  p_sku text,
  p_lines jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  target public.products;
  line jsonb;
  ingredient public.ingredients;
  quantity numeric;
begin
  perform app.assert_org_writable(p_organization_id);

  if jsonb_typeof(p_lines) <> 'array' then
    raise exception 'lines must be an array of {ingredient_sku, quantity}'
      using errcode = 'check_violation';
  end if;

  select * into target
    from public.products p
   where p.organization_id = p_organization_id
     and p.sku = p_sku::extensions.citext
     and p.archived_at is null;

  if target.id is null then
    raise exception 'no product with sku "%" in this organization', p_sku
      using errcode = 'no_data_found';
  end if;

  delete from public.product_ingredients where product_id = target.id;

  for line in select * from jsonb_array_elements(p_lines)
  loop
    quantity := (line ->> 'quantity')::numeric;

    if quantity is null or quantity <= 0 then
      raise exception 'quantity must be greater than zero for ingredient "%"',
        line ->> 'ingredient_sku'
        using errcode = 'check_violation';
    end if;

    select * into ingredient
      from public.ingredients i
     where i.organization_id = p_organization_id
       and i.sku = (line ->> 'ingredient_sku')::extensions.citext
       and i.archived_at is null;

    if ingredient.id is null then
      raise exception 'no ingredient with sku "%" in this organization',
        line ->> 'ingredient_sku'
        using errcode = 'no_data_found';
    end if;

    -- No unit is accepted here. The quantity is in the ingredient's own unit,
    -- which is the reason a recipe cannot mix grams and units by accident.
    insert into public.product_ingredients
      (product_id, ingredient_id, organization_id, quantity)
    values
      (target.id, ingredient.id, p_organization_id, quantity);
  end loop;

  select * into target from public.products p where p.id = target.id;
  return private.api_product_json(target);
end;
$$;

-- --- Ingredients ------------------------------------------------------------

create or replace function public.api_upsert_ingredient(
  p_organization_id uuid,
  p_sku text,
  p_name text,
  p_unit public.unit_of_measure,
  p_allergens text[] default '{}',
  p_reorder_level numeric default 0
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  saved public.ingredients;
begin
  perform app.assert_org_writable(p_organization_id);

  if coalesce(trim(p_sku), '') = '' or coalesce(trim(p_name), '') = '' then
    raise exception 'sku and name are required' using errcode = 'check_violation';
  end if;

  select * into saved
    from public.ingredients i
   where i.organization_id = p_organization_id
     and i.sku = trim(p_sku)::extensions.citext;

  if saved.id is null then
    -- An unknown allergen code is refused by the validation trigger with
    -- 23514 and a hint naming public.allergens. Nothing is coerced.
    insert into public.ingredients (
      organization_id, sku, name, unit, allergens, reorder_level
    )
    values (
      p_organization_id, trim(p_sku), trim(p_name), p_unit,
      coalesce(p_allergens, '{}'), coalesce(p_reorder_level, 0)
    )
    returning * into saved;
  else
    if p_unit is distinct from saved.unit then
      -- Changing the unit would silently reinterpret every recipe quantity and
      -- every ledger row already recorded against it. Make a new ingredient.
      raise exception 'an ingredient''s unit cannot be changed once it is in use'
        using errcode = 'check_violation',
              hint = 'Create a new ingredient with the new unit and repoint the recipes.';
    end if;

    update public.ingredients
       set name = trim(p_name),
           allergens = coalesce(p_allergens, saved.allergens),
           reorder_level = coalesce(p_reorder_level, saved.reorder_level),
           archived_at = null
     where id = saved.id
    returning * into saved;
  end if;

  return jsonb_build_object(
    'sku', saved.sku,
    'name', saved.name,
    'unit', saved.unit,
    'allergens', to_jsonb(saved.allergens),
    'reorder_level', saved.reorder_level,
    'available', public.ingredient_available(saved.id),
    'updated_at', saved.updated_at
  );
end;
$$;

-- --- Inventory --------------------------------------------------------------

create or replace function public.api_stock_levels(
  p_organization_id uuid,
  p_below_reorder_level boolean default false
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(row order by row ->> 'sku'), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'sku', i.sku,
               'name', i.name,
               'unit', i.unit,
               'available', public.ingredient_available(i.id),
               'reorder_level', i.reorder_level,
               'allergens', to_jsonb(i.allergens)
             ) as row
        from public.ingredients i
       where i.organization_id = p_organization_id
         and i.archived_at is null
         and (
           not p_below_reorder_level
           or public.ingredient_available(i.id) < i.reorder_level
         )
    ) rows;
$$;

-- Receipts, waste and adjustments only. `consumption` and `release` are not
-- accepted: those are written by place_order() and cancel_order(), and letting
-- an endpoint forge one would decouple the ledger from the orders it is meant
-- to explain.
create or replace function public.api_record_movement(
  p_organization_id uuid,
  p_sku text,
  p_kind public.stock_movement_kind,
  p_quantity numeric,
  p_unit_cost_cents integer default null,
  p_note text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  ingredient public.ingredients;
begin
  perform app.assert_org_writable(p_organization_id);

  if p_kind not in ('receipt', 'waste', 'adjustment') then
    raise exception 'kind must be receipt, waste or adjustment'
      using errcode = 'check_violation',
            hint = 'Consumption and release are written by the order functions.';
  end if;

  select * into ingredient
    from public.ingredients i
   where i.organization_id = p_organization_id
     and i.sku = p_sku::extensions.citext
     and i.archived_at is null;

  if ingredient.id is null then
    raise exception 'no ingredient with sku "%" in this organization', p_sku
      using errcode = 'no_data_found';
  end if;

  -- The sign check is a table constraint, so a negative receipt fails here
  -- with 23514 whatever this function forgets to check.
  insert into public.inventory_movements (
    organization_id, ingredient_id, kind, quantity, unit_cost_cents, note
  )
  values (
    p_organization_id, ingredient.id, p_kind, p_quantity,
    p_unit_cost_cents, p_note
  );

  return jsonb_build_object(
    'sku', ingredient.sku,
    'kind', p_kind,
    'quantity', p_quantity,
    'available', public.ingredient_available(ingredient.id)
  );
end;
$$;

-- --- Customers --------------------------------------------------------------

-- Addressed by email, which is also the uniqueness key within an organization,
-- so this converges on a retry. An anonymized customer is not resurrected by
-- an upsert: their record was scrubbed on purpose.
create or replace function public.api_upsert_customer(
  p_organization_id uuid,
  p_email text,
  p_full_name text default null,
  p_phone text default null,
  p_marketing_opt_in boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  saved public.customers;
begin
  perform app.assert_org_writable(p_organization_id);

  if coalesce(trim(p_email), '') = '' then
    raise exception 'email is required' using errcode = 'check_violation';
  end if;

  select * into saved
    from public.customers c
   where c.organization_id = p_organization_id
     and c.email = trim(p_email)::extensions.citext;

  if saved.id is not null and saved.anonymized_at is not null then
    raise exception 'this customer record has been anonymized'
      using errcode = 'check_violation',
            hint = 'Anonymization is deliberate and is not undone by an upsert.';
  end if;

  if saved.id is null then
    insert into public.customers (
      organization_id, email, full_name, phone, marketing_opt_in
    )
    values (
      p_organization_id, trim(p_email), p_full_name, p_phone,
      coalesce(p_marketing_opt_in, false)
    )
    returning * into saved;
  else
    update public.customers
       set full_name = coalesce(p_full_name, saved.full_name),
           phone = coalesce(p_phone, saved.phone),
           marketing_opt_in = coalesce(p_marketing_opt_in, saved.marketing_opt_in)
     where id = saved.id
    returning * into saved;
  end if;

  return jsonb_build_object(
    'id', saved.id,
    'email', saved.email,
    'full_name', saved.full_name,
    'phone', saved.phone,
    'marketing_opt_in', saved.marketing_opt_in,
    'created_at', saved.created_at
  );
end;
$$;

-- --- Orders -----------------------------------------------------------------

create or replace function public.api_list_orders(
  p_organization_id uuid,
  p_status public.order_status default null,
  p_limit integer default 25,
  p_before timestamptz default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(row order by row ->> 'placed_at' desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'order_number', o.order_number,
               'status', o.status,
               'currency', o.currency,
               'total_cents', o.total_cents,
               'placed_at', o.placed_at,
               'customer_email', c.email,
               'line_count', (select count(*) from public.order_items oi
                               where oi.order_id = o.id)
             ) as row
        from public.orders o
        join public.customers c on c.id = o.customer_id
       where o.organization_id = p_organization_id
         and (p_status is null or o.status = p_status)
         and (p_before is null or o.placed_at < p_before)
       order by o.placed_at desc
       limit least(coalesce(p_limit, 25), 100)
    ) rows;
$$;

create or replace function public.api_get_order(
  p_organization_id uuid,
  p_order_number text
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.get_order(p_organization_id, o.id)
    from public.orders o
   where o.organization_id = p_organization_id
     and o.order_number = p_order_number;
$$;

-- The endpoint resolves the customer by email and then hands the whole thing to
-- public.place_order(), which is where the lock ordering, the stock check and
-- the snapshotting live. This function deliberately adds nothing to that
-- sequence: an endpoint that could assemble an order a different way would be
-- an endpoint that could assemble one wrongly.
create or replace function public.api_place_order(
  p_organization_id uuid,
  p_customer_email text,
  p_lines jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  customer public.customers;
begin
  select * into customer
    from public.customers c
   where c.organization_id = p_organization_id
     and c.email = trim(coalesce(p_customer_email, ''))::extensions.citext
     and c.anonymized_at is null;

  if customer.id is null then
    raise exception 'no customer with email "%" in this organization', p_customer_email
      using errcode = 'no_data_found',
            hint = 'Create the customer first; an order is not a place to register one.';
  end if;

  return public.place_order(p_organization_id, customer.id, p_lines);
end;
$$;

create or replace function public.api_cancel_order(
  p_organization_id uuid,
  p_order_number text,
  p_reason text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  target_id uuid;
begin
  select o.id into target_id
    from public.orders o
   where o.organization_id = p_organization_id
     and o.order_number = p_order_number;

  if target_id is null then
    raise exception 'no order numbered "%" in this organization', p_order_number
      using errcode = 'no_data_found';
  end if;

  return public.cancel_order(p_organization_id, target_id, p_reason);
end;
$$;

-- --- Recalls ----------------------------------------------------------------

-- The query this whole domain exists to make answerable: orders whose label
-- omitted an allergen the product is now known to contain. It is on the machine
-- surface because the answer is a list of people to contact, and contacting
-- them is a job for a system, not a spreadsheet.
create or replace function public.api_recall_report(
  p_organization_id uuid,
  p_allergen text,
  p_since timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.allergens a where a.code = p_allergen) then
    raise exception 'unknown allergen "%"', p_allergen
      using errcode = 'no_data_found',
            hint = 'See the allergen vocabulary in public.allergens.';
  end if;

  return jsonb_build_object(
    'allergen', p_allergen,
    'since', p_since,
    'affected', public.orders_missing_allergen(p_organization_id, p_allergen, p_since)
  );
end;
$$;

-- --- Grants -----------------------------------------------------------------
-- service_role only, and nothing else. These functions take an organization id
-- as an argument and trust it, which is safe exactly because the only caller
-- that can reach them got that id from an authenticated API key. Granting any
-- of them to `authenticated` would hand every signed-in user a way to name
-- someone else's organization.

revoke execute on function
  private.api_product_json(public.products),
  public.api_list_products(uuid, public.product_status, integer, timestamptz),
  public.api_get_product(uuid, text),
  public.api_upsert_product(uuid, text, text, integer, text, text, public.product_status),
  public.api_set_recipe(uuid, text, jsonb),
  public.api_upsert_ingredient(uuid, text, text, public.unit_of_measure, text[], numeric),
  public.api_stock_levels(uuid, boolean),
  public.api_record_movement(uuid, text, public.stock_movement_kind, numeric, integer, text),
  public.api_upsert_customer(uuid, text, text, text, boolean),
  public.api_list_orders(uuid, public.order_status, integer, timestamptz),
  public.api_get_order(uuid, text),
  public.api_place_order(uuid, text, jsonb),
  public.api_cancel_order(uuid, text, text),
  public.api_recall_report(uuid, text, timestamptz)
from public, anon, authenticated;

grant execute on function
  public.api_list_products(uuid, public.product_status, integer, timestamptz),
  public.api_get_product(uuid, text),
  public.api_upsert_product(uuid, text, text, integer, text, text, public.product_status),
  public.api_set_recipe(uuid, text, jsonb),
  public.api_upsert_ingredient(uuid, text, text, public.unit_of_measure, text[], numeric),
  public.api_stock_levels(uuid, boolean),
  public.api_record_movement(uuid, text, public.stock_movement_kind, numeric, integer, text),
  public.api_upsert_customer(uuid, text, text, text, boolean),
  public.api_list_orders(uuid, public.order_status, integer, timestamptz),
  public.api_get_order(uuid, text),
  public.api_place_order(uuid, text, jsonb),
  public.api_cancel_order(uuid, text, text),
  public.api_recall_report(uuid, text, timestamptz)
to service_role;

comment on function public.api_place_order(uuid, text, jsonb) is
  'API: resolves the customer by email, then delegates to public.place_order().';
comment on function public.api_set_recipe(uuid, text, jsonb) is
  'API: replaces a product recipe wholesale, so allergens are recomputed once.';
comment on function public.api_recall_report(uuid, text, timestamptz) is
  'API: orders placed under a label that omitted an allergen the product contains.';
