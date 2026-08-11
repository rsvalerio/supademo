-- ---------------------------------------------------------------------------
-- 0300 · Tenancy: organizations, members, invitations
--
-- Every tenant-scoped row in this database carries `organization_id`, and every
-- policy resolves access through the helpers below. The helpers are
-- SECURITY DEFINER so they read `organization_members` without re-entering RLS,
-- which is what keeps the membership policies from recursing into themselves.
-- ---------------------------------------------------------------------------

-- Declared least- to most-privileged so the native enum ordering *is* the role
-- hierarchy: `app.org_role(x) >= 'admin'` needs no lookup table.
create type public.org_role as enum ('viewer', 'member', 'admin', 'owner');

create table public.organizations (
  id             uuid primary key default extensions.gen_random_uuid(),
  slug           extensions.citext not null unique,
  name           text not null,
  logo_path      text,
  website        text,
  billing_email  extensions.citext,
  settings       jsonb not null default '{}'::jsonb,
  created_by     uuid references public.profiles (id) on delete set null,
  deleted_at     timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  constraint organizations_slug_format check (slug ~ '^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])$'),
  constraint organizations_name_length check (char_length(name) between 1 and 120),
  constraint organizations_settings_is_object check (jsonb_typeof(settings) = 'object')
);

comment on table public.organizations is 'Tenant root. Created through public.create_organization().';

create index organizations_created_by_idx on public.organizations (created_by);
create index organizations_active_idx on public.organizations (created_at desc) where deleted_at is null;

select private.attach_updated_at('public.organizations');

create trigger guard_server_columns
  before update on public.organizations
  for each row execute function private.tg_guard_columns('id', 'created_by', 'created_at');

create table public.organization_members (
  organization_id uuid not null references public.organizations (id) on delete cascade,
  user_id         uuid not null references public.profiles (id) on delete cascade,
  role            public.org_role not null default 'member',
  invited_by      uuid references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  primary key (organization_id, user_id)
);

comment on table public.organization_members is 'Membership edge between a user and a tenant.';

create index organization_members_user_id_idx on public.organization_members (user_id);
-- Exactly one owner is not required, but at least one is (enforced by trigger).
create index organization_members_owner_idx on public.organization_members (organization_id) where role = 'owner';

select private.attach_updated_at('public.organization_members');

create table public.organization_invites (
  id              uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  email           extensions.citext not null,
  role            public.org_role not null default 'member',
  token_hash      text not null unique,
  invited_by      uuid references public.profiles (id) on delete set null,
  expires_at      timestamptz not null default now() + interval '7 days',
  accepted_at     timestamptz,
  accepted_by     uuid references public.profiles (id) on delete set null,
  revoked_at      timestamptz,
  created_at      timestamptz not null default now(),

  constraint organization_invites_email_format check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  constraint organization_invites_role_not_owner check (role <> 'owner')
);

comment on table public.organization_invites is
  'Pending invitations. Only the SHA-256 of the token is stored; the raw token is returned once, by the RPC that creates the invite.';

-- One live invite per address per org. Accepted/revoked rows stay for the audit
-- trail and are excluded from the constraint.
create unique index organization_invites_pending_idx
  on public.organization_invites (organization_id, email)
  where accepted_at is null and revoked_at is null;

create index organization_invites_email_idx on public.organization_invites (email) where accepted_at is null;

-- ---------------------------------------------------------------------------
-- Access helpers
-- ---------------------------------------------------------------------------

create or replace function app.org_role(p_organization_id uuid)
returns public.org_role
language sql
stable
security definer
set search_path = ''
as $$
  select m.role
    from public.organization_members m
   where m.organization_id = p_organization_id
     and m.user_id = (select auth.uid());
$$;

comment on function app.org_role(uuid) is
  'Role of the calling user in the given organization, or NULL when not a member.';

create or replace function app.is_org_member(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.organization_members m
     where m.organization_id = p_organization_id
       and m.user_id = (select auth.uid())
  );
$$;

-- `p_min_role` is inclusive: 'admin' matches admins and owners.
create or replace function app.has_org_role(p_organization_id uuid, p_min_role public.org_role)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(app.org_role(p_organization_id) >= p_min_role, false);
$$;

create or replace function app.current_org_ids()
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(m.organization_id order by m.organization_id), '{}'::uuid[])
    from public.organization_members m
   where m.user_id = (select auth.uid());
$$;

create or replace function app.shares_org_with(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.organization_members mine
      join public.organization_members theirs
        on theirs.organization_id = mine.organization_id
     where mine.user_id = (select auth.uid())
       and theirs.user_id = p_user_id
  );
$$;

grant execute on function
  app.org_role(uuid),
  app.is_org_member(uuid),
  app.has_org_role(uuid, public.org_role),
  app.current_org_ids(),
  app.shares_org_with(uuid)
to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Integrity triggers
-- ---------------------------------------------------------------------------

-- An organization must never be left without an owner.
create or replace function private.tg_protect_last_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  owner_count integer;
  losing_owner boolean;
begin
  -- NEW is unassigned in a DELETE trigger, so every branch below touches only
  -- the record that actually exists for this operation.
  if tg_op = 'DELETE' then
    -- A cascade from a deleted organization or profile is not a demotion. RI
    -- cascades run after the parent row is gone, so its absence identifies them.
    if not exists (select 1 from public.organizations o where o.id = old.organization_id)
       or not exists (select 1 from public.profiles p where p.id = old.user_id)
    then
      return old;
    end if;
    losing_owner := (old.role = 'owner');
  else
    losing_owner := (old.role = 'owner' and new.role <> 'owner');
  end if;

  if losing_owner then
    select count(*) into owner_count
      from public.organization_members m
     where m.organization_id = old.organization_id
       and m.role = 'owner';

    if owner_count <= 1 then
      raise exception 'organization % must keep at least one owner', old.organization_id
        using errcode = 'check_violation';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger protect_last_owner
  before update or delete on public.organization_members
  for each row execute function private.tg_protect_last_owner();

-- Nobody promotes themselves. Role changes must be made by a strictly more
-- privileged member, and only up to their own level.
create or replace function private.tg_check_role_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  actor_role public.org_role;
begin
  -- Vetted RPCs (org creation, invite acceptance, ownership transfer) write
  -- membership rows for the caller themselves; they raise the trusted-path flag
  -- after doing their own authorization.
  if actor is null
     or coalesce(auth.role(), '') = 'service_role'
     or private.is_privileged()
  then
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if old.role is not distinct from new.role then
      return new;
    end if;
  end if;

  if new.user_id = actor then
    raise exception 'you cannot change your own role'
      using errcode = 'insufficient_privilege';
  end if;

  select m.role into actor_role
    from public.organization_members m
   where m.organization_id = new.organization_id
     and m.user_id = actor;

  if actor_role is null or actor_role < 'admin' then
    raise exception 'only admins and owners can assign roles'
      using errcode = 'insufficient_privilege';
  end if;

  if new.role > actor_role then
    raise exception 'you cannot grant a role above your own'
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

create trigger check_role_change
  before insert or update of role on public.organization_members
  for each row execute function private.tg_check_role_change();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;
alter table public.organization_invites enable row level security;

-- Organizations are created only through public.create_organization(), so there
-- is deliberately no INSERT policy here.
create policy "organizations: read as member"
  on public.organizations for select
  to authenticated
  using (app.is_org_member(id));

create policy "organizations: update as admin"
  on public.organizations for update
  to authenticated
  using (app.has_org_role(id, 'admin'))
  with check (app.has_org_role(id, 'admin'));

-- Hard delete is owner-only and requires a second factor.
create policy "organizations: delete as owner with mfa"
  on public.organizations for delete
  to authenticated
  using (app.has_org_role(id, 'owner') and app.is_mfa_verified());

create policy "organization_members: read as member"
  on public.organization_members for select
  to authenticated
  using (app.is_org_member(organization_id));

create policy "organization_members: write as admin"
  on public.organization_members for insert
  to authenticated
  with check (app.has_org_role(organization_id, 'admin'));

create policy "organization_members: update as admin"
  on public.organization_members for update
  to authenticated
  using (app.has_org_role(organization_id, 'admin'))
  with check (app.has_org_role(organization_id, 'admin'));

-- Admins remove others; anyone may remove themselves (leave).
create policy "organization_members: delete as admin or self"
  on public.organization_members for delete
  to authenticated
  using (
    app.has_org_role(organization_id, 'admin')
    or user_id = (select auth.uid())
  );

create policy "organization_invites: read as admin or invitee"
  on public.organization_invites for select
  to authenticated
  using (
    app.has_org_role(organization_id, 'admin')
    or email = (app.jwt() ->> 'email')::extensions.citext
  );

create policy "organization_invites: manage as admin"
  on public.organization_invites for all
  to authenticated
  using (app.has_org_role(organization_id, 'admin'))
  with check (app.has_org_role(organization_id, 'admin'));

-- Now that membership helpers exist, let co-workers see each other.
create policy "profiles: read organization peers"
  on public.profiles for select
  to authenticated
  using (app.shares_org_with(id));

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

create or replace function public.create_organization(
  p_name text,
  p_slug text default null
)
returns public.organizations
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  base_slug text;
  candidate text;
  suffix integer := 0;
  org public.organizations;
begin
  if actor is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;

  perform private.begin_privileged();

  base_slug := app.slugify(coalesce(nullif(trim(p_slug), ''), p_name));
  if char_length(base_slug) < 3 then
    base_slug := base_slug || '-' || app.short_id(6);
  end if;

  candidate := left(base_slug, 40);
  while exists (select 1 from public.organizations o where o.slug = candidate::extensions.citext) loop
    suffix := suffix + 1;
    candidate := left(base_slug, 34) || '-' || suffix::text;
  end loop;

  insert into public.organizations (slug, name, created_by, billing_email)
  values (
    candidate::extensions.citext,
    trim(p_name),
    actor,
    (app.jwt() ->> 'email')::extensions.citext
  )
  returning * into org;

  insert into public.organization_members (organization_id, user_id, role)
  values (org.id, actor, 'owner');

  return org;
end;
$$;

comment on function public.create_organization(text, text) is
  'RPC: creates an organization, derives a unique slug, and makes the caller its owner.';

-- Returns the raw invite token exactly once. Only its SHA-256 is persisted, so
-- a leaked database dump cannot be used to join an organization.
create or replace function public.create_organization_invite(
  p_organization_id uuid,
  p_email text,
  p_role public.org_role default 'member'
)
returns table (invite_id uuid, token text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  raw_token text;
begin
  perform private.begin_privileged();

  if not app.has_org_role(p_organization_id, 'admin') then
    raise exception 'only admins and owners can invite' using errcode = 'insufficient_privilege';
  end if;

  if p_role = 'owner' then
    raise exception 'ownership is transferred, not invited' using errcode = 'check_violation';
  end if;

  if exists (
    select 1
      from public.organization_members m
      join public.profiles p on p.id = m.user_id
     where m.organization_id = p_organization_id
       and p.email = p_email::extensions.citext
  ) then
    raise exception '% is already a member', p_email using errcode = 'unique_violation';
  end if;

  raw_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into public.organization_invites (organization_id, email, role, token_hash, invited_by)
  values (
    p_organization_id,
    p_email::extensions.citext,
    p_role,
    encode(extensions.digest(raw_token, 'sha256'), 'hex'),
    actor
  )
  on conflict (organization_id, email) where accepted_at is null and revoked_at is null
  do update set
    role = excluded.role,
    token_hash = excluded.token_hash,
    invited_by = excluded.invited_by,
    expires_at = now() + interval '7 days'
  returning id into invite_id;

  token := raw_token;
  return next;
end;
$$;

comment on function public.create_organization_invite(uuid, text, public.org_role) is
  'RPC: issues an invitation and returns the single-use token (shown only here).';

create or replace function public.accept_organization_invite(p_token text)
returns public.organization_members
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  actor_email extensions.citext := (app.jwt() ->> 'email')::extensions.citext;
  invite public.organization_invites;
  membership public.organization_members;
begin
  perform private.begin_privileged();

  if actor is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;

  select * into invite
    from public.organization_invites i
   where i.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
   for update;

  if invite.id is null then
    raise exception 'invitation not found' using errcode = 'no_data_found';
  end if;

  if invite.accepted_at is not null or invite.revoked_at is not null then
    raise exception 'invitation is no longer valid' using errcode = 'check_violation';
  end if;

  if invite.expires_at < now() then
    raise exception 'invitation has expired' using errcode = 'check_violation';
  end if;

  if actor_email is null or actor_email <> invite.email then
    raise exception 'invitation was issued to a different address' using errcode = 'insufficient_privilege';
  end if;

  insert into public.organization_members (organization_id, user_id, role, invited_by)
  values (invite.organization_id, actor, invite.role, invite.invited_by)
  on conflict (organization_id, user_id) do update set role = excluded.role
  returning * into membership;

  update public.organization_invites
     set accepted_at = now(), accepted_by = actor
   where id = invite.id;

  return membership;
end;
$$;

comment on function public.accept_organization_invite(text) is
  'RPC: redeems an invitation token for the calling user.';

-- Ownership transfer: the only way to mint a new owner.
create or replace function public.transfer_organization_ownership(
  p_organization_id uuid,
  p_to_user_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
begin
  perform private.begin_privileged();

  if not app.has_org_role(p_organization_id, 'owner') then
    raise exception 'only an owner can transfer ownership' using errcode = 'insufficient_privilege';
  end if;

  if not app.is_mfa_verified() then
    raise exception 'multi-factor authentication is required for this action'
      using errcode = 'insufficient_privilege';
  end if;

  if not exists (
    select 1 from public.organization_members m
     where m.organization_id = p_organization_id and m.user_id = p_to_user_id
  ) then
    raise exception 'the new owner must already be a member' using errcode = 'no_data_found';
  end if;

  update public.organization_members
     set role = 'owner'
   where organization_id = p_organization_id and user_id = p_to_user_id;

  update public.organization_members
     set role = 'admin'
   where organization_id = p_organization_id and user_id = actor;
end;
$$;

grant execute on function
  public.create_organization(text, text),
  public.create_organization_invite(uuid, text, public.org_role),
  public.accept_organization_invite(text),
  public.transfer_organization_ownership(uuid, uuid)
to authenticated;
