create table if not exists public.rate_limits (
  user_id bigint primary key,
  request_count integer not null default 0,
  window_start timestamptz not null default now()
);

alter table public.rate_limits enable row level security;

create or replace function public.check_rate_limit(
  p_user_id bigint,
  p_max_requests integer default 15,
  p_window_seconds integer default 60
)
returns boolean
language plpgsql
as $$
declare
  v_now timestamptz := now();
  v_count integer;
begin
  insert into public.rate_limits (user_id, request_count, window_start)
  values (p_user_id, 1, v_now)
  on conflict (user_id) do update
    set request_count = case
          when public.rate_limits.window_start < v_now - (p_window_seconds || ' seconds')::interval then 1
          else public.rate_limits.request_count + 1
        end,
        window_start = case
          when public.rate_limits.window_start < v_now - (p_window_seconds || ' seconds')::interval then v_now
          else public.rate_limits.window_start
        end
  returning request_count into v_count;

  return v_count <= p_max_requests;
end;
$$;

revoke execute on function public.check_rate_limit(bigint, integer, integer) from anon, authenticated;
revoke execute on function public.support_stats() from anon, authenticated;
revoke execute on function public.open_tickets(integer) from anon, authenticated;
