-- ---------------------------------------------------------------------------
-- 0700 · Storage buckets and object policies
--
-- Path convention — the first two segments carry the authorization context, so
-- every policy is a cheap prefix check rather than a join:
--
--   avatars        users/<user_id>/<filename>
--   org-branding   orgs/<organization_id>/<filename>
--   demo-assets    orgs/<organization_id>/demos/<demo_id>/<filename>
--   exports        orgs/<organization_id>/<job_id>.<ext>
--
-- Buckets live in a migration (not config.toml) so `supabase db push` applies
-- the same definitions to hosted projects.
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars', 'avatars', true, 2097152,
   array['image/png', 'image/jpeg', 'image/webp', 'image/gif']),
  ('org-branding', 'org-branding', true, 5242880,
   array['image/png', 'image/jpeg', 'image/webp', 'image/svg+xml']),
  ('demo-assets', 'demo-assets', false, 52428800,
   array['image/png', 'image/jpeg', 'image/webp', 'image/gif', 'video/mp4', 'video/webm', 'application/pdf']),
  ('exports', 'exports', false, 104857600, null)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- --- Path helpers -----------------------------------------------------------

-- Second path segment as a uuid, or NULL when the path is not shaped like
-- `<scope>/<uuid>/...`. Used by every policy below.
create or replace function app.storage_scope_id(p_name text)
returns uuid
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  parts text[] := string_to_array(coalesce(p_name, ''), '/');
begin
  if coalesce(array_length(parts, 1), 0) < 2 then
    return null;
  end if;

  return app.safe_uuid(parts[2]);
end;
$$;

comment on function app.storage_scope_id(text) is
  'Owning organization (or user) id embedded in a storage object path.';

grant execute on function app.storage_scope_id(text) to anon, authenticated, service_role;

-- --- avatars (public bucket) ------------------------------------------------
-- Anyone can read; you may only write under users/<your id>/.

create policy "avatars: public read"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'avatars');

create policy "avatars: write own"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = 'users'
    and app.storage_scope_id(name) = (select auth.uid())
  );

create policy "avatars: update own"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'avatars' and app.storage_scope_id(name) = (select auth.uid()))
  with check (bucket_id = 'avatars' and app.storage_scope_id(name) = (select auth.uid()));

create policy "avatars: delete own"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'avatars' and app.storage_scope_id(name) = (select auth.uid()));

-- --- org-branding (public bucket) -------------------------------------------
-- Public read so logos can be embedded in shared demos; admin-only write.

create policy "org-branding: public read"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'org-branding');

create policy "org-branding: manage as admin"
  on storage.objects for all
  to authenticated
  using (
    bucket_id = 'org-branding'
    and app.has_org_role(app.storage_scope_id(name), 'admin')
  )
  with check (
    bucket_id = 'org-branding'
    and (storage.foldername(name))[1] = 'orgs'
    and app.has_org_role(app.storage_scope_id(name), 'admin')
  );

-- --- demo-assets (private bucket) -------------------------------------------
-- Members read and write their own organization's assets. Anonymous viewers of
-- a shared demo never read the bucket directly: the player is handed a signed
-- URL minted server-side by the `public-demo` edge function.

create policy "demo-assets: read as member"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'demo-assets'
    and app.is_org_member(app.storage_scope_id(name))
  );

create policy "demo-assets: write as member"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'demo-assets'
    and (storage.foldername(name))[1] = 'orgs'
    and app.has_org_role(app.storage_scope_id(name), 'member')
    and app.is_org_active(app.storage_scope_id(name))
  );

create policy "demo-assets: update as member"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'demo-assets'
    and app.has_org_role(app.storage_scope_id(name), 'member')
  )
  with check (
    bucket_id = 'demo-assets'
    and app.has_org_role(app.storage_scope_id(name), 'member')
  );

create policy "demo-assets: delete as member"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'demo-assets'
    and app.has_org_role(app.storage_scope_id(name), 'member')
  );

-- --- exports (private bucket) -----------------------------------------------
-- Written by background jobs running as service_role; admins download.

create policy "exports: read as admin"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'exports'
    and app.has_org_role(app.storage_scope_id(name), 'admin')
  );

-- --- Resumable uploads ------------------------------------------------------
-- TUS uploads land in storage.s3_multipart_uploads before becoming objects, so
-- large demo videos need matching policies there.

do $$
begin
  if to_regclass('storage.s3_multipart_uploads') is not null then
    execute $policy$
      create policy "demo-assets: multipart as member"
        on storage.s3_multipart_uploads for all
        to authenticated
        using (bucket_id = 'demo-assets' and app.has_org_role(app.storage_scope_id(key), 'member'))
        with check (bucket_id = 'demo-assets' and app.has_org_role(app.storage_scope_id(key), 'member'))
    $policy$;

    execute $policy$
      create policy "demo-assets: multipart parts as member"
        on storage.s3_multipart_uploads_parts for all
        to authenticated
        using (bucket_id = 'demo-assets' and app.has_org_role(app.storage_scope_id(key), 'member'))
        with check (bucket_id = 'demo-assets' and app.has_org_role(app.storage_scope_id(key), 'member'))
    $policy$;
  end if;
end;
$$;

-- --- Storage metering -------------------------------------------------------
-- Bytes stored are metered per organization so the `storage_mb` quota has
-- something to read.

create or replace function private.tg_meter_storage()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  org_id uuid;
  bucket text;
  delta numeric;
begin
  -- AFTER trigger: the return value is ignored, and only one of NEW/OLD is
  -- assigned, so each branch reads exactly the record it has.
  if tg_op = 'DELETE' then
    bucket := old.bucket_id;
    org_id := app.storage_scope_id(old.name);
    delta  := -coalesce((old.metadata ->> 'size')::numeric, 0);
  elsif tg_op = 'INSERT' then
    bucket := new.bucket_id;
    org_id := app.storage_scope_id(new.name);
    delta  := coalesce((new.metadata ->> 'size')::numeric, 0);
  else
    bucket := new.bucket_id;
    org_id := app.storage_scope_id(new.name);
    delta  := coalesce((new.metadata ->> 'size')::numeric, 0)
              - coalesce((old.metadata ->> 'size')::numeric, 0);
  end if;

  if org_id is null
     or bucket not in ('demo-assets', 'org-branding', 'exports')
     or delta = 0
     -- Objects can outlive their organization during a cascade.
     or not exists (select 1 from public.organizations o where o.id = org_id)
  then
    return null;
  end if;

  insert into public.usage_events (organization_id, metric, quantity, subject_type, metadata)
  values (org_id, 'storage_bytes', abs(delta), 'object',
          jsonb_build_object('direction', case when delta > 0 then 'add' else 'remove' end,
                             'bucket', bucket));

  return null;
end;
$$;

create trigger meter_storage
  after insert or update or delete on storage.objects
  for each row execute function private.tg_meter_storage();
