# Authentication

Supabase deals in three identities. Knowing which one you are holding explains
almost every "why can't I read this" question.

| Identity | What it is | Who may hold it | What enforces it |
| --- | --- | --- | --- |
| **anon / publishable key** | A JWT with `role=anon`. Identifies the *project*, not a caller. | Anyone. It ships in the client bundle. | RLS — which is why publishing it is safe |
| **user JWT** | Minted by GoTrue at sign-in. Carries `sub`, `role`, `aal` and our custom claims. Expires in an hour. | The signed-in user | RLS, via `auth.uid()` |
| **service_role / secret key** | Bypasses RLS entirely. | Servers only. Never a browser, never a mobile app. | Nothing — it is the trusted path |

This project adds a fourth for machines:

| **API key** | `sk_<prefix>_<secret>`, hashed at rest. Resolves to one organization and a scope list. | A customer's backend, CI | `public.authenticate_api_key()` |

## How a user request is authorized

```
browser ──► PostgREST ──► Postgres
   │            │             │
   │            │             └─ RLS policy calls auth.uid(), reads
   │            │                request.jwt.claims
   │            └─ verifies the JWT signature, sets role + claims
   └─ Authorization: Bearer <user JWT>   (plus apikey: <anon key>)
```

Nothing in application code decides access. The JWT sets `role` and
`request.jwt.claims` on the Postgres session; policies read them. That is why
the rules hold identically for a browser, a CLI and a mobile app —
see [`rls.md`](rls.md).

Three things worth knowing about the user path here:

- **`auth.uid()` is the authority, not the claims.** Our custom access token
  hook writes the caller's organizations and roles into `app_metadata`
  (migration 1300) so a UI knows what to render. Those claims are a snapshot,
  stale by up to the token's lifetime. No policy reads them.
- **`aal` gates the destructive things.** Deleting an organization and
  transferring ownership require `aal2`, i.e. a verified second factor.
- **Anonymous is a real identity.** `enable_anonymous_sign_ins` is on; an
  anonymous user gets a JWT with a `sub` like anyone else, so RLS still applies.

## How a machine request is authorized

```
customer backend ──► edge function (api-v1) ──► Postgres
        │                     │                    │
        │                     │                    └─ authenticate_api_key():
        │                     │                       hash → org + scopes
        │                     │                       → scope check
        │                     │                       → per-minute budget
        │                     │                       → meter + audit
        │                     └─ runs as service_role (RLS bypassed)
        └─ Authorization: Bearer sk_…
           or x-supademo-api-key: sk_…
```

### The key itself

Issued by `public.create_api_key()`, which returns the plaintext **once**:

```sql
select * from public.create_api_key(
  '<organization_id>', 'CI key', array['demos:read', 'analytics:read']);
```

```
 key_id | key_prefix  | api_key
 ...    | sk_a1b2c3d4 | sk_a1b2c3d4_9f3e…
```

Only `sha256(api_key)` is stored. A database dump therefore grants nothing —
which the test suite asserts directly, rather than trusting the comment.

The prefix is kept in the clear so a dashboard can show `sk_a1b2c3d4…` beside
"last used 3 hours ago" without being able to reconstruct the key.

### Scopes

`public.api_scopes` is the complete vocabulary, and a trigger rejects a key
carrying anything that is not in it. A typo like `demos:reed` fails at issue
time with `23514`, instead of producing a key that mysteriously 403s later.

| Scope | Grants |
| --- | --- |
| `demos:read` | List and read demos, including steps |
| `demos:write` | Create, update, publish |
| `analytics:read` | Views, completions, durations |
| `leads:read` | Email captures |
| `projects:read` | List projects |
| `documents:read` / `documents:write` | Knowledge base |

There is deliberately **no wildcard scope**. A `*` key is the one nobody
audits.

### Rate limiting

Per key, per minute, budgeted by the organization's plan — because a request
budget is an entitlement like any other, not a constant in application code:

| Plan | Requests / minute |
| --- | --- |
| free | 60 |
| pro | 600 |
| scale | 6000 |

Implemented as a fixed window in `private.api_rate_limits`. The counter is an
`INSERT … ON CONFLICT DO UPDATE … RETURNING`, so it is atomic: two concurrent
requests cannot both read the same count and both conclude they are under the
limit. A refusal carries `retry_after_seconds`, and the function turns that
into a `Retry-After` header — a 429 without one just makes clients guess, and
they guess badly.

### The part that actually prevents cross-tenant leaks

The edge function runs as `service_role`, which bypasses RLS. So "remember to
filter by organization" would be the only thing between one customer and
another's data — and that is exactly the kind of thing that gets forgotten in
the fifth endpoint.

Instead every read goes through a function that **takes** the organization id:

```sql
public.api_list_demos(p_organization_id uuid, …)
public.api_get_demo(p_organization_id uuid, p_public_id text)
public.api_demo_analytics(p_organization_id uuid, p_public_id text, …)
```

They are `service_role`-only and filter by that argument themselves. The edge
function has exactly one organization id — the one the key resolved to — so
forgetting the filter is not expressible. The suite asserts one tenant's demos
never appear in another's listing.

### Every attempt is recorded

`private.api_key_events` logs `ok`, `unknown_key`, `revoked`, `expired`,
`missing_scope` and `rate_limited`. Failed attempts are the signal that someone
is probing, so they belong in a log rather than the void. Admins read their own
via `public.api_key_activity()`.

Successful calls also write a `usage_events` row with metric `api_call`, so API
traffic lands on the same bill as everything else.

## Using it

```bash
# Everything this key can do
curl https://<project>.supabase.co/functions/v1/api-v1/whoami \
  -H "Authorization: Bearer sk_a1b2c3d4_…"

curl .../api-v1/demos
curl .../api-v1/demos/demoacme001
curl .../api-v1/demos/demoacme001/analytics
```

Both header forms work. `Authorization: Bearer` is what most HTTP clients reach
for; `x-supademo-api-key` exists because Supabase's own gateway also reads
`Authorization`, so on a function with `verify_jwt` enabled that header is
already spoken for.

Responses carry `X-RateLimit-Limit`, `X-RateLimit-Remaining` and
`X-RateLimit-Reset`.

### Failure codes

| Code | HTTP | Meaning |
| --- | --- | --- |
| `missing_key` | 401 | No key presented |
| `unknown_key` / `revoked` / `expired` | 401 | All three return the same message — telling them apart tells a prober whether a key was ever real |
| `missing_scope` | 403 | Valid key, wrong permission. The message names the scope needed |
| `rate_limited` | 429 | With `Retry-After` |

### Rotation

```sql
select * from public.rotate_api_key('<key_id>');            -- 24h grace
select * from public.rotate_api_key('<key_id>', '1 hour');
```

Issues a replacement and puts the old key on a fuse rather than killing it
immediately, so a deploy has a window to pick up the new value. `revoke_api_key`
is the immediate version, for when a key has leaked.

## What is deliberately not here

- **Third-party auth** (Clerk, Auth0, Firebase). Supabase supports it, and the
  RLS in this project would work unchanged since it only reads `auth.uid()`.
  Nothing needs it yet.
- **OAuth for machines.** Client-credentials flow is the right answer at the
  point where customers need scoped, revocable, per-integration access with
  short-lived tokens. API keys are the right answer before that, and pretending
  otherwise buys a token endpoint nobody asked for.
- **Per-endpoint scopes finer than the table.** `demos:read` covers all demos in
  the organization. Row-level grants for machines would need a policy language
  we do not have a use case for.
