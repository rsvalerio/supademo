# Working with the Supabase CLI

Everything in this repository runs through the CLI. There is no bespoke tooling
to learn, no hand-rolled migration runner, and no `psql` in any script — if you
know the CLI, you know this project.

## The only prerequisite is Docker

Not Node, not npm, not a globally installed CLI, not Postgres client tools.

```bash
git clone … && cd supademo
make setup
```

`./supa` resolves the CLI on first use: it downloads the pinned version from the
npm registry over plain HTTPS, checks its SHA-512 against the table in
`scripts/toolchain.lock`, and caches it in `.toolchain/` (gitignored). About three
seconds, once. After that it is the real CLI, unmodified — every flag and
subcommand behaves exactly as documented upstream.

```bash
./supa <any supabase command>    # the CLI itself
make <task>                      # the composite tasks
make help                        # what those tasks are
```

Every `make` target is one line that runs a script in `scripts/`; the shared
functions live in `scripts/lib/`. So `make` is a convenience, not a dependency —
`bash scripts/setup.sh` does the same thing, which matters on a machine without
the Xcode command line tools. `npm run …` aliases exist for muscle memory too.

### Why not run the CLI in a container too?

It is the obvious question, since Docker is required anyway. Three things make
it a worse trade than a pinned binary:

1. **It needs the Docker socket.** The CLI's whole job is starting containers,
   so a containerised CLI needs `/var/run/docker.sock` mounted — Docker-out-of-
   Docker, with the privilege that implies.
2. **Paths stop matching.** The CLI passes host paths to the daemon when it
   bind-mounts your migrations and functions into the stack. Inside a container
   those paths are its own, so the project must be mounted at its *own absolute
   path* to keep the two views aligned.
3. **Networking.** After `start`, the CLI connects to `127.0.0.1:54322` — which
   inside a container is that container's loopback, not the host's. It needs
   host networking, which is fine on Linux and opt-in on Docker Desktop.

A checksum-pinned binary gives the same reproducibility with none of that. Where
a container genuinely is the right answer — Deno, which needs nothing from the
host but the source tree — that is exactly what `make fmt` and `make check` do:
use a local `deno` if there is one, otherwise `docker run denoland/deno`.

So the floor is: **Docker, a POSIX shell, `curl` and `tar`.** Docker is
irreducible (the local stack *is* containers); the rest ship with macOS and
every Linux distribution. On Windows, use WSL.

## Getting started

`make setup` (`scripts/setup.sh`) is a thin sequence of CLI calls:

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

`make` covers the composite tasks; anything else is `./supa <command>`.

Stack:

```bash
make start                     # boot the local stack
make stop                      # shut it down, keeping the data volume
make status                    # URLs and keys
./supa stop --no-backup       # shut down and throw the data away
./supa status -o env          # the same status, shell-shaped
./supa services               # image versions, local vs hosted
```

Schema:

```bash
make new name=add_widgets           # supabase migration new — a timestamped file
make reset                     # replay every migration from empty, then seed
./supa migration list         # local vs remote migration history
./supa migration up           # apply only what is pending (rarely what you want)
./supa db diff -f my_change   # capture Studio edits as a migration
./supa db dump --local -f supabase/schema.sql
```

Checks:

```bash
make doctor                    # preflight: tools, ports, stack state
make lint                      # typing errors in functions and views
make advisors                  # the dashboard's Security + Performance advisors
make test                      # the pgTAP suite
make verify                    # everything CI runs
./supa test new my_test       # scaffold a pgTAP test file
./supa inspect db table-stats --local
```

`make advisors` is the one people miss. It runs the same checks as the
dashboard's Security Advisor — tables without RLS, `SECURITY DEFINER` views,
functions with a mutable `search_path`, unindexed foreign keys — and CI fails on
any security finding at error level.

Ad-hoc SQL, without a Postgres client installed:

```bash
make query sql="select id, name, price_cents from api.plans order by sort_order"
./supa db query --local --file some-script.sql
```

Types:

```bash
make types                     # TypeScript, from the local stack
./supa gen types --local --lang swift --schema public,api
```

`supabase gen types` also speaks Go and Python. The schema is the interface, so
each client generates its own binding rather than sharing a hand-written one.

Edge functions:

```bash
make serve                     # serve all of them, hot-reloading
make fmt                       # format (--check to verify only)
make check                     # lint + typecheck
./supa functions new my-fn    # scaffold one
./supa functions list         # what is deployed
make deploy                    # deploy all (respects verify_jwt per function)
```

Hosted project:

```bash
./supa link --project-ref abcdefgh
./supa db push --linked       # apply migrations to the linked project
./supa db pull --linked       # capture remote drift as a migration
./supa config push            # push config.toml (auth settings, API config)
./supa secrets set --env-file supabase/functions/.env.local
./supa secrets list
```

## How the scripts are organised

```
Makefile              one line per target: run a script
supa                  the Supabase CLI itself, resolved and pinned
scripts/
  toolchain.lock      pinned tool versions + per-platform SHA-512 (data, not code)
  lib/
    init.sh           the only thing task scripts source; loads the rest in order
    log.sh            bold/step/pass/info/miss/warn/fail — all output goes here
    env.sh            ROOT, .env loading, ensure_env_file
    guard.sh          require_cmd/require_docker/require_stack, port_in_use
    vendor.sh         download + checksum + cache, shared by both pinned tools
    cli.sh            the Supabase CLI: platform naming, resolution
    bun.sh            Bun: platform naming, resolution, bun_run
    status.sh         status_value, api_url, anon_key, service_key, ports
    deno.sh           deno_run — local deno, else the official image
  setup.sh            first run
  doctor.sh           preflight report
  verify.sh           everything CI runs
  stack.sh            start|stop|restart|status|clean
  db.sh               reset|new|test|lint|advisors|query|list|dump
  functions.sh        serve|fmt|check|new|list|deploy   (edge functions: Deno)
  js.sh               install|typecheck|test|run        (packages/ + apps/: Bun)
  types.sh            regenerate packages/db-types
  secrets.sh          seed Vault entries for scheduled jobs
  update-toolchain.sh re-pin a tool in toolchain.lock
```

Two conventions worth keeping:

- **Task scripts define functions and call `main` at the bottom.** The dispatch
  `case` is the last thing in the file, so reading top-to-bottom gives you the
  pieces before the wiring.
- **`scripts/lib/` never runs anything on its own.** Sourcing it defines
  functions and resolves the CLI; it does not start containers or print
  reports. That is what makes the libraries safe to reuse from any script.

## Two runtimes, on purpose

| Where | Runtime | Why |
| --- | --- | --- |
| `supabase/functions/` | **Deno** | Not a choice. The Supabase Edge Runtime is a Deno fork, and the functions use `Deno.serve`, `EdgeRuntime.waitUntil` and `Supabase.ai` — none of which exist elsewhere. `deno check` is also the only type checker that understands `npm:` specifiers the way the runtime resolves them. |
| `packages/`, `apps/` | **Bun** | Ordinary TypeScript for clients. Bun is one binary instead of node+npm, and it is fast. |

Neither has to be installed. Bun is vendored exactly like the CLI; Deno runs
from its official image when absent, which costs nothing because it only ever
formats, lints and typechecks.

Backend work — migrations, seeds, RLS, tests — touches neither.

## Upgrading a pinned tool

Versions and per-platform checksums live in `scripts/toolchain.lock`:

```bash
bash scripts/update-toolchain.sh supabase 2.114.0
bash scripts/update-toolchain.sh bun 1.3.15
rm -rf .toolchain && make doctor
```

That rewrites just that tool's block from the registry's own integrity hashes,
so an upgrade is a reviewable diff rather than a silent "latest" that behaves
differently on your laptop than in CI.

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
./supa link -- --project-ref "$SUPABASE_PROJECT_REF"
./supa migration list          # confirm what is about to run
./supa db push --linked
./supa secrets set --env-file supabase/functions/.env.local
make deploy
bash scripts/secrets.sh --linked   # Vault entries for pg_cron
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
