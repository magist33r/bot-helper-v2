alter table public.qa_log
  add column if not exists feedback smallint;
-- 1 = positive, -1 = negative, null = no feedback

create index if not exists qa_log_feedback_idx on public.qa_log(feedback) where feedback is not null;

create or replace function public.feedback_stats(days int default 7)
returns table (
  total_with_feedback bigint,
  positive bigint,
  negative bigint,
  positive_percent numeric
)
language sql
stable
as $$
  select
    count(*) filter (where feedback is not null) as total_with_feedback,
    count(*) filter (where feedback = 1) as positive,
    count(*) filter (where feedback = -1) as negative,
    case when count(*) filter (where feedback is not null) > 0
      then round(100.0 * count(*) filter (where feedback = 1) / count(*) filter (where feedback is not null), 1)
      else 0
    end as positive_percent
  from public.qa_log
  where created_at > now() - (days || ' days')::interval;
$$;

revoke execute on function public.feedback_stats(int) from anon, authenticated;
