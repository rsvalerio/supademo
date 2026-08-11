-- ---------------------------------------------------------------------------
-- 0200 · Profiles
--
-- `auth.users` is owned by GoTrue and must not be read directly by clients.
-- `public.profiles` is the public mirror: one row per user, kept in sync by
-- triggers, and the FK target every other table joins against.
-- ---------------------------------------------------------------------------

create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  email         extensions.citext not null,
  full_name     text,
  avatar_path   text,
  headline      text,
  locale        text not null default 'en',
  timezone      text not null default 'UTC',
  preferences   jsonb not null default '{}'::jsonb,
  is_admin      boolean not null default false,
  onboarded_at  timestamptz,
  last_seen_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint profiles_full_name_length check (full_name is null or char_length(full_name) <= 120),
  constraint profiles_headline_length check (headline is null or char_length(headline) <= 240),
  constraint profiles_preferences_is_object check (jsonb_typeof(preferences) = 'object')
);

comment on table public.profiles is 'Public mirror of auth.users. One row per user.';
comment on column public.profiles.avatar_path is 'Object path inside the `avatars` storage bucket.';
comment on column public.profiles.is_admin is 'Supademo staff flag. Server-owned; clients cannot set it.';

create index profiles_email_idx on public.profiles (email);
create index profiles_last_seen_at_idx on public.profiles (last_seen_at desc nulls last);

select private.attach_updated_at('public.profiles');

create trigger guard_server_columns
  before update on public.profiles
  for each row execute function private.tg_guard_columns('id', 'email', 'is_admin', 'created_at');

-- --- Sync from auth.users ---------------------------------------------------

create or replace function private.tg_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, full_name, avatar_path)
  values (
    new.id,
    coalesce(new.email, new.id::text || '@anonymous.local'),
    nullif(trim(coalesce(
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'name',
      ''
    )), ''),
    nullif(new.raw_user_meta_data ->> 'avatar_url', '')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

comment on function private.tg_handle_new_user() is
  'Creates the public.profiles row for a newly signed-up user.';

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.tg_handle_new_user();

create or replace function private.tg_handle_user_email_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles
     set email = new.email,
         updated_at = now()
   where id = new.id;

  return new;
end;
$$;

create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row
  when (new.email is distinct from old.email and new.email is not null)
  execute function private.tg_handle_user_email_change();

-- --- RLS --------------------------------------------------------------------
-- Peer visibility (seeing co-workers in the same organization) is added in
-- 0300, once the membership helpers exist.

alter table public.profiles enable row level security;

create policy "profiles: read own"
  on public.profiles for select
  to authenticated
  using (id = (select auth.uid()));

create policy "profiles: update own"
  on public.profiles for update
  to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- No insert/delete policy: rows are created by the auth trigger and removed by
-- the cascade from auth.users.

-- --- Convenience ------------------------------------------------------------

create or replace function public.touch_last_seen()
returns void
language sql
volatile
security invoker
set search_path = ''
as $$
  update public.profiles
     set last_seen_at = now()
   where id = (select auth.uid());
$$;

comment on function public.touch_last_seen() is
  'RPC: records a heartbeat for the calling user.';

grant execute on function public.touch_last_seen() to authenticated;
