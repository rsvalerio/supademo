-- ---------------------------------------------------------------------------
-- 1600 · The machine API's write surface
--
-- Same rule as the read functions in 1500: each takes the organization id the
-- key resolved to and scopes itself by it, because the caller is service_role
-- and therefore has RLS switched off.
--
-- Writes need two things reads did not:
--
--   1. The checks RLS was doing. `app.is_org_active()` gates every write policy
--      in this schema, so a lapsed subscription cannot create data. service_role
--      never sees those policies, so the check has to be made here explicitly.
--      This is the tax on the service-role path, and the reason the surface is
--      deliberately small.
--
--   2. Idempotency. A machine client that times out will retry, and "create a
--      demo" is not safe to run twice. Retrying with the same Idempotency-Key
--      replays the first response instead of doing the work again.
-- ---------------------------------------------------------------------------

-- --- The checks RLS would have made -----------------------------------------

-- Raises unless the organization exists and is in good standing. Mirrors the
-- `with check` half of the write policies in 0500/1000.
create or replace function app.assert_org_writable(p_organization_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.organizations o
     where o.id = p_organization_id and o.deleted_at is null
  ) then
    raise exception 'organization not found' using errcode = 'no_data_found';
  end if;

  if not app.is_org_active(p_organization_id) then
    raise exception 'subscription is not in good standing'
      using errcode = 'check_violation',
            hint = 'Reads keep working; writes resume once billing is current.';
  end if;
end;
$$;

grant execute on function app.assert_org_writable(uuid) to service_role;

-- --- Idempotency ------------------------------------------------------------

create table private.api_idempotency (
  key_id              uuid not null references public.api_keys (id) on delete cascade,
  idempotency_key     text not null,
  request_fingerprint text not null,
  status_code         integer not null default 200,
  response            jsonb not null,
  created_at          timestamptz not null default now(),

  primary key (key_id, idempotency_key),
  constraint api_idempotency_key_length check (char_length(idempotency_key) between 8 and 255)
);

comment on table private.api_idempotency is
  'Replayable responses, scoped to the API key that made the request. Swept hourly.';

create index api_idempotency_created_idx on private.api_idempotency (created_at);

-- Returns the stored response for a repeated request, NULL when this is the
-- first time, and raises when the same key is reused with a different body —
-- which is a client bug worth surfacing loudly rather than silently doing
-- something the caller did not intend.
create or replace function public.api_replay_idempotent(
  p_key_id uuid,
  p_idempotency_key text,
  p_fingerprint text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  prior private.api_idempotency;
begin
  if not app.is_service_role() then
    raise exception 'service_role required' using errcode = 'insufficient_privilege';
  end if;
  if p_idempotency_key is null then
    return null;
  end if;

  select * into prior
    from private.api_idempotency i
   where i.key_id = p_key_id and i.idempotency_key = p_idempotency_key;

  if prior.key_id is null then
    return null;
  end if;

  if prior.request_fingerprint <> p_fingerprint then
    raise exception 'idempotency key reused with a different request body'
      using errcode = 'unique_violation',
            hint = 'Use a fresh Idempotency-Key for a different request.';
  end if;

  return jsonb_build_object(
    'replayed', true,
    'status_code', prior.status_code,
    'response', prior.response
  );
end;
$$;

create or replace function public.api_remember_idempotent(
  p_key_id uuid,
  p_idempotency_key text,
  p_fingerprint text,
  p_response jsonb,
  p_status_code integer default 200
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not app.is_service_role() then
    raise exception 'service_role required' using errcode = 'insufficient_privilege';
  end if;
  if p_idempotency_key is null then
    return;
  end if;

  insert into private.api_idempotency
    (key_id, idempotency_key, request_fingerprint, status_code, response)
  values (p_key_id, p_idempotency_key, p_fingerprint, p_status_code, p_response)
  on conflict (key_id, idempotency_key) do nothing;
end;
$$;

revoke execute on function
  public.api_replay_idempotent(uuid, text, text),
  public.api_remember_idempotent(uuid, text, text, jsonb, integer)
from public, anon, authenticated;

grant execute on function
  public.api_replay_idempotent(uuid, text, text),
  public.api_remember_idempotent(uuid, text, text, jsonb, integer)
to service_role;

-- --- Writes -----------------------------------------------------------------

-- Projects are addressed by slug over the API: a customer's automation should
-- not have to store our uuids to file a demo in the right place.
create or replace function public.api_create_demo(
  p_organization_id uuid,
  p_project text,
  p_title text,
  p_description text default null,
  p_tags text[] default '{}'
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  project_id uuid;
  created public.demos;
begin
  perform app.assert_org_writable(p_organization_id);

  select p.id into project_id
    from public.projects p
   where p.organization_id = p_organization_id
     and (p.slug = p_project::extensions.citext or p.id = app.safe_uuid(p_project))
     and p.archived_at is null;

  if project_id is null then
    raise exception 'project "%" not found in this organization', p_project
      using errcode = 'no_data_found';
  end if;

  if coalesce(trim(p_title), '') = '' then
    raise exception 'title is required' using errcode = 'check_violation';
  end if;

  -- The demos quota trigger fires here; exceeding the plan raises 23514, which
  -- the edge function turns into a 402.
  insert into public.demos (organization_id, project_id, title, description, tags)
  values (p_organization_id, project_id, trim(p_title), p_description, coalesce(p_tags, '{}'))
  returning * into created;

  return public.api_get_demo(p_organization_id, created.public_id);
end;
$$;

create or replace function public.api_update_demo(
  p_organization_id uuid,
  p_public_id text,
  p_title text default null,
  p_description text default null,
  p_tags text[] default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  target public.demos;
begin
  perform app.assert_org_writable(p_organization_id);

  select * into target
    from public.demos d
   where d.organization_id = p_organization_id
     and d.public_id = p_public_id
     and d.deleted_at is null;

  if target.id is null then
    raise exception 'demo not found' using errcode = 'no_data_found';
  end if;

  -- NULL means "leave alone" rather than "clear", so a partial update does not
  -- silently blank the fields it did not mention.
  update public.demos
     set title = coalesce(nullif(trim(coalesce(p_title, '')), ''), title),
         description = coalesce(p_description, description),
         tags = coalesce(p_tags, tags)
   where id = target.id;

  return public.api_get_demo(p_organization_id, p_public_id);
end;
$$;

-- Publishing is its own call rather than a field on update: it is the action
-- that makes a demo visible to the world and fires the demo.published webhook,
-- and that deserves to be explicit in a client's code.
create or replace function public.api_publish_demo(
  p_organization_id uuid,
  p_public_id text,
  p_visibility public.demo_visibility default 'link'
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  target public.demos;
begin
  perform app.assert_org_writable(p_organization_id);

  select * into target
    from public.demos d
   where d.organization_id = p_organization_id
     and d.public_id = p_public_id
     and d.deleted_at is null;

  if target.id is null then
    raise exception 'demo not found' using errcode = 'no_data_found';
  end if;

  if not exists (select 1 from public.demo_steps s where s.demo_id = target.id) then
    raise exception 'a demo needs at least one step before it can be published'
      using errcode = 'check_violation';
  end if;

  -- The demo_defaults trigger stamps published_at; dispatch_demo_events fires
  -- the webhook, but only on the transition, so re-publishing is quiet.
  update public.demos
     set status = 'published', visibility = p_visibility
   where id = target.id;

  return public.api_get_demo(p_organization_id, p_public_id);
end;
$$;

-- Upsert by source_id so a customer's sync job can run repeatedly without
-- accumulating duplicates. Content changes queue re-embedding through the
-- trigger from 1100; unchanged content is skipped by the checksum.
create or replace function public.api_upsert_document(
  p_organization_id uuid,
  p_source_id uuid,
  p_title text,
  p_content text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  saved public.documents;
begin
  perform app.assert_org_writable(p_organization_id);

  if coalesce(trim(p_title), '') = '' then
    raise exception 'title is required' using errcode = 'check_violation';
  end if;

  select * into saved
    from public.documents d
   where d.organization_id = p_organization_id
     and d.source_type = 'upload'
     and d.source_id = p_source_id;

  if saved.id is null then
    insert into public.documents (organization_id, source_type, source_id, title, content)
    values (p_organization_id, 'upload', p_source_id, trim(p_title), coalesce(p_content, ''))
    returning * into saved;
  else
    update public.documents
       set title = trim(p_title), content = coalesce(p_content, '')
     where id = saved.id
    returning * into saved;
  end if;

  return jsonb_build_object(
    'source_id', saved.source_id,
    'title', saved.title,
    'checksum', saved.checksum,
    'updated_at', saved.updated_at
  );
end;
$$;

revoke execute on function
  public.api_create_demo(uuid, text, text, text, text[]),
  public.api_update_demo(uuid, text, text, text, text[]),
  public.api_publish_demo(uuid, text, public.demo_visibility),
  public.api_upsert_document(uuid, uuid, text, text)
from public, anon, authenticated;

grant execute on function
  public.api_create_demo(uuid, text, text, text, text[]),
  public.api_update_demo(uuid, text, text, text, text[]),
  public.api_publish_demo(uuid, text, public.demo_visibility),
  public.api_upsert_document(uuid, uuid, text, text)
to service_role;

-- --- Retention --------------------------------------------------------------
-- Replay records are only useful for as long as a client might retry.

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
  delete from private.api_idempotency where created_at < now() - interval '24 hours';

  return removed;
end;
$$;
