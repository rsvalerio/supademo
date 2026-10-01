-- Plan enforcement, the allergen vocabulary, and the invitation lifecycle.
-- Impersonation helpers follow the same pattern as 01_tenancy.
begin;

-- pgTAP is test-only tooling. Creating it inside the transaction means it is
-- rolled back with everything else, so `supabase test db` needs no setup step
-- and no deployed database ever carries a thousand assertion functions it will
-- never call. `search_path` covers both placements: a fresh install lands in
-- `public`, while a project that enabled pgTAP from the dashboard has it in
-- `extensions`.
create extension if not exists pgtap;
set local search_path to public, extensions;

select plan(10);

-- Restores the session after impersonating. `reset role` alone is not enough:
-- set_config(..., is_local => true) lasts until the transaction ends, so the
-- JWT claims would linger and later assertions would silently run as that user.
create or replace function pg_temp.deimpersonate()
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

create or replace function pg_temp.claims(p_uid text, p_email text)
returns text language sql immutable as $$
  select case
    when p_uid is null then '{"role":"anon"}'
    else json_build_object('sub', p_uid, 'role', 'authenticated',
                           'email', p_email, 'aal', 'aal1')::text
  end;
$$;

create or replace function pg_temp.scalar_as(p_uid text, p_email text, p_sql text)
returns text language plpgsql as $$
declare result text;
begin
  perform set_config('request.jwt.claims', pg_temp.claims(p_uid, p_email), true);
  execute case when p_uid is null then 'set local role anon' else 'set local role authenticated' end;
  execute p_sql into result;
  perform pg_temp.deimpersonate();
  return result;
exception when others then
  perform pg_temp.deimpersonate();
  raise;
end $$;

create or replace function pg_temp.attempt_as(p_uid text, p_email text, p_sql text)
returns text language plpgsql as $$
begin
  perform set_config('request.jwt.claims', pg_temp.claims(p_uid, p_email), true);
  execute case when p_uid is null then 'set local role anon' else 'set local role authenticated' end;
  execute p_sql;
  perform pg_temp.deimpersonate();
  return null;
exception when others then
  perform pg_temp.deimpersonate();
  return sqlstate;
end $$;

insert into auth.users (id, email, raw_user_meta_data) values
  ('eeeeeeee-0000-4000-a000-000000000001', 'founder@test.local', '{"full_name":"Founder"}'),
  ('eeeeeeee-0000-4000-a000-000000000002', 'invitee@test.local', '{"full_name":"Invitee"}');

-- --- Organization creation --------------------------------------------------

create temporary table fixture on commit drop as
  select (pg_temp.scalar_as('eeeeeeee-0000-4000-a000-000000000001', 'founder@test.local',
    $$select (public.create_organization('Quota Test Co')).id::text$$))::uuid as org_id;

select is(
  (select role::text from public.organization_members m, fixture f
    where m.organization_id = f.org_id
      and m.user_id = 'eeeeeeee-0000-4000-a000-000000000001'),
  'owner', 'the creator becomes the owner');

select is(
  (select plan_id from public.subscriptions s, fixture f where s.organization_id = f.org_id),
  'free', 'a new organization starts on the free plan');

-- --- Quotas -----------------------------------------------------------------
-- The free plan allows ten products. The limit lives in plans.limits as jsonb
-- and is enforced by a BEFORE INSERT trigger, so it fails as a check violation
-- (23514) — which the API layer maps to 402, not 500.

select is(
  pg_temp.attempt_as('eeeeeeee-0000-4000-a000-000000000001', 'founder@test.local',
    format($$insert into public.products (organization_id, sku, name, price_cents)
             select %L, 'SKU-' || n, 'Product ' || n, 100 * n
               from generate_series(1, 10) n$$, (select org_id from fixture))),
  null, 'ten products fit on the free plan');

select is(
  pg_temp.attempt_as('eeeeeeee-0000-4000-a000-000000000001', 'founder@test.local',
    format($$insert into public.products (organization_id, sku, name, price_cents)
             values (%L, 'SKU-11', 'One too many', 999)$$,
           (select org_id from fixture))),
  '23514', 'the eleventh product is refused');

-- A product with no recipe has no allergens, and the column says so rather
-- than being null — an empty list is a claim, a null is a gap in the record.
select is(
  (select allergens::text from public.products p, fixture f
    where p.organization_id = f.org_id and p.sku = 'SKU-1'),
  '{}', 'a product with no recipe declares no allergens');

-- Allergen codes are a closed vocabulary in a table, so a typo is a write-time
-- error rather than a label nobody notices is wrong.
select is(
  pg_temp.attempt_as('eeeeeeee-0000-4000-a000-000000000001', 'founder@test.local',
    format($$insert into public.ingredients (organization_id, sku, name, unit, allergens)
             values (%L, 'TYPO', 'Mislabelled', 'g', array['peanut'])$$,
           (select org_id from fixture))),
  '23514', 'an allergen code outside the vocabulary is refused');

-- --- Invitations ------------------------------------------------------------

create temporary table invite on commit drop as
  select pg_temp.scalar_as('eeeeeeee-0000-4000-a000-000000000001', 'founder@test.local',
    format($$select (public.create_organization_invite(%L, 'invitee@test.local', 'member')).token$$,
           (select org_id from fixture))) as token;

select is(
  (select count(*)::text from public.organization_invites
    where email = 'invitee@test.local' and accepted_at is null),
  '1', 'an invitation is pending');

select is(
  pg_temp.attempt_as('eeeeeeee-0000-4000-a000-000000000001', 'founder@test.local',
    format($$select public.accept_organization_invite(%L)$$, (select token from invite))),
  '42501', 'an invitation cannot be redeemed by a different address');

select is(
  pg_temp.attempt_as('eeeeeeee-0000-4000-a000-000000000002', 'invitee@test.local',
    format($$select public.accept_organization_invite(%L)$$, (select token from invite))),
  null, 'the intended recipient can redeem the invitation');

select is(
  pg_temp.attempt_as('eeeeeeee-0000-4000-a000-000000000002', 'invitee@test.local',
    format($$select public.accept_organization_invite(%L)$$, (select token from invite))),
  '23514', 'an invitation cannot be redeemed twice');

select * from finish();
rollback;
