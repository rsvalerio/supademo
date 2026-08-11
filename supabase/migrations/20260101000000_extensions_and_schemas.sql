-- ---------------------------------------------------------------------------
-- 0000 · Extensions, schemas and baseline grants
--
-- Schema map
--   public      tables the API may reach, always behind RLS
--   api         curated read-only views exposed to PostgREST
--   app         helper functions used by policies and application code
--   private     internal tables/functions; NOT exposed to PostgREST
--   auth_hooks  functions called by GoTrue (Auth hooks)
--   extensions  where relocatable extensions live
-- ---------------------------------------------------------------------------

create schema if not exists extensions;
create schema if not exists app;
create schema if not exists api;
create schema if not exists private;
create schema if not exists auth_hooks;

comment on schema app is 'Helper functions shared by RLS policies and application code.';
comment on schema api is 'Curated, client-facing views. Exposed via PostgREST.';
comment on schema private is 'Internal tables and functions. Never exposed to PostgREST.';
comment on schema auth_hooks is 'Functions invoked by GoTrue auth hooks.';

-- --- Required extensions ----------------------------------------------------
create extension if not exists pgcrypto with schema extensions;      -- gen_random_uuid, digest, hmac
create extension if not exists citext with schema extensions;        -- case-insensitive email/slug
create extension if not exists pg_trgm with schema extensions;       -- fuzzy search
create extension if not exists btree_gin with schema extensions;     -- composite GIN indexes
create extension if not exists vector with schema extensions;        -- pgvector: embeddings

-- --- Optional extensions ----------------------------------------------------
-- These are available on hosted Supabase and on recent local images, but a
-- pinned/older image may not have them. Migrations must still apply cleanly, so
-- each one is attempted and downgraded to a notice on failure. Everything that
-- depends on them is guarded the same way (see 1100/1200).
do $$
declare
  ext text;
begin
  foreach ext in array array['pg_net', 'pg_cron', 'pgmq', 'supabase_vault', 'pg_stat_statements']
  loop
    begin
      execute format('create extension if not exists %I', ext);
    exception when others then
      raise notice 'optional extension % not installed: %', ext, sqlerrm;
    end;
  end loop;
end;
$$;

-- Reports whether an optional extension made it in. Later migrations branch on
-- this instead of assuming.
create or replace function app.extension_enabled(p_name text)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select exists (select 1 from pg_catalog.pg_extension where extname = p_name);
$$;

comment on function app.extension_enabled(text) is
  'True when the named extension is installed in this database.';

-- --- Baseline grants --------------------------------------------------------
grant usage on schema extensions to anon, authenticated, service_role;
grant usage on schema app to anon, authenticated, service_role;
grant usage on schema api to anon, authenticated, service_role;

-- `private` is deliberately unreachable from the API roles.
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to service_role;

-- PostgREST never resolves auth_hooks; only GoTrue's role touches it.
revoke all on schema auth_hooks from public, anon, authenticated;

-- Table privileges are the coarse gate (which verbs a role may attempt); RLS is
-- the fine gate (which rows). `service_role` is intentionally absent here — it
-- already bypasses RLS and gets its grants from Supabase's own defaults.
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public
  grant select on tables to anon;
alter default privileges in schema public
  grant usage, select on sequences to authenticated, anon;

alter default privileges in schema api grant select on tables to anon, authenticated;
alter default privileges in schema app grant execute on functions to anon, authenticated;
