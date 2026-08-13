# Architecture

## The shape of it

```
                        ┌──────────────────────────────┐
   future apps/  ─────►  │  PostgREST     (public, api) │
   (web, cli,            │  GoTrue        (auth)        │
    desktop, mobile)     │  Storage       (4 buckets)   │
                         │  Realtime      (changes +    │
                         │                 broadcast)   │
                         └───────────────┬──────────────┘
                                         │  every request carries a JWT
                                         ▼
                         ┌──────────────────────────────┐
                         │  Postgres                    │
   edge functions  ────►  │   public   tables + RLS      │
   (8, Deno)             │   api      curated views     │
                         │   app      policy helpers    │
                         │   private  internals         │
                         │   auth_hooks  GoTrue hooks   │
                         └───────────────┬──────────────┘
                                         │
              pg_cron ──► pgmq queues, pg_net webhooks, Vault secrets
```

There is no application server. That is the point: authorization lives in the
database, so it holds no matter which client is talking — a browser today, a CLI
and a mobile app later, all against the same rules.

## Decisions worth knowing about

### Authorization lives in RLS, not in code

Every table in `public` has RLS enabled and at least one policy, and
`supabase/tests/00_structure.test.sql` fails the build if that stops being true.
Policies never inline a membership subquery; they call `app.is_org_member()` or
`app.has_org_role()`, which are `SECURITY DEFINER` and therefore do not
re-enter RLS. That is what keeps the membership table's own policies from
recursing into themselves, and it means the rule exists in exactly one place.

### Tenant id is denormalized, and cannot drift

Child tables (`demo_steps`, `demo_comments`, `demo_leads`, `document_sections`)
carry their own `organization_id`, so every policy is a single-table predicate
rather than a join. The usual objection — denormalized columns go stale — is
answered by a composite foreign key against `(id, organization_id)` on the
parent. Writing a mismatched pair is a constraint violation, not a silent leak.

### Three ways in, one set of rules

| Caller | Identity | Enforced by |
| --- | --- | --- |
| Signed-in user | Supabase JWT | RLS, via `auth.uid()` |
| Anonymous viewer | none | `SECURITY DEFINER` RPCs that re-derive the tenant from the share id |
| Machine | `x-supademo-api-key` | `public.verify_api_key()`, service-role only |

An anonymous viewer never writes to a table directly. `track_demo_view` and
`capture_demo_lead` take a share id, look up which organization it belongs to,
and write on the caller's behalf — so traffic cannot be attributed to an
organization the caller does not already have a link to.

### Link-sharing is not listing

`visibility` has three values, and the middle one is the interesting one.
`public` demos are visible to `anon` through an ordinary RLS policy and appear
in `api.demo_directory`. `link` demos are visible to nobody through RLS at all;
they are reachable only via `public.get_public_demo(share_id)`, which returns
`NULL` for both "no such demo" and "not shared". Holding a link is therefore
never a licence to enumerate, and probing cannot distinguish a wrong id from an
unshared one.

### Two realtime mechanisms, deliberately

Postgres Changes is used for the four collaborative, low-volume tables
(`demos`, `demo_steps`, `demo_comments`, `notifications`) where per-row
filtering per subscriber is affordable. Broadcast on a private `org:<uuid>`
topic is used for everything that has to scale: one RLS check on
`realtime.messages` authorizes the whole stream instead of re-filtering every
row for every listener. `demo_steps` and `demo_comments` also carry
`REPLICA IDENTITY FULL` so subscribers get the previous row on update and can
reconcile a change they did not originate.

### Slow work never happens in the request path

Two mechanisms, chosen per job:

- **pgmq** (`embeddings`, `emails`) — enqueued in the same transaction as the
  change that caused it, so a write either records the fact *and* the intent to
  react to it, or neither. The `queue-worker` edge function drains them at
  least once, with a visibility timeout, so handlers must be idempotent. A
  message that fails five times is archived, not deleted: a poison message is
  evidence.
- **A durable table + `pg_net`** (webhooks) — deliveries live in
  `private.webhook_deliveries` with an exponential backoff clock. `pg_net` is
  asynchronous, so sending and settling are separate passes: `drain_webhooks()`
  posts, `reconcile_webhooks()` reads `net._http_response` and closes the loop.

Embeddings go through a queue because inference is slow and belongs outside a
transaction. Webhooks do not, because retry state is exactly what a table is
good at and the send has to happen from inside Postgres to reach the Vault-held
signing key.

### Secrets stay in the database

Webhook signing keys are generated by a trigger and stored with
`vault.create_secret()`. No code path holds one in plaintext; `deliver_webhook`
decrypts it, signs, and discards it inside a single function call. The same
applies to the credentials `pg_cron` needs to call an edge function — see
`scripts/secrets.sh`.

### Embeddings are local

`gte-small` ships inside the Supabase Edge Runtime, so `embed-document` needs no
external inference API, no key to rotate, and no per-token bill. It produces
384-dimensional vectors, which is why `document_sections.embedding` is
`vector(384)`. Search is hybrid: keyword and vector rankings merged with
Reciprocal Rank Fusion, because keyword search misses paraphrases and vectors
miss rare exact terms, and RRF combines the two rankings without needing their
scores to be comparable.

### Storage paths carry the authorization context

```
avatars        users/<user_id>/<filename>
org-branding   orgs/<organization_id>/<filename>
demo-assets    orgs/<organization_id>/demos/<demo_id>/<filename>
exports        orgs/<organization_id>/<job_id>.<ext>
```

Policies read the second path segment (`app.storage_scope_id`) and check
membership. That makes every storage check a prefix comparison rather than a
join. Build paths with the helpers in `@supademo/shared` — an ad-hoc path is a
silent 403.

`demo-assets` is private. Anonymous viewers of a shared demo never touch the
bucket: the `public-demo` function mints short-lived signed URLs server-side.
Public buckets serve transformed images (`publicAssetUrl(..., {width})`), which
is cheaper than generating and storing thumbnails.

### JWT claims are a hint, not an authority

`auth_hooks.custom_access_token` writes the caller's organizations, roles and
plan into `app_metadata` so a client knows what to render without a round trip.
Those claims are a snapshot, stale by up to the token's one-hour lifetime.
Nothing in RLS reads them — policies always go to the membership tables. Clients
should treat them as "what to grey out", never "what to allow".

### Destructive actions require a second factor

Deleting an organization and transferring ownership check
`app.is_mfa_verified()` (`aal2` in the JWT). This is the one place where the
assurance level, rather than the role, decides.

## Failure behaviour

| If this breaks | What happens |
| --- | --- |
| An auth hook raises | It is caught and the original claims are returned. A broken hook must never lock everyone out. |
| A realtime broadcast fails | Warned and swallowed. A notification failure must not roll back the write that caused it. |
| pgmq / pg_net / pg_cron missing | The feature stays dormant with a notice. Migrations still apply — every reference sits inside a PL/pgSQL body, which is not name-resolved until it runs. |
| An embedding fails | That section is marked `failed` with the error; the rest of the document still indexes. |
| A billing webhook arrives twice | Handling is idempotent; Stripe retries and reorders, and the schema assumes it. |
| A subscription lapses | Writes are blocked (`app.is_org_active`), reads keep working. Nobody is locked out of their own data over an expired card. |
