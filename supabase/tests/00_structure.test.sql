-- Structural invariants. These are the rules that are easy to break by adding a
-- table and forgetting the boring part.
begin;
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

select has_function('app', 'is_org_member', array['uuid'], 'app.is_org_member exists');
select has_function('app', 'has_org_role', array['uuid', 'org_role'], 'app.has_org_role exists');
select has_function('public', 'create_organization', array['text', 'text'], 'create_organization RPC exists');
select has_function('auth_hooks', 'custom_access_token', array['jsonb'], 'custom access token hook exists');

-- The role hierarchy depends on the enum's declaration order.
select ok(
  'owner'::public.org_role > 'admin'::public.org_role
    and 'admin'::public.org_role > 'member'::public.org_role
    and 'member'::public.org_role > 'viewer'::public.org_role,
  'org_role enum is ordered least- to most-privileged'
);

select * from finish();
rollback;
