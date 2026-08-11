-- ---------------------------------------------------------------------------
-- 0800 · Realtime and notifications
--
-- Two delivery mechanisms, on purpose, because they suit different things:
--
--   Postgres Changes  — row-level streams for collaborative editing. Simple,
--                       but every change is filtered per subscriber, so it is
--                       reserved for low-volume tables.
--   Broadcast         — server-authored messages on a private topic
--                       (`org:<uuid>`), authorized once by an RLS policy on
--                       realtime.messages. This is the scalable path.
-- ---------------------------------------------------------------------------

create type public.notification_kind as enum (
  'comment', 'mention', 'invite', 'demo_published', 'quota_warning', 'billing', 'system'
);

create table public.notifications (
  id              uuid primary key default extensions.gen_random_uuid(),
  user_id         uuid not null references public.profiles (id) on delete cascade,
  organization_id uuid references public.organizations (id) on delete cascade,
  kind            public.notification_kind not null default 'system',
  title           text not null,
  body            text,
  url             text,
  data            jsonb not null default '{}'::jsonb,
  read_at         timestamptz,
  created_at      timestamptz not null default now(),

  constraint notifications_data_is_object check (jsonb_typeof(data) = 'object')
);

create index notifications_inbox_idx on public.notifications (user_id, created_at desc);
create index notifications_unread_idx on public.notifications (user_id) where read_at is null;

alter table public.notifications enable row level security;

create policy "notifications: read own"
  on public.notifications for select
  to authenticated
  using (user_id = (select auth.uid()));

-- The only field a recipient may change is whether they have read it; the
-- guard trigger reverts anything else.
create policy "notifications: mark own as read"
  on public.notifications for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "notifications: delete own"
  on public.notifications for delete
  to authenticated
  using (user_id = (select auth.uid()));

create trigger guard_server_columns
  before update on public.notifications
  for each row execute function private.tg_guard_columns(
    'id', 'user_id', 'organization_id', 'kind', 'title', 'body', 'url', 'data', 'created_at'
  );

-- No insert policy: notifications are produced server-side.
create or replace function private.notify_users(
  p_user_ids uuid[],
  p_organization_id uuid,
  p_kind public.notification_kind,
  p_title text,
  p_body text default null,
  p_url text default null,
  p_data jsonb default '{}'::jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  inserted integer;
begin
  insert into public.notifications (user_id, organization_id, kind, title, body, url, data)
  select u, p_organization_id, p_kind, p_title, p_body, p_url, p_data
    from unnest(p_user_ids) as u
   where u is not null;

  get diagnostics inserted = row_count;
  return inserted;
end;
$$;

create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  affected integer;
begin
  update public.notifications
     set read_at = now()
   where user_id = (select auth.uid())
     and read_at is null
     and (p_ids is null or id = any(p_ids));

  get diagnostics affected = row_count;
  return affected;
end;
$$;

grant execute on function public.mark_notifications_read(uuid[]) to authenticated;

-- --- Domain events ----------------------------------------------------------

-- A new comment notifies the demo's author and everyone already in the thread.
create or replace function private.tg_notify_on_comment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  demo public.demos;
  recipients uuid[];
begin
  select * into demo from public.demos d where d.id = new.demo_id;

  select coalesce(array_agg(distinct uid), '{}'::uuid[]) into recipients
    from (
      select demo.created_by as uid
      union
      select c.author_id from public.demo_comments c where c.demo_id = new.demo_id
    ) candidates
   where uid is not null and uid <> new.author_id;

  perform private.notify_users(
    recipients,
    new.organization_id,
    'comment',
    'New comment on ' || coalesce(demo.title, 'a demo'),
    left(new.body, 280),
    '/demos/' || demo.id::text,
    jsonb_build_object('demo_id', demo.id, 'comment_id', new.id, 'author_id', new.author_id)
  );

  return null;
end;
$$;

create trigger notify_on_comment
  after insert on public.demo_comments
  for each row execute function private.tg_notify_on_comment();

-- --- Postgres Changes -------------------------------------------------------
-- Only collaborative, low-volume tables join the publication. High-volume
-- tables (usage_events, demo_views) deliberately stay out.

do $$
declare
  tbl text;
begin
  if not exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime') then
    raise notice 'publication supabase_realtime not found; skipping Postgres Changes setup';
    return;
  end if;

  foreach tbl in array array[
    'public.demos', 'public.demo_steps', 'public.demo_comments', 'public.notifications'
  ] loop
    execute format('alter publication supabase_realtime add table %s', tbl);
  end loop;
end;
$$;

-- REPLICA IDENTITY FULL makes the previous row available to subscribers on
-- UPDATE/DELETE, which is what lets a client reconcile a change it did not
-- originate. It costs WAL volume, so it is opt-in per table.
alter table public.demo_steps replica identity full;
alter table public.demo_comments replica identity full;

-- --- Broadcast on private topics --------------------------------------------
-- Topic convention: `org:<organization_id>`. One membership check authorizes the
-- whole stream, instead of re-filtering every row per subscriber.

do $$
begin
  if to_regclass('realtime.messages') is null
     or to_regprocedure('realtime.topic()') is null
  then
    raise notice 'realtime broadcast primitives not present; skipping channel policies';
    return;
  end if;

  execute $policy$
    create policy "realtime: read own organization topics"
      on realtime.messages for select
      to authenticated
      using (
        realtime.topic() like 'org:%'
        and app.is_org_member(app.safe_uuid(split_part(realtime.topic(), ':', 2)))
      )
  $policy$;

  -- Clients may publish to their organization's topic (presence, cursors,
  -- "someone is typing"). Server-authored events use service_role.
  execute $policy$
    create policy "realtime: write own organization topics"
      on realtime.messages for insert
      to authenticated
      with check (
        realtime.topic() like 'org:%'
        and app.is_org_member(app.safe_uuid(split_part(realtime.topic(), ':', 2)))
      )
  $policy$;
end;
$$;

-- Mirrors row changes onto the organization topic. Registered only when the
-- running Realtime version ships broadcast_changes().
create or replace function private.tg_broadcast_org_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  org_id uuid;
begin
  -- broadcast_changes() takes `record` arguments, which cannot be a bare NULL,
  -- so each operation passes the records it actually has.
  if tg_op = 'INSERT' then
    org_id := new.organization_id;
    perform realtime.broadcast_changes(
      'org:' || org_id::text, tg_op, tg_op, tg_table_name, tg_table_schema, new, new);
  elsif tg_op = 'UPDATE' then
    org_id := new.organization_id;
    perform realtime.broadcast_changes(
      'org:' || org_id::text, tg_op, tg_op, tg_table_name, tg_table_schema, new, old);
  else
    org_id := old.organization_id;
    perform realtime.broadcast_changes(
      'org:' || org_id::text, tg_op, tg_op, tg_table_name, tg_table_schema, old, old);
  end if;

  return null;
exception when others then
  -- Never let a notification failure roll back the write that caused it.
  raise warning 'broadcast failed for %.%: %', tg_table_schema, tg_table_name, sqlerrm;
  return null;
end;
$$;

do $$
begin
  if not exists (
       select 1
         from pg_catalog.pg_proc p
         join pg_catalog.pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'realtime' and p.proname = 'broadcast_changes'
     ) then
    raise notice 'realtime.broadcast_changes() not available; skipping broadcast triggers';
    return;
  end if;

  execute $trg$
    create trigger broadcast_changes
      after insert or update or delete on public.demos
      for each row execute function private.tg_broadcast_org_change()
  $trg$;

  execute $trg$
    create trigger broadcast_changes
      after insert or update or delete on public.demo_comments
      for each row execute function private.tg_broadcast_org_change()
  $trg$;
end;
$$;
