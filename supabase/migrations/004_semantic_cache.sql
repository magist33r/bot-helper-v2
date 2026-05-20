-- ============================================================
-- Semantic answer cache
-- Кеширует пары (embedding вопроса → ответ) чтобы не дёргать
-- LLM на повторяющиеся по смыслу вопросы.
-- ============================================================

create table if not exists public.cache_answers (
  id bigint generated always as identity primary key,
  question text not null,
  answer text not null,
  embedding vector(1536) not null,
  hit_count integer not null default 1,
  source_log_id bigint references public.qa_log(id) on delete set null,
  last_used_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

alter table public.cache_answers enable row level security;

create index if not exists cache_answers_embedding_ivfflat_idx
  on public.cache_answers
  using ivfflat (embedding vector_cosine_ops)
  with (lists = 100);

create index if not exists cache_answers_last_used_idx
  on public.cache_answers (last_used_at desc);

-- Поиск похожего кешированного ответа.
-- threshold намеренно выше чем у match_documents (0.92 vs 0.75),
-- потому что для прямого ответа без LLM нужно почти полное совпадение смысла.
create or replace function public.match_cached_answer(
  query_embedding vector(1536),
  match_threshold double precision default 0.92
)
returns table (
  id bigint,
  answer text,
  similarity double precision
)
language sql
stable
as $$
  select
    c.id,
    c.answer,
    1 - (c.embedding <=> query_embedding) as similarity
  from public.cache_answers c
  where 1 - (c.embedding <=> query_embedding) >= match_threshold
  order by c.embedding <=> query_embedding
  limit 1;
$$;

-- Регистрация попадания в кеш (обновить hit_count + last_used_at)
create or replace function public.touch_cache_answer(cache_id bigint)
returns void
language sql
as $$
  update public.cache_answers
  set hit_count = hit_count + 1,
      last_used_at = now()
  where id = cache_id;
$$;

-- Очистка устаревшего кеша (использовать в cron / по команде /reload).
-- По умолчанию удаляет записи которые не использовались 7 дней.
create or replace function public.evict_stale_cache(stale_days integer default 7)
returns bigint
language sql
as $$
  with deleted as (
    delete from public.cache_answers
    where last_used_at < now() - (stale_days || ' days')::interval
    returning id
  )
  select count(*) from deleted;
$$;

-- Жёсткая очистка всего кеша (вызывать при заливке новой базы знаний).
create or replace function public.purge_cache()
returns void
language sql
as $$
  truncate table public.cache_answers;
$$;

-- Защита: эти служебные функции не должны быть доступны через anon/authenticated
revoke execute on function public.touch_cache_answer(bigint) from anon, authenticated;
revoke execute on function public.evict_stale_cache(integer) from anon, authenticated;
revoke execute on function public.purge_cache() from anon, authenticated;
