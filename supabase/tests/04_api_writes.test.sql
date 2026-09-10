-- The machine API's write surface: tenant scoping, the checks RLS would have
-- made, quota, and idempotent replay.
begin;

-- pgTAP is test-only tooling. Creating it inside the transaction means it is
-- rolled back with everything else, so `supabase test db` needs no setup step
-- and no deployed database ever carries a thousand assertion functions it will
-- never call. `search_path` covers both placements: a fresh install lands in
-- `public`, while a project that enabled pgTAP from the dashboard has it in
-- `extensions`.
create extension if not exists pgtap;
set local search_path to public, extensions;

select plan(13);

-- --- Fixtures ---------------------------------------------------------------
-- Written directly rather than through an impersonated session: these tests are
-- about the service_role path, which is what the edge function uses.

insert into auth.users (id, email) values
  ('33333333-4444-4000-a000-000000000001', 'writer@test.local');

insert into public.organizations (id, slug, name, created_by)
values ('33333333-4444-4000-b000-000000000001', 'write-test', 'Write Test Co',
        '33333333-4444-4000-a000-000000000001');

insert into public.organization_members values
  ('33333333-4444-4000-b000-000000000001', '33333333-4444-4000-a000-000000000001', 'owner');

insert into public.projects (id, organization_id, name, slug, created_by)
values ('33333333-4444-4000-c000-000000000001', '33333333-4444-4000-b000-000000000001',
        'Tours', 'tours', '33333333-4444-4000-a000-000000000001');

-- --- Creating ---------------------------------------------------------------

select is(
  public.api_create_demo('33333333-4444-4000-b000-000000000001', 'tours', 'From the API')
    ->> 'title',
  'From the API', 'a demo can be created through the API surface');

select is(
  (select count(*)::text from public.demos
    where organization_id = '33333333-4444-4000-b000-000000000001'),
  '1', 'and it lands in the calling organization');

select throws_ok(
  $$select public.api_create_demo('33333333-4444-4000-b000-000000000001', 'no-such-project', 'x')$$,
  'P0002', null, 'an unknown project slug is refused');

-- The project must belong to the caller: naming another tenant's project by
-- slug must not reach across.
select throws_ok(
  $$select public.api_create_demo('33333333-4444-4000-b000-000000000001', 'product-tours', 'x')$$,
  'P0002', null, 'a project slug from another organization is not visible');

select throws_ok(
  $$select public.api_create_demo('33333333-4444-4000-b000-000000000001', 'tours', '   ')$$,
  '23514', null, 'a blank title is refused');

-- --- The checks RLS would have made -----------------------------------------
-- service_role bypasses RLS, so app.assert_org_writable has to make them.

update public.subscriptions set status = 'canceled'
 where organization_id = '33333333-4444-4000-b000-000000000001';

select throws_ok(
  $$select public.api_create_demo('33333333-4444-4000-b000-000000000001', 'tours', 'Nope')$$,
  '23514', null, 'a lapsed subscription blocks writes even for service_role');

select lives_ok(
  $$select public.api_list_demos('33333333-4444-4000-b000-000000000001')$$,
  'but reads keep working, so nobody is locked out of their own data');

update public.subscriptions set status = 'active'
 where organization_id = '33333333-4444-4000-b000-000000000001';

-- --- Quota ------------------------------------------------------------------
-- Free plan allows 3 demos; one exists.

select lives_ok(
  $$select public.api_create_demo('33333333-4444-4000-b000-000000000001', 'tours', 'Second'),
           public.api_create_demo('33333333-4444-4000-b000-000000000001', 'tours', 'Third')$$,
  'the plan''s demo allowance can be filled');

select throws_ok(
  $$select public.api_create_demo('33333333-4444-4000-b000-000000000001', 'tours', 'Fourth')$$,
  '23514', null, 'the demo past the plan limit is refused');

-- --- Publishing -------------------------------------------------------------

select throws_ok(
  $$select public.api_publish_demo('33333333-4444-4000-b000-000000000001',
      (select public_id from public.demos
        where organization_id = '33333333-4444-4000-b000-000000000001'
        order by created_at limit 1))$$,
  '23514', null, 'a demo with no steps cannot be published');

insert into public.demo_steps (demo_id, organization_id, position, title)
select id, organization_id, 0, 'Step one'
  from public.demos
 where organization_id = '33333333-4444-4000-b000-000000000001'
 order by created_at limit 1;

select is(
  (public.api_publish_demo('33333333-4444-4000-b000-000000000001',
    (select public_id from public.demos
      where organization_id = '33333333-4444-4000-b000-000000000001'
      order by created_at limit 1)) -> 'steps' -> 0 ->> 'title'),
  'Step one', 'a demo with a step publishes and returns its steps');

-- --- Idempotent replay ------------------------------------------------------

-- Inserted directly rather than via create_api_key, which needs an admin
-- session; the plaintext is irrelevant here since idempotency keys off key_id.
insert into public.api_keys (organization_id, name, prefix, key_hash, scopes)
values ('33333333-4444-4000-b000-000000000001', 'writer', 'sk_writertest',
        encode(extensions.digest('sk_writertest_secret', 'sha256'), 'hex'),
        array['demos:write']);

create temporary table apikey on commit drop as
  select id as key_id
    from public.api_keys
   where organization_id = '33333333-4444-4000-b000-000000000001';

select public.api_remember_idempotent(
  (select key_id from apikey), 'retry-key-0001', 'fingerprint-a',
  '{"title":"stored"}'::jsonb, 201);

select is(
  public.api_replay_idempotent((select key_id from apikey), 'retry-key-0001', 'fingerprint-a')
    -> 'response' ->> 'title',
  'stored', 'the same request replays the stored response');

select throws_ok(
  format($$select public.api_replay_idempotent(%L, 'retry-key-0001', 'fingerprint-b')$$,
         (select key_id from apikey)),
  '23505', null, 'the same key with a different body is a conflict, not a replay');

select * from finish();
rollback;
