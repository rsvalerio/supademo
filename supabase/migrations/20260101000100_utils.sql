-- ---------------------------------------------------------------------------
-- 0100 · Shared helpers
--
-- Everything here is dependency-free so later migrations can lean on it.
-- Convention: helpers callable from policies/clients live in `app`; trigger
-- functions and anything privileged lives in `private`.
-- ---------------------------------------------------------------------------

-- --- Request context --------------------------------------------------------

-- The whole JWT as jsonb. Empty object for unauthenticated requests, so callers
-- can always use `->>` without a null guard.
create or replace function app.jwt()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb,
    '{}'::jsonb
  );
$$;

create or replace function app.uid()
returns uuid
language sql
stable
security invoker
set search_path = ''
as $$
  select auth.uid();
$$;

create or replace function app.role()
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(auth.role(), 'anon');
$$;

-- True for the service key (PostgREST sets role=service_role in the JWT) and
-- for a direct database session such as psql, a migration or a pg_cron job,
-- which have no JWT at all. An API client cannot reach the second branch:
-- PostgREST always presents a JWT — the anon key is one — and its session user
-- is `authenticator`, never `postgres`.
create or replace function app.is_service_role()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(auth.role(), '') = 'service_role'
      or (
        nullif(current_setting('request.jwt.claims', true), '') is null
        and session_user = 'postgres'
      );
$$;

-- Authenticator Assurance Level: 'aal1' for password/OAuth, 'aal2' once a second
-- factor has been verified. Used to gate destructive operations.
create or replace function app.aal()
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(app.jwt() ->> 'aal', 'aal1');
$$;

create or replace function app.is_mfa_verified()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select app.aal() = 'aal2';
$$;

comment on function app.aal() is
  'Assurance level of the current session. aal2 means MFA was verified.';

-- --- Text helpers -----------------------------------------------------------

-- Cast that yields NULL instead of raising. Policies must never error on
-- attacker-controlled text: an exception is a 500, not a denial.
create or replace function app.safe_uuid(p_input text)
returns uuid
language plpgsql
immutable
security invoker
set search_path = ''
as $$
begin
  return p_input::uuid;
exception when invalid_text_representation then
  return null;
end;
$$;

create or replace function app.slugify(p_input text)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select trim(
    both '-' from
    regexp_replace(
      regexp_replace(lower(coalesce(p_input, '')), '[^a-z0-9]+', '-', 'g'),
      '-{2,}', '-', 'g'
    )
  );
$$;

comment on function app.slugify(text) is
  'Lowercase, hyphenated, URL-safe form of the input.';

-- Short, URL-safe, non-sequential public identifier (e.g. demo share links).
-- Base32-ish alphabet: no vowels, no look-alikes.
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
  i integer;
begin
  for i in 1 .. greatest(p_length, 6) loop
    result := result || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return result;
end;
$$;

-- --- Trusted path -----------------------------------------------------------
-- Some integrity triggers must reject an operation coming straight from a
-- client but allow the same operation when a vetted SECURITY DEFINER routine
-- performs it (accepting an invite writes your own membership row, for
-- example). Those routines raise a transaction-local flag; the triggers look
-- for it. The flag is `set_config(..., is_local => true)`, so it dies with the
-- transaction and cannot be set by a client — nothing exposed to PostgREST
-- sets it.

create or replace function private.begin_privileged()
returns void
language sql
volatile
security invoker
set search_path = ''
as $$
  select set_config('app.privileged', 'on', true);
$$;

create or replace function private.is_privileged()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(current_setting('app.privileged', true), 'off') = 'on';
$$;

-- --- Trigger functions ------------------------------------------------------

create or replace function private.tg_set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Blocks client-side tampering with columns the server owns. Attach with
-- `execute function private.tg_guard_columns('col_a', 'col_b')`.
create or replace function private.tg_guard_columns()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  col text;
  old_value jsonb := to_jsonb(old);
  new_value jsonb := to_jsonb(new);
begin
  -- service_role is the server; it is allowed to move these.
  if coalesce(auth.role(), '') = 'service_role' then
    return new;
  end if;

  foreach col in array tg_argv loop
    if old_value -> col is distinct from new_value -> col then
      new_value := jsonb_set(new_value, array[col], old_value -> col);
    end if;
  end loop;

  return jsonb_populate_record(new, new_value);
end;
$$;

comment on function private.tg_guard_columns() is
  'BEFORE UPDATE trigger. Silently reverts client edits to server-owned columns.';

-- Convenience wrapper so tables get the same updated_at behaviour without
-- repeating the DDL by hand.
create or replace function private.attach_updated_at(p_table regclass)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  execute format(
    'create or replace trigger set_updated_at
       before update on %s
       for each row execute function private.tg_set_updated_at()',
    p_table
  );
end;
$$;
