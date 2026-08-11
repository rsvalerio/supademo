-- Seeds the Vault entries that database-side jobs need.
--
-- pg_cron cannot call an edge function without a URL and a key, and neither
-- belongs in a migration — they differ per environment and one of them is a
-- credential. Run this once per project, by hand:
--
--   psql "$SUPABASE_DB_URL" -f scripts/bootstrap-secrets.sql \
--     -v url="https://<ref>.supabase.co/functions/v1" \
--     -v key="<service-role-key>"
--
-- Locally:
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres \
--     -f scripts/bootstrap-secrets.sql \
--     -v url="http://host.docker.internal:54321/functions/v1" \
--     -v key="$(npx supabase status -o json | jq -r .SERVICE_ROLE_KEY)"

select vault.create_secret(:'url', 'edge_functions_url', 'Base URL for edge function invocations')
where not exists (select 1 from vault.secrets where name = 'edge_functions_url');

select vault.create_secret(:'key', 'service_role_key', 'Service role key used by scheduled jobs')
where not exists (select 1 from vault.secrets where name = 'service_role_key');

select name, description, created_at from vault.secrets order by name;
