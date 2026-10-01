-- ---------------------------------------------------------------------------
-- 1900 · Retiring the demo domain
--
-- Migrations are append-only, so "replacing" the original demo domain means a
-- migration that explicitly takes it apart — not an edit to 0500. Everything
-- the platform spine provides (organizations, members, plans, billing, usage,
-- audit, webhooks, cron, the whole API-key layer) stays exactly as it was; only
-- the domain tables and the entry points that named them go away, because 1800
-- now supplies the domain.
--
-- Order matters. Postgres would let `drop ... cascade` sort it out, but cascade
-- is a blunt instrument: it silently takes dependents nobody listed, which in a
-- schema with views and triggers over the same tables is how you lose a policy
-- you meant to keep. Everything below is dropped explicitly, dependents first,
-- so the diff is the inventory.
--
-- Three things cannot be undone and are left in place deliberately:
--
--   * Enum values. Postgres has no `alter type ... drop value`, so
--     `document_source.demo`, `notification_kind.demo_published` and
--     `usage_metric.demo_view` / `demo_created` survive as dead labels. Nothing
--     writes them after this migration. Removing them means recreating the type
--     and rewriting every column that uses it, which is a cost with no payoff.
--   * Audit rows. private.audit_log keeps history for tables that no longer
--     exist. That is the point of an audit log.
--   * Already-rolled-up usage. usage_daily rows for demo metrics stay; they
--     were true when they were written.
-- ---------------------------------------------------------------------------

-- --- Views over the retired tables ------------------------------------------
-- These are the anonymous and authenticated read surfaces from 1400. They are
-- dropped first because a view holds a hard dependency on its tables.

drop view if exists api.demo_directory;
drop view if exists api.demo_stats;

-- api.my_organizations only *mentions* public.demos, in a scalar subquery for
-- the workspace switcher's badge. A view's column list cannot be changed in
-- place, so it is dropped and rebuilt without the count.
drop view if exists api.my_organizations;

create view api.my_organizations
  with (security_invoker = true)
as
  select o.id,
         o.slug,
         o.name,
         o.logo_path,
         m.role,
         s.plan_id,
         s.status as subscription_status,
         s.trial_ends_at,
         s.current_period_end,
         (select count(*) from public.organization_members mm where mm.organization_id = o.id) as member_count,
         o.created_at
    from public.organizations o
    join public.organization_members m
      on m.organization_id = o.id and m.user_id = (select auth.uid())
    left join public.subscriptions s on s.organization_id = o.id
   where o.deleted_at is null;

comment on view api.my_organizations is 'Workspace switcher payload for the signed-in user.';

grant select on api.my_organizations to authenticated;

-- --- The API-key endpoint surface -------------------------------------------
-- The six functions the api-v1 edge function routed to. Their bodies are not
-- checked until they run, so dropping the tables under them would have left
-- six endpoints that fail at call time with a confusing error instead of a 404.

drop function if exists public.api_list_demos(uuid, integer, timestamptz);
drop function if exists public.api_get_demo(uuid, text);
drop function if exists public.api_demo_analytics(uuid, text, timestamptz);
drop function if exists public.api_create_demo(uuid, text, text, text, text[]);
drop function if exists public.api_update_demo(uuid, text, text, text, text[]);
drop function if exists public.api_publish_demo(uuid, text, public.demo_visibility);

-- --- The session-authenticated RPCs -----------------------------------------

drop function if exists public.get_public_demo(text);
drop function if exists public.search_demos(text, uuid, integer);
drop function if exists public.demo_analytics(uuid, timestamptz);
drop function if exists public.track_demo_view(text, uuid, integer, boolean, integer, text, text, text);
drop function if exists public.capture_demo_lead(text, text, text, jsonb, uuid);

-- --- Trigger functions ------------------------------------------------------
-- The triggers themselves go when their tables do; these are the functions the
-- triggers pointed at, which would otherwise linger as unreferenced code.

drop function if exists private.tg_demo_defaults();
drop function if exists private.tg_enforce_project_quota();
drop function if exists private.tg_notify_on_comment();
drop function if exists private.tg_dispatch_demo_events();

-- --- Storage ----------------------------------------------------------------
-- `demo-assets` becomes `product-media`: same shape (private, members read and
-- write their own organization's prefix), same path convention with a different
-- second segment —
--
--   product-media  orgs/<organization_id>/products/<product_id>/<filename>
--
-- A bucket id cannot be renamed while objects reference it, so the row is
-- replaced. On a hosted project with objects already in `demo-assets` this
-- delete will fail loudly rather than orphan files, which is the correct
-- outcome: a copy has to happen first.

drop policy if exists "demo-assets: read as member"   on storage.objects;
drop policy if exists "demo-assets: write as member"  on storage.objects;
drop policy if exists "demo-assets: update as member" on storage.objects;
drop policy if exists "demo-assets: delete as member" on storage.objects;

do $$
begin
  if to_regclass('storage.s3_multipart_uploads') is not null then
    drop policy if exists "demo-assets: multipart as member" on storage.s3_multipart_uploads;
    drop policy if exists "demo-assets: multipart parts as member"
      on storage.s3_multipart_uploads_parts;
  end if;
end;
$$;

delete from storage.buckets where id = 'demo-assets';

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('product-media', 'product-media', false, 20971520,
   array['image/png', 'image/jpeg', 'image/webp', 'application/pdf'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- A spec sheet or an allergen label is not public: a product can be listed
-- anonymously (1800 allows that for active products) while its media stays
-- behind a signed URL minted server-side.
create policy "product-media: read as member"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'product-media'
    and app.is_org_member(app.storage_scope_id(name))
  );

create policy "product-media: write as member"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'product-media'
    and (storage.foldername(name))[1] = 'orgs'
    and app.has_org_role(app.storage_scope_id(name), 'member')
    and app.is_org_active(app.storage_scope_id(name))
  );

create policy "product-media: update as member"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'product-media'
    and app.has_org_role(app.storage_scope_id(name), 'member')
  )
  with check (
    bucket_id = 'product-media'
    and app.has_org_role(app.storage_scope_id(name), 'member')
  );

create policy "product-media: delete as member"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'product-media'
    and app.has_org_role(app.storage_scope_id(name), 'member')
  );

do $$
begin
  if to_regclass('storage.s3_multipart_uploads') is not null then
    execute $policy$
      create policy "product-media: multipart as member"
        on storage.s3_multipart_uploads for all
        to authenticated
        using (bucket_id = 'product-media' and app.has_org_role(app.storage_scope_id(key), 'member'))
        with check (bucket_id = 'product-media' and app.has_org_role(app.storage_scope_id(key), 'member'))
    $policy$;

    execute $policy$
      create policy "product-media: multipart parts as member"
        on storage.s3_multipart_uploads_parts for all
        to authenticated
        using (bucket_id = 'product-media' and app.has_org_role(app.storage_scope_id(key), 'member'))
        with check (bucket_id = 'product-media' and app.has_org_role(app.storage_scope_id(key), 'member'))
    $policy$;
  end if;
end;
$$;

-- The meter's bucket allowlist is a literal, so it has to learn the new name or
-- product media would be stored for free.
create or replace function private.tg_meter_storage()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  org_id uuid;
  bucket text;
  delta numeric;
begin
  if tg_op = 'DELETE' then
    bucket := old.bucket_id;
    org_id := app.storage_scope_id(old.name);
    delta  := -coalesce((old.metadata ->> 'size')::numeric, 0);
  elsif tg_op = 'INSERT' then
    bucket := new.bucket_id;
    org_id := app.storage_scope_id(new.name);
    delta  := coalesce((new.metadata ->> 'size')::numeric, 0);
  else
    bucket := new.bucket_id;
    org_id := app.storage_scope_id(new.name);
    delta  := coalesce((new.metadata ->> 'size')::numeric, 0)
              - coalesce((old.metadata ->> 'size')::numeric, 0);
  end if;

  if org_id is null
     or bucket not in ('product-media', 'org-branding', 'exports')
     or delta = 0
     or not exists (select 1 from public.organizations o where o.id = org_id)
  then
    return null;
  end if;

  insert into public.usage_events (organization_id, metric, quantity, subject_type, metadata)
  values (org_id, 'storage_bytes', abs(delta), 'object',
          jsonb_build_object('direction', case when delta > 0 then 'add' else 'remove' end,
                             'bucket', bucket));

  return null;
end;
$$;

-- --- The tables -------------------------------------------------------------
-- Children first. Every one of these would have gone with a cascade from
-- public.demos; listing them is what makes the removal reviewable.

drop table if exists public.demo_leads;
drop table if exists public.demo_views;
drop table if exists public.demo_comments;
drop table if exists public.demo_steps;
drop table if exists public.demos;
drop table if exists public.projects;

drop type if exists public.demo_status;
drop type if exists public.demo_visibility;

-- --- Cron jobs that read the retired tables ---------------------------------
-- The jobs stay scheduled; pg_cron stores a SQL string, so only the function
-- bodies change.

-- Retention no longer purges soft-deleted demos or viewer rows. Note what is
-- *not* here: inventory_movements. Stock on hand is the sum of the ledger, so
-- trimming old movements would not save space, it would change the answer.
create or replace function private.enforce_retention()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  usage_deleted integer;
  audit_deleted integer;
  invites_expired integer;
  deliveries_deleted integer;
begin
  delete from public.usage_events where occurred_at < now() - interval '90 days';
  get diagnostics usage_deleted = row_count;

  delete from private.audit_log where created_at < now() - interval '365 days';
  get diagnostics audit_deleted = row_count;

  update public.organization_invites
     set revoked_at = now()
   where accepted_at is null
     and revoked_at is null
     and expires_at < now();
  get diagnostics invites_expired = row_count;

  delete from private.webhook_deliveries
   where created_at < now() - interval '30 days'
     and status in ('delivered', 'abandoned');
  get diagnostics deliveries_deleted = row_count;

  return jsonb_build_object(
    'usage_events_deleted', usage_deleted,
    'audit_rows_deleted', audit_deleted,
    'invites_expired', invites_expired,
    'webhook_deliveries_deleted', deliveries_deleted
  );
end;
$$;

-- The metered quota is orders placed, not demo views.
create or replace function private.check_quota_warnings()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  row_org record;
  limit_orders numeric;
  used_orders numeric;
  warned integer := 0;
begin
  for row_org in
    select s.organization_id
      from public.subscriptions s
     where s.status in ('active', 'trialing')
  loop
    limit_orders := app.quota_limit(row_org.organization_id, 'orders_per_month');
    continue when limit_orders is null or limit_orders <= 0;  -- unlimited or unset

    select coalesce(sum(u.quantity), 0) into used_orders
      from public.usage_daily u
     where u.organization_id = row_org.organization_id
       and u.metric = 'order_placed'
       and u.day >= date_trunc('month', now())::date;

    if used_orders >= limit_orders * 0.8 then
      perform private.notify_users(
        (select coalesce(array_agg(m.user_id), '{}'::uuid[])
           from public.organization_members m
          where m.organization_id = row_org.organization_id
            and m.role >= 'admin'),
        row_org.organization_id,
        'quota_warning',
        'You have used ' || round(used_orders / limit_orders * 100) || '% of this month''s orders',
        'The order allowance resets at the start of the next billing period.',
        '/settings/billing',
        jsonb_build_object('metric', 'orders_per_month', 'used', used_orders, 'limit', limit_orders)
      );
      warned := warned + 1;
    end if;
  end loop;

  return warned;
end;
$$;

-- --- Plan limits ------------------------------------------------------------
-- Limits are data, not schema, which is the whole reason they live in jsonb.
-- Only keys something actually reads are listed: `products` is enforced by the
-- quota trigger in 1800, `orders_per_month` by the warning job above,
-- `members` by the seat trigger, `storage_mb` and `ai_embeddings` by their own
-- call sites. A key nobody reads is a promise nobody keeps.

update public.plans set
  features = '["10 products", "Allergen labelling", "Community support"]'::jsonb,
  limits = '{"products": 10, "members": 2, "storage_mb": 100, "orders_per_month": 100, "ai_embeddings": 100}'::jsonb
where id = 'free';

update public.plans set
  features = '["Unlimited products", "Recipe costing", "Allergen recall reports", "Email support"]'::jsonb,
  limits = '{"products": -1, "members": 10, "storage_mb": 10240, "orders_per_month": 10000, "ai_embeddings": 10000}'::jsonb
where id = 'pro';

update public.plans set
  features = '["Everything in Pro", "SSO", "Audit log export", "Priority support"]'::jsonb,
  limits = '{"products": -1, "members": -1, "storage_mb": 102400, "orders_per_month": -1, "ai_embeddings": 100000}'::jsonb
where id = 'scale';

comment on column public.plans.limits is
  'Quota map, e.g. {"products": 25, "members": 10}. -1 means unlimited.';

-- --- API scopes -------------------------------------------------------------
-- The scope list is a closed vocabulary in a table precisely so that this is a
-- delete and an insert rather than a search through string literals. The
-- commerce scopes are registered now, ahead of the routes that will require
-- them, so a key can be issued with the right grants from the start.

delete from public.api_scopes
 where scope in ('demos:read', 'demos:write', 'leads:read', 'projects:read');

insert into public.api_scopes (scope, description, is_write, sort_order) values
  ('products:read',    'List and read products, including their recipe and allergens.', false, 10),
  ('products:write',   'Create and update products, ingredients and recipes.',          true,  20),
  ('inventory:read',   'Read stock on hand and the movement ledger.',                   false, 30),
  ('inventory:write',  'Record receipts, waste and adjustments.',                       true,  40),
  ('orders:read',      'Read orders and their snapshotted lines.',                      false, 50),
  ('orders:write',     'Place and cancel orders.',                                      true,  60),
  ('customers:read',   'Read customer records.',                                        false, 70),
  ('customers:write',  'Create and anonymize customer records.',                        true,  80)
on conflict (scope) do nothing;

update public.api_scopes
   set description = 'Read order volumes and daily usage.', sort_order = 90
 where scope = 'analytics:read';

update public.api_scopes set sort_order = 100 where scope = 'documents:read';
update public.api_scopes set sort_order = 110 where scope = 'documents:write';

-- `demos:read` was the default scope in two places, and a default that names a
-- scope no longer in the vocabulary is a key that cannot be issued.
alter table public.api_keys alter column scopes set default array['products:read'];

create or replace function public.create_api_key(
  p_organization_id uuid,
  p_name text,
  p_scopes text[] default array['products:read'],
  p_expires_in interval default null
)
returns table (key_id uuid, key_prefix text, api_key text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  secret text;
  generated_prefix text;
  full_key text;
begin
  if not app.has_org_role(p_organization_id, 'admin') then
    raise exception 'only admins and owners can create API keys' using errcode = 'insufficient_privilege';
  end if;

  secret := encode(extensions.gen_random_bytes(24), 'hex');
  generated_prefix := 'sk_' || app.short_id(8);
  full_key := generated_prefix || '_' || secret;

  insert into public.api_keys (
    organization_id, name, prefix, key_hash, scopes, created_by, expires_at
  )
  values (
    p_organization_id,
    left(p_name, 80),
    generated_prefix,
    encode(extensions.digest(full_key, 'sha256'), 'hex'),
    p_scopes,
    (select auth.uid()),
    case when p_expires_in is null then null else now() + p_expires_in end
  )
  returning api_keys.id into key_id;

  key_prefix := generated_prefix;
  api_key := full_key;
  return next;
end;
$$;

comment on function public.create_api_key(uuid, text, text[], interval) is
  'RPC: issues an API key. The plaintext value is returned once and never stored.';

-- --- Knowledge base ---------------------------------------------------------
-- A document can describe a product now. The `demo` label stays in the enum,
-- unused, for the reason given at the top of this file.
alter type public.document_source add value if not exists 'product';

-- --- Realtime ---------------------------------------------------------------
-- Orders are the one commerce table worth streaming: a kitchen or packing
-- screen wants a new line the moment it is confirmed. order_items deliberately
-- stays out — a subscriber gets the order and reads its lines, rather than
-- receiving the same sale twice in two shapes.
do $$
begin
  if exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_catalog.pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'orders'
    ) then
      alter publication supabase_realtime add table public.orders;
    end if;
  end if;
end;
$$;

alter table public.orders replica identity full;
