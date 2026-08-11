-- ---------------------------------------------------------------------------
-- 1400 · The `api` schema and machine credentials
--
-- `public` holds the tables; `api` holds the shapes clients actually want. All
-- views are `security_invoker = true`, so they inherit the RLS of the tables
-- underneath instead of quietly becoming a bypass (a view is otherwise checked
-- with its owner's permissions — the single most common way an RLS setup
-- springs a leak).
-- ---------------------------------------------------------------------------

create view api.plans
  with (security_invoker = true)
as
  select p.id,
         p.name,
         p.description,
         p.price_cents,
         p.currency,
         p.billing_interval,
         p.features,
         p.limits,
         p.sort_order
    from public.plans p
   where p.is_public
   order by p.sort_order;

comment on view api.plans is 'Public pricing table.';

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
         (select count(*) from public.demos d where d.organization_id = o.id and d.deleted_at is null) as demo_count,
         o.created_at
    from public.organizations o
    join public.organization_members m
      on m.organization_id = o.id and m.user_id = (select auth.uid())
    left join public.subscriptions s on s.organization_id = o.id
   where o.deleted_at is null;

comment on view api.my_organizations is 'Workspace switcher payload for the signed-in user.';

create view api.demo_directory
  with (security_invoker = true)
as
  select d.public_id,
         d.title,
         d.description,
         d.cover_path,
         d.tags,
         d.published_at,
         o.name as organization_name,
         o.logo_path as organization_logo_path
    from public.demos d
    join public.organizations o on o.id = d.organization_id
   where d.visibility = 'public'
     and d.status = 'published'
     and d.deleted_at is null
     and o.deleted_at is null;

comment on view api.demo_directory is
  'Anonymous, crawlable listing of demos published to the world.';

create view api.demo_stats
  with (security_invoker = true)
as
  select d.id as demo_id,
         d.organization_id,
         d.title,
         count(v.id) as views,
         count(distinct v.session_id) as unique_sessions,
         count(v.id) filter (where v.completed) as completions,
         max(v.created_at) as last_viewed_at
    from public.demos d
    left join public.demo_views v on v.demo_id = d.id
   where d.deleted_at is null
   group by d.id, d.organization_id, d.title;

grant select on api.plans, api.demo_directory to anon, authenticated;
grant select on api.my_organizations, api.demo_stats to authenticated;

-- --- What anonymous visitors may reach --------------------------------------
-- `api.demo_directory` is security_invoker, so anon needs genuine access to the
-- rows underneath. Rather than widen RLS and hope the view never leaks a column,
-- the row policy is narrow AND the column grants are explicit: two independent
-- limits, either of which alone would be enough.

create policy "organizations: read when publicly listed"
  on public.organizations for select
  to anon
  using (
    deleted_at is null
    and exists (
      select 1
        from public.demos d
       where d.organization_id = organizations.id
         and d.visibility = 'public'
         and d.status = 'published'
         and d.deleted_at is null
    )
  );

revoke select on public.organizations from anon;
grant select (id, slug, name, logo_path, deleted_at) on public.organizations to anon;

revoke select on public.demos from anon;
grant select (
  id, organization_id, project_id, public_id, title, slug, description,
  status, visibility, cover_path, theme, tags, published_at, deleted_at, created_at
) on public.demos to anon;

-- ---------------------------------------------------------------------------
-- Machine credentials
--
-- API keys let a CI job or a customer's backend call the API without a user
-- session. Only a hash is stored, and the prefix is kept in the clear so the
-- UI can show `sk_live_a1b2…` next to "last used 3 hours ago".
-- ---------------------------------------------------------------------------

create table public.api_keys (
  id              uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  name            text not null,
  prefix          text not null unique,
  key_hash        text not null unique,
  scopes          text[] not null default array['demos:read'],
  created_by      uuid references public.profiles (id) on delete set null,
  last_used_at    timestamptz,
  expires_at      timestamptz,
  revoked_at      timestamptz,
  created_at      timestamptz not null default now(),

  constraint api_keys_name_length check (char_length(name) between 1 and 80),
  constraint api_keys_scopes_not_empty check (array_length(scopes, 1) > 0)
);

comment on table public.api_keys is
  'Hashed machine credentials. The plaintext key exists only in the response of public.create_api_key().';

create index api_keys_org_idx on public.api_keys (organization_id) where revoked_at is null;

alter table public.api_keys enable row level security;

-- The hash column is readable by admins, which is fine — it is a hash — but the
-- key itself is never recoverable.
create policy "api_keys: read as admin"
  on public.api_keys for select
  to authenticated
  using (app.has_org_role(organization_id, 'admin'));

create policy "api_keys: revoke as admin"
  on public.api_keys for update
  to authenticated
  using (app.has_org_role(organization_id, 'admin'))
  with check (app.has_org_role(organization_id, 'admin'));

create policy "api_keys: delete as admin"
  on public.api_keys for delete
  to authenticated
  using (app.has_org_role(organization_id, 'admin'));

create trigger guard_server_columns
  before update on public.api_keys
  for each row execute function private.tg_guard_columns(
    'id', 'organization_id', 'prefix', 'key_hash', 'created_by', 'created_at'
  );

create or replace function public.create_api_key(
  p_organization_id uuid,
  p_name text,
  p_scopes text[] default array['demos:read'],
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

grant execute on function public.create_api_key(uuid, text, text[], interval) to authenticated;

-- Resolves a presented key to an organization. Called by edge functions running
-- as service_role — never by a client, which is why the guard is explicit.
create or replace function public.verify_api_key(p_key text)
returns table (organization_id uuid, key_id uuid, scopes text[])
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not app.is_service_role() then
    raise exception 'service_role required' using errcode = 'insufficient_privilege';
  end if;

  return query
    with touched as (
      update public.api_keys k
         set last_used_at = now()
       where k.key_hash = encode(extensions.digest(p_key, 'sha256'), 'hex')
         and k.revoked_at is null
         and (k.expires_at is null or k.expires_at > now())
      returning k.organization_id, k.id as key_id, k.scopes
    )
    select t.organization_id, t.key_id, t.scopes from touched t;
end;
$$;

revoke execute on function public.verify_api_key(text) from public, anon, authenticated;
grant execute on function public.verify_api_key(text) to service_role;

-- ---------------------------------------------------------------------------
-- Dashboard summary — one call instead of six.
-- ---------------------------------------------------------------------------

create or replace function public.organization_overview(p_organization_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
           'organization', to_jsonb(o) - 'settings',
           'role', app.org_role(o.id),
           'entitlements', app.entitlements(o.id),
           'counts', jsonb_build_object(
             'projects', (select count(*) from public.projects p
                           where p.organization_id = o.id and p.archived_at is null),
             'demos', (select count(*) from public.demos d
                        where d.organization_id = o.id and d.deleted_at is null),
             'members', (select count(*) from public.organization_members m
                          where m.organization_id = o.id),
             'pending_invites', (select count(*) from public.organization_invites i
                                  where i.organization_id = o.id
                                    and i.accepted_at is null and i.revoked_at is null)
           ),
           'usage_this_month', coalesce((
             select jsonb_object_agg(u.metric, u.total)
               from (
                 select ud.metric, sum(ud.quantity) as total
                   from public.usage_daily ud
                  where ud.organization_id = o.id
                    and ud.day >= date_trunc('month', now())::date
                  group by ud.metric
               ) u
           ), '{}'::jsonb)
         )
    from public.organizations o
   where o.id = p_organization_id
     and o.deleted_at is null;
$$;

comment on function public.organization_overview(uuid) is
  'RPC: everything a dashboard needs for one workspace, in a single round trip.';

grant execute on function public.organization_overview(uuid) to authenticated;
