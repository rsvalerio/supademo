# Bootstrapping the generated types from CI

**This documents a temporary workaround. If `.github/workflows/bootstrap-types.yml`
still exists, the workaround is still in place — [remove it](#removing-the-workaround).**

## The problem it solves

`packages/db-types/src/database.types.ts` is committed as a **placeholder**: 51
lines with permissive index signatures, so the workspace type-checks on a fresh
clone before anyone has booted the database. Its own header says as much.

CI's last database step regenerates that file from the live schema and fails if
the result differs from what is committed:

```yaml
- name: Check generated types are current
  run: |
    ./supa gen types --local --schema public,api \
      > packages/db-types/src/database.types.ts
    if ! git diff --quiet -- packages/db-types/src/database.types.ts; then
      echo "::error::packages/db-types is stale. …"
      exit 1
    fi
```

A placeholder can never match ~1,700 lines of generated output, so that check
fails on **every** branch, including the default one. It is not branch-specific
drift; it is the placeholder never having been replaced.

Normally you fix this in ten seconds:

```bash
make types
git add packages/db-types/src/database.types.ts && git commit
```

That needs a machine that can boot the Supabase stack — `supabase gen types`
runs `postgres-meta` in a container. This workflow exists for the case where
nobody has one to hand: the sandbox the API-authentication work was written in
had its container-registry egress blocked by policy (403 on
`production.cloudfront.docker.com` and the ECR CloudFront host), so it could
neither boot the stack nor pull the image.

## What the workaround is

`.github/workflows/bootstrap-types.yml` — one manually-triggered job that does
on a GitHub runner exactly what `make types` does locally, then commits the
result back to the branch it was dispatched on.

Three properties worth knowing:

| Property | Why |
| --- | --- |
| `on: workflow_dispatch` and nothing else | It never fires on a push or a pull request. Someone has to ask for it. |
| `permissions: contents: write` | It is the only job in this repository that writes to the repository. Keeping it in its own file makes that grant visible and removable in one delete. |
| `git add` names one path | A bare `git add -A` would blind-commit whatever the local stack left in the working tree. |

Dispatching requires the workflow file to exist on the repository's **default
branch** — that is a GitHub constraint on `workflow_dispatch`, not a choice
made here.

## Running it

From the Actions tab: **Bootstrap generated types (temporary)** → *Run
workflow* → pick the branch.

Or:

```bash
gh workflow run bootstrap-types.yml --ref <branch>
```

It boots the stack, replays every migration (`db reset` — `start` alone leaves
an empty database), regenerates the file, and pushes a single commit authored
by `github-actions[bot]` if anything changed. If the file already matches the
schema it commits nothing and exits clean, so running it twice is harmless.

That push triggers CI again, and `Check generated types are current` should
then pass.

## Removing the workaround

Do this as soon as a real generated file is committed. The workflow has served
its purpose the moment `database.types.ts` is no longer a placeholder.

**1. Confirm the types file is real.** The placeholder is 51 lines and says
`PLACEHOLDER` on line 2:

```bash
wc -l packages/db-types/src/database.types.ts     # expect thousands, not 51
head -3 packages/db-types/src/database.types.ts   # expect no "PLACEHOLDER"
grep -c 'Record<string, {' packages/db-types/src/database.types.ts   # expect 0
```

**2. Delete the workflow and this document.**

```bash
git rm .github/workflows/bootstrap-types.yml docs/ci-types-bootstrap.md
git commit -m "Remove the temporary types-bootstrap workflow

packages/db-types now holds real generated output, so the one-shot
bootstrap has served its purpose. Removing it also drops the only
contents: write grant in this repository's CI."
```

Deleting the file is the entire removal: the `contents: write` permission is
declared inside it and goes away with it. There is nothing to unset in the
repository settings, no secret to rotate, and no change to `ci.yml` — the
workaround never touched it.

**3. Keep the file current the normal way.** After every migration:

```bash
make types
```

and commit the result, exactly as `packages/db-types/README.md` says. CI fails
on a stale file, which is the point of that check and the reason it is worth
having once the file is real.

## If you need it again later

You should not — `make types` is the supported path and this only existed to
break a chicken-and-egg. But if the placeholder is ever restored, or a
contributor genuinely cannot run containers, the workflow is short enough to
recreate from this document: check out the branch, `./supa start`, `./supa db
reset`, `./supa gen types --local --schema public,api` into the file, then
commit that one path and push.

## Related

- `packages/db-types/README.md` — why the file is generated and never edited
- `docs/local-development.md` — booting the stack
- `docs/supabase-cli.md` — what `gen types` does and its other output languages
