-- Structural invariants. These are the rules that are easy to break by adding a
-- table and forgetting the boring part.
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

-- 1. Every table in `public` has RLS enabled. This is the single check most
--    likely to catch a real leak in a future migration.
select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and not c.relrowsecurity),
  0,
  'every table in public has row level security enabled'
);

-- 2. ...and every one of them has at least one policy, since RLS with no policy
--    denies everything, which is usually an accident rather than a decision.
select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and not exists (select 1 from pg_policy p where p.polrelid = c.oid)),
  0,
  'every table in public has at least one policy'
);

-- 3. Nothing in `private` is reachable by the API roles.
select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where table_schema = 'private'
      and grantee in ('anon', 'authenticated')),
  0,
  'anon and authenticated hold no grants in the private schema'
);

-- 4. SECURITY DEFINER functions must pin search_path, or they are exploitable
--    by anyone who can create objects in a schema that precedes theirs.
select is(
  (select count(*)::int
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'app', 'private', 'auth_hooks')
      and p.prosecdef
      and not exists (
        select 1 from unnest(coalesce(p.proconfig, '{}')) cfg
         where cfg like 'search_path=%'
      )),
  0,
  'every SECURITY DEFINER function pins its search_path'
);

-- 5. Views in the API surface must not silently bypass RLS.
select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'api'
      and c.relkind = 'v'
      and not coalesce(
        (select option_value = 'true'
           from pg_options_to_table(c.reloptions)
          where option_name = 'security_invoker'),
        false
      )),
  0,
  'every view in the api schema is security_invoker'
);

select has_table('public', 'organizations', 'organizations exists');
select has_table('public', 'organization_members', 'organization_members exists');
select has_table('public', 'demos', 'demos exists');
select has_table('public', 'subscriptions', 'subscriptions exists');

-- Checked against the catalog rather than pgTAP's has_function(), whose
-- argument matching depends on how a custom enum's type name renders under the
-- current search_path. A structural test must not have a failure mode of its own.
select ok(
  to_regprocedure('app.is_org_member(uuid)') is not null,
  'app.is_org_member(uuid) exists'
);
select ok(
  to_regprocedure('app.has_org_role(uuid, public.org_role)') is not null,
  'app.has_org_role(uuid, org_role) exists'
);
select ok(
  to_regprocedure('public.create_organization(text, text)') is not null,
  'create_organization RPC exists'
);
select ok(
  to_regprocedure('auth_hooks.custom_access_token(jsonb)') is not null,
  'custom access token hook exists'
);

-- The role hierarchy depends on the enum's declaration order.
select ok(
  'owner'::public.org_role > 'admin'::public.org_role
    and 'admin'::public.org_role > 'member'::public.org_role
    and 'member'::public.org_role > 'viewer'::public.org_role,
  'org_role enum is ordered least- to most-privileged'
);

select * from finish();
rollback;
