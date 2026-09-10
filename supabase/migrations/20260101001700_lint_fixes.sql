-- ---------------------------------------------------------------------------
-- 1700 · Fixes for three `supabase db lint` findings
--
-- Migrations are append-only, so these arrive as replacements rather than edits
-- to 0100 and 1100. The three were pre-existing; CI has been failing on them
-- since the lint job was added, which is how they surfaced.
--
-- One of them is a real bug, not a style complaint.
-- ---------------------------------------------------------------------------

-- --- app.short_id: unused variable "i" --------------------------------------
-- `FOR i IN …` declares its own loop variable, which shadowed the declared one.
-- The declaration was therefore never read. Harmless, but it is the kind of
-- thing that makes a reader look twice for a second `i`.

create or replace function app.short_id(p_length integer default 12)
returns text
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  alphabet constant text := '23456789bcdfghjkmnpqrstvwxyz';
  result text := '';
begin
  for i in 1 .. greatest(p_length, 6) loop
    result := result || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return result;
end;
$$;

-- --- private.dispatch_event: never-read variable "delivery_id" --------------
-- The RETURNING clause existed to populate a variable nothing consumed. The
-- deliveries table is itself the queue and drain_webhooks() finds rows by
-- status, so the id was never needed here.

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
            ));

    -- No queue message: the deliveries table IS the queue for webhooks, and
    -- private.drain_webhooks() (scheduled every minute) is its consumer.
    fanned := fanned + 1;
  end loop;

  return fanned;
end;
$$;

-- --- private.deliver_webhook: a genuine 42P01 -------------------------------
--
-- This one would have failed at runtime. The local variable `request_id`
-- shadows the column of the same name on private.webhook_deliveries, and the
-- original disambiguated it as `deliver_webhook.request_id`. Qualifying a local
-- by the function name does not resolve inside an UPDATE ... SET — Postgres
-- reads it as a table reference and raises
--
--   42P01  missing FROM-clause entry for table "deliver_webhook"
--
-- so every webhook delivery would have thrown once it got that far. It never
-- did: the function returns early unless pg_net is available, which it is not
-- in the local stack or in CI, so no test ever reached this statement. The
-- linter found what the tests structurally could not.
--
-- Renaming the local removes the collision rather than trying to out-qualify
-- it, matching the v_ convention used elsewhere in this schema.

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
  v_request_id bigint;
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
  ) into v_request_id;

  -- pg_net is asynchronous: the row stays 'pending' until reconcile_webhooks()
  -- reads the response. The backoff schedule doubles as the retry clock, so a
  -- response that never arrives is retried rather than lost.
  update private.webhook_deliveries
     set attempts = attempts + 1,
         request_id = v_request_id,
         status = case when attempts + 1 >= 5 then 'abandoned' else 'pending' end,
         -- 2s, 4s, 8s, 16s …
         next_attempt_at = now() + (power(2, attempts + 1)::text || ' seconds')::interval
   where id = p_delivery_id;
end;
$$;
