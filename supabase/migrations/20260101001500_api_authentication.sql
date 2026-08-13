-- ---------------------------------------------------------------------------
-- 1500 · Machine authentication (API keys)
--
-- Supabase gives you two authenticated identities out of the box:
--
--   a user JWT      minted by GoTrue after sign-in. Carries `sub`, `role` and
--                   our custom claims. RLS reads it through auth.uid().
--   the service key  bypasses RLS entirely. Server-side only.
--
-- Neither fits a customer's backend calling our API: there is no human to sign
-- in, and handing out a service key would hand out every tenant's data. So this
-- migration adds a third identity — an API key that resolves to exactly one
-- organization and a set of scopes.
--
-- The shape of the trust chain matters:
--
--   caller presents  sk_ab12cd34_<secret>
--     → only its SHA-256 is stored, so a database dump grants nothing
--     → resolves to one organization_id and a scope list
--     → scope is checked against what the endpoint requires
--     → a per-minute quota from the caller's plan is consumed
--     → every read goes through a function that TAKES the organization id
--
-- That last step is the important one. The edge function runs as service_role,
-- which bypasses RLS, so "remember to filter by tenant" would be the only thing
-- standing between one customer and another's data. Instead the read functions
-- below take `p_organization_id` as an argument and filter by it themselves:
-- forgetting is not expressible.
-- ---------------------------------------------------------------------------

-- --- Scope vocabulary -------------------------------------------------------
-- A table rather than an enum: scopes are reference data a dashboard wants to
-- list and describe, and adding one should not be a type migration.

create table public.api_scopes (
  scope       text primary key,
  description text not null,
  is_write    boolean not null default false,
  sort_order  integer not null default 0,

  constraint api_scopes_format check (scope ~ '^[a-z_]+:[a-z_]+$')
);

comment on table public.api_scopes is
  'The complete set of permissions an API key may hold. Reference data.';

insert into public.api_scopes (scope, description, is_write, sort_order) values
  ('demos:read',      'List and read demos, including their steps.',        false, 10),
  ('demos:write',     'Create, update and publish demos.',                  true,  20),
  ('analytics:read',  'Read view counts, completion rates and daily usage.', false, 30),
  ('leads:read',      'Read email captures from demo call-to-actions.',     false, 40),
  ('projects:read',   'List projects.',                                     false, 50),
  ('documents:read',  'Search the knowledge base.',                         false, 60),
  ('documents:write', 'Create and re-index knowledge base documents.',      true,  70)
on conflict (scope) do nothing;

alter table public.api_scopes enable row level security;

create policy "api_scopes: readable by any member"
  on public.api_scopes for select
  to authenticated
  using (true);

-- A key may only carry scopes that exist. Without this, a typo
-- ('demos:reed') silently produces a key that can never do anything, and the
-- failure surfaces later as a confusing 403.
create or replace function private.tg_validate_api_scopes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  unknown_scopes text[];
begin
  select coalesce(array_agg(s), '{}'::text[]) into unknown_scopes
    from unnest(new.scopes) as s
   where s not in (select scope from public.api_scopes);

  if array_length(unknown_scopes, 1) > 0 then
    raise exception 'unknown API scope(s): %', array_to_string(unknown_scopes, ', ')
      using errcode = 'check_violation',
            hint = 'Valid scopes are listed in public.api_scopes.';
  end if;

  return new;
end;
$$;

create trigger validate_api_scopes
  before insert or update of scopes on public.api_keys
  for each row execute function private.tg_validate_api_scopes();

-- --- Per-plan request budget ------------------------------------------------
-- Rate limiting is an entitlement like any other, so it lives with the plan
-- limits rather than as a constant in application code.

update public.plans
   set limits = limits || jsonb_build_object('api_requests_per_minute',
     case id
       when 'free'  then 60
       when 'pro'   then 600
       when 'scale' then 6000
       else 60
     end)
 where not (limits ? 'api_requests_per_minute');

create table private.api_rate_limits (
  key_id        uuid not null references public.api_keys (id) on delete cascade,
  window_start  timestamptz not null,
  request_count integer not null default 0,

  primary key (key_id, window_start)
);

comment on table private.api_rate_limits is
  'Fixed-window request counters, one row per key per minute. Swept by the retention job.';

-- Counts this request and reports whether it is within budget. The upsert is
-- the whole mechanism: it is atomic, so two concurrent requests cannot both
-- read the same count and both decide they are under the limit.
create or replace function private.consume_api_quota(
  p_key_id uuid,
  p_limit integer
)
returns table (allowed boolean, used integer, limit_per_minute integer, resets_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- v_ prefixed: a local named `window_start` would be ambiguous against the
  -- column of that name in the INSERT below.
  v_window_start timestamptz := date_trunc('minute', now());
  v_count integer;
begin
  -- -1 means unlimited, consistent with every other quota in this schema.
  if p_limit = -1 then
    return query select true, 0, -1, v_window_start + interval '1 minute';
    return;
  end if;

  insert into private.api_rate_limits as l (key_id, window_start, request_count)
  values (p_key_id, v_window_start, 1)
  on conflict (key_id, window_start)
  do update set request_count = l.request_count + 1
  returning l.request_count into v_count;

  return query
    select v_count <= p_limit, v_count, p_limit, v_window_start + interval '1 minute';
end;
$$;

-- --- Security timeline ------------------------------------------------------
-- Failed key attempts are the signal that someone is probing. They belong in a
-- log, not in the void.

create table private.api_key_events (
  id              bigint generated always as identity primary key,
  key_id          uuid references public.api_keys (id) on delete set null,
  organization_id uuid references public.organizations (id) on delete cascade,
  prefix          text,
  outcome         text not null,
  scope_required  text,
  created_at      timestamptz not null default now(),

  constraint api_key_events_outcome_valid check (
    outcome in ('ok', 'unknown_key', 'revoked', 'expired', 'missing_scope', 'rate_limited')
  )
);

create index api_key_events_key_time_idx on private.api_key_events (key_id, created_at desc);
create index api_key_events_failures_idx on private.api_key_events (created_at desc)
  where outcome <> 'ok';

-- --- Authentication ---------------------------------------------------------

-- Resolves a presented key, checks the scope, consumes rate budget and meters
-- the call — in one round trip, because an API gateway that needs four is not
-- one anybody wants in front of their requests.
--
-- Returns jsonb rather than a row so the caller gets a discriminated result
-- (`ok` plus an `error` code) instead of an empty set it has to interpret.
create or replace function public.authenticate_api_key(
  p_key text,
  p_required_scope text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  matched public.api_keys;
  quota record;
  budget numeric;
  presented_prefix text := split_part(coalesce(p_key, ''), '_', 1) || '_' ||
                           split_part(coalesce(p_key, ''), '_', 2);
begin
  if not app.is_service_role() then
    raise exception 'service_role required' using errcode = 'insufficient_privilege';
  end if;

  select * into matched
    from public.api_keys k
   where k.key_hash = encode(extensions.digest(coalesce(p_key, ''), 'sha256'), 'hex');

  if matched.id is null then
    insert into private.api_key_events (prefix, outcome, scope_required)
    values (nullif(presented_prefix, '_'), 'unknown_key', p_required_scope);
    return jsonb_build_object('ok', false, 'error', 'unknown_key');
  end if;

  if matched.revoked_at is not null then
    insert into private.api_key_events (key_id, organization_id, prefix, outcome, scope_required)
    values (matched.id, matched.organization_id, matched.prefix, 'revoked', p_required_scope);
    return jsonb_build_object('ok', false, 'error', 'revoked');
  end if;

  if matched.expires_at is not null and matched.expires_at <= now() then
    insert into private.api_key_events (key_id, organization_id, prefix, outcome, scope_required)
    values (matched.id, matched.organization_id, matched.prefix, 'expired', p_required_scope);
    return jsonb_build_object('ok', false, 'error', 'expired');
  end if;

  if p_required_scope is not null and not (matched.scopes @> array[p_required_scope]) then
    insert into private.api_key_events (key_id, organization_id, prefix, outcome, scope_required)
    values (matched.id, matched.organization_id, matched.prefix, 'missing_scope', p_required_scope);
    return jsonb_build_object(
      'ok', false, 'error', 'missing_scope',
      'required_scope', p_required_scope, 'scopes', to_jsonb(matched.scopes)
    );
  end if;

  budget := app.quota_limit(matched.organization_id, 'api_requests_per_minute');
  -- A plan with no budget configured gets a conservative default rather than
  -- either zero (locked out) or unlimited (a free denial-of-wallet).
  if budget is null or budget = 0 then
    budget := 60;
  end if;

  select * into quota from private.consume_api_quota(matched.id, budget::integer);

  if not quota.allowed then
    insert into private.api_key_events (key_id, organization_id, prefix, outcome, scope_required)
    values (matched.id, matched.organization_id, matched.prefix, 'rate_limited', p_required_scope);
    return jsonb_build_object(
      'ok', false, 'error', 'rate_limited',
      'limit', quota.limit_per_minute,
      'resets_at', quota.resets_at,
      'retry_after_seconds', greatest(1, ceil(extract(epoch from quota.resets_at - now()))::integer)
    );
  end if;

  update public.api_keys set last_used_at = now() where id = matched.id;

  insert into private.api_key_events (key_id, organization_id, prefix, outcome, scope_required)
  values (matched.id, matched.organization_id, matched.prefix, 'ok', p_required_scope);

  -- Metered like every other billable action, so `api_call` finally has a writer.
  insert into public.usage_events (organization_id, metric, subject_type, subject_id)
  values (matched.organization_id, 'api_call', 'api_key', matched.id);

  return jsonb_build_object(
    'ok', true,
    'organization_id', matched.organization_id,
    'key_id', matched.id,
    'scopes', to_jsonb(matched.scopes),
    'rate_limit', jsonb_build_object(
      'limit', quota.limit_per_minute,
      'remaining', greatest(0, quota.limit_per_minute - quota.used),
      'resets_at', quota.resets_at
    )
  );
end;
$$;

comment on function public.authenticate_api_key(text, text) is
  'Resolves an API key to an organization, enforcing scope and per-minute budget. service_role only.';

revoke execute on function public.authenticate_api_key(text, text) from public, anon, authenticated;
grant execute on function public.authenticate_api_key(text, text) to service_role;

-- Superseded by authenticate_api_key, which also enforces scope and rate limit.
-- Leaving both would leave a way to authenticate that skips those checks.
drop function if exists public.verify_api_key(text);

-- --- Key lifecycle ----------------------------------------------------------

create or replace function public.revoke_api_key(p_key_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  target public.api_keys;
begin
  select * into target from public.api_keys k where k.id = p_key_id;
  if target.id is null then
    raise exception 'API key not found' using errcode = 'no_data_found';
  end if;
  if not app.has_org_role(target.organization_id, 'admin') then
    raise exception 'only admins and owners can revoke API keys'
      using errcode = 'insufficient_privilege';
  end if;

  update public.api_keys set revoked_at = coalesce(revoked_at, now()) where id = p_key_id;
end;
$$;

-- Issues a replacement and puts the old key on a short fuse, so a deploy has a
-- window to pick up the new value. Revoking outright would take the caller
-- down between the two steps.
create or replace function public.rotate_api_key(
  p_key_id uuid,
  p_grace interval default interval '24 hours'
)
returns table (key_id uuid, key_prefix text, api_key text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  target public.api_keys;
  fresh record;
begin
  select * into target from public.api_keys k where k.id = p_key_id;
  if target.id is null then
    raise exception 'API key not found' using errcode = 'no_data_found';
  end if;
  if not app.has_org_role(target.organization_id, 'admin') then
    raise exception 'only admins and owners can rotate API keys'
      using errcode = 'insufficient_privilege';
  end if;

  select * into fresh
    from public.create_api_key(
      target.organization_id,
      left(target.name || ' (rotated)', 80),
      target.scopes,
      null
    );

  update public.api_keys
     set expires_at = least(coalesce(expires_at, now() + p_grace), now() + p_grace)
   where id = p_key_id;

  key_id := fresh.key_id;
  key_prefix := fresh.key_prefix;
  api_key := fresh.api_key;
  return next;
end;
$$;

grant execute on function
  public.revoke_api_key(uuid),
  public.rotate_api_key(uuid, interval)
to authenticated;

-- Usage history for a key, so a dashboard can show "what has this been doing".
create or replace function public.api_key_activity(
  p_key_id uuid,
  p_limit integer default 100
)
returns table (outcome text, scope_required text, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select e.outcome, e.scope_required, e.created_at
    from private.api_key_events e
    join public.api_keys k on k.id = e.key_id
   where e.key_id = p_key_id
     and app.has_org_role(k.organization_id, 'admin')
   order by e.created_at desc
   limit least(coalesce(p_limit, 100), 500);
$$;

grant execute on function public.api_key_activity(uuid, integer) to authenticated;

-- --- The machine-facing read surface ---------------------------------------
--
-- Each takes the organization id the key resolved to and filters by it. The
-- edge function runs as service_role and therefore bypasses RLS, so this is
-- what keeps one tenant out of another's data: the filter is inside the
-- function, not in code that has to remember it.

create or replace function public.api_list_demos(
  p_organization_id uuid,
  p_limit integer default 25,
  p_before timestamptz default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(demo order by demo ->> 'created_at' desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'public_id', d.public_id,
               'title', d.title,
               'description', d.description,
               'status', d.status,
               'visibility', d.visibility,
               'tags', d.tags,
               'project', p.name,
               'published_at', d.published_at,
               'created_at', d.created_at
             ) as demo
        from public.demos d
        join public.projects p on p.id = d.project_id
       where d.organization_id = p_organization_id
         and d.deleted_at is null
         and (p_before is null or d.created_at < p_before)
       order by d.created_at desc
       limit least(coalesce(p_limit, 25), 100)
    ) page;
$$;

create or replace function public.api_get_demo(
  p_organization_id uuid,
  p_public_id text
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
           'public_id', d.public_id,
           'title', d.title,
           'description', d.description,
           'status', d.status,
           'visibility', d.visibility,
           'tags', d.tags,
           'published_at', d.published_at,
           'steps', coalesce((
             select jsonb_agg(
                      jsonb_build_object(
                        'position', s.position,
                        'title', s.title,
                        'body', s.body,
                        'duration_ms', s.duration_ms
                      ) order by s.position
                    )
               from public.demo_steps s
              where s.demo_id = d.id
           ), '[]'::jsonb)
         )
    from public.demos d
   where d.organization_id = p_organization_id
     and d.public_id = p_public_id
     and d.deleted_at is null;
$$;

create or replace function public.api_demo_analytics(
  p_organization_id uuid,
  p_public_id text,
  p_since timestamptz default now() - interval '30 days'
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
           'public_id', d.public_id,
           'since', p_since,
           'views', count(v.id),
           'unique_sessions', count(distinct v.session_id),
           'completions', count(v.id) filter (where v.completed),
           'avg_duration_ms', coalesce(round(avg(v.duration_ms)), 0)
         )
    from public.demos d
    left join public.demo_views v
      on v.demo_id = d.id and v.created_at >= p_since
   where d.organization_id = p_organization_id
     and d.public_id = p_public_id
     and d.deleted_at is null
   group by d.public_id;
$$;

revoke execute on function
  public.api_list_demos(uuid, integer, timestamptz),
  public.api_get_demo(uuid, text),
  public.api_demo_analytics(uuid, text, timestamptz)
from public, anon, authenticated;

grant execute on function
  public.api_list_demos(uuid, integer, timestamptz),
  public.api_get_demo(uuid, text),
  public.api_demo_analytics(uuid, text, timestamptz)
to service_role;

-- --- Retention --------------------------------------------------------------
-- Rate-limit windows are worthless once past; auth events age out with the
-- rest of the security timeline.

create or replace function private.enforce_api_retention()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  removed integer;
begin
  delete from private.api_rate_limits where window_start < now() - interval '1 hour';
  get diagnostics removed = row_count;

  delete from private.api_key_events where created_at < now() - interval '90 days';

  return removed;
end;
$$;
