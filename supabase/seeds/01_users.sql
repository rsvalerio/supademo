-- ---------------------------------------------------------------------------
-- Seed 1 · Users and identities
--
-- Applied by `supabase db reset`, which picks these up through the glob in
-- [db.seed] sql_paths. Files run in filename order, so the numeric prefix is
-- load-bearing: this one depends on everything before it.
--
-- Runs as `postgres`, which bypasses RLS. The seed is not a test of the
-- policies — that is what supabase/tests is for.
-- ---------------------------------------------------------------------------

-- Sign in locally with any of these accounts, password: `supademo123!`
-- Deterministic UUIDs so tests, fixtures and screenshots can hard-code them.

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
