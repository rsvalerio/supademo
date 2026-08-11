-- ---------------------------------------------------------------------------
-- Seed 4 · Viewer sessions, metering and captured leads
--
-- Applied by `supabase db reset`, which picks these up through the glob in
-- [db.seed] sql_paths. Files run in filename order, so the numeric prefix is
-- load-bearing: this one depends on everything before it.
--
-- Runs as `postgres`, which bypasses RLS. The seed is not a test of the
-- policies — that is what supabase/tests is for.
-- ---------------------------------------------------------------------------

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
