-- ---------------------------------------------------------------------------
-- 1300 · Auth hooks
--
-- GoTrue calls these as the `supabase_auth_admin` role while it is minting a
-- token or judging a login attempt. They must be fast (they sit in the auth
-- path), total (an exception here breaks sign-in), and invisible to clients.
--
-- Wire-up lives in supabase/config.toml under [auth.hook.*].
-- ---------------------------------------------------------------------------

create table private.auth_events (
  id          bigint generated always as identity primary key,
  user_id     uuid,
  kind        text not null,
  succeeded   boolean not null,
  detail      jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),

  constraint auth_events_kind_valid check (kind in ('password', 'mfa', 'signup'))
);

comment on table private.auth_events is
  'Security timeline for authentication attempts. Written by auth hooks.';

create index auth_events_user_time_idx on private.auth_events (user_id, created_at desc);
create index auth_events_failures_idx on private.auth_events (user_id, created_at desc)
  where not succeeded;

-- --- Custom access token ----------------------------------------------------

-- Puts organization membership and plan into the JWT. Clients then know which
-- workspaces they belong to without a round trip, and Postgres can read the
-- same facts from `request.jwt.claims`.
--
-- Note the claims are a snapshot: they are as old as the access token (one
-- hour, per config.toml). Authorization decisions in RLS therefore read the
-- membership tables through app.* helpers, never these claims. The claims are
-- for the UI's benefit — what to render, and what to render as disabled.
create or replace function auth_hooks.custom_access_token(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  claims jsonb;
  v_user_id uuid;
  memberships jsonb;
  is_staff boolean;
begin
  v_user_id := (event ->> 'user_id')::uuid;
  claims := coalesce(event -> 'claims', '{}'::jsonb);

  -- Capped: a token that grows without bound eventually breaks the header size
  -- limit of whatever proxy sits in front of the API.
  select coalesce(jsonb_agg(entry order by entry ->> 'name'), '[]'::jsonb)
    into memberships
    from (
      select jsonb_build_object(
               'id', m.organization_id,
               'slug', o.slug,
               'name', o.name,
               'role', m.role,
               'plan', s.plan_id
             ) as entry
        from public.organization_members m
        join public.organizations o
          on o.id = m.organization_id and o.deleted_at is null
        left join public.subscriptions s on s.organization_id = m.organization_id
       where m.user_id = v_user_id
       order by o.name
       limit 20
    ) capped;

  select p.is_admin into is_staff from public.profiles p where p.id = v_user_id;

  claims := jsonb_set(
    claims,
    '{app_metadata}',
    coalesce(claims -> 'app_metadata', '{}'::jsonb)
      || jsonb_build_object(
           'organizations', memberships,
           'is_staff', coalesce(is_staff, false)
         )
  );

  return jsonb_build_object('claims', claims);
exception when others then
  -- A broken hook must never lock everyone out; fall back to the original claims.
  raise warning 'custom_access_token hook failed: %', sqlerrm;
  return jsonb_build_object('claims', coalesce(event -> 'claims', '{}'::jsonb));
end;
$$;

-- --- Password verification --------------------------------------------------

-- Records every attempt and throttles an account after repeated failures. This
-- is per-account throttling, complementary to GoTrue's per-IP rate limits.
create or replace function auth_hooks.password_verification_attempt(event jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_succeeded boolean;
  recent_failures integer;
begin
  v_user_id := (event ->> 'user_id')::uuid;
  v_succeeded := coalesce((event ->> 'valid')::boolean, false);

  insert into private.auth_events (user_id, kind, succeeded)
  values (v_user_id, 'password', v_succeeded);

  if v_succeeded then
    return jsonb_build_object('decision', 'continue');
  end if;

  select count(*) into recent_failures
    from private.auth_events e
   where e.user_id = v_user_id
     and e.kind = 'password'
     and not e.succeeded
     and e.created_at > now() - interval '15 minutes';

  if recent_failures >= 10 then
    return jsonb_build_object(
      'decision', 'reject',
      'message', 'Too many failed attempts. Try again in a few minutes.'
    );
  end if;

  return jsonb_build_object('decision', 'continue');
exception when others then
  raise warning 'password_verification_attempt hook failed: %', sqlerrm;
  return jsonb_build_object('decision', 'continue');
end;
$$;

-- --- MFA verification -------------------------------------------------------

create or replace function auth_hooks.mfa_verification_attempt(event jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_succeeded boolean;
  recent_failures integer;
begin
  v_user_id := (event ->> 'user_id')::uuid;
  v_succeeded := coalesce((event ->> 'valid')::boolean, false);

  insert into private.auth_events (user_id, kind, succeeded, detail)
  values (v_user_id, 'mfa', v_succeeded, jsonb_build_object('factor_id', event ->> 'factor_id'));

  if v_succeeded then
    return jsonb_build_object('decision', 'continue');
  end if;

  select count(*) into recent_failures
    from private.auth_events e
   where e.user_id = v_user_id
     and e.kind = 'mfa'
     and not e.succeeded
     and e.created_at > now() - interval '10 minutes';

  if recent_failures >= 5 then
    return jsonb_build_object(
      'decision', 'reject',
      'message', 'Too many incorrect codes. Wait a few minutes before retrying.'
    );
  end if;

  return jsonb_build_object('decision', 'continue');
exception when others then
  raise warning 'mfa_verification_attempt hook failed: %', sqlerrm;
  return jsonb_build_object('decision', 'continue');
end;
$$;

-- --- Grants -----------------------------------------------------------------
-- Only GoTrue may call these, and clients must not be able to probe them.

grant usage on schema auth_hooks to supabase_auth_admin;

grant execute on function
  auth_hooks.custom_access_token(jsonb),
  auth_hooks.password_verification_attempt(jsonb),
  auth_hooks.mfa_verification_attempt(jsonb)
to supabase_auth_admin;

revoke execute on function
  auth_hooks.custom_access_token(jsonb),
  auth_hooks.password_verification_attempt(jsonb),
  auth_hooks.mfa_verification_attempt(jsonb)
from public, anon, authenticated;

-- --- Security timeline read path --------------------------------------------

create or replace function public.my_auth_events(p_limit integer default 50)
returns table (kind text, succeeded boolean, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select e.kind, e.succeeded, e.created_at
    from private.auth_events e
   where e.user_id = (select auth.uid())
   order by e.created_at desc
   limit least(coalesce(p_limit, 50), 200);
$$;

comment on function public.my_auth_events(integer) is
  'RPC: the calling user''s recent sign-in attempts.';

grant execute on function public.my_auth_events(integer) to authenticated;
