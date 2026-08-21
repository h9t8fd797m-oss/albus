-- 0006_entitlements
-- Subscription state and AI usage. Both are SERVER-WRITTEN ONLY.
-- Clients may read their own row; there is no insert/update/delete policy for
-- `authenticated`, so those operations are denied no matter what the client
-- sends. Only the service role (which bypasses RLS) writes here.

create table public.entitlements (
  user_id                 uuid primary key references auth.users(id) on delete cascade,
  tier                    text not null default 'free' check (tier in ('free','plus')),
  expires_at              timestamptz,
  original_transaction_id text,
  updated_at              timestamptz not null default now()
);

create table public.ai_usage (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  kind       text not null check (kind in ('breakdown','chat')),
  model      text not null,
  input_tokens  integer,
  output_tokens integer,
  created_at timestamptz not null default now()
);

create index ai_usage_user_idx on public.ai_usage(user_id, created_at desc);

create trigger entitlements_set_updated_at
  before update on public.entitlements
  for each row execute function public.set_updated_at();

alter table public.entitlements enable row level security;
alter table public.ai_usage     enable row level security;

revoke all on public.entitlements from anon, public, authenticated;
revoke all on public.ai_usage     from anon, public, authenticated;
grant select on public.entitlements to authenticated;
grant select on public.ai_usage     to authenticated;

create policy entitlements_select_own on public.entitlements
  for select to authenticated using ((select auth.uid()) = user_id);
create policy entitlements_owner_only on public.entitlements
  as restrictive for all to authenticated using ((select auth.uid()) = user_id);

create policy ai_usage_select_own on public.ai_usage
  for select to authenticated using ((select auth.uid()) = user_id);
create policy ai_usage_owner_only on public.ai_usage
  as restrictive for all to authenticated using ((select auth.uid()) = user_id);
