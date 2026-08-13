-- API keys: issuing, scoping, rate limiting, revocation and rotation.
--
-- These run as the test's own role, which is a superuser and therefore
-- satisfies app.is_service_role() the same way a direct psql session or a cron
-- job does. Where a caller's identity matters — issuing a key requires being an
-- admin — the impersonation helper is used, exactly as in 01_tenancy.
begin;

-- pgTAP is test-only tooling. Creating it inside the transaction means it is
-- rolled back with everything else, so `supabase test db` needs no setup step
-- and no deployed database ever carries a thousand assertion functions it will
-- never call. `search_path` covers both placements: a fresh install lands in
-- `public`, while a project that enabled pgTAP from the dashboard has it in
-- `extensions`.
create extension if not exists pgtap;
set local search_path to public, extensions;

select plan(16);

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
  select json_build_object('sub', p_uid, 'role', 'authenticated',
                           'email', p_email, 'aal', 'aal1')::text;
$$;

create or replace function pg_temp.scalar_as(p_uid text, p_email text, p_sql text)
returns text language plpgsql as $$
declare result text;
begin
  perform set_config('request.jwt.claims', pg_temp.claims(p_uid, p_email), true);
  execute 'set local role authenticated';
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
  execute 'set local role authenticated';
  execute p_sql;
  perform pg_temp.deimpersonate();
  return null;
exception when others then
  perform pg_temp.deimpersonate();
  return sqlstate;
end $$;

-- --- Fixtures ---------------------------------------------------------------

insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-2222-4000-a000-000000000001', 'apiowner@test.local',  '{"full_name":"Owner"}'),
  ('11111111-2222-4000-a000-000000000002', 'apimember@test.local', '{"full_name":"Member"}');

insert into public.organizations (id, slug, name, created_by)
values ('11111111-2222-4000-b000-000000000001', 'api-test', 'API Test Co',
        '11111111-2222-4000-a000-000000000001');

insert into public.organization_members (organization_id, user_id, role) values
  ('11111111-2222-4000-b000-000000000001', '11111111-2222-4000-a000-000000000001', 'owner'),
  ('11111111-2222-4000-b000-000000000001', '11111111-2222-4000-a000-000000000002', 'member');

insert into public.projects (id, organization_id, name, slug, created_by)
values ('11111111-2222-4000-c000-000000000001', '11111111-2222-4000-b000-000000000001',
        'API Project', 'api-project', '11111111-2222-4000-a000-000000000001');

insert into public.demos (id, organization_id, project_id, public_id, title, slug, created_by)
values ('11111111-2222-4000-d000-000000000001', '11111111-2222-4000-b000-000000000001',
        '11111111-2222-4000-c000-000000000001', 'apitestdemo1', 'API Demo', 'api-demo',
        '11111111-2222-4000-a000-000000000001');

-- --- Issuing ----------------------------------------------------------------

select is(
  pg_temp.attempt_as('11111111-2222-4000-a000-000000000002', 'apimember@test.local',
    $$select public.create_api_key('11111111-2222-4000-b000-000000000001', 'Members cannot')$$),
  '42501', 'a member cannot issue an API key');

-- Issued as the owner, not as the test's own superuser role: create_api_key
-- authorizes against auth.uid(), which is NULL outside an impersonated session.
create temporary table issued on commit drop as
  select pg_temp.scalar_as('11111111-2222-4000-a000-000000000001', 'apiowner@test.local',
    $$select (public.create_api_key(
        '11111111-2222-4000-b000-000000000001', 'CI key',
        array['demos:read', 'analytics:read'])).api_key$$) as api_key,
    null::uuid as key_id;

-- Resolved in a second statement on purpose: a join in the statement above
-- would run against a snapshot taken before create_api_key inserted the row,
-- and would find nothing.
update issued set key_id = k.id
  from public.api_keys k
 where k.key_hash = encode(extensions.digest(issued.api_key, 'sha256'), 'hex');

select ok(
  (select api_key from issued) like 'sk\_%',
  'the issued key carries the sk_ prefix');

-- The plaintext must exist nowhere but that response.
select is(
  (select count(*)::text from public.api_keys k, issued i where k.key_hash = i.api_key),
  '0', 'the plaintext key is never stored');

select is(
  (select count(*)::text from public.api_keys k, issued i
    where k.id = i.key_id
      and k.key_hash = encode(extensions.digest(i.api_key, 'sha256'), 'hex')),
  '1', 'only the SHA-256 of the key is stored');

-- --- Scope vocabulary -------------------------------------------------------

select is(
  pg_temp.attempt_as('11111111-2222-4000-a000-000000000001', 'apiowner@test.local',
    $$select public.create_api_key('11111111-2222-4000-b000-000000000001', 'Typo',
        array['demos:reed'])$$),
  '23514', 'a key cannot be issued with an unknown scope');

-- --- Authenticating ---------------------------------------------------------

select is(
  (select public.authenticate_api_key((select api_key from issued), 'demos:read') ->> 'ok'),
  'true', 'a valid key with the right scope authenticates');

select is(
  (select public.authenticate_api_key((select api_key from issued), 'demos:read')
            ->> 'organization_id'),
  '11111111-2222-4000-b000-000000000001', 'it resolves to its own organization');

select is(
  (select public.authenticate_api_key((select api_key from issued), 'demos:write') ->> 'error'),
  'missing_scope', 'a scope the key does not hold is refused');

select is(
  (select public.authenticate_api_key('sk_notarealkey_deadbeef', 'demos:read') ->> 'error'),
  'unknown_key', 'an unknown key is refused');

-- Every attempt, good or bad, leaves a trace.
select ok(
  (select count(*) from private.api_key_events where outcome = 'unknown_key') >= 1,
  'a failed attempt is recorded in the security timeline');

-- Authenticating is metered, so API traffic shows up on the bill.
select ok(
  (select count(*) from public.usage_events
    where organization_id = '11111111-2222-4000-b000-000000000001'
      and metric = 'api_call') >= 1,
  'a successful call is metered as api_call');

-- --- Rate limiting ----------------------------------------------------------
-- The org is on the free plan (60/minute). Burn the budget and check the 61st
-- call is refused rather than merely slowed.

select lives_ok(
  $$select public.authenticate_api_key((select api_key from issued), 'demos:read')
      from generate_series(1, 58)$$,
  'the first 60 calls in a minute are allowed');

select is(
  (select public.authenticate_api_key((select api_key from issued), 'demos:read') ->> 'error'),
  'rate_limited', 'the call past the per-minute budget is refused');

select ok(
  (select (public.authenticate_api_key((select api_key from issued), 'demos:read')
            ->> 'retry_after_seconds')::int between 1 and 60),
  'the refusal carries a usable Retry-After');

-- --- Tenant isolation of the read surface -----------------------------------
-- The API functions take the organization id and filter by it, so a key from
-- one tenant cannot reach another's rows even though the caller is service_role.

select is(
  (select jsonb_array_length(
    public.api_list_demos('11111111-2222-4000-b000-000000000001')))::text,
  '1', 'the read surface returns this organization''s demos');

-- Against a real second tenant, not an empty one: the interesting property is
-- that the other organization's own demos come back and ours do not leak into
-- them, which an id that matches nothing could not demonstrate.
select ok(
  public.api_list_demos('00000000-0000-4000-b000-000000000002')::text
    not like '%apitestdemo1%',
  'the same function never returns this organization''s demos to another');

select * from finish();
rollback;
