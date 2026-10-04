-- ---------------------------------------------------------------------------
-- Seed 5 · Knowledge base, webhooks and notifications
--
-- Applied by `supabase db reset`, which picks these up through the glob in
-- [db.seed] sql_paths. Files run in filename order, so the numeric prefix is
-- load-bearing: this one depends on everything before it.
--
-- Runs as `postgres`, which bypasses RLS. The seed is not a test of the
-- policies — that is what supabase/tests is for.
-- ---------------------------------------------------------------------------

-- --- Knowledge base ---------------------------------------------------------
-- Sections are left with status 'pending' and no embedding: run the
-- embed-document edge function to see the AI path populate them.

insert into public.documents (id, organization_id, source_type, title, content, created_by)
values
  ('00000000-0000-4000-f000-000000000001', '00000000-0000-4000-b000-000000000001',
   'help_article', 'How allergen labelling works',
   'A product does not carry its own allergen list: it inherits one from its recipe. '
   'Correcting an ingredient relabels every product that uses it, immediately. '
   'Orders already placed keep the list the buyer was shown, so the two can be compared '
   'to find out who needs to be contacted after a correction.',
   '00000000-0000-4000-a000-000000000001'),
  ('00000000-0000-4000-f000-000000000002', '00000000-0000-4000-b000-000000000001',
   'help_article', 'Understanding plan limits',
   'Every plan caps the number of products and members. Reaching a cap does not '
   'delete anything: it stops new items being created until you upgrade or remove '
   'something. Orders are metered monthly and reset with the billing period.',
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
  array['order.confirmed', 'order.cancelled'],
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
