-- ---------------------------------------------------------------------------
-- 1100 · Queues (pgmq), outbound webhooks (pg_net) and secrets (Vault)
--
-- Anything slow or failure-prone is pushed onto a queue inside the same
-- transaction as the change that caused it, so a write either records the fact
-- AND the intent to react to it, or neither. Workers drain the queues.
--
-- Every reference to pgmq / pg_net / vault sits inside a PL/pgSQL body, which
-- is not name-resolved until it runs. That is deliberate: the schema still
-- applies on an image where one of those extensions is unavailable, and the
-- feature simply stays dormant.
-- ---------------------------------------------------------------------------

do $$
begin
  if app.extension_enabled('pgmq') then
    perform pgmq.create('embeddings');
    perform pgmq.create('emails');
  else
    raise notice 'pgmq unavailable; queues not created';
  end if;
end;
$$;

-- Enqueue helper that degrades to a no-op (with a warning) rather than failing
-- the transaction that called it.
create or replace function private.enqueue(p_queue text, p_message jsonb)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  msg_id bigint;
begin
  if not app.extension_enabled('pgmq') then
    raise warning 'pgmq unavailable; dropping message for queue %', p_queue;
    return null;
  end if;

  execute format('select pgmq.send(%L, $1)', p_queue) into msg_id using p_message;
  return msg_id;
end;
$$;

comment on function private.enqueue(text, jsonb) is
  'Transactional enqueue. Returns NULL when pgmq is not installed.';

-- --- Outbound webhooks ------------------------------------------------------

create table public.webhook_endpoints (
  id              uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  url             text not null,
  description     text,
  events          text[] not null default '{}',
  secret_id       uuid,
  is_active       boolean not null default true,
  failure_count   integer not null default 0,
  disabled_at     timestamptz,
  created_by      uuid references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint webhook_endpoints_url_https check (url ~ '^https://'),
  constraint webhook_endpoints_events_not_empty check (array_length(events, 1) > 0)
);

comment on column public.webhook_endpoints.secret_id is
  'Vault secret id holding the HMAC signing key. The key itself never leaves the database unencrypted.';

create index webhook_endpoints_org_idx on public.webhook_endpoints (organization_id) where is_active;

select private.attach_updated_at('public.webhook_endpoints');

create trigger guard_server_columns
  before update on public.webhook_endpoints
  for each row execute function private.tg_guard_columns(
    'id', 'organization_id', 'secret_id', 'failure_count', 'created_by', 'created_at'
  );

-- Delivery attempts are operational data, not tenant data: `private`, read
-- through an RPC.
create table private.webhook_deliveries (
  id              uuid primary key default extensions.gen_random_uuid(),
  endpoint_id     uuid not null references public.webhook_endpoints (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  event           text not null,
  payload         jsonb not null,
  status          text not null default 'pending',
  attempts        integer not null default 0,
  response_status integer,
  last_error      text,
  request_id      bigint,
  next_attempt_at timestamptz not null default now(),
  delivered_at    timestamptz,
  created_at      timestamptz not null default now(),

  constraint webhook_deliveries_status_valid
    check (status in ('pending', 'delivered', 'failed', 'abandoned'))
);

create index webhook_deliveries_due_idx on private.webhook_deliveries (next_attempt_at)
  where status = 'pending';
create index webhook_deliveries_endpoint_idx on private.webhook_deliveries (endpoint_id, created_at desc);

alter table public.webhook_endpoints enable row level security;

create policy "webhook_endpoints: read as admin"
  on public.webhook_endpoints for select
  to authenticated
  using (app.has_org_role(organization_id, 'admin'));

create policy "webhook_endpoints: manage as admin"
  on public.webhook_endpoints for all
  to authenticated
  using (app.has_org_role(organization_id, 'admin'))
  with check (app.has_org_role(organization_id, 'admin') and app.is_org_active(organization_id));

-- Mints the signing secret in Vault when an endpoint is created, so no code
-- path ever has to hold it in plaintext.
create or replace function private.tg_provision_webhook_secret()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  generated text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  new.created_by := coalesce(new.created_by, (select auth.uid()));

  if app.extension_enabled('supabase_vault') then
    begin
      execute 'select vault.create_secret($1, $2, $3)'
        into new.secret_id
        using generated,
              'webhook_' || new.id::text,
              'HMAC signing key for webhook endpoint ' || new.id::text;
    exception when others then
      raise warning 'could not store webhook secret in vault: %', sqlerrm;
    end;
  end if;

  return new;
end;
$$;

create trigger provision_webhook_secret
  before insert on public.webhook_endpoints
  for each row execute function private.tg_provision_webhook_secret();

-- --- Event dispatch ---------------------------------------------------------

-- Fans an event out to every subscribed endpoint and queues the deliveries.
create or replace function private.dispatch_event(
  p_organization_id uuid,
  p_event text,
  p_payload jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  endpoint public.webhook_endpoints;
  delivery_id uuid;
  fanned integer := 0;
begin
  for endpoint in
    select *
      from public.webhook_endpoints e
     where e.organization_id = p_organization_id
       and e.is_active
       and (e.events @> array[p_event] or e.events @> array['*'])
  loop
    insert into private.webhook_deliveries (endpoint_id, organization_id, event, payload)
    values (endpoint.id, p_organization_id, p_event,
            jsonb_build_object(
              'event', p_event,
              'organization_id', p_organization_id,
              'sent_at', now(),
              'data', p_payload
            ))
    returning id into delivery_id;

    -- No queue message: the deliveries table IS the queue for webhooks, and
    -- private.drain_webhooks() (scheduled every minute) is its consumer.
    fanned := fanned + 1;
  end loop;

  return fanned;
end;
$$;

-- Publishing a demo is the canonical domain event; more can be added the same
-- way without touching the delivery machinery.
create or replace function private.tg_dispatch_demo_events()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status <> 'published' then
    return null;
  end if;

  -- Announce the transition, not every subsequent save. OLD is unassigned on
  -- INSERT, so it is only read in the UPDATE branch.
  if tg_op = 'UPDATE' then
    if old.status = 'published' then
      return null;
    end if;
  end if;

  perform private.dispatch_event(
    new.organization_id,
    'demo.published',
    jsonb_build_object(
      'id', new.id,
      'public_id', new.public_id,
      'title', new.title,
      'project_id', new.project_id,
      'published_at', new.published_at
    )
  );

  return null;
end;
$$;

create trigger dispatch_demo_events
  after insert or update of status on public.demos
  for each row execute function private.tg_dispatch_demo_events();

-- --- Delivery ---------------------------------------------------------------

-- Posts one delivery with pg_net (async: the HTTP call is handed to a
-- background worker and does not hold the transaction open). Retries use
-- exponential backoff; five failures abandon the delivery.
create or replace function private.deliver_webhook(p_delivery_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  delivery private.webhook_deliveries;
  endpoint public.webhook_endpoints;
  signing_key text;
  signature text;
  body text;
  request_id bigint;
begin
  if not app.extension_enabled('pg_net') then
    raise warning 'pg_net unavailable; webhook % not sent', p_delivery_id;
    return;
  end if;

  select * into delivery from private.webhook_deliveries d
   where d.id = p_delivery_id and d.status = 'pending'
   for update skip locked;

  if delivery.id is null then
    return;
  end if;

  select * into endpoint from public.webhook_endpoints e where e.id = delivery.endpoint_id;
  if endpoint.id is null or not endpoint.is_active then
    update private.webhook_deliveries set status = 'abandoned', last_error = 'endpoint inactive'
     where id = p_delivery_id;
    return;
  end if;

  body := delivery.payload::text;

  if endpoint.secret_id is not null and app.extension_enabled('supabase_vault') then
    begin
      execute 'select decrypted_secret from vault.decrypted_secrets where id = $1'
        into signing_key
        using endpoint.secret_id;
    exception when others then
      signing_key := null;
    end;
  end if;

  signature := case
    when signing_key is null then null
    else 'sha256=' || encode(extensions.hmac(body, signing_key, 'sha256'), 'hex')
  end;

  select net.http_post(
    url := endpoint.url,
    body := delivery.payload,
    headers := jsonb_strip_nulls(jsonb_build_object(
      'Content-Type', 'application/json',
      'User-Agent', 'Supademo-Webhooks/1',
      'X-Supademo-Event', delivery.event,
      'X-Supademo-Delivery', delivery.id::text,
      'X-Supademo-Signature', signature
    )),
    timeout_milliseconds := 5000
  ) into request_id;

  -- pg_net is asynchronous: the row stays 'pending' until reconcile_webhooks()
  -- reads the response. The backoff schedule doubles as the retry clock, so a
  -- response that never arrives is retried rather than lost.
  update private.webhook_deliveries
     set attempts = attempts + 1,
         request_id = deliver_webhook.request_id,
         status = case when attempts + 1 >= 5 then 'abandoned' else 'pending' end,
         -- 2s, 4s, 8s, 16s …
         next_attempt_at = now() + (power(2, attempts + 1)::text || ' seconds')::interval
   where id = p_delivery_id;
end;
$$;

-- Called by cron: sweeps everything that is due.
create or replace function private.drain_webhooks(p_batch_size integer default 50)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  due uuid;
  processed integer := 0;
begin
  for due in
    select d.id
      from private.webhook_deliveries d
     where d.status = 'pending'
       and d.next_attempt_at <= now()
     order by d.next_attempt_at
     limit greatest(coalesce(p_batch_size, 50), 1)
  loop
    perform private.deliver_webhook(due);
    processed := processed + 1;
  end loop;

  return processed;
end;
$$;

-- pg_net writes responses to net._http_response. Reconciliation closes the
-- loop: a 2xx marks the delivery done, anything else leaves it to the backoff
-- schedule until the attempt limit is reached.
create or replace function private.reconcile_webhooks(p_limit integer default 200)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  settled integer := 0;
begin
  if not app.extension_enabled('pg_net') then
    return 0;
  end if;

  execute $sql$
    with responses as (
      select d.id as delivery_id, r.status_code, r.error_msg
        from private.webhook_deliveries d
        join net._http_response r on r.id = d.request_id
       where d.status = 'pending'
         and d.request_id is not null
       limit $1
    )
    update private.webhook_deliveries d
       set response_status = r.status_code,
           last_error = r.error_msg,
           status = case
                      when r.status_code between 200 and 299 then 'delivered'
                      when d.attempts >= 5 then 'abandoned'
                      else 'pending'
                    end,
           delivered_at = case
                            when r.status_code between 200 and 299 then now()
                            else d.delivered_at
                          end
      from responses r
     where d.id = r.delivery_id
  $sql$ using greatest(coalesce(p_limit, 200), 1);

  get diagnostics settled = row_count;
  return settled;
end;
$$;

comment on function private.reconcile_webhooks(integer) is
  'Reads pg_net responses and settles the matching webhook deliveries.';

-- --- Read path --------------------------------------------------------------

create or replace function public.webhook_delivery_log(
  p_endpoint_id uuid,
  p_limit integer default 50
)
returns table (
  id uuid,
  event text,
  status text,
  attempts integer,
  response_status integer,
  last_error text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select d.id, d.event, d.status, d.attempts, d.response_status, d.last_error, d.created_at
    from private.webhook_deliveries d
   where d.endpoint_id = p_endpoint_id
     and app.has_org_role(d.organization_id, 'admin')
   order by d.created_at desc
   limit least(coalesce(p_limit, 50), 200);
$$;

grant execute on function public.webhook_delivery_log(uuid, integer) to authenticated;

-- --- Queue access for workers -----------------------------------------------
--
-- Supabase's own `pgmq_public` schema is not exposed to PostgREST here, and
-- exposing it would hand every queue operation to whatever roles reach the API.
-- These three wrappers are the entire surface a worker needs, and they are
-- service_role-only.

create or replace function public.queue_read(
  p_queue text,
  p_count integer default 10,
  p_visibility_seconds integer default 120
)
returns table (msg_id bigint, read_ct integer, enqueued_at timestamptz, message jsonb)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not app.is_service_role() then
    raise exception 'service_role required' using errcode = 'insufficient_privilege';
  end if;
  if not app.extension_enabled('pgmq') then
    return;
  end if;

  return query execute
    format('select msg_id, read_ct, enqueued_at, message from pgmq.read(%L, $1, $2)', p_queue)
    using greatest(coalesce(p_visibility_seconds, 120), 1),
          least(greatest(coalesce(p_count, 10), 1), 100);
end;
$$;

create or replace function public.queue_delete(p_queue text, p_msg_id bigint)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  deleted boolean;
begin
  if not app.is_service_role() then
    raise exception 'service_role required' using errcode = 'insufficient_privilege';
  end if;
  if not app.extension_enabled('pgmq') then
    return false;
  end if;

  execute format('select pgmq.delete(%L, $1)', p_queue) into deleted using p_msg_id;
  return coalesce(deleted, false);
end;
$$;

-- Archiving keeps a poison message for inspection instead of destroying the
-- evidence of why it kept failing.
create or replace function public.queue_archive(p_queue text, p_msg_id bigint)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  archived boolean;
begin
  if not app.is_service_role() then
    raise exception 'service_role required' using errcode = 'insufficient_privilege';
  end if;
  if not app.extension_enabled('pgmq') then
    return false;
  end if;

  execute format('select pgmq.archive(%L, $1)', p_queue) into archived using p_msg_id;
  return coalesce(archived, false);
end;
$$;

revoke execute on function
  public.queue_read(text, integer, integer),
  public.queue_delete(text, bigint),
  public.queue_archive(text, bigint)
from public, anon, authenticated;

grant execute on function
  public.queue_read(text, integer, integer),
  public.queue_delete(text, bigint),
  public.queue_archive(text, bigint)
to service_role;

-- --- Embedding jobs ---------------------------------------------------------

-- Content changes queue re-embedding rather than doing it inline: inference is
-- slow and must never be in the request path.
create or replace function private.tg_queue_embedding()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if old.checksum = new.checksum then
      return null;  -- content unchanged; the existing vectors still stand
    end if;
  end if;

  perform private.enqueue(
    'embeddings',
    jsonb_build_object('document_id', new.id, 'organization_id', new.organization_id)
  );

  return null;
end;
$$;

create trigger queue_embedding
  after insert or update of content on public.documents
  for each row execute function private.tg_queue_embedding();
