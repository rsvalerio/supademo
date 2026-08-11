-- ---------------------------------------------------------------------------
-- 0600 · Viewer analytics and lead capture
--
-- The write path here is anonymous by definition — a demo viewer has no
-- account. Anonymous writes never touch a table directly: they go through
-- SECURITY DEFINER RPCs that re-derive the organization from the share id, so a
-- caller cannot attribute traffic to an organization they do not know.
-- ---------------------------------------------------------------------------

create table public.demo_views (
  id              bigint generated always as identity primary key,
  demo_id         uuid not null references public.demos (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  session_id      uuid not null,
  viewer_id       uuid references public.profiles (id) on delete set null,
  steps_viewed    integer not null default 0,
  completed       boolean not null default false,
  duration_ms     integer not null default 0,
  referrer        text,
  country         text,
  device_type     text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  unique (demo_id, session_id),
  constraint demo_views_country_format check (country is null or country ~ '^[A-Z]{2}$'),
  constraint demo_views_duration_positive check (duration_ms >= 0)
);

comment on table public.demo_views is
  'One row per (demo, viewer session). Upserted by public.track_demo_view().';

create index demo_views_demo_time_idx on public.demo_views (demo_id, created_at desc);
create index demo_views_org_time_idx on public.demo_views (organization_id, created_at desc);
create index demo_views_completed_idx on public.demo_views (demo_id) where completed;

create table public.demo_leads (
  id              uuid primary key default extensions.gen_random_uuid(),
  demo_id         uuid not null,
  organization_id uuid not null,
  email           extensions.citext not null,
  name            text,
  fields          jsonb not null default '{}'::jsonb,
  session_id      uuid,
  created_at      timestamptz not null default now(),

  foreign key (demo_id, organization_id)
    references public.demos (id, organization_id) on delete cascade,
  unique (demo_id, email),
  constraint demo_leads_email_format check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  constraint demo_leads_fields_is_object check (jsonb_typeof(fields) = 'object')
);

comment on table public.demo_leads is 'Email captures from a demo CTA. Written by public.capture_demo_lead().';

create index demo_leads_org_time_idx on public.demo_leads (organization_id, created_at desc);

-- --- Anonymous write path ---------------------------------------------------

create or replace function public.track_demo_view(
  p_public_id text,
  p_session_id uuid,
  p_steps_viewed integer default 0,
  p_completed boolean default false,
  p_duration_ms integer default 0,
  p_referrer text default null,
  p_country text default null,
  p_device_type text default null
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  target public.demos;
  is_new_session boolean;
begin
  select d.* into target
    from public.demos d
   where d.public_id = p_public_id
     and d.status = 'published'
     and d.visibility in ('public', 'link')
     and d.deleted_at is null;

  if target.id is null then
    return;  -- unknown or unshared demo: silently ignore, never confirm existence
  end if;

  insert into public.demo_views as v (
    demo_id, organization_id, session_id, viewer_id,
    steps_viewed, completed, duration_ms, referrer, country, device_type
  )
  values (
    target.id, target.organization_id, p_session_id, (select auth.uid()),
    greatest(p_steps_viewed, 0), p_completed, greatest(p_duration_ms, 0),
    left(p_referrer, 500), upper(nullif(p_country, '')), left(p_device_type, 40)
  )
  on conflict (demo_id, session_id) do update set
    steps_viewed = greatest(v.steps_viewed, excluded.steps_viewed),
    completed    = v.completed or excluded.completed,
    duration_ms  = greatest(v.duration_ms, excluded.duration_ms),
    updated_at   = now()
  -- xmax is zero only on a genuine insert, which is how an upsert reports
  -- whether this session is new.
  returning (v.xmax::text::bigint = 0) into is_new_session;

  -- Meter the session once, not on every heartbeat.
  if is_new_session then
    insert into public.usage_events (organization_id, metric, subject_type, subject_id)
    values (target.organization_id, 'demo_view', 'demo', target.id);
  end if;
end;
$$;

comment on function public.track_demo_view(text, uuid, integer, boolean, integer, text, text, text) is
  'RPC: records or extends an anonymous viewing session. Silent no-op for demos that are not shareable.';

create or replace function public.capture_demo_lead(
  p_public_id text,
  p_email text,
  p_name text default null,
  p_fields jsonb default '{}'::jsonb,
  p_session_id uuid default null
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  target public.demos;
begin
  select d.* into target
    from public.demos d
   where d.public_id = p_public_id
     and d.status = 'published'
     and d.visibility in ('public', 'link')
     and d.deleted_at is null;

  if target.id is null then
    return;
  end if;

  insert into public.demo_leads as l (demo_id, organization_id, email, name, fields, session_id)
  values (
    target.id, target.organization_id, p_email::extensions.citext,
    left(p_name, 120),
    case when jsonb_typeof(p_fields) = 'object' then p_fields else '{}'::jsonb end,
    p_session_id
  )
  on conflict (demo_id, email) do update set
    name = coalesce(excluded.name, l.name),
    fields = l.fields || excluded.fields;
end;
$$;

grant execute on function
  public.track_demo_view(text, uuid, integer, boolean, integer, text, text, text),
  public.capture_demo_lead(text, text, text, jsonb, uuid)
to anon, authenticated;

-- --- Reporting --------------------------------------------------------------

create or replace function public.demo_analytics(
  p_demo_id uuid,
  p_since timestamptz default now() - interval '30 days'
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
           'views', count(*),
           'unique_sessions', count(distinct v.session_id),
           'completions', count(*) filter (where v.completed),
           'completion_rate', round(
             (count(*) filter (where v.completed))::numeric
             / greatest(count(*), 1) * 100, 1),
           'avg_duration_ms', coalesce(round(avg(v.duration_ms)), 0),
           'by_day', coalesce((
             select jsonb_agg(jsonb_build_object('day', day, 'views', views) order by day)
               from (
                 select date_trunc('day', v2.created_at)::date as day, count(*) as views
                   from public.demo_views v2
                  where v2.demo_id = p_demo_id and v2.created_at >= p_since
                  group by 1
               ) daily
           ), '[]'::jsonb)
         )
    from public.demo_views v
   where v.demo_id = p_demo_id
     and v.created_at >= p_since;
$$;

comment on function public.demo_analytics(uuid, timestamptz) is
  'RPC: headline metrics for one demo. SECURITY INVOKER, so RLS enforces access.';

grant execute on function public.demo_analytics(uuid, timestamptz) to authenticated;

-- --- RLS --------------------------------------------------------------------

alter table public.demo_views enable row level security;
alter table public.demo_leads enable row level security;

create policy "demo_views: read as member"
  on public.demo_views for select
  to authenticated
  using (app.is_org_member(organization_id));

-- Leads are commercial data: members and above, not viewers.
create policy "demo_leads: read as member"
  on public.demo_leads for select
  to authenticated
  using (app.has_org_role(organization_id, 'member'));

create policy "demo_leads: delete as admin"
  on public.demo_leads for delete
  to authenticated
  using (app.has_org_role(organization_id, 'admin'));

-- No INSERT policies: both tables are written only through the RPCs above.
