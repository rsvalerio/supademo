-- Plan enforcement, the invitation lifecycle, and what the outside world sees.
-- Impersonation helpers follow the same pattern as 01_tenancy.
begin;
select plan(13);

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
  reset role;
  return result;
exception when others then
  reset role;
  raise;
end $$;

create or replace function pg_temp.attempt_as(p_uid text, p_email text, p_sql text)
returns text language plpgsql as $$
begin
  perform set_config('request.jwt.claims', pg_temp.claims(p_uid, p_email), true);
  execute case when p_uid is null then 'set local role anon' else 'set local role authenticated' end;
  execute p_sql;
  reset role;
  return null;
exception when others then
  reset role;
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

select is(
  pg_temp.attempt_as('eeeeeeee-0000-4000-a000-000000000001', 'founder@test.local',
    format($$insert into public.projects (organization_id, name)
             values (%L, 'First')$$, (select org_id from fixture))),
  null, 'the first project is allowed');

select is(
  pg_temp.attempt_as('eeeeeeee-0000-4000-a000-000000000001', 'founder@test.local',
    format($$insert into public.projects (organization_id, name)
             values (%L, 'Second')$$, (select org_id from fixture))),
  '23514', 'the free plan allows only one project');

select is(
  pg_temp.attempt_as('eeeeeeee-0000-4000-a000-000000000001', 'founder@test.local',
    format($$insert into public.demos (organization_id, project_id, title)
             select %L, p.id, 'Demo ' || n
               from public.projects p, generate_series(1, 3) n
              where p.organization_id = %L$$,
           (select org_id from fixture), (select org_id from fixture))),
  null, 'three demos fit on the free plan');

select is(
  pg_temp.attempt_as('eeeeeeee-0000-4000-a000-000000000001', 'founder@test.local',
    format($$insert into public.demos (organization_id, project_id, title)
             select %L, p.id, 'One too many' from public.projects p
              where p.organization_id = %L$$,
           (select org_id from fixture), (select org_id from fixture))),
  '23514', 'the fourth demo is refused');

-- Slugs are derived from titles and de-duplicated automatically.
select is(
  (select count(distinct slug)::text from public.demos d, fixture f
    where d.organization_id = f.org_id),
  '3', 'derived slugs are unique within an organization');

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

-- --- Sharing ----------------------------------------------------------------

update public.demos set status = 'published', visibility = 'link'
 where title = 'Demo 1' and organization_id = (select org_id from fixture);

select is(
  pg_temp.scalar_as(null, null,
    format('select count(*) from public.demos where organization_id = %L',
           (select org_id from fixture))),
  '0', 'a link-shared demo is not listable by anonymous callers');

select is(
  pg_temp.scalar_as(null, null,
    format($$select public.get_public_demo(%L) ->> 'title'$$,
           (select public_id from public.demos d, fixture f
             where d.organization_id = f.org_id and d.title = 'Demo 1'))),
  'Demo 1', 'a link-shared demo is readable through the share RPC');

-- An unknown share id must not distinguish "does not exist" from "not shared".
select is(
  pg_temp.scalar_as(null, null, $$select public.get_public_demo('nosuchshareid')$$),
  null, 'an unknown share id yields nothing');

select * from finish();
rollback;
