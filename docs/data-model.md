# Data model

```
auth.users ──1:1──► profiles
                       │
                       ├──< organization_members >── organizations ──1:1── subscriptions ──► plans
                       │                                   │
                       │                                   ├──< organization_invites
                       │                                   ├──< api_keys
                       │                                   ├──< webhook_endpoints ──< webhook_deliveries (private)
                       │                                   ├──< usage_events / usage_daily
                       │                                   ├──< documents ──< document_sections   (pgvector)
                       │                                   └──< projects
                       │                                          │
                       │                                          └──< demos ──< demo_steps
                       │                                                  │
                       └──< demo_comments ◄───────────────────────────────┤
                                                                   ├──< demo_views
                                                                   └──< demo_leads
```

## Schemas

| Schema | Contents | Reachable from the API |
| --- | --- | --- |
| `public` | Tables, all with RLS. Client-callable RPCs. | Yes |
| `api` | Curated `security_invoker` views. | Yes |
| `app` | Helpers used by policies and clients (`is_org_member`, `entitlements`, …). | Execute only |
| `private` | Audit log, webhook deliveries, auth events, trigger functions. | **No** |
| `auth_hooks` | Functions GoTrue calls. | No — `supabase_auth_admin` only |
| `extensions` | Relocatable extensions. | Usage only |

## Tables

### Identity and tenancy

**`profiles`** — one row per `auth.users` row, created by a trigger and kept in
sync on email change. This, not `auth.users`, is what every other table's
foreign keys point at; clients must never read `auth.users` directly.
`is_admin` is staff-only and server-owned (a `BEFORE UPDATE` guard reverts any
client edit).

**`organizations`** — the tenant root. Created only through
`public.create_organization()`, which derives a unique slug and makes the caller
its owner in one transaction. There is deliberately no INSERT policy: a
plain insert would leave an organization with no members, and RLS applies its
SELECT policy to an INSERT's `RETURNING` clause before any `AFTER` trigger could
add one.

**`organization_members`** — the membership edge, keyed `(organization_id,
user_id)`. `role` is `public.org_role`, an enum declared **least- to
most-privileged** so the native ordering *is* the hierarchy:
`app.org_role(x) >= 'admin'` needs no lookup table. Two triggers protect it: an
organization can never lose its last owner, and nobody can change their own role
or grant one above their own.

**`organization_invites`** — only the SHA-256 of the token is stored. The raw
token is returned exactly once, by the RPC that creates the invite. A leaked
database dump therefore cannot be used to join an organization. A partial unique
index allows one live invite per address per organization while keeping
accepted and revoked rows for the audit trail.

### Billing

**`plans`** — reference data, readable by everyone including the marketing site.
`limits` is a jsonb quota map, so adding a limit is a data change rather than a
migration. `-1` means unlimited.

**`subscriptions`** — one row per organization, created automatically on a
14-day trial. Written **only** by the billing webhook running as `service_role`;
there is no client write policy. `limit_overrides` handles one-off deals without
inventing a plan.

**`usage_events` / `usage_daily`** — append-only meter and its nightly rollup.
Retention is 90 days for raw events; the aggregate is what reporting reads.

Quotas are enforced by `BEFORE INSERT` triggers calling `app.assert_quota()`,
which raises `check_violation` (`23514`) with a hint. Clients should surface the
message rather than pre-empting it, since the plan can change between render and
submit.

### The product

**`projects`** — a folder within an organization. Also the target of the
composite FKs below, via `unique (id, organization_id)`.

**`demos`** — the unit of work. Notable columns:

- `public_id` — an unguessable share id, the only handle an anonymous viewer
  ever sees. Generated with `app.short_id()`, whose alphabet omits vowels and
  look-alike characters.
- `visibility` — `private` | `link` | `public`; see the sharing model in
  [`architecture.md`](architecture.md).
- `search_vector` — generated `tsvector`, title weighted above description.
- `slug` — derived from the title and de-duplicated per organization by trigger,
  so clients never have to invent one.
- `deleted_at` — soft delete. Purged for real after 30 days by the retention job.

**`demo_steps`** — ordered steps. The `(demo_id, position)` unique constraint is
`DEFERRABLE INITIALLY DEFERRED`, so a client can reorder a whole demo in one
transaction without shuffling through temporary positions.

**`demo_comments`** — realtime collaboration. Viewers may comment: feedback is
the point of sharing a demo internally.

### Analytics

**`demo_views`** — one row per `(demo, session)`, upserted by
`public.track_demo_view()`. Sessions are metered once (detected with the
`xmax = 0` trick on the upsert), not on every heartbeat.

**`demo_leads`** — email captures from a demo CTA. Commercial data: readable by
`member` and above, not `viewer`.

### AI

**`documents` / `document_sections`** — chunked text plus a `vector(384)`
embedding, indexed with HNSW (`m=16, ef_construction=64`). HNSW rather than
IVFFlat because there is no training step and recall holds as rows arrive one at
a time, which is how documents actually arrive. `checksum` is a generated column
so re-embedding is skipped when content has not moved.

### Operations

**`webhook_endpoints`** — HTTPS only. The signing key is generated by a trigger
and stored in Vault; `secret_id` is the only reference the table holds.

**`api_keys`** — hashed machine credentials. The prefix is kept in the clear so
a UI can show `sk_a1b2c3d4…` next to "last used 3 hours ago".

**`notifications`** — the only field a recipient may change is `read_at`; a
guard trigger reverts everything else.

**`private.audit_log`** — generic change log written by `private.tg_audit()`,
attached to six tables. Redacts `token_hash`, `key_hash`, `secret` and noise
columns. Read through `public.audit_trail()`, which is admin-only.

## Conventions

- Primary keys are `uuid` with `gen_random_uuid()`, except append-only tables
  (`usage_events`, `demo_views`, `audit_log`, `auth_events`) which use identity
  bigints.
- Every table has `created_at`; every mutable table has `updated_at`, maintained
  by `private.attach_updated_at()`.
- Enums live in `public` so PostgREST exposes them and clients get literal
  union types.
- jsonb columns carry a `jsonb_typeof(...) = 'object'` check. An array where an
  object was expected is a bug that otherwise surfaces three layers away.
- Server-owned columns are protected by `private.tg_guard_columns()`, which
  silently reverts client edits rather than raising — a client that tries to set
  `is_admin` gets its row saved, minus the escalation.
