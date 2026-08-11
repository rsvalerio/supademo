-- ---------------------------------------------------------------------------
-- 0400 · Plans, subscriptions, entitlements and metering
--
-- Plans are reference data (readable by everyone, including the marketing site).
-- Subscriptions are written only by the billing webhook running as service_role;
-- clients read them. Limits live on the plan as jsonb so a new limit is a data
-- change, not a migration, and per-organization overrides sit on the
-- subscription for one-off deals.
-- ---------------------------------------------------------------------------

create type public.subscription_status as enum (
  'trialing', 'active', 'past_due', 'canceled', 'incomplete', 'paused'
);

create type public.usage_metric as enum (
  'demo_view', 'demo_created', 'ai_embedding', 'storage_bytes', 'api_call', 'email_sent'
);

create table public.plans (
  id            text primary key,
  name          text not null,
  description   text,
  price_cents   integer not null default 0,
  currency      text not null default 'usd',
  billing_interval text not null default 'month',
  stripe_price_id text,
  features      jsonb not null default '[]'::jsonb,
  limits        jsonb not null default '{}'::jsonb,
  is_public     boolean not null default true,
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint plans_interval_valid check (billing_interval in ('month', 'year')),
  constraint plans_limits_is_object check (jsonb_typeof(limits) = 'object'),
  constraint plans_features_is_array check (jsonb_typeof(features) = 'array')
);

comment on column public.plans.limits is
  'Quota map, e.g. {"demos": 25, "members": 10}. -1 means unlimited.';

select private.attach_updated_at('public.plans');

insert into public.plans (id, name, description, price_cents, sort_order, features, limits) values
  ('free',  'Free',  'Kick the tyres.',            0,    10,
   '["3 demos", "1 project", "Community support"]'::jsonb,
   '{"demos": 3, "projects": 1, "members": 2, "storage_mb": 100, "monthly_views": 1000, "ai_embeddings": 100}'::jsonb),
  ('pro',   'Pro',   'For small teams shipping.',  2900, 20,
   '["Unlimited demos", "Custom branding", "Analytics", "Email support"]'::jsonb,
   '{"demos": -1, "projects": 25, "members": 10, "storage_mb": 10240, "monthly_views": 100000, "ai_embeddings": 10000}'::jsonb),
  ('scale', 'Scale', 'Usage-based, with SSO.',     9900, 30,
   '["Everything in Pro", "SSO", "Audit log export", "Priority support"]'::jsonb,
   '{"demos": -1, "projects": -1, "members": -1, "storage_mb": 102400, "monthly_views": -1, "ai_embeddings": 100000}'::jsonb)
on conflict (id) do nothing;

create table public.subscriptions (
  organization_id        uuid primary key references public.organizations (id) on delete cascade,
  plan_id                text not null references public.plans (id),
  status                 public.subscription_status not null default 'trialing',
  seats                  integer not null default 1,
  limit_overrides        jsonb not null default '{}'::jsonb,
  trial_ends_at          timestamptz,
  current_period_start   timestamptz,
  current_period_end     timestamptz,
  cancel_at_period_end   boolean not null default false,
  canceled_at            timestamptz,
  stripe_customer_id     text unique,
  stripe_subscription_id text unique,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),

  constraint subscriptions_seats_positive check (seats > 0),
  constraint subscriptions_overrides_is_object check (jsonb_typeof(limit_overrides) = 'object')
);

comment on table public.subscriptions is
  'One row per organization. Written only by the billing webhook (service_role).';

create index subscriptions_status_idx on public.subscriptions (status);
create index subscriptions_renewal_idx on public.subscriptions (current_period_end)
  where status in ('active', 'trialing');

select private.attach_updated_at('public.subscriptions');

-- Every organization starts on Free with a 14-day trial of Pro-style limits.
create or replace function private.tg_start_subscription()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.subscriptions (organization_id, plan_id, status, trial_ends_at)
  values (new.id, 'free', 'trialing', now() + interval '14 days')
  on conflict (organization_id) do nothing;

  return new;
end;
$$;

create trigger start_subscription
  after insert on public.organizations
  for each row execute function private.tg_start_subscription();

-- --- Metering ---------------------------------------------------------------

create table public.usage_events (
  id              bigint generated always as identity primary key,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  metric          public.usage_metric not null,
  quantity        numeric not null default 1,
  subject_type    text,
  subject_id      uuid,
  metadata        jsonb not null default '{}'::jsonb,
  occurred_at     timestamptz not null default now(),

  constraint usage_events_quantity_positive check (quantity >= 0)
);

comment on table public.usage_events is
  'Append-only meter. Read by rollups; never updated. Retention is enforced by the nightly cron job.';

create index usage_events_org_metric_time_idx
  on public.usage_events (organization_id, metric, occurred_at desc);
create index usage_events_occurred_at_idx on public.usage_events (occurred_at);

-- Daily rollup. Populated by public.rollup_usage(), which pg_cron runs nightly.
create table public.usage_daily (
  organization_id uuid not null references public.organizations (id) on delete cascade,
  metric          public.usage_metric not null,
  day             date not null,
  quantity        numeric not null default 0,
  updated_at      timestamptz not null default now(),

  primary key (organization_id, metric, day)
);

create index usage_daily_day_idx on public.usage_daily (day desc);

-- --- Entitlements -----------------------------------------------------------

-- Resolution order: subscription override → plan limit → 0 (deny by default).
create or replace function app.quota_limit(p_organization_id uuid, p_key text)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (s.limit_overrides ->> p_key)::numeric,
    (p.limits ->> p_key)::numeric,
    0
  )
    from public.subscriptions s
    join public.plans p on p.id = s.plan_id
   where s.organization_id = p_organization_id;
$$;

comment on function app.quota_limit(uuid, text) is
  'Effective limit for a quota key. -1 means unlimited.';

create or replace function app.entitlements(p_organization_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
           'plan_id', s.plan_id,
           'status', s.status,
           'seats', s.seats,
           'trial_ends_at', s.trial_ends_at,
           'current_period_end', s.current_period_end,
           'limits', p.limits || s.limit_overrides,
           'features', p.features
         )
    from public.subscriptions s
    join public.plans p on p.id = s.plan_id
   where s.organization_id = p_organization_id;
$$;

-- A subscription is "delinquent" once past due or canceled; write paths block,
-- read paths keep working so nobody is locked out of their own data.
create or replace function app.is_org_active(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.subscriptions s
     where s.organization_id = p_organization_id
       and s.status in ('trialing', 'active', 'past_due')
  );
$$;

-- Raises when adding `p_increment` more of `p_key` would exceed the plan.
create or replace function app.assert_quota(
  p_organization_id uuid,
  p_key text,
  p_current numeric,
  p_increment numeric default 1
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  allowed numeric := app.quota_limit(p_organization_id, p_key);
begin
  if allowed = -1 then
    return;
  end if;

  if p_current + p_increment > allowed then
    raise exception 'plan limit reached for "%": % of % used', p_key, p_current, allowed
      using errcode = 'check_violation',
            hint = 'Upgrade the plan or remove existing items.';
  end if;
end;
$$;

grant execute on function
  app.quota_limit(uuid, text),
  app.entitlements(uuid),
  app.is_org_active(uuid),
  app.assert_quota(uuid, text, numeric, numeric)
to authenticated, service_role;

-- Seat limit is enforced where members are added.
create or replace function private.tg_enforce_seat_quota()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  used integer;
begin
  select count(*) into used
    from public.organization_members m
   where m.organization_id = new.organization_id;

  perform app.assert_quota(new.organization_id, 'members', used, 1);
  return new;
end;
$$;

create trigger enforce_seat_quota
  before insert on public.organization_members
  for each row execute function private.tg_enforce_seat_quota();

-- --- Rollups ----------------------------------------------------------------

create or replace function public.rollup_usage(p_day date default (now() - interval '1 day')::date)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  affected integer;
begin
  insert into public.usage_daily (organization_id, metric, day, quantity, updated_at)
  select e.organization_id,
         e.metric,
         p_day,
         sum(e.quantity),
         now()
    from public.usage_events e
   where e.occurred_at >= p_day::timestamptz
     and e.occurred_at < (p_day + 1)::timestamptz
   group by e.organization_id, e.metric
  on conflict (organization_id, metric, day)
  do update set quantity = excluded.quantity, updated_at = now();

  get diagnostics affected = row_count;
  return affected;
end;
$$;

comment on function public.rollup_usage(date) is
  'Aggregates usage_events into usage_daily for one day. Idempotent; scheduled by pg_cron.';

revoke execute on function public.rollup_usage(date) from public, anon, authenticated;
grant execute on function public.rollup_usage(date) to service_role;

-- --- RLS --------------------------------------------------------------------

alter table public.plans enable row level security;
alter table public.subscriptions enable row level security;
alter table public.usage_events enable row level security;
alter table public.usage_daily enable row level security;

-- Pricing is public on purpose: the marketing site reads it anonymously.
create policy "plans: read public plans"
  on public.plans for select
  to anon, authenticated
  using (is_public);

create policy "subscriptions: read as member"
  on public.subscriptions for select
  to authenticated
  using (app.is_org_member(organization_id));

-- No write policies for subscriptions or usage: the billing webhook and the
-- metering path run as service_role, which bypasses RLS.

create policy "usage_events: read as admin"
  on public.usage_events for select
  to authenticated
  using (app.has_org_role(organization_id, 'admin'));

create policy "usage_daily: read as member"
  on public.usage_daily for select
  to authenticated
  using (app.is_org_member(organization_id));
