# Data model

```
auth.users ──1:1──► profiles ──< organization_members >── organizations
                                                               │
                                                               ├──< organization_invites
                                                               ├──< api_keys
                                                               ├──1:1── subscriptions ──► plans
                                                               ├──< webhook_endpoints ──< webhook_deliveries (private)
                                                               ├──< usage_events / usage_daily
                                                               ├──< documents ──< document_sections   (pgvector)
                                                               │
                                                               ├──< ingredients ──< inventory_movements
                                                               ├──< products                  ▲
                                                               ├──< customers                 │ consumption / release
                                                               └──< orders ──< order_items ───┘

products >── product_ingredients ──< ingredients        (the recipe)
orders ──< order_items ──► products                     (nullable: the line outlives the product)

allergens  ──►  ingredients.allergens  ──►  products.allergens  ──►  order_items.allergens_disclosed
(vocabulary)                          derived by trigger        frozen at the moment of sale
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

### The domain

The shape that matters: **a product is a recipe over things you count, not a
thing you count.** Stock lives on ingredients; how many of a product you could
sell is derived from the recipe and the ledger. Most of what follows is a
consequence of that one decision.

**`allergens`** — a global closed vocabulary, seeded with the fourteen
declarable allergens of EU FIC 1169/2011 Annex II. A table rather than an enum
so it is reference data a client can render, and a trigger validates ingredient
labels against it: a typo fails at write time instead of becoming a label
nobody notices is wrong.

**`ingredients`** — what is actually counted. Notable columns:

- `unit` — `g` | `ml` | `unit`. Base units only. Kilograms and litres are a
  presentation concern, and one canonical unit per ingredient means no
  conversion ever runs inside a constraint, a trigger, or the sell path. No
  other table carries a unit, so there is no unit to mismatch: you cannot add
  500 g to 2 units because there is nowhere to write the wrong unit down.
- `allergens` — what this ingredient contains, validated against the
  vocabulary. Correcting it relabels every product that uses it, which is what
  makes a recall possible at all.
- Also the target of the composite FKs below, via `unique (id, organization_id)`.

**`products`** — what is sold. Notable columns:

- `price_cents` + `currency` — integer minor units, never a float. An order may
  not mix currencies.
- `allergens` — **derived**, recomputed by trigger from the recipe. A member has
  no `UPDATE` privilege on this column at all; see the note on derived columns
  under Conventions.
- `search_vector` — generated `tsvector`, name weighted above description.
- `status` — `draft` | `active` | `discontinued`. An `active` product is
  readable by anyone: that is the shop window, and a second RLS policy grants it
  to `anon` alongside the organization-scoped one. The column grants to `anon`
  are narrowed to match, so the policy and the privilege are two independent
  limits on the same read.

**`product_ingredients`** — the recipe, keyed `(product_id, ingredient_id)`.
`quantity` is in the ingredient's own unit. It cascades from the product and
*restricts* from the ingredient: deleting a product is a decision, deleting an
ingredient something still sells is a mistake.

**`inventory_movements`** — an append-only ledger. There is deliberately no
`quantity_on_hand` column anywhere in this schema, so there is no
`qty = qty - 1` to lose under concurrency. The RLS policies are `select` and
`insert` only, with no `update` or `delete`: a ledger you can edit is not a
ledger. `kind` is checked against the sign of `quantity`, so a receipt cannot be
negative, and a cancellation returns stock as a separate `release` movement
rather than by deleting what it consumed.

Stock on hand is `public.ingredient_available()`, a sum. How many of a product
could be made is `public.product_sellable()`, a `min` over the recipe. Neither
is stored, so neither can be stale.

**`customers`** — a third kind of identity, and explicitly **not** an
`auth.users` row: a customer never signs in. They are data an organization holds
about someone, which is also why `public.anonymize_customer()` scrubs the
details in place rather than deleting the row — the orders stay referentially
intact.

**`orders`** — written only by `public.place_order()`; there is no INSERT policy
at all. One call resolves each sku against the active catalogue, snapshots the
lines, locks every ingredient the order touches **in ascending id order**,
checks the ledger, and writes the consumption. Two orders racing for the last of
something therefore queue instead of both concluding there is enough, and
locking in the same order every time is what keeps them from deadlocking
against each other. Not enough stock raises `insufficient_resources` (`53000`).

**`order_items`** — the snapshot, and the reason this schema is worth reading.
Each line keeps `sku_at_purchase`, `name_at_purchase`, `unit_price_cents` and
`allergens_disclosed` as they were at the moment of sale. Repricing never
rewrites history, and correcting an allergen never rewrites what a buyer was
told — so the two records can disagree, and
`public.orders_missing_allergen()` reads that disagreement back as a recall
list. `product_id` is nullable with `on delete set null`: the line outlives the
product.

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
  (`usage_events`, `audit_log`, `auth_events`) which use identity
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
- A *derived* column is protected by column-level `UPDATE` privilege instead.
  The guard decides by reading the request's JWT role, so it cannot tell a
  client apart from a `SECURITY DEFINER` function acting on that client's
  behalf: both arrive with the same claim, and both would be reverted.
  Privilege can tell them apart, because the function runs as the table's
  owner — and it refuses the client's write outright rather than ignoring it.
  `products.allergens` is the example.
