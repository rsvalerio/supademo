# Supademo

A backend-first reference application built on Supabase. It models a small but
realistic multi-tenant SaaS (organizations → projects → interactive demos) and
deliberately exercises as much of the Supabase platform as possible, so it can
double as a playground for trying out new Supabase features.

There is **no frontend yet**. Everything here is the platform layer: database,
policies, functions, jobs and generated types. The repository is laid out as a
workspace so `apps/web`, `apps/cli`, `apps/desktop` and `apps/mobile` can be
dropped in later without moving anything.

---

## What is exercised

| Area | Feature | Where |
| --- | --- | --- |
| Database | Schemas, enums, constraints, generated columns | `supabase/migrations/` |
| Database | Row Level Security on every table | `supabase/migrations/`, `docs/rls.md` |
| Database | `SECURITY DEFINER` helpers, RPC surface | `..._organizations.sql`, `..._rpc.sql` |
| Database | Triggers, audit log, soft deletes | `..._audit.sql` |
| Database | Full-text search (`tsvector`) + trigram | `..._projects_demos.sql` |
| Database | `pgvector` semantic + hybrid search (RRF) | `..._ai_search.sql` |
| Database | Partition-friendly analytics + rollups | `..._analytics.sql` |
| Auth | Email/password, OAuth, magic link, anonymous | `supabase/config.toml` |
| Auth | MFA (TOTP), AAL-aware policies | `supabase/config.toml`, `..._organizations.sql` |
| Auth | Custom Access Token hook (org claims in JWT) | `..._auth_hooks.sql` |
| Auth | Password verification attempt hook | `..._auth_hooks.sql` |
| Auth | Send Email hook → Edge Function | `supabase/functions/auth-email-hook/` |
| Auth | `auth.users` → `public.profiles` sync trigger | `..._profiles.sql` |
| Storage | Public + private buckets, per-org path policies | `..._storage.sql` |
| Storage | Image transformations, signed URLs | `docs/architecture.md` |
| Realtime | Postgres Changes publication | `..._realtime.sql` |
| Realtime | Private channels + `broadcast_changes` | `..._realtime.sql` |
| Realtime | Presence-ready channel naming convention | `docs/architecture.md` |
| Edge Functions | Deno functions, shared lib, CORS, JWT verify | `supabase/functions/` |
| Edge Functions | Built-in AI inference (`gte-small`) | `supabase/functions/embed-document/` |
| Edge Functions | Background tasks (`EdgeRuntime.waitUntil`) | `supabase/functions/queue-worker/` |
| Queues | `pgmq` queues + worker drain loop | `..._queues.sql`, `functions/queue-worker/` |
| Cron | `pg_cron` schedules for rollups and workers | `..._cron.sql` |
| Webhooks | `pg_net` outbound delivery with retries | `..._queues.sql` |
| Vault | Encrypted secrets for outbound integrations | `..._queues.sql` |
| API | PostgREST views, RPC, API keys for machines | `..._rpc.sql` |
| Testing | pgTAP unit + RLS tests | `supabase/tests/` |
| Tooling | Typed clients generated from the schema | `packages/db-types/` |
| Tooling | CLI-driven: start, reset, lint, advisors, gen types, deploy | `docs/supabase-cli.md` |
| CI/CD | Lint, advisors, test, migration check, deploy | `.github/workflows/` |

## Layout

```
.
├── apps/                    # reserved for future frontends (web, cli, desktop, mobile)
├── packages/
│   ├── db-types/            # generated database.types.ts (source of truth for clients)
│   └── shared/              # framework-agnostic domain types, zod schemas, client factory
├── supabase/
│   ├── config.toml          # local stack + hosted project settings
│   ├── migrations/          # ordered, immutable SQL migrations
│   ├── functions/           # Deno edge functions
│   ├── tests/               # pgTAP tests (`supabase test db`)
│   ├── seeds/               # globbed seed files, applied in filename order
│   └── templates/           # auth email templates
├── scripts/                 # dev helpers (typegen, reset, verify)
├── docs/                    # architecture, data model, RLS, roadmap
└── .github/workflows/       # CI + deploy
```

## Quick start

**Docker is the only prerequisite.** No Node, no npm, no globally installed
Supabase CLI, no Postgres client tools.

```bash
make setup
```

`./supa` fetches the pinned CLI on first use — a checksum-verified binary from
the npm registry, cached in `.supabase-cli/` — then `make setup` runs
`supabase start`, `db reset`, `db query` and `gen types`, and prints the local
URLs, keys and seeded logins.

```bash
make doctor      # what is installed, what is missing, what ports are busy
make test        # pgTAP suite
make advisors    # the dashboard's security + performance lints
make verify      # everything CI runs
make help        # every task
./supa <cmd>    # the CLI itself, unmodified
```

The `Makefile` is deliberately thin: every target is one line that runs a
script in `scripts/`, which is where the logic lives. `npm run …` aliases call
the same scripts, so neither `make` nor Node is load-bearing.
The day-to-day lifecycle is in
[`docs/local-development.md`](docs/local-development.md#the-lifecycle).

CI runs the same `./supa` resolver rather than an install action, so tooling
cannot drift between a laptop and a build agent.

Everything here goes through the Supabase CLI — no `psql`, no bespoke migration
tooling. [`docs/supabase-cli.md`](docs/supabase-cli.md) is the command tour and
explains why the CLI is pinned rather than containerised;
[`docs/local-development.md`](docs/local-development.md) is the daily loop;
[`docs/roadmap.md`](docs/roadmap.md) covers how frontends slot in.

## Conventions

- Migrations are **append-only**. Never edit a migration that has been pushed;
  add a new one.
- Every table in `public` has RLS enabled and at least one policy. Tables with
  no policy are unreachable by design and live in `private`.
- Tenant scoping is always by `organization_id`, checked through the helpers in
  the `app` schema — never by inlining a subquery in a policy.
- Anything a client is allowed to call is either a table with policies, a view
  in `api`, or a `SECURITY DEFINER` function with an explicit `search_path`.
