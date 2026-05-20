create or replace function public.match_documents(
  query_embedding vector(1536),
  match_threshold double precision default 0.75,
  match_count integer default 3
)
returns table (
  id bigint,
  content text,
  metadata jsonb,
  similarity double precision
)
language sql
stable
as $$
  select
    d.id,
    d.content,
    d.metadata,
    1 - (d.embedding <=> query_embedding) as similarity
  from public.documents d
  where 1 - (d.embedding <=> query_embedding) >= match_threshold
  order by d.embedding <=> query_embedding
  limit match_count;
$$;

create or replace function public.support_stats()
returns table (
  open_tickets bigint,
  closed_tickets bigint,
  answered_tickets bigint,
  total_questions bigint,
  answered_percent numeric,
  avg_similarity numeric
)
language sql
stable
as $$
  select
    (select count(*) from public.tickets where status = 'open') as open_tickets,
    (select count(*) from public.tickets where status = 'closed') as closed_tickets,
    (select count(*) from public.tickets where status = 'answered') as answered_tickets,
    (select count(*) from public.qa_log) as total_questions,
    coalesce(round(100.0 * sum(case when was_answered then 1 else 0 end) / nullif(count(*), 0), 2), 0) as answered_percent,
    round(avg(similarity)::numeric, 4) as avg_similarity
  from public.qa_log;
$$;

create or replace function public.open_tickets(limit_count integer default 10)
returns table (
  id bigint,
  telegram_user_id bigint,
  username text,
  question text,
  created_at timestamptz
)
language sql
stable
as $$
  select t.id, t.telegram_user_id, t.username, t.question, t.created_at
  from public.tickets t
  where t.status = 'open'
  order by t.created_at desc
  limit limit_count;
$$;
