-- ---------------------------------------------------------------------------
-- Seed 3 · Projects, demos, steps and comments
--
-- Applied by `supabase db reset`, which picks these up through the glob in
-- [db.seed] sql_paths. Files run in filename order, so the numeric prefix is
-- load-bearing: this one depends on everything before it.
--
-- Runs as `postgres`, which bypasses RLS. The seed is not a test of the
-- policies — that is what supabase/tests is for.
-- ---------------------------------------------------------------------------

-- --- Projects and demos -----------------------------------------------------

insert into public.projects (id, organization_id, name, slug, description, created_by)
values
  ('00000000-0000-4000-d000-000000000001', '00000000-0000-4000-b000-000000000001',
   'Product Tours', 'product-tours', 'Everything customers see on day one.',
   '00000000-0000-4000-a000-000000000001'),
  ('00000000-0000-4000-d000-000000000002', '00000000-0000-4000-b000-000000000001',
   'Sales Enablement', 'sales-enablement', 'Demos the sales team sends after a call.',
   '00000000-0000-4000-a000-000000000001'),
  ('00000000-0000-4000-d000-000000000003', '00000000-0000-4000-b000-000000000002',
   'Internal', 'internal', 'Globex demos. Invisible to Acme.',
   '00000000-0000-4000-a000-000000000003')
on conflict (id) do nothing;

insert into public.demos (
  id, organization_id, project_id, public_id, title, slug, description,
  status, visibility, tags, published_at, created_by
)
values
  ('00000000-0000-4000-e000-000000000001', '00000000-0000-4000-b000-000000000001',
   '00000000-0000-4000-d000-000000000001', 'demoacme001',
   'Getting started with Acme', 'getting-started-with-acme',
   'A five-step walkthrough of first-run setup.',
   'published', 'public', array['onboarding', 'tour'], now() - interval '9 days',
   '00000000-0000-4000-a000-000000000001'),
  ('00000000-0000-4000-e000-000000000002', '00000000-0000-4000-b000-000000000001',
   '00000000-0000-4000-d000-000000000002', 'demoacme002',
   'Advanced reporting', 'advanced-reporting',
   'How to build a custom report. Shared by link only.',
   'published', 'link', array['reporting'], now() - interval '3 days',
   '00000000-0000-4000-a000-000000000002'),
  ('00000000-0000-4000-e000-000000000003', '00000000-0000-4000-b000-000000000001',
   '00000000-0000-4000-d000-000000000001', 'demoacme003',
   'Work in progress', 'work-in-progress',
   'Still a draft. Members only.',
   'draft', 'private', array[]::text[], null,
   '00000000-0000-4000-a000-000000000001'),
  ('00000000-0000-4000-e000-000000000004', '00000000-0000-4000-b000-000000000002',
   '00000000-0000-4000-d000-000000000003', 'demoglobex01',
   'Globex confidential', 'globex-confidential',
   'Belongs to the other tenant. Acme must never see this.',
   'published', 'private', array['internal'], now() - interval '1 day',
   '00000000-0000-4000-a000-000000000003')
on conflict (id) do nothing;

insert into public.demo_steps (demo_id, organization_id, position, title, body, hotspot)
values
  ('00000000-0000-4000-e000-000000000001', '00000000-0000-4000-b000-000000000001', 0,
   'Create your workspace', 'Pick a name. You can change it later.',
   '{"x": 0.24, "y": 0.31, "shape": "circle"}'),
  ('00000000-0000-4000-e000-000000000001', '00000000-0000-4000-b000-000000000001', 1,
   'Invite your team', 'Anyone with the link can join as a viewer.',
   '{"x": 0.68, "y": 0.42, "shape": "rect"}'),
  ('00000000-0000-4000-e000-000000000001', '00000000-0000-4000-b000-000000000001', 2,
   'Record your first demo', 'Install the extension and hit record.',
   '{"x": 0.51, "y": 0.77, "shape": "circle"}'),
  ('00000000-0000-4000-e000-000000000002', '00000000-0000-4000-b000-000000000001', 0,
   'Open the report builder', 'Reports live under Analytics.',
   '{"x": 0.15, "y": 0.22, "shape": "rect"}'),
  ('00000000-0000-4000-e000-000000000002', '00000000-0000-4000-b000-000000000001', 1,
   'Pick your dimensions', 'Group by whatever you actually measure.',
   '{"x": 0.44, "y": 0.55, "shape": "circle"}');

insert into public.demo_comments (demo_id, organization_id, author_id, body)
values
  ('00000000-0000-4000-e000-000000000001', '00000000-0000-4000-b000-000000000001',
   '00000000-0000-4000-a000-000000000002', 'Step 2 could use a screenshot.'),
  ('00000000-0000-4000-e000-000000000001', '00000000-0000-4000-b000-000000000001',
   '00000000-0000-4000-a000-000000000001', 'Agreed — recording one now.');
