# apps/

Empty on purpose. The backend is deliberately finished first, and this is where
clients land when they arrive.

The workspace is already configured for them: `package.json` globs `apps/*`, so
a new app is a directory with a `package.json` and nothing else to wire up.

## Planned

| Directory | Stack | Notes |
| --- | --- | --- |
| `apps/web` | Next.js (App Router) | Dashboard + the public storefront. Use `@supabase/ssr` for cookie-based sessions. |
| `apps/cli` | Node + Commander | `supademo stock`, CI-friendly. Authenticates with an API key, not a user session. |
| `apps/desktop` | Tauri or Electron | The back office. Needs resumable (TUS) uploads for label artwork. |
| `apps/mobile` | Expo / React Native | Order status and stock on hand. Read-mostly. |

## What a new app should and should not do

**Do**

- Import `@supademo/db-types` for `Database`, and `@supademo/shared` for the
  client factory, permission helpers and validation schemas. Do not re-derive
  any of them.
- Talk to the database through PostgREST and the RPCs. There is a function for
  every non-trivial read (`organization_overview`, `get_order`,
  `orders_missing_allergen`) precisely so clients do not assemble six queries by
  hand. Writes that have to hold an invariant — placing an order is the one that
  matters — are RPCs for the same reason: the sequence belongs in the database,
  not in whichever client happens to be calling.
- Build storage paths with the helpers in `@supademo/shared/client`. The storage
  policies parse those paths; an ad-hoc path is a silent 403.
- Treat `app_metadata.organizations` in the JWT as a rendering hint only. It can
  be up to an hour stale. The database is the authority on what is allowed.

**Do not**

- Ship the `service_role` key. It bypasses RLS completely. If a client seems to
  need it, the missing piece is an RPC or an edge function, not the key.
- Add a table without RLS, or reach around a policy with a `SECURITY DEFINER`
  function that skips the membership check. `supabase/tests/00_structure.test.sql`
  fails the build for the first; only review catches the second.
- Re-implement the role hierarchy. It is in `permissions.ts`, mirrored from the
  `org_role` enum, and both are derived from the same ordering.

## Suggested first slice

The storefront. It needs no authentication, and it exercises the anonymous
catalogue policy with its narrowed column grants, signed storage URLs for
product media, and allergen labels that arrive derived rather than typed in —
which is a good deal of the platform, without a login screen in the way.
