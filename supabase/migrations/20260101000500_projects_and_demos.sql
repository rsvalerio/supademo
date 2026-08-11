-- ---------------------------------------------------------------------------
-- 0500 · The product: projects → demos → steps (+ comments)
--
-- Child tables carry a denormalized `organization_id` so every policy is a
-- single-table predicate — no joins inside RLS, which is the difference between
-- an index scan and a nested loop on every request. A composite foreign key
-- against (id, organization_id) makes the denormalized column impossible to
-- forge or drift.
-- ---------------------------------------------------------------------------

create type public.demo_status as enum ('draft', 'published', 'archived');

-- private = members only · link = anyone holding the unguessable public_id
-- public  = listed and crawlable
create type public.demo_visibility as enum ('private', 'link', 'public');

create table public.projects (
  id              uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  name            text not null,
  slug            extensions.citext not null,
  description     text,
  color           text not null default '#3ecf8e',
  archived_at     timestamptz,
  created_by      uuid references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  unique (organization_id, slug),
  -- Target for the composite FKs below.
  unique (id, organization_id),
  constraint projects_name_length check (char_length(name) between 1 and 120),
  constraint projects_color_format check (color ~* '^#[0-9a-f]{6}$')
);

create index projects_organization_id_idx on public.projects (organization_id)
  where archived_at is null;

select private.attach_updated_at('public.projects');

create table public.demos (
  id              uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  project_id      uuid not null,
  public_id       text not null unique default app.short_id(12),
  title           text not null,
  slug            extensions.citext not null,
  description     text,
  status          public.demo_status not null default 'draft',
  visibility      public.demo_visibility not null default 'private',
  cover_path      text,
  theme           jsonb not null default '{}'::jsonb,
  tags            text[] not null default '{}',
  published_at    timestamptz,
  created_by      uuid references public.profiles (id) on delete set null,
  deleted_at      timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  search_vector tsvector generated always as (
    setweight(to_tsvector('english'::regconfig, coalesce(title, '')), 'A') ||
    setweight(to_tsvector('english'::regconfig, coalesce(description, '')), 'B')
  ) stored,

  foreign key (project_id, organization_id)
    references public.projects (id, organization_id) on delete cascade,
  unique (id, organization_id),
  unique (organization_id, slug),
  constraint demos_title_length check (char_length(title) between 1 and 200),
  constraint demos_published_has_timestamp
    check (status <> 'published' or published_at is not null),
  constraint demos_theme_is_object check (jsonb_typeof(theme) = 'object')
);

comment on column public.demos.public_id is
  'Unguessable share identifier. The only handle anonymous viewers ever see.';

create index demos_organization_id_idx on public.demos (organization_id) where deleted_at is null;
create index demos_project_id_idx on public.demos (project_id) where deleted_at is null;
create index demos_search_idx on public.demos using gin (search_vector);
create index demos_tags_idx on public.demos using gin (tags);
create index demos_title_trgm_idx on public.demos using gin (title extensions.gin_trgm_ops);
create index demos_public_listing_idx on public.demos (published_at desc)
  where visibility = 'public' and status = 'published' and deleted_at is null;

select private.attach_updated_at('public.demos');

create trigger guard_server_columns
  before update on public.demos
  for each row execute function private.tg_guard_columns('id', 'organization_id', 'public_id', 'created_by', 'created_at');

create table public.demo_steps (
  id              uuid primary key default extensions.gen_random_uuid(),
  demo_id         uuid not null,
  organization_id uuid not null,
  position        integer not null,
  title           text,
  body            text,
  asset_path      text,
  hotspot         jsonb not null default '{}'::jsonb,
  duration_ms     integer,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  foreign key (demo_id, organization_id)
    references public.demos (id, organization_id) on delete cascade,
  constraint demo_steps_position_positive check (position >= 0),
  constraint demo_steps_hotspot_is_object check (jsonb_typeof(hotspot) = 'object')
);

-- Deferrable so a client can reorder steps in one transaction without shuffling
-- through temporary positions.
alter table public.demo_steps
  add constraint demo_steps_position_unique unique (demo_id, position)
  deferrable initially deferred;

select private.attach_updated_at('public.demo_steps');

create table public.demo_comments (
  id              uuid primary key default extensions.gen_random_uuid(),
  demo_id         uuid not null,
  organization_id uuid not null,
  step_id         uuid references public.demo_steps (id) on delete set null,
  author_id       uuid not null references public.profiles (id) on delete cascade,
  body            text not null,
  resolved_at     timestamptz,
  resolved_by     uuid references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  foreign key (demo_id, organization_id)
    references public.demos (id, organization_id) on delete cascade,
  constraint demo_comments_body_length check (char_length(body) between 1 and 5000)
);

create index demo_comments_demo_id_idx on public.demo_comments (demo_id, created_at desc);
create index demo_comments_open_idx on public.demo_comments (demo_id) where resolved_at is null;

select private.attach_updated_at('public.demo_comments');

create trigger guard_server_columns
  before update on public.demo_comments
  for each row execute function private.tg_guard_columns('id', 'demo_id', 'organization_id', 'author_id', 'created_at');

-- --- Defaults and quotas ----------------------------------------------------

create or replace function private.tg_demo_defaults()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  base text;
  candidate text;
  suffix integer := 0;
  used integer;
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, (select auth.uid()));

    base := nullif(app.slugify(coalesce(nullif(new.slug::text, ''), new.title)), '');
    candidate := coalesce(base, app.short_id(8));
    while exists (
      select 1 from public.demos d
       where d.organization_id = new.organization_id
         and d.slug = candidate::extensions.citext
    ) loop
      suffix := suffix + 1;
      candidate := left(coalesce(base, 'demo'), 40) || '-' || suffix::text;
    end loop;
    new.slug := candidate::extensions.citext;

    select count(*) into used
      from public.demos d
     where d.organization_id = new.organization_id
       and d.deleted_at is null;
    perform app.assert_quota(new.organization_id, 'demos', used, 1);
  end if;

  -- published_at is set once, by the transition into 'published'.
  if new.status = 'published' and new.published_at is null then
    new.published_at := now();
  end if;

  return new;
end;
$$;

create trigger demo_defaults
  before insert or update on public.demos
  for each row execute function private.tg_demo_defaults();

create or replace function private.tg_enforce_project_quota()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  used integer;
begin
  new.created_by := coalesce(new.created_by, (select auth.uid()));
  new.slug := coalesce(nullif(new.slug::text, ''), app.slugify(new.name))::extensions.citext;

  select count(*) into used
    from public.projects p
   where p.organization_id = new.organization_id
     and p.archived_at is null;

  perform app.assert_quota(new.organization_id, 'projects', used, 1);
  return new;
end;
$$;

create trigger enforce_project_quota
  before insert on public.projects
  for each row execute function private.tg_enforce_project_quota();

-- --- RLS --------------------------------------------------------------------
-- Reads follow membership. Writes additionally require the organization to be
-- in good standing (`app.is_org_active`) and the caller to be at least a
-- 'member' — 'viewer' is read-only by construction.

alter table public.projects enable row level security;
alter table public.demos enable row level security;
alter table public.demo_steps enable row level security;
alter table public.demo_comments enable row level security;

create policy "projects: read as member"
  on public.projects for select
  to authenticated
  using (app.is_org_member(organization_id));

create policy "projects: write as member"
  on public.projects for insert
  to authenticated
  with check (app.has_org_role(organization_id, 'member') and app.is_org_active(organization_id));

create policy "projects: update as member"
  on public.projects for update
  to authenticated
  using (app.has_org_role(organization_id, 'member'))
  with check (app.has_org_role(organization_id, 'member') and app.is_org_active(organization_id));

create policy "projects: delete as admin"
  on public.projects for delete
  to authenticated
  using (app.has_org_role(organization_id, 'admin'));

create policy "demos: read as member"
  on public.demos for select
  to authenticated
  using (app.is_org_member(organization_id) and deleted_at is null);

-- Anonymous visitors see only demos explicitly published to the world. Demos
-- shared by link are served through public.get_public_demo(), so holding a link
-- never becomes a licence to enumerate.
create policy "demos: read published public demos"
  on public.demos for select
  to anon, authenticated
  using (visibility = 'public' and status = 'published' and deleted_at is null);

create policy "demos: write as member"
  on public.demos for insert
  to authenticated
  with check (app.has_org_role(organization_id, 'member') and app.is_org_active(organization_id));

create policy "demos: update as member"
  on public.demos for update
  to authenticated
  using (app.has_org_role(organization_id, 'member'))
  with check (app.has_org_role(organization_id, 'member') and app.is_org_active(organization_id));

create policy "demos: delete as admin"
  on public.demos for delete
  to authenticated
  using (app.has_org_role(organization_id, 'admin'));

create policy "demo_steps: read as member"
  on public.demo_steps for select
  to authenticated
  using (app.is_org_member(organization_id));

create policy "demo_steps: write as member"
  on public.demo_steps for all
  to authenticated
  using (app.has_org_role(organization_id, 'member'))
  with check (app.has_org_role(organization_id, 'member') and app.is_org_active(organization_id));

create policy "demo_comments: read as member"
  on public.demo_comments for select
  to authenticated
  using (app.is_org_member(organization_id));

-- Viewers may comment: feedback is the point of sharing a demo internally.
create policy "demo_comments: create as member"
  on public.demo_comments for insert
  to authenticated
  with check (
    app.is_org_member(organization_id)
    and author_id = (select auth.uid())
    and app.is_org_active(organization_id)
  );

create policy "demo_comments: edit own"
  on public.demo_comments for update
  to authenticated
  using (author_id = (select auth.uid()) or app.has_org_role(organization_id, 'admin'))
  with check (app.is_org_member(organization_id));

create policy "demo_comments: delete own or as admin"
  on public.demo_comments for delete
  to authenticated
  using (author_id = (select auth.uid()) or app.has_org_role(organization_id, 'admin'));

-- --- Public read path -------------------------------------------------------

-- Single round trip for the embeddable player: demo + ordered steps, resolved
-- by share id. SECURITY DEFINER because link-shared demos are invisible to RLS.
create or replace function public.get_public_demo(p_public_id text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
           'id', d.id,
           'public_id', d.public_id,
           'title', d.title,
           'description', d.description,
           'cover_path', d.cover_path,
           'theme', d.theme,
           'tags', d.tags,
           'published_at', d.published_at,
           'organization', jsonb_build_object('name', o.name, 'logo_path', o.logo_path),
           'steps', coalesce((
             select jsonb_agg(
                      jsonb_build_object(
                        'id', s.id,
                        'position', s.position,
                        'title', s.title,
                        'body', s.body,
                        'asset_path', s.asset_path,
                        'hotspot', s.hotspot,
                        'duration_ms', s.duration_ms
                      ) order by s.position
                    )
               from public.demo_steps s
              where s.demo_id = d.id
           ), '[]'::jsonb)
         )
    from public.demos d
    join public.organizations o on o.id = d.organization_id
   where d.public_id = p_public_id
     and d.status = 'published'
     and d.visibility in ('public', 'link')
     and d.deleted_at is null
     and o.deleted_at is null;
$$;

comment on function public.get_public_demo(text) is
  'RPC: fetches a published demo and its steps by share id. Returns NULL when not shareable.';

grant execute on function public.get_public_demo(text) to anon, authenticated;

-- Full-text + trigram search, scoped by RLS to the caller's organizations.
create or replace function public.search_demos(
  p_query text,
  p_organization_id uuid default null,
  p_limit integer default 20
)
returns setof public.demos
language sql
stable
security invoker
set search_path = ''
as $$
  select d.*
    from public.demos d
   where d.deleted_at is null
     and (p_organization_id is null or d.organization_id = p_organization_id)
     and (
       d.search_vector @@ websearch_to_tsquery('english'::regconfig, p_query)
       or d.title ilike '%' || p_query || '%'
     )
   order by ts_rank_cd(d.search_vector, websearch_to_tsquery('english'::regconfig, p_query)) desc,
            d.updated_at desc
   limit least(coalesce(p_limit, 20), 100);
$$;

comment on function public.search_demos(text, uuid, integer) is
  'RPC: keyword search. SECURITY INVOKER, so RLS scopes results to the caller.';

grant execute on function public.search_demos(text, uuid, integer) to authenticated;
