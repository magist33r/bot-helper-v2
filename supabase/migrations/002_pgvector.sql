create extension if not exists vector;

create index if not exists documents_embedding_ivfflat_idx
on public.documents
using ivfflat (embedding vector_cosine_ops)
with (lists = 100);

analyze public.documents;
