-- ---------------------------------------------------------------------------
-- 0900 · Audit trail
--
-- The log lives in `private` so PostgREST cannot reach it at all, which keeps
-- "who can read the audit log" a single decision made in one function rather
-- than a policy that has to be right on every column. Admins read it through
-- public.audit_trail().
-- ---------------------------------------------------------------------------

create table private.audit_log (
  id              bigint generated always as identity primary key,
  organization_id uuid,
  actor_id        uuid,
  actor_role      text,
  action          text not null,
  table_name      text not null,
  record_id       text,
  changed_fields  text[],
  old_data        jsonb,
  new_data        jsonb,
  request_id      text,
  created_at      timestamptz not null default now(),

  constraint audit_log_action_valid check (action in ('INSERT', 'UPDATE', 'DELETE'))
);

comment on table private.audit_log is
  'Append-only change log. Not exposed to PostgREST; read via public.audit_trail().';

create index audit_log_org_time_idx on private.audit_log (organization_id, created_at desc);
create index audit_log_record_idx on private.audit_log (table_name, record_id, created_at desc);
create index audit_log_actor_idx on private.audit_log (actor_id, created_at desc);

-- Columns that are noise in a change log, or that must never be copied into it.
create or replace function private.audit_redactions()
returns text[]
language sql
immutable
security invoker
set search_path = ''
as $$
  select array['updated_at', 'search_vector', 'token_hash', 'secret', 'key_hash'];
$$;

create or replace function private.tg_audit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_row jsonb := null;
  new_row jsonb := null;
  changed text[] := null;
  org_id uuid;
  rec_id text;
  redactions text[] := private.audit_redactions();
begin
  if tg_op <> 'INSERT' then
    old_row := to_jsonb(old) - redactions;
  end if;
  if tg_op <> 'DELETE' then
    new_row := to_jsonb(new) - redactions;
  end if;

  if tg_op = 'UPDATE' then
    select coalesce(array_agg(key), '{}'::text[]) into changed
      from jsonb_each(new_row) e(key, value)
     where old_row -> e.key is distinct from e.value;

    -- Nothing meaningful changed (only redacted columns moved).
    if changed = '{}'::text[] then
      return null;
    end if;
  end if;

  org_id := app.safe_uuid(coalesce(new_row, old_row) ->> 'organization_id');
  rec_id := coalesce(new_row, old_row) ->> 'id';

  insert into private.audit_log (
    organization_id, actor_id, actor_role, action, table_name, record_id,
    changed_fields, old_data, new_data, request_id
  )
  values (
    org_id,
    (select auth.uid()),
    coalesce(auth.role(), current_user),
    tg_op,
    tg_table_schema || '.' || tg_table_name,
    rec_id,
    changed,
    old_row,
    new_row,
    nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-request-id'
  );

  return null;
end;
$$;

comment on function private.tg_audit() is
  'AFTER trigger. Records the change, minus redacted columns, in private.audit_log.';

-- Attaching auditing is one statement per table, so it is easy to add later.
create or replace function private.attach_audit(p_table regclass)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  execute format(
    'create or replace trigger audit_changes
       after insert or update or delete on %s
       for each row execute function private.tg_audit()',
    p_table
  );
end;
$$;

select private.attach_audit('public.organizations');
select private.attach_audit('public.organization_members');
select private.attach_audit('public.organization_invites');
select private.attach_audit('public.subscriptions');
select private.attach_audit('public.projects');
select private.attach_audit('public.demos');

-- --- Read path --------------------------------------------------------------

create or replace function public.audit_trail(
  p_organization_id uuid,
  p_limit integer default 100,
  p_before timestamptz default null
)
returns table (
  id bigint,
  actor_id uuid,
  actor_email text,
  action text,
  table_name text,
  record_id text,
  changed_fields text[],
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select a.id,
         a.actor_id,
         p.email::text,
         a.action,
         a.table_name,
         a.record_id,
         a.changed_fields,
         a.created_at
    from private.audit_log a
    left join public.profiles p on p.id = a.actor_id
   where a.organization_id = p_organization_id
     and (p_before is null or a.created_at < p_before)
     -- Authorization is the function's job, since the table has no policies.
     and app.has_org_role(p_organization_id, 'admin')
   order by a.created_at desc
   limit least(coalesce(p_limit, 100), 500);
$$;

comment on function public.audit_trail(uuid, integer, timestamptz) is
  'RPC: paginated audit history for an organization. Admins only.';

grant execute on function public.audit_trail(uuid, integer, timestamptz) to authenticated;
