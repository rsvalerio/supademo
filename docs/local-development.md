# Local development

## Prerequisites

**Docker.** That is the list.

The local stack is a set of containers, so a container runtime is irreducible.
Everything else the project needs — the Supabase CLI, and Deno for the edge
functions — is fetched on demand: the CLI as a checksum-pinned binary cached in
`.supabase-cli/`, Deno via its official image when it is not already installed.

You do **not** need Node, npm, a global Supabase CLI, Postgres, or `psql`.
(Node only becomes relevant when a frontend lands in `apps/`.) On Windows, run
this from WSL.

`./x doctor` reports exactly what is present and what is missing, checks the
ports the stack wants, and exits non-zero if a hard requirement is absent — so
it works as a preflight check in a script too. The scripts also check for
themselves: `./x start` and friends fail with a plain message if the Docker
daemon is not running, rather than surfacing a socket error.

## First run

```bash
./x setup
```

That checks Docker, creates `.env`, boots the stack (`supabase start`), applies
every migration and seed file (`supabase db reset`), seeds the Vault entries
scheduled jobs need, generates types, and prints everything below.
`./x help` lists the tasks; `./supa <command>` is the raw CLI. See
[`supabase-cli.md`](supabase-cli.md) for the full tour.

The important local URLs:

| Service | URL |
| --- | --- |
| API | http://127.0.0.1:54321 |
| Studio | http://127.0.0.1:54323 |
| Postgres | postgresql://postgres:postgres@127.0.0.1:54322/postgres |
| Inbucket (mail catcher) | http://127.0.0.1:54324 |

Every auth email lands in Inbucket. Nothing is sent to a real address locally.

`./x status` reprints these at any time; `./supa status -o env` gives the
same thing machine-readably, which is how the scripts read the anon and service
keys.

## The lifecycle

### Day 1 — a fresh clone

```bash
git clone <repo> && cd supademo
./x doctor      # optional: what is present, what is missing, what ports are busy
./x setup       # everything else
```

`./x setup` is idempotent. Run it again any time; it will not duplicate
anything.

### Every day

```bash
./x start       # ~30s cold, a few seconds warm
… work …
./x stop        # or leave it running
```

`./x stop` keeps the data volume, so the next `start` has your data. To throw
it away, `./supa stop --no-backup`.

### Making a schema change

```bash
./x new add_widget_table     # creates supabase/migrations/<timestamp>_add_widget_table.sql
$EDITOR supabase/migrations/*_add_widget_table.sql
./x reset                    # replay everything from empty, then seed
./x types                    # regenerate packages/db-types
./x test                     # pgTAP
./x advisors                 # did the new table forget RLS?
```

Always `reset`, never "apply just the new one". Replaying from empty is the only
thing that catches a migration which works against *your* database but not a
fresh one — which is the database CI and production both have.

Prefer clicking around in Studio first? Do that, then capture it:

```bash
./supa db diff -f add_widget_table
```

Read what it wrote before committing. The diff captures what changed, not what
you meant.

### Working on edge functions

```bash
./x serve                    # hot-reloads on save
# in another shell:
curl http://127.0.0.1:54321/functions/v1/health
./x check                    # lint + typecheck
```

### Before pushing

```bash
./x verify
```

That is exactly what CI runs: reset, lint, advisors, pgTAP, function checks, and
a stale-types check. If it passes locally it passes in CI, because both call the
same scripts through the same pinned CLI.

### Starting over

```bash
./supa stop --no-backup      # drop the data volume
./x setup                    # rebuild from migrations + seed
```

Cheap by design. Nothing local is precious — the seed rebuilds it.

### Where state actually lives

| State | Lives in | Survives `./x stop`? | Survives `--no-backup`? |
| --- | --- | --- | --- |
| Your schema | `supabase/migrations/` (git) | yes | yes |
| Fixture data | `supabase/seeds/` (git) | yes | yes |
| Rows you created by hand | Docker volume | yes | **no** |
| Storage objects | Docker volume | yes | **no** |
| The CLI binary | `.supabase-cli/` (gitignored) | yes | yes |
| Generated types | `packages/db-types/` (git) | yes | yes |

The rule of thumb: if it matters, it is in git as a migration or a seed file. If
it is only in the volume, treat it as scratch.

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

Fixtures live in `supabase/seeds/*.sql` and are applied in filename order by
`supabase db reset`. Drop a new numbered file in and it is picked up on the next
reset.

## The loop

```bash
# 1. Write a migration
./x new add_widget_table

# 2. Apply it from scratch — always from scratch, never incrementally
./x reset

# 3. Regenerate types and run the checks
./x types
./x test
./x advisors
```

`db:reset` re-runs everything from empty. That is the point: it is the only way
to catch a migration that happens to work against your database but not against
a new one.

If you prefer to explore in Studio first, `./supa db diff -f add_widget_table`
writes the changes you made by hand into a migration file. Read it before
committing — the diff tool captures what changed, not what you meant.

## Useful commands

```bash
./x verify           # everything CI runs
./x lint          # typing errors in functions and views
./x advisors      # the dashboard's Security + Performance advisors
./supa migration list          # local vs remote migration history
./supa inspect db table-stats --local       # table stats (see `supabase inspect db --help` for more)
./x test          # pgTAP suite
./x serve  # serve all edge functions on :54321/functions/v1
./x status           # local URLs and keys
```

Ad-hoc SQL without a Postgres client installed:

```bash
./x query "select id, name, price_cents from api.plans order by sort_order"
```

## Edge functions

```bash
./x serve
```

That creates `supabase/functions/.env.local` from `.env.example` on first run —
the CLI refuses to start if `--env-file` points at a missing file, and that
file is gitignored because it holds credentials.

Only `RESEND_API_KEY` and the Stripe keys are worth setting locally, and only if
you are working on those paths. Without `RESEND_API_KEY` the email paths log
what they would have sent rather than failing, which is usually what you want.

Calling one:

```bash
# Public — no auth
curl http://127.0.0.1:54321/functions/v1/health

# The share endpoint (demoacme002 is seeded, shared by link)
curl 'http://127.0.0.1:54321/functions/v1/public-demo?id=demoacme002'

# Authenticated — the anon key comes from `./x status`
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

```bash
./x query "select extname from pg_extension order by 1"
./x query "select app.extension_enabled('pgmq')"
```

`./x setup` already seeds the two Vault secrets `pg_cron` needs to call an
edge function. To redo it after a reset:

```bash
bash scripts/bootstrap-secrets.sh            # local
bash scripts/bootstrap-secrets.sh --linked   # a linked project
```

## Auth hooks

The three Postgres-backed hooks (custom access token, password verification, MFA
verification) are on by default and need no setup. Check the claims your token
actually carries:

```bash
./x query "select auth_hooks.custom_access_token(jsonb_build_object(
  'user_id', '00000000-0000-4000-a000-000000000001', 'claims', '{}'::jsonb))"
```

The Send Email hook ships **disabled**. Enabling it without a deployed function
stops auth email entirely. To turn it on: set `AUTH_HOOK_SECRET`, run
`./x serve`, then flip `enabled = true` under
`[auth.hook.send_email]` and restart the stack.

## Troubleshooting

**A migration fails half way.** `db:reset` from scratch; migrations are
append-only and never edited after being pushed. If you need to change one you
have already pushed, write a new migration.

**`permission denied for table X`** — a grant is missing, or RLS has no matching
policy for that role. Studio's Table Editor shows both, or:

```bash
./x query "select grantee, privilege_type from information_schema.role_table_grants where table_name = 'X'"
./x query "select policyname, cmd, roles, qual from pg_policies where tablename = 'X'"
```

**`new row violates row-level security policy`** — the `WITH CHECK` failed. The
row would have been written somewhere the caller cannot see. Usually a missing
or wrong `organization_id`.

**Realtime is silent.** The table has to be in the publication *and* the client
has to be subscribed to the right topic. Broadcast topics are `org:<uuid>`; the
RLS policy on `realtime.messages` rejects anything else.

**Types look stale.** They are. `./x types` after every migration; CI
fails on a stale file.

**Port already in use.** Another project's stack is running. `./supa stop
--project-id <other>` stops it, or change the ports in `config.toml`.

**A container will not come up.** `./x status` shows what is missing and
`./supa services` shows image versions. `./supa stop --no-backup` throws the data
volume away and starts over — the seed makes that cheap.
