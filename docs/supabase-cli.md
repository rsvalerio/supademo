# Working with the Supabase CLI

Everything in this repository runs through the CLI. There is no bespoke tooling
to learn, no hand-rolled migration runner, and no `psql` in any script — if you
know the CLI, you know this project.

The CLI is a **pinned devDependency**, not a global install, so everyone runs
the same version:

```json
"devDependencies": { "supabase": "2.113.0" }
```

`npm install` is the only setup step besides Docker. `npm run <script>` puts
`node_modules/.bin` on PATH, so the scripts call `supabase` directly;
`scripts/_cli.sh` finds the same binary when a script is run by hand.

## Getting started

```bash
npm install
npm run setup
```

`npm run setup` (`scripts/bootstrap.sh`) is a thin sequence of CLI calls:

| Step | Command | What it does |
| --- | --- | --- |
| 1 | — | Checks Docker is running |
| 2 | — | Creates `.env` and `supabase/functions/.env.local` |
| 3 | `supabase start` | Boots Postgres, GoTrue, PostgREST, Storage, Realtime, the edge runtime, Studio and Inbucket |
| 4 | `supabase db reset` | Replays every migration from empty, then the seed files |
| 5 | `supabase db query` | Seeds two Vault secrets so `pg_cron` can call edge functions |
| 6 | `supabase gen types` | Writes `packages/db-types/src/database.types.ts` |

Then it prints the URLs, keys and seeded logins.

## What the CLI is doing for you

`supabase start` is the interesting one. It brings up a complete Supabase
installation as containers — the same components a hosted project runs:

```
supabase_db_supademo          Postgres 17 with the Supabase extensions
supabase_auth_supademo        GoTrue     — sign-in, JWTs, auth hooks
supabase_rest_supademo        PostgREST  — the REST API over public + api
supabase_realtime_supademo    Realtime   — Postgres Changes and Broadcast
supabase_storage_supademo     Storage    — buckets, signed URLs, transforms
supabase_edge_runtime_supademo Deno       — the edge functions
supabase_studio_supademo      Studio     — the dashboard
supabase_inbucket_supademo    Inbucket   — catches every outbound email
supabase_pooler_supademo      Supavisor  — the transaction pooler
```

`supabase status` lists them with their URLs and keys.
`supabase services` shows which image version each is running, which is how you
tell whether your local Postgres matches the hosted one.

Two things worth understanding, because they explain most confusion:

- **`config.toml` is the source of truth for the local stack.** Change a setting
  there and restart; the CLI reconciles the containers. `supabase config push`
  applies the same file to a linked hosted project.
- **`supabase db reset` always starts from empty.** It does not apply "pending"
  migrations to your current database — it drops it and replays the lot, then
  seeds. That is deliberate: it is the only way to catch a migration that works
  against your database but not a fresh one.

## Everyday commands

Stack:

```bash
npm start              # supabase start
npm stop               # supabase stop           (keeps the data volume)
npm run stop:clean     # supabase stop --no-backup  (throws the data away)
npm run status         # URLs and keys
npm run status:json    # the same, machine-readable
npm run services       # image versions, local vs hosted
```

Schema:

```bash
npm run db:new add_widgets   # supabase migration new — creates a timestamped file
npm run db:reset             # replay everything + seed
npm run db:list              # local vs remote migration history
npm run db:up                # apply only what is pending (rarely what you want)
npm run db:diff my_change    # capture Studio edits as a migration file
npm run db:dump              # snapshot the current schema to supabase/schema.sql
```

Checks:

```bash
npm run db:lint        # typing errors in functions and views
npm run db:advisors    # the dashboard's Security + Performance advisors
npm run db:inspect     # table stats; see `supabase inspect db --help` for more
npm run test:db        # the pgTAP suite
npm run test:new name  # scaffold a new pgTAP test file
npm run verify         # everything CI runs
```

`db:advisors` is the one people miss. It runs the same checks as the dashboard's
Security Advisor — tables without RLS, `SECURITY DEFINER` views, functions with
a mutable `search_path`, unindexed foreign keys — and CI fails on any security
finding at error level.

Ad-hoc SQL, without needing a Postgres client installed:

```bash
npm run db:query "select id, name, price_cents from api.plans order by sort_order"
npm run db:query -- --file supabase/tests/00_structure.test.sql
```

Types:

```bash
npm run gen:types          # TypeScript, from the local stack
npm run gen:types:swift    # the same schema as Swift, for a future mobile app
```

`supabase gen types` also speaks Go and Python. The schema is the interface, so
each client generates its own binding rather than sharing a hand-written one.

Edge functions:

```bash
npm run functions:serve         # serve all of them, hot-reloading
npm run functions:new my-fn     # scaffold one
npm run functions:list          # what is deployed
npm run functions:deploy        # deploy all (respects verify_jwt per function)
```

Hosted project:

```bash
npm run link -- --project-ref abcdefgh
npm run db:push        # apply migrations to the linked project
npm run db:pull        # capture remote drift as a migration
npm run config:push    # push config.toml (auth settings, API config)
npm run secrets:set    # upload supabase/functions/.env.local as function secrets
npm run secrets:list
```

## Where files live, and what resolves relative to what

This trips people up, so it is worth stating plainly:

| Setting | Path is relative to |
| --- | --- |
| `[db.seed] sql_paths` | `supabase/` |
| `[db.migrations] schema_paths` | `supabase/` |
| `[auth.email.template.*] content_path` | **the project root** |

That is why the template paths in `config.toml` read
`./supabase/templates/invite.html` while the seed glob reads `./seeds/*.sql`.
It looks like a typo. It is not.

## Seeds

`[db.seed] sql_paths` accepts globs, so fixtures are split by concern rather
than piling into one file:

```
supabase/seeds/01_users.sql
supabase/seeds/02_organizations.sql
supabase/seeds/03_projects_and_demos.sql
supabase/seeds/04_traffic.sql
supabase/seeds/05_knowledge_and_integrations.sql
```

They run in filename order, so the numeric prefixes are load-bearing. Drop a new
file in and the next `db reset` picks it up.

## Storage buckets

Buckets are created in a migration, not in a `[storage.buckets]` block.

The CLI can seed buckets from config (`supabase seed buckets`, including
uploading local files via `objects_path`), and it is genuinely convenient — but
it is local-only, so a hosted project would still need the migration. Declaring
buckets in both places invites the two to drift. The migration upserts, so one
definition covers every environment.

If you want local *objects* as well as buckets, add an `objects_path` block for
local development only, and keep the bucket definitions where they are.

## Testing

`supabase test db` runs pgTAP through `pg_prove` against the local database.

Each test file creates the pgTAP extension **inside its own transaction**:

```sql
begin;
create extension if not exists pgtap;
set local search_path to public, extensions;
select plan(14);
...
select * from finish();
rollback;
```

The rollback takes the extension with it, so `supabase test db` needs no setup
step and no deployed database carries a thousand assertion functions it will
never call. (The Supabase docs suggest enabling pgTAP in a migration instead;
that works too, and is the trade you want if test startup time ever matters more
than a clean production schema.)

Note that tests run against the **seeded** database — `supabase test db` does not
reset first. Scope assertions to your own fixtures; a bare `count(*)` will
count the seed's rows too.

## Deploying

CI does this on merge (`.github/workflows/deploy.yml`), but by hand it is:

```bash
export SUPABASE_PROJECT_REF=abcdefgh
npm run link -- --project-ref "$SUPABASE_PROJECT_REF"
npm run db:list          # confirm what is about to run
npm run db:push
npm run secrets:set
npm run functions:deploy
bash scripts/bootstrap-secrets.sh --linked   # Vault entries for pg_cron
```

`supabase db push` applies only migrations the remote has not seen, tracked in
`supabase_migrations.schema_migrations`. If that history and your files ever
disagree — usually because someone ran SQL in the dashboard —
`supabase migration repair` is how you reconcile them. Do not edit a migration
that has already been pushed; write a new one.

## Things the CLI does that are easy to miss

- `supabase db diff -f name` writes the changes you made in Studio into a proper
  migration. Read it before committing; it captures what changed, not what you
  meant.
- `supabase migration squash` collapses a long migration history into one file.
  Useful before a first production deploy, dangerous afterwards.
- `supabase inspect db` has a whole family of reports — `bloat`, `outliers`,
  `long-running-queries`, `index-stats`, `locks`, `blocking`, `vacuum-stats`.
  Run them against a linked project with `--linked`.
- `supabase gen bearer-jwt` mints a token for poking at the API by hand.
- `supabase bootstrap` starts a brand-new project from a starter template —
  which is where a repository like this one begins.
