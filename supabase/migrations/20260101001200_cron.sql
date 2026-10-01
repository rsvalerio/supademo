-- ---------------------------------------------------------------------------
-- 1200 · Scheduled work (pg_cron)
--
-- Schedules are idempotent: re-running the migration (or `db reset`) replaces
-- a job instead of creating a duplicate. Nothing here is required for the app
-- to function — if pg_cron is missing, the jobs simply do not exist and the
-- same functions can be driven externally.
-- ---------------------------------------------------------------------------

-- Replaces a job by name. pg_cron's own `cron.schedule` upserts by name on
-- recent versions, but not on all of them.
create or replace function private.schedule_job(
  p_name text,
  p_schedule text,
  p_command text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app.extension_enabled('pg_cron') then
    raise notice 'pg_cron unavailable; skipping job %', p_name;
    return;
  end if;

  begin
    execute format('select cron.unschedule(%L)', p_name);
  exception when others then
    null;  -- not scheduled yet
  end;

  execute format('select cron.schedule(%L, %L, %L)', p_name, p_schedule, p_command);
end;
$$;

-- --- Retention --------------------------------------------------------------

-- Raw meter events are only needed until they have been rolled up; the daily
-- aggregate is what reporting reads.
create or replace function private.enforce_retention()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  usage_deleted integer;
  audit_deleted integer;
  views_deleted integer;
  invites_expired integer;
  demos_purged integer;
begin
  delete from public.usage_events where occurred_at < now() - interval '90 days';
  get diagnostics usage_deleted = row_count;

  delete from private.audit_log where created_at < now() - interval '365 days';
  get diagnostics audit_deleted = row_count;

  delete from public.demo_views where created_at < now() - interval '400 days';
  get diagnostics views_deleted = row_count;

  update public.organization_invites
     set revoked_at = now()
   where accepted_at is null
     and revoked_at is null
     and expires_at < now();
  get diagnostics invites_expired = row_count;

  -- Soft-deleted demos become unrecoverable after 30 days.
  delete from public.demos where deleted_at is not null and deleted_at < now() - interval '30 days';
  get diagnostics demos_purged = row_count;

  delete from private.webhook_deliveries
   where created_at < now() - interval '30 days'
     and status in ('delivered', 'abandoned');

  return jsonb_build_object(
    'usage_events_deleted', usage_deleted,
    'audit_rows_deleted', audit_deleted,
    'demo_views_deleted', views_deleted,
    'invites_expired', invites_expired,
    'demos_purged', demos_purged
  );
end;
$$;

-- --- Quota warnings ---------------------------------------------------------

-- Notifies admins once an organization crosses 80% of a metered limit.
create or replace function private.check_quota_warnings()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  row_org record;
  limit_views numeric;
  used_views numeric;
  warned integer := 0;
begin
  for row_org in
    select s.organization_id
      from public.subscriptions s
     where s.status in ('active', 'trialing')
  loop
    limit_views := app.quota_limit(row_org.organization_id, 'monthly_views');
    continue when limit_views is null or limit_views <= 0;  -- unlimited or unset

    select coalesce(sum(u.quantity), 0) into used_views
      from public.usage_daily u
     where u.organization_id = row_org.organization_id
       and u.metric = 'demo_view'
       and u.day >= date_trunc('month', now())::date;

    if used_views >= limit_views * 0.8 then
      perform private.notify_users(
        (select coalesce(array_agg(m.user_id), '{}'::uuid[])
           from public.organization_members m
          where m.organization_id = row_org.organization_id
            and m.role >= 'admin'),
        row_org.organization_id,
        'quota_warning',
        'You have used ' || round(used_views / limit_views * 100) || '% of this month''s views',
        'Views reset at the start of the next billing period.',
        '/settings/billing',
        jsonb_build_object('metric', 'monthly_views', 'used', used_views, 'limit', limit_views)
      );
      warned := warned + 1;
    end if;
  end loop;

  return warned;
end;
$$;

-- --- Calling edge functions from the database -------------------------------

-- Cron cannot call an edge function without the project URL and a service key.
-- Both live in Vault; see docs/local-development.md for how to seed them.
create or replace function private.call_edge_function(p_name text, p_body jsonb default '{}'::jsonb)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  base_url text;
  service_key text;
  request_id bigint;
begin
  if not app.extension_enabled('pg_net') or not app.extension_enabled('supabase_vault') then
    raise warning 'pg_net or vault unavailable; cannot call edge function %', p_name;
    return null;
  end if;

  begin
    execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
      into base_url using 'edge_functions_url';
    execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
      into service_key using 'service_role_key';
  exception when others then
    raise warning 'could not read edge function credentials from vault: %', sqlerrm;
    return null;
  end;

  if base_url is null or service_key is null then
    raise warning 'vault is missing edge_functions_url or service_role_key; skipping %', p_name;
    return null;
  end if;

  select net.http_post(
           url := rtrim(base_url, '/') || '/' || p_name,
           body := p_body,
           headers := jsonb_build_object(
             'Content-Type', 'application/json',
             'Authorization', 'Bearer ' || service_key
           ),
           timeout_milliseconds := 30000
         )
    into request_id;

  return request_id;
end;
$$;

comment on function private.call_edge_function(text, jsonb) is
  'Fire-and-forget POST to an edge function using credentials held in Vault.';

-- --- Schedules --------------------------------------------------------------

select private.schedule_job(
  'supademo-rollup-usage',
  '15 0 * * *',                       -- 00:15 UTC daily
  $job$select public.rollup_usage()$job$
);

select private.schedule_job(
  'supademo-retention',
  '30 3 * * 0',                       -- Sundays, 03:30 UTC
  $job$select private.enforce_retention()$job$
);

-- Rate-limit windows go stale within the hour, so they get their own sweep
-- rather than waiting for the weekly one.
select private.schedule_job(
  'supademo-api-retention',
  '20 * * * *',                       -- hourly, at :20
  $job$select private.enforce_api_retention()$job$
);

select private.schedule_job(
  'supademo-quota-warnings',
  '0 9 * * *',                        -- 09:00 UTC daily
  $job$select private.check_quota_warnings()$job$
);

select private.schedule_job(
  'supademo-drain-webhooks',
  '* * * * *',                        -- every minute
  $job$select private.drain_webhooks(100)$job$
);

-- pg_net answers asynchronously, so sending and settling are separate passes.
select private.schedule_job(
  'supademo-reconcile-webhooks',
  '* * * * *',
  $job$select private.reconcile_webhooks(200)$job$
);

-- The embeddings queue is drained by an edge function, because inference does
-- not belong inside a database transaction.
select private.schedule_job(
  'supademo-drain-embeddings',
  '* * * * *',
  $job$select private.call_edge_function('queue-worker', '{"queue":"embeddings","batch_size":10}'::jsonb)$job$
);
