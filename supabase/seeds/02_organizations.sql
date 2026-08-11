-- ---------------------------------------------------------------------------
-- Seed 2 · Organizations, membership and a pending invite
--
-- Applied by `supabase db reset`, which picks these up through the glob in
-- [db.seed] sql_paths. Files run in filename order, so the numeric prefix is
-- load-bearing: this one depends on everything before it.
--
-- Runs as `postgres`, which bypasses RLS. The seed is not a test of the
-- policies — that is what supabase/tests is for.
-- ---------------------------------------------------------------------------

-- --- Organizations ----------------------------------------------------------

insert into public.organizations (id, slug, name, billing_email, created_by)
values
  ('00000000-0000-4000-b000-000000000001', 'acme', 'Acme Inc',
   'billing@acme.test', '00000000-0000-4000-a000-000000000001'),
  ('00000000-0000-4000-b000-000000000002', 'globex', 'Globex Corp',
   'billing@globex.test', '00000000-0000-4000-a000-000000000003')
on conflict (id) do nothing;

-- Acme is on Pro so the seed can exceed the Free tier's limits.
update public.subscriptions
   set plan_id = 'pro',
       status = 'active',
       seats = 5,
       current_period_start = date_trunc('month', now()),
       current_period_end = date_trunc('month', now()) + interval '1 month'
 where organization_id = '00000000-0000-4000-b000-000000000001';

insert into public.organization_members (organization_id, user_id, role)
values
  ('00000000-0000-4000-b000-000000000001', '00000000-0000-4000-a000-000000000001', 'owner'),
  ('00000000-0000-4000-b000-000000000001', '00000000-0000-4000-a000-000000000002', 'member'),
  ('00000000-0000-4000-b000-000000000002', '00000000-0000-4000-a000-000000000003', 'owner')
on conflict (organization_id, user_id) do nothing;

-- A pending invitation to exercise the accept flow. Raw token: `seed-invite-token`.
insert into public.organization_invites (
  id, organization_id, email, role, token_hash, invited_by
)
values (
  '00000000-0000-4000-c000-000000000001',
  '00000000-0000-4000-b000-000000000001',
  'alan@supademo.test',
  'member',
  encode(extensions.digest('seed-invite-token', 'sha256'), 'hex'),
  '00000000-0000-4000-a000-000000000001'
)
on conflict (id) do nothing;
