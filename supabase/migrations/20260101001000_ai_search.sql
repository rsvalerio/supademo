-- ---------------------------------------------------------------------------
-- 1000 · Semantic and hybrid search (pgvector)
--
-- Embeddings are 384-dimensional because they are produced by `gte-small`, the
-- model bundled with the Supabase Edge Runtime — no external inference API, no
-- key to rotate. Swapping in a larger model means changing the vector width
-- here and re-embedding; nothing else in the schema cares.
-- ---------------------------------------------------------------------------

create type public.document_source as enum ('demo', 'help_article', 'upload', 'note');
create type public.embedding_status as enum ('pending', 'processing', 'ready', 'failed');

create table public.documents (
  id              uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  source_type     public.document_source not null default 'note',
  source_id       uuid,
  title           text not null,
  content         text not null default '',
  metadata        jsonb not null default '{}'::jsonb,
  checksum        text generated always as (encode(extensions.digest(content, 'sha256'), 'hex')) stored,
  created_by      uuid references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  unique (id, organization_id),
  constraint documents_metadata_is_object check (jsonb_typeof(metadata) = 'object')
);

comment on column public.documents.checksum is
  'Content hash. Re-embedding is skipped when it has not moved.';

create index documents_organization_id_idx on public.documents (organization_id);
create index documents_source_idx on public.documents (source_type, source_id);

select private.attach_updated_at('public.documents');

create table public.document_sections (
  id              uuid primary key default extensions.gen_random_uuid(),
  document_id     uuid not null,
  organization_id uuid not null,
  position        integer not null default 0,
  content         text not null,
  token_count     integer,
  embedding       extensions.vector(384),
  status          public.embedding_status not null default 'pending',
  error           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  search_vector tsvector generated always as (
    to_tsvector('english'::regconfig, coalesce(content, ''))
  ) stored,

  foreign key (document_id, organization_id)
    references public.documents (id, organization_id) on delete cascade,
  unique (document_id, position)
);

comment on table public.document_sections is
  'Chunked document text plus its embedding. Filled in by the embed-document edge function.';

-- HNSW beats IVFFlat here: no training step, and recall stays good as rows are
-- added one at a time (which is exactly how documents arrive).
create index document_sections_embedding_idx
  on public.document_sections
  using hnsw (embedding extensions.vector_cosine_ops)
  with (m = 16, ef_construction = 64);

create index document_sections_fts_idx on public.document_sections using gin (search_vector);
create index document_sections_pending_idx on public.document_sections (created_at)
  where status in ('pending', 'failed');
create index document_sections_org_idx on public.document_sections (organization_id);

select private.attach_updated_at('public.document_sections');

-- --- Search -----------------------------------------------------------------

-- SECURITY INVOKER throughout: RLS is what keeps one tenant's vectors out of
-- another tenant's results, and it also prunes the candidate set before the
-- index scan.
create or replace function public.match_document_sections(
  p_organization_id uuid,
  p_embedding extensions.vector(384),
  p_match_count integer default 10,
  p_min_similarity double precision default 0.5
)
returns table (
  id uuid,
  document_id uuid,
  content text,
  similarity double precision
)
language sql
stable
security invoker
set search_path = ''
as $$
  select s.id,
         s.document_id,
         s.content,
         1 - (s.embedding operator(extensions.<=>) p_embedding) as similarity
    from public.document_sections s
   where s.organization_id = p_organization_id
     and s.embedding is not null
     and 1 - (s.embedding operator(extensions.<=>) p_embedding) >= p_min_similarity
   order by s.embedding operator(extensions.<=>) p_embedding
   limit least(coalesce(p_match_count, 10), 100);
$$;

comment on function public.match_document_sections(uuid, extensions.vector, integer, double precision) is
  'RPC: nearest-neighbour search over document embeddings (cosine distance).';

-- Reciprocal Rank Fusion. Keyword and vector search fail in different ways —
-- keyword misses paraphrases, vectors miss rare exact terms — and RRF merges
-- their rankings without needing the two scores to be commensurable.
create or replace function public.hybrid_search_documents(
  p_organization_id uuid,
  p_query text,
  p_embedding extensions.vector(384),
  p_match_count integer default 10,
  p_rrf_k integer default 50
)
returns table (
  id uuid,
  document_id uuid,
  content text,
  score double precision
)
language sql
stable
security invoker
set search_path = ''
as $$
  with keyword as (
    select t.id, row_number() over (order by t.rank_score desc, t.id) as rank
      from (
        select s.id,
               ts_rank_cd(s.search_vector, websearch_to_tsquery('english'::regconfig, p_query)) as rank_score
          from public.document_sections s
         where s.organization_id = p_organization_id
           and s.search_vector @@ websearch_to_tsquery('english'::regconfig, p_query)
         order by rank_score desc
         limit least(coalesce(p_match_count, 10), 100) * 4
      ) t
  ),
  semantic as (
    select t.id, row_number() over (order by t.distance, t.id) as rank
      from (
        select s.id,
               s.embedding operator(extensions.<=>) p_embedding as distance
          from public.document_sections s
         where s.organization_id = p_organization_id
           and s.embedding is not null
         order by distance
         limit least(coalesce(p_match_count, 10), 100) * 4
      ) t
  )
  select s.id,
         s.document_id,
         s.content,
         coalesce(1.0 / (p_rrf_k + k.rank), 0.0) + coalesce(1.0 / (p_rrf_k + v.rank), 0.0) as score
    from public.document_sections s
    left join keyword k on k.id = s.id
    left join semantic v on v.id = s.id
   where k.id is not null or v.id is not null
   order by score desc
   limit least(coalesce(p_match_count, 10), 100);
$$;

comment on function public.hybrid_search_documents(uuid, text, extensions.vector, integer, integer) is
  'RPC: keyword + vector search merged with Reciprocal Rank Fusion.';

grant execute on function
  public.match_document_sections(uuid, extensions.vector, integer, double precision),
  public.hybrid_search_documents(uuid, text, extensions.vector, integer, integer)
to authenticated;

-- --- Ingestion --------------------------------------------------------------

-- Replaces a document's chunks in one transaction. The embed-document function
-- calls this after chunking, then fills in the vectors.
create or replace function public.replace_document_sections(
  p_document_id uuid,
  p_sections text[]
)
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  doc public.documents;
  inserted integer;
begin
  select * into doc from public.documents d where d.id = p_document_id;
  if doc.id is null then
    raise exception 'document not found' using errcode = 'no_data_found';
  end if;

  delete from public.document_sections s where s.document_id = p_document_id;

  insert into public.document_sections (document_id, organization_id, position, content, token_count)
  select p_document_id,
         doc.organization_id,
         ordinality - 1,
         chunk,
         -- ~4 characters per token is close enough for budgeting.
         greatest(1, char_length(chunk) / 4)
    from unnest(p_sections) with ordinality as t(chunk, ordinality)
   where length(trim(chunk)) > 0;

  get diagnostics inserted = row_count;
  return inserted;
end;
$$;

grant execute on function public.replace_document_sections(uuid, text[]) to authenticated, service_role;

-- --- RLS --------------------------------------------------------------------

alter table public.documents enable row level security;
alter table public.document_sections enable row level security;

create policy "documents: read as member"
  on public.documents for select
  to authenticated
  using (app.is_org_member(organization_id));

create policy "documents: write as member"
  on public.documents for all
  to authenticated
  using (app.has_org_role(organization_id, 'member'))
  with check (app.has_org_role(organization_id, 'member') and app.is_org_active(organization_id));

create policy "document_sections: read as member"
  on public.document_sections for select
  to authenticated
  using (app.is_org_member(organization_id));

create policy "document_sections: write as member"
  on public.document_sections for all
  to authenticated
  using (app.has_org_role(organization_id, 'member'))
  with check (app.has_org_role(organization_id, 'member'));
