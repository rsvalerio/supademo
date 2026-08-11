# @supademo/shared

Everything a client needs that is **not** specific to a rendering framework:
the typed Supabase client factory, the domain vocabulary, and validation
schemas that mirror the database's own constraints.

Kept framework-free on purpose. `apps/web` (React), `apps/mobile` (React
Native), `apps/cli` (Node) and `apps/desktop` (Electron/Tauri) can all depend on
this without any of them dragging in the others' runtime.

- `client.ts` — `createSupademoClient()`, plus storage URL helpers
- `permissions.ts` — the role hierarchy, mirrored from the `org_role` enum
- `schemas.ts` — zod schemas that match the CHECK constraints in the database
- `types.ts` — hand-written domain types layered over the generated ones
