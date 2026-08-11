# Local development

## Prerequisites

- Docker (the local stack is a set of containers)
- Node 20+
- Deno 2 — optional, only for linting and type-checking edge functions

## First run

```bash
npm install
cp .env.example .env

npm run db:start     # boots Postgres, GoTrue, Storage, Realtime, the edge runtime
npm run db:reset     # applies every migration in order, then seed.sql
npm run gen:types    # writes packages/db-types/src/database.types.ts
```

`npm run db:start` prints the local URLs and keys. The important ones:

| Service | URL |
| --- | --- |
| API | http://127.0.0.1:54321 |
| Studio | http://127.0.0.1:54323 |
| Postgres | postgresql://postgres:postgres@127.0.0.1:54322/postgres |
| Inbucket (mail catcher) | http://127.0.0.1:54324 |

Every auth email lands in Inbucket. Nothing is sent to a real address locally.

## Seeded accounts

Password for all of them: `supademo123!`

| Email | Workspace | Role |
| --- | --- | --- |
| `ada@supademo.test` | Acme Inc (Pro) | owner |
| `grace@supademo.test` | Acme Inc | member |
| `alan@supademo.test` | Globex Corp | owner |
| `outsider@supademo.test` | none | — |

`outsider@` exists so "can someone outside the tenant see this?" is one login
away rather than a fixture you have to build.

Also seeded: a pending invitation to `alan@supademo.test` for Acme, whose raw
token is literally `seed-invite-token`, and about 180 viewing sessions spread
over 30 days so the analytics RPCs return something with a shape.

## The loop

```bash
# 1. Write a migration
npx supabase migration new add_widget_table

# 2. Apply it from scratch — always from scratch, never incrementally
npm run db:reset

# 3. Regenerate types and run the suite
npm run gen:types
npm run test:db
```

`db:reset` re-runs everything from empty. That is the point: it is the only way
to catch a migration that happens to work against your database but not against
a new one.

If you prefer to explore in Studio first, `npm run db:diff -- add_widget_table`
writes the changes you made by hand into a migration file. Read it before
committing — the diff tool captures what changed, not what you meant.

## Useful commands

```bash
npm run verify           # everything CI runs
npm run db:lint          # schema linter (unindexed FKs, missing RLS, …)
npm run test:db          # pgTAP suite
npm run functions:serve  # serve all edge functions on :54321/functions/v1
npm run db:status        # local URLs and keys
```

## Edge functions

```bash
cp .env.example supabase/functions/.env.local   # then fill in what you need
npm run functions:serve
```

Only `RESEND_API_KEY` and the Stripe keys are worth setting locally, and only if
you are working on those paths. Without `RESEND_API_KEY` the email paths log
what they would have sent rather than failing, which is usually what you want.

Calling one:

```bash
# Public — no auth
curl http://127.0.0.1:54321/functions/v1/health

# The share endpoint (demoacme002 is seeded, shared by link)
curl 'http://127.0.0.1:54321/functions/v1/public-demo?id=demoacme002'

# Authenticated — grab the anon key from `npm run db:status`
curl -X POST http://127.0.0.1:54321/functions/v1/embed-document \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"document_id":"00000000-0000-4000-f000-000000000001"}'
```

The seed leaves document sections `pending` with no embedding on purpose: run
`embed-document` and watch the AI path fill them in.

## Optional extensions

`pgmq`, `pg_cron`, `pg_net` and `supabase_vault` are created best-effort
(migration 0000). If your image lacks one, migrations still apply and the
feature stays dormant with a notice — every reference to them sits inside a
PL/pgSQL body, which is not name-resolved until it runs.

Check what you actually got:

```sql
select extname from pg_extension order by 1;
select app.extension_enabled('pgmq');
```

To let `pg_cron` call an edge function, seed the two Vault secrets it needs:

```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres \
  -f scripts/bootstrap-secrets.sql \
  -v url="http://host.docker.internal:54321/functions/v1" \
  -v key="$(npx supabase status -o json | jq -r .SERVICE_ROLE_KEY)"
```

## Auth hooks

The three Postgres-backed hooks (custom access token, password verification, MFA
verification) are on by default and need no setup. Check the claims your token
actually carries:

```sql
select auth_hooks.custom_access_token(jsonb_build_object(
  'user_id', '00000000-0000-4000-a000-000000000001',
  'claims', '{}'::jsonb
));
```

The Send Email hook ships **disabled**. Enabling it without a deployed function
stops auth email entirely. To turn it on: set `AUTH_HOOK_SECRET`, run
`npm run functions:serve`, then flip `enabled = true` under
`[auth.hook.send_email]` and restart the stack.

## Troubleshooting

**A migration fails half way.** `db:reset` from scratch; migrations are
append-only and never edited after being pushed. If you need to change one you
have already pushed, write a new migration.

**`permission denied for table X`** — a grant is missing, or RLS has no matching
policy for that role. `\dp public.X` in psql shows the grants; `\d+ public.X`
lists the policies.

**`new row violates row-level security policy`** — the `WITH CHECK` failed. The
row would have been written somewhere the caller cannot see. Usually a missing
or wrong `organization_id`.

**Realtime is silent.** The table has to be in the publication *and* the client
has to be subscribed to the right topic. Broadcast topics are `org:<uuid>`; the
RLS policy on `realtime.messages` rejects anything else.

**Types look stale.** They are. `npm run gen:types` after every migration; CI
fails on a stale file.

**Port already in use.** Another project's stack is running: `npx supabase stop
--project-id <other>`, or change the ports in `config.toml`.
