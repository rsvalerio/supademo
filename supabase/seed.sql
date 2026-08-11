-- ---------------------------------------------------------------------------
-- Local seed data. Applied by `supabase db reset`.
--
-- Deterministic UUIDs so tests, fixtures and screenshots can hard-code them.
-- Everything here runs as `postgres`, which bypasses RLS — the seed is not a
-- test of the policies (that is what supabase/tests is for).
--
-- Sign in locally with any of the accounts below, password: `supademo123!`
-- ---------------------------------------------------------------------------

-- --- Users ------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-a000-000000000001',
   'authenticated', 'authenticated', 'ada@supademo.test',
   extensions.crypt('supademo123!', extensions.gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}', '{"full_name":"Ada Lovelace"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-a000-000000000002',
   'authenticated', 'authenticated', 'grace@supademo.test',
   extensions.crypt('supademo123!', extensions.gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}', '{"full_name":"Grace Hopper"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-a000-000000000003',
   'authenticated', 'authenticated', 'alan@supademo.test',
   extensions.crypt('supademo123!', extensions.gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}', '{"full_name":"Alan Turing"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-a000-000000000004',
   'authenticated', 'authenticated', 'outsider@supademo.test',
   extensions.crypt('supademo123!', extensions.gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}', '{"full_name":"Unaffiliated User"}', now(), now())
on conflict (id) do nothing;

-- GoTrue will not authenticate a user without a matching identity row.
insert into auth.identities (
  provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at
)
select u.id::text,
       u.id,
       jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
       'email',
       now(), now(), now()
  from auth.users u
 where u.email like '%@supademo.test'
on conflict (provider, provider_id) do nothing;

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

-- --- Traffic ----------------------------------------------------------------
-- Thirty days of viewing sessions, so the analytics RPCs have a shape to return.

insert into public.demo_views (
  demo_id, organization_id, session_id, steps_viewed, completed,
  duration_ms, referrer, country, device_type, created_at, updated_at
)
select '00000000-0000-4000-e000-000000000001',
       '00000000-0000-4000-b000-000000000001',
       extensions.gen_random_uuid(),
       (random() * 3)::int,
       random() > 0.55,
       (random() * 180000)::int,
       (array['https://news.ycombinator.com', 'https://google.com', 'https://acme.test', null])[1 + floor(random() * 4)],
       (array['US', 'GB', 'DE', 'BR', 'JP'])[1 + floor(random() * 5)],
       (array['desktop', 'mobile', 'tablet'])[1 + floor(random() * 3)],
       ts, ts
  from generate_series(now() - interval '30 days', now(), interval '4 hours') as ts;

insert into public.usage_events (organization_id, metric, quantity, subject_type, subject_id, occurred_at)
select organization_id, 'demo_view', 1, 'demo', demo_id, created_at
  from public.demo_views;

select public.rollup_usage(d::date) from generate_series(now() - interval '30 days', now(), interval '1 day') as d;

insert into public.demo_leads (demo_id, organization_id, email, name)
values
  ('00000000-0000-4000-e000-000000000001', '00000000-0000-4000-b000-000000000001',
   'curious@prospect.test', 'Curious Prospect'),
  ('00000000-0000-4000-e000-000000000001', '00000000-0000-4000-b000-000000000001',
   'evaluating@bigco.test', 'Evaluating Buyer')
on conflict do nothing;

-- --- Knowledge base ---------------------------------------------------------
-- Sections are left with status 'pending' and no embedding: run the
-- embed-document edge function to see the AI path populate them.

insert into public.documents (id, organization_id, source_type, title, content, created_by)
values
  ('00000000-0000-4000-f000-000000000001', '00000000-0000-4000-b000-000000000001',
   'help_article', 'Sharing a demo',
   'Demos can be private, shared by link, or published publicly. A link-shared demo '
   'is reachable by anyone holding its share id, but never appears in listings. '
   'Publishing makes a demo appear in the public directory and lets search engines index it.',
   '00000000-0000-4000-a000-000000000001'),
  ('00000000-0000-4000-f000-000000000002', '00000000-0000-4000-b000-000000000001',
   'help_article', 'Understanding plan limits',
   'Every plan caps the number of demos, projects and members. Reaching a cap does not '
   'delete anything: it stops new items being created until you upgrade or remove '
   'something. Views are metered monthly and reset with the billing period.',
   '00000000-0000-4000-a000-000000000001')
on conflict (id) do nothing;

insert into public.document_sections (document_id, organization_id, position, content, token_count)
select d.id, d.organization_id, 0, d.content, greatest(1, char_length(d.content) / 4)
  from public.documents d
 where d.organization_id = '00000000-0000-4000-b000-000000000001'
on conflict (document_id, position) do nothing;

-- --- Integrations -----------------------------------------------------------

insert into public.webhook_endpoints (organization_id, url, description, events, created_by)
values (
  '00000000-0000-4000-b000-000000000001',
  'https://example.test/hooks/supademo',
  'Example receiver. Deliveries will fail locally, which is what makes the retry path visible.',
  array['demo.published'],
  '00000000-0000-4000-a000-000000000001'
)
on conflict do nothing;

insert into public.notifications (user_id, organization_id, kind, title, body, url)
values (
  '00000000-0000-4000-a000-000000000001',
  '00000000-0000-4000-b000-000000000001',
  'system',
  'Welcome to Supademo',
  'This workspace was created by the local seed. Poke around.',
  '/'
);
