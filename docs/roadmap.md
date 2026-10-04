# Roadmap

The backend is deliberately first and deliberately complete. Everything below
is either a client that consumes it, or a Supabase feature worth wiring in when
there is a reason to.

## Frontends

The workspace already globs `apps/*`, so a new client is a directory with a
`package.json`. See [`apps/README.md`](../apps/README.md) for what each one
should and should not do.

Suggested order, and why:

1. **`apps/web` — the storefront.** No authentication, so no login screen
   stands between you and the interesting parts: the anonymous catalogue policy
   with its narrowed column grants, signed storage URLs for product media, and
   the allergen labels coming through derived rather than typed in.
2. **`apps/web` — the dashboard.** Auth, the workspace switcher
   (`api.my_organizations`), quotas and billing. Use `@supabase/ssr` for
   cookie-based sessions; do not hand-roll session handling.
3. **`apps/cli`.** Authenticates with an API key rather than a user session,
   which proves the machine path is genuinely usable and not just present.
4. **`apps/desktop` — the back office.** Needs resumable (TUS) uploads for
   label artwork and spec sheets; the multipart policies are already in place.
5. **`apps/mobile`.** Order status and stock on hand, read-mostly.

## Backend work worth doing

**Ready to build on what exists**

- **Carts and fulfilment.** `order_status` has `pending` and `fulfilled` values
  that nothing currently sets: today `place_order()` goes straight to
  `confirmed`. A cart that reserves stock without consuming it is the
  interesting version of this problem.
- **Export jobs.** The `exports` bucket and its policies exist and nothing
  writes to them yet. A queue message, a worker, a signed URL in a notification.
- **More domain events.** `private.dispatch_event()` fans out to subscribed
  endpoints; only the `order.*` events use it. `stock.low` — a reorder level is
  already on every ingredient and nothing reads it — and `member.joined` are
  each a trigger away.

**Needs a decision first**

- **Partitioning `usage_events` and `inventory_movements`.** Both are
  append-only and time-ordered, so monthly range partitions are the natural
  fit. The ledger needs more care than the meter: stock on hand is a sum over
  all of history, so partitions can be detached for storage but never dropped
  without materializing an opening balance first.
- **Analytics buckets / Iceberg.** Supabase's analytics storage suits the view
  and usage streams better than Postgres does at volume, at the cost of a second
  query path.
- **Read replicas.** The catalogue is the obvious candidate — it is read by
  everyone and written by almost no one. The sell path is not: `place_order()`
  takes row locks and reads its own writes.

## Supabase features not yet used

Listed with what each would take, so the next person can judge whether it earns
its place rather than adding it because it is on the list.

| Feature | Where it would go | Cost |
| --- | --- | --- |
| **Declarative schemas** (`supabase/schemas/`) | Alternative to hand-written migrations | Real refactor; migrations currently are the source of truth |
| **Branching** | Preview databases per pull request | CI change plus a paid plan |
| **SSO (SAML)** | The `scale` plan already advertises it | Hosted-only; needs an IdP to test against |
| **Anonymous sign-ins** | Enabled in config, unused | A "try it without an account" flow, plus a conversion path |
| **Multi-factor: WebAuthn** | Alongside the existing TOTP | Client-side work; `app.is_mfa_verified()` already gates the sensitive actions |
| **Realtime Presence** | "Who else is editing this recipe" | Client-side; the channel convention (`org:<uuid>`) is already established |
| **Postgres Foreign Data Wrappers** | Pulling Stripe or Airtable data in as tables | Replaces some webhook plumbing with queries |
| **`pg_graphql`** | Exposed but unused | Nothing to do — it is on; it simply has no consumer yet |
| **Supabase AI: larger models** | Better retrieval than `gte-small` | Change the vector width and re-embed; nothing else in the schema cares |
| **Log drains / analytics buckets** | Observability | Hosted configuration |

## Deliberate non-goals

- **An application server.** Authorization lives in the database precisely so it
  holds for every client. A server in front would become a second place for
  rules to live, and then a second place for them to be wrong.
- **An ORM.** The schema is the interface. Generated types plus RPCs cover it.
- **Client-side authorization as anything but a hint.** `permissions.ts` decides
  what renders disabled; RLS decides what happens.
