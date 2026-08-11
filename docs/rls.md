# Row Level Security

## The rules

1. **Every table in `public` has RLS enabled and at least one policy.** RLS with
   no policy denies everything, which is almost always an accident rather than a
   decision. `supabase/tests/00_structure.test.sql` asserts both and fails the
   build.
2. **Policies never inline a membership subquery.** They call `app.is_org_member()`
   or `app.has_org_role()`. One definition, one place to fix.
3. **Helpers are `SECURITY DEFINER` with `search_path = ''`.** Definer because
   they must read `organization_members` without re-entering RLS — that is what
   keeps the membership policies from recursing into themselves. Pinned
   `search_path` because a definer function that resolves names through the
   caller's path is exploitable by anyone who can create objects.
4. **Anything a client cannot be trusted with lives in `private`.** No grants,
   not exposed to PostgREST, reachable only through a vetted RPC that does its
   own authorization.
5. **Views in `api` are `security_invoker = true`.** A view is otherwise checked
   with its *owner's* permissions, which is the single most common way an
   otherwise careful RLS setup springs a leak.

## Helpers

| Function | Returns | Use |
| --- | --- | --- |
| `app.uid()` | `uuid` | The caller, or NULL |
| `app.org_role(org)` | `org_role` | Caller's role, NULL if not a member |
| `app.is_org_member(org)` | `boolean` | Any role at all |
| `app.has_org_role(org, min)` | `boolean` | Role ≥ min, inclusive |
| `app.is_org_active(org)` | `boolean` | Subscription is in good standing |
| `app.is_mfa_verified()` | `boolean` | Session reached `aal2` |
| `app.is_service_role()` | `boolean` | Service key, or a direct DB session |
| `app.safe_uuid(text)` | `uuid` | Cast that returns NULL instead of raising |

`app.safe_uuid` exists for a specific reason: a policy must never raise on
attacker-controlled text. An exception is a 500, not a denial, and the
difference is observable.

## The standard pattern

```sql
-- Read: any member.
create policy "widgets: read as member"
  on public.widgets for select
  to authenticated
  using (app.is_org_member(organization_id));

-- Write: member and above, and only while the account is in good standing.
create policy "widgets: write as member"
  on public.widgets for insert
  to authenticated
  with check (
    app.has_org_role(organization_id, 'member')
    and app.is_org_active(organization_id)
  );

-- Destroy: admin and above. Note the absence of is_org_active — a lapsed
-- subscription must not prevent someone from cleaning up their own data.
create policy "widgets: delete as admin"
  on public.widgets for delete
  to authenticated
  using (app.has_org_role(organization_id, 'admin'));
```

Two details that are easy to get wrong:

- `(select auth.uid())` rather than bare `auth.uid()`. The subquery form is
  evaluated once per statement instead of once per row — on a large table the
  difference is substantial.
- `to authenticated` on every policy. Without a role clause a policy also
  applies to `anon`, which is rarely what was meant.

## Access matrix

| Table | viewer | member | admin | owner | anon |
| --- | --- | --- | --- | --- | --- |
| `organizations` | read | read | read, update | + delete (MFA) | public-listed only, 4 columns |
| `organization_members` | read | read | manage | manage | — |
| `organization_invites` | — | — | manage | manage | — |
| `subscriptions` | read | read | read | read | — |
| `usage_events` | — | — | read | read | — |
| `projects` | read | write | + delete | + delete | — |
| `demos` | read | write | + delete | + delete | `public` only, 15 columns |
| `demo_steps` | read | write | write | write | — |
| `demo_comments` | read, comment | + edit own | + moderate | + moderate | — |
| `demo_views` | read | read | read | read | write via RPC |
| `demo_leads` | — | read | + delete | + delete | write via RPC |
| `documents` | read | write | write | write | — |
| `api_keys` | — | — | manage | manage | — |
| `webhook_endpoints` | — | — | manage | manage | — |
| `notifications` | own | own | own | own | — |
| `plans` | read | read | read | read | read |
| `private.*` | — | — | — | — | — |

"write" means insert and update; "manage" means all four verbs.

## Two limits, not one, for anonymous access

`api.demo_directory` is `security_invoker`, so `anon` needs genuine access to
the rows underneath it. Rather than widening RLS and trusting the view never to
select a column it should not, the row policy is narrow **and** the column
grants are explicit:

```sql
create policy "organizations: read when publicly listed"
  on public.organizations for select to anon
  using (deleted_at is null and exists (
    select 1 from public.demos d
     where d.organization_id = organizations.id
       and d.visibility = 'public' and d.status = 'published'
       and d.deleted_at is null));

revoke select on public.organizations from anon;
grant select (id, slug, name, logo_path, deleted_at) on public.organizations to anon;
```

Either limit alone would be sufficient. Both together mean a mistake in one is
not a breach.

## Writing a new table

1. Add `organization_id uuid not null`, plus a composite FK to the parent's
   `(id, organization_id)` if there is one.
2. `alter table ... enable row level security;`
3. Add the four policies above.
4. Attach `private.attach_updated_at()`, and `private.attach_audit()` if the
   table is worth an audit trail.
5. Add a test to `supabase/tests/01_tenancy.test.sql` proving an outsider sees
   nothing.

Step 2 is enforced by CI. Steps 3–5 are not, so they are on you.

## Testing policies

Impersonation belongs **inside** a helper that restores the session before
returning, not wrapped around the assertions:

```sql
select is(
  pg_temp.scalar_as(OUTSIDER, 'outsider@test.local',
    'select count(*) from public.demos where organization_id = ''...'''),
  '0', 'outsider sees no demos');
```

Asserting from within an impersonated session is how RLS suites end up failing
for reasons that have nothing to do with the policy under test — the assertion
framework needs privileges the impersonated role does not have. See
`supabase/tests/01_tenancy.test.sql`.

Note also that the local database is seeded, so scope every count to the
fixture. A bare `count(*)` passes locally and fails in CI, or worse, the reverse.

## Things that are not RLS, and why

- **Quotas** are triggers, not policies. A policy answers "may you touch this
  row"; a quota is a statement about the *set*, which a row-level predicate
  cannot express.
- **Role changes** are triggers. The policy allows an admin to write the
  membership table at all; the trigger enforces that they cannot promote
  themselves or exceed their own level.
- **Last-owner protection** is a trigger, and it deliberately distinguishes a
  cascade (organization or profile deleted) from a demotion by checking whether
  the parent row still exists. Without that, deleting an organization would trip
  its own integrity guard.
