-- Tenant isolation: the property that everything else in this schema exists to
-- protect.
--
-- Impersonation is confined to the helpers below. They set the JWT claims, drop
-- into the API role, run one statement, and restore the session before
-- returning — so the assertions themselves always run as the test's own role.
-- Asserting from inside an impersonated session is how RLS test suites end up
-- failing for reasons that have nothing to do with the policy under test.
begin;

-- pgTAP is test-only tooling. Creating it inside the transaction means it is
-- rolled back with everything else, so `supabase test db` needs no setup step
-- and no deployed database ever carries a thousand assertion functions it will
-- never call. `search_path` covers both placements: a fresh install lands in
-- `public`, while a project that enabled pgTAP from the dashboard has it in
-- `extensions`.
create extension if not exists pgtap;
set local search_path to public, extensions;

select plan(14);

-- Restores the session after impersonating. `reset role` alone is not enough:
-- set_config(..., is_local => true) lasts until the transaction ends, so the
-- JWT claims would linger and later assertions would silently run as that user.
create or replace function pg_temp.deimpersonate()
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

create or replace function pg_temp.claims(p_uid text, p_email text, p_aal text default 'aal1')
returns text language sql immutable as $$
  select case
    when p_uid is null then '{"role":"anon"}'
    else json_build_object('sub', p_uid, 'role', 'authenticated',
                           'email', p_email, 'aal', p_aal)::text
  end;
$$;

-- Runs a scalar query as the given user. Returns the result as text.
create or replace function pg_temp.scalar_as(p_uid text, p_email text, p_sql text, p_aal text default 'aal1')
returns text language plpgsql as $$
declare
  result text;
begin
  perform set_config('request.jwt.claims', pg_temp.claims(p_uid, p_email, p_aal), true);
  execute case when p_uid is null then 'set local role anon' else 'set local role authenticated' end;
  execute p_sql into result;
  perform pg_temp.deimpersonate();
  return result;
exception when others then
  perform pg_temp.deimpersonate();
  raise;
end $$;

-- Runs a statement as the given user. Returns NULL when it succeeds, or the
-- SQLSTATE when it raises — which makes "was this refused, and how" a value.
create or replace function pg_temp.attempt_as(p_uid text, p_email text, p_sql text, p_aal text default 'aal1')
returns text language plpgsql as $$
begin
  perform set_config('request.jwt.claims', pg_temp.claims(p_uid, p_email, p_aal), true);
  execute case when p_uid is null then 'set local role anon' else 'set local role authenticated' end;
  execute p_sql;
  perform pg_temp.deimpersonate();
  return null;
exception when others then
  perform pg_temp.deimpersonate();
  return sqlstate;
end $$;

-- --- Fixtures ---------------------------------------------------------------

insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaaaaaa-0000-4000-a000-000000000001', 'owner@test.local',    '{"full_name":"Owner"}'),
  ('aaaaaaaa-0000-4000-a000-000000000002', 'member@test.local',   '{"full_name":"Member"}'),
  ('aaaaaaaa-0000-4000-a000-000000000003', 'outsider@test.local', '{"full_name":"Outsider"}');

insert into public.organizations (id, slug, name, created_by)
values ('bbbbbbbb-0000-4000-b000-000000000001', 'test-tenancy', 'Test Tenancy',
        'aaaaaaaa-0000-4000-a000-000000000001');

insert into public.organization_members (organization_id, user_id, role) values
  ('bbbbbbbb-0000-4000-b000-000000000001', 'aaaaaaaa-0000-4000-a000-000000000001', 'owner'),
  ('bbbbbbbb-0000-4000-b000-000000000001', 'aaaaaaaa-0000-4000-a000-000000000002', 'member');

insert into public.projects (id, organization_id, name, slug, created_by)
values ('cccccccc-0000-4000-c000-000000000001', 'bbbbbbbb-0000-4000-b000-000000000001',
        'Test Project', 'test-project', 'aaaaaaaa-0000-4000-a000-000000000001');

insert into public.demos (id, organization_id, project_id, title, slug, created_by)
values ('dddddddd-0000-4000-d000-000000000001', 'bbbbbbbb-0000-4000-b000-000000000001',
        'cccccccc-0000-4000-c000-000000000001', 'Secret Demo', 'secret-demo',
        'aaaaaaaa-0000-4000-a000-000000000001');

-- --- The owner --------------------------------------------------------------

select is(
  pg_temp.scalar_as('aaaaaaaa-0000-4000-a000-000000000001', 'owner@test.local',
    'select count(*) from public.organizations where id = ''bbbbbbbb-0000-4000-b000-000000000001'''),
  '1', 'owner sees their organization');

select is(
  pg_temp.scalar_as('aaaaaaaa-0000-4000-a000-000000000001', 'owner@test.local',
    'select count(*) from public.demos where organization_id = ''bbbbbbbb-0000-4000-b000-000000000001'''),
  '1', 'owner sees the demo');

select is(
  pg_temp.scalar_as('aaaaaaaa-0000-4000-a000-000000000001', 'owner@test.local',
    $$select app.has_org_role('bbbbbbbb-0000-4000-b000-000000000001', 'admin')$$),
  'true', 'owner satisfies an admin-level check');

select is(
  pg_temp.attempt_as('aaaaaaaa-0000-4000-a000-000000000001', 'owner@test.local',
    $$update public.demos set title = 'Renamed' where slug = 'secret-demo'$$),
  null, 'owner can rename a demo');

-- --- A plain member ---------------------------------------------------------

select is(
  pg_temp.scalar_as('aaaaaaaa-0000-4000-a000-000000000002', 'member@test.local',
    'select count(*) from public.demos where organization_id = ''bbbbbbbb-0000-4000-b000-000000000001'''),
  '1', 'member sees the demo');

select is(
  pg_temp.scalar_as('aaaaaaaa-0000-4000-a000-000000000002', 'member@test.local',
    $$select app.has_org_role('bbbbbbbb-0000-4000-b000-000000000001', 'admin')$$),
  'false', 'member does not satisfy an admin-level check');

-- Deleting is admin-only. RLS filters the row out rather than raising, so the
-- evidence is that the row survived.
select is(
  pg_temp.attempt_as('aaaaaaaa-0000-4000-a000-000000000002', 'member@test.local',
    $$delete from public.demos where slug = 'secret-demo'$$),
  null, 'a member''s delete is accepted but matches nothing');

select is(
  (select count(*)::text from public.demos
    where slug = 'secret-demo' and organization_id = 'bbbbbbbb-0000-4000-b000-000000000001'),
  '1', 'the demo survived the member''s delete');

select is(
  pg_temp.attempt_as('aaaaaaaa-0000-4000-a000-000000000002', 'member@test.local',
    $$select public.create_organization_invite(
        'bbbbbbbb-0000-4000-b000-000000000001', 'x@test.local', 'member')$$),
  '42501', 'member cannot issue invitations');

select is(
  pg_temp.attempt_as('aaaaaaaa-0000-4000-a000-000000000002', 'member@test.local',
    $$update public.organization_members set role = 'owner'
       where user_id = 'aaaaaaaa-0000-4000-a000-000000000002'$$),
  null, 'a member''s self-promotion is accepted but matches nothing');

select is(
  (select role::text from public.organization_members
    where user_id = 'aaaaaaaa-0000-4000-a000-000000000002'),
  'member', 'the member was not promoted');

-- --- An outsider ------------------------------------------------------------

select is(
  pg_temp.scalar_as('aaaaaaaa-0000-4000-a000-000000000003', 'outsider@test.local',
    'select count(*) from public.organizations where id = ''bbbbbbbb-0000-4000-b000-000000000001'''),
  '0', 'outsider sees no organizations');

select is(
  pg_temp.scalar_as('aaaaaaaa-0000-4000-a000-000000000003', 'outsider@test.local',
    'select count(*) from public.demos where organization_id = ''bbbbbbbb-0000-4000-b000-000000000001'''),
  '0', 'outsider sees no demos');

-- --- An anonymous visitor ---------------------------------------------------

select is(
  pg_temp.scalar_as(null, null,
    'select count(*) from public.demos where organization_id = ''bbbbbbbb-0000-4000-b000-000000000001'''),
  '0', 'anonymous visitors see no unpublished demos');

select * from finish();
rollback;
