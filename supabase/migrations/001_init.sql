create extension if not exists vector;

create table if not exists public.documents (
  id bigint generated always as identity primary key,
  content text not null,
  metadata jsonb not null default '{}'::jsonb,
  embedding vector(1536) not null,
  created_at timestamptz not null default now()
);

create table if not exists public.tickets (
  id bigint generated always as identity primary key,
  telegram_user_id bigint not null,
  username text,
  question text not null,
  status text not null default 'open' check (status in ('open', 'answered', 'closed')),
  created_at timestamptz not null default now(),
  closed_at timestamptz
);

create table if not exists public.qa_log (
  id bigint generated always as identity primary key,
  telegram_user_id bigint not null,
  question text not null,
  answer text,
  similarity double precision,
  was_answered boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists tickets_status_idx on public.tickets (status);
create index if not exists tickets_telegram_user_id_idx on public.tickets (telegram_user_id);
create index if not exists qa_log_created_at_idx on public.qa_log (created_at desc);

alter table public.documents enable row level security;
alter table public.tickets enable row level security;
alter table public.qa_log enable row level security;
