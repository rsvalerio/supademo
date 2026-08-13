# @supademo/db-types

`src/database.types.ts` is **generated**. Never edit it.

```bash
make types            # from the repo root, against the local stack
SUPABASE_PROJECT_REF=xxx make types   # against a hosted project
```

Regenerate after every migration. CI fails if the committed file is stale
(`.github/workflows/ci.yml`), because a drifted type file is worse than none —
it type-checks against a schema that no longer exists.

Every client in `apps/` should import `Database` from here and parameterise its
Supabase client with it:

```ts
import type { Database } from "@supademo/db-types";
const supabase = createClient<Database>(url, key);
```
