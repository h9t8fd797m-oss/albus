-- Count the tokens Anthropic charges for and we were throwing away.
--
-- **The ledger has been undercounting every cached call since caching was
-- switched on.** `response.usage.input_tokens` from the Anthropic API counts
-- only the tokens that were neither read from cache nor written to it. The
-- other two live in separate fields, and both are billed:
--
--   cache_creation_input_tokens   1.25x the base input rate  (MORE than input)
--   cache_read_input_tokens       0.10x the base input rate
--
-- `generateBreakdown` and `gradeWork` captured `cache_read_input_tokens` and
-- then dropped it on the floor; `chatReply` never captured it at all; and
-- `cache_creation_input_tokens` was captured nowhere, despite being the
-- expensive one. `finalize_ai_usage` took input and output only, so none of it
-- could have reached a cost figure even if the Edge Functions had passed it.
--
-- The blind spot is therefore largest exactly where the money is: a cache write
-- costs 25% more per token than ordinary input and was counted as zero.
--
-- This is not a large sum today -- 43 calls -- but the ledger is the thing the
-- monthly safety ceiling and every reconciliation against the provider's own
-- invoice are computed from. A ceiling that cannot see a quarter of its own
-- spend is not a ceiling, and the gap widens with exactly the traffic caching
-- is meant to make cheap.

alter table public.ai_usage
  add column if not exists cache_write_tokens integer,
  add column if not exists cache_read_tokens integer;

comment on column public.ai_usage.cache_write_tokens is
  'Anthropic cache_creation_input_tokens. Billed at 1.25x the base input rate.';
comment on column public.ai_usage.cache_read_tokens is
  'Anthropic cache_read_input_tokens. Billed at 0.10x the base input rate.';

-- Dropped rather than replaced: `create or replace` with a different argument
-- count creates an overload instead, and two candidates make every existing
-- three-argument call ambiguous.
drop function if exists private.ai_metered_cost(text, integer, integer);

create function private.ai_metered_cost(
  p_model text,
  p_input_tokens integer,
  p_output_tokens integer,
  p_cache_write_tokens integer default 0,
  p_cache_read_tokens integer default 0
) returns bigint
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_input_rate integer;
  v_output_rate integer;
begin
  select p.input_microusd_per_token, p.output_microusd_per_token
    into v_input_rate, v_output_rate
    from private.ai_model_prices p
   where p.model = p_model;

  if not found then
    v_input_rate := 50;
    v_output_rate := 100;
    raise warning 'AI model "%" has no configured token price; using fallback input=50/output=100 micro-USD per token',
      coalesce(p_model, '<null>');
  end if;

  -- **Multiply before dividing, deliberately.** Rates are whole micro-USD per
  -- token and Haiku's input rate is 1, so `rate / 10` for a cache read is zero
  -- in integer arithmetic -- the cheapest model would price its cached tokens
  -- at exactly nothing, which is the bug this migration exists to remove.
  -- Scaling by the multiplier first keeps the result honest; the remaining
  -- truncation is under one micro-USD per call.
  return greatest(0, coalesce(p_input_tokens, 0))::bigint * v_input_rate
       + greatest(0, coalesce(p_output_tokens, 0))::bigint * v_output_rate
       + (greatest(0, coalesce(p_cache_write_tokens, 0))::bigint * v_input_rate * 125) / 100
       + (greatest(0, coalesce(p_cache_read_tokens, 0))::bigint * v_input_rate * 10) / 100;
end;
$$;

revoke all on function private.ai_metered_cost(text, integer, integer, integer, integer)
  from public, anon, authenticated;

-- Same reasoning: drop, then recreate with the two new arguments defaulted.
-- The Edge Functions call this through PostgREST with *named* arguments, so a
-- caller that has not been redeployed yet still resolves to this function and
-- simply gets the previous behaviour -- no window during a deploy where a
-- finalisation fails and leaves a reservation stranded.
drop function if exists public.finalize_ai_usage(uuid, text, integer, integer, text);

create function public.finalize_ai_usage(
  p_usage_id uuid,
  p_state text,
  p_input_tokens integer default null,
  p_output_tokens integer default null,
  p_failure_code text default null,
  p_cache_write_tokens integer default null,
  p_cache_read_tokens integer default null
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_input integer := least(2000000, greatest(0, coalesce(p_input_tokens, 0)));
  v_output integer := least(2000000, greatest(0, coalesce(p_output_tokens, 0)));
  v_cache_write integer := least(2000000, greatest(0, coalesce(p_cache_write_tokens, 0)));
  v_cache_read integer := least(2000000, greatest(0, coalesce(p_cache_read_tokens, 0)));
  v_changed integer;
begin
  if p_state not in ('completed', 'failed') then
    raise exception 'INVALID_USAGE_STATE' using errcode = '22023';
  end if;

  update public.ai_usage u
     set attempt_state = p_state,
         input_tokens = case when p_input_tokens is null then null else v_input end,
         output_tokens = case when p_output_tokens is null then null else v_output end,
         cache_write_tokens = case when p_cache_write_tokens is null then null else v_cache_write end,
         cache_read_tokens = case when p_cache_read_tokens is null then null else v_cache_read end,
         -- Unchanged rule: a row with no token evidence at all keeps its
         -- conservative reservation rather than becoming free. Cache tokens
         -- alone are enough evidence to price a call, because a request that
         -- read its whole prompt from cache genuinely has near-zero fresh input.
         actual_cost_microusd = case
           when p_input_tokens is null and p_output_tokens is null
                and p_cache_write_tokens is null and p_cache_read_tokens is null then null
           else least(
             10000000::bigint,
             private.ai_metered_cost(u.model, v_input, v_output, v_cache_write, v_cache_read)
           )::integer
           end,
         failure_code = case when p_state = 'failed'
                             then left(coalesce(p_failure_code, 'UNKNOWN'), 64)
                             else null end,
         finished_at = now()
   where u.id = p_usage_id
     and u.attempt_state = 'reserved';

  get diagnostics v_changed = row_count;
  return v_changed = 1;
end;
$$;

revoke all on function public.finalize_ai_usage(uuid, text, integer, integer, text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.finalize_ai_usage(uuid, text, integer, integer, text, integer, integer)
  to service_role;

-- Prove the pricing, rather than trusting the arithmetic above.
do $$
declare
  v_cost bigint;
begin
  -- Sonnet: input 2, output 10 micro-USD per token.
  -- 1000 input + 100 output + 1000 cache writes + 10000 cache reads
  --   = 2000 + 1000 + (1000*2*125/100 = 2500) + (10000*2*10/100 = 2000) = 7500
  select private.ai_metered_cost('claude-sonnet-5', 1000, 100, 1000, 10000) into v_cost;
  if v_cost <> 7500 then
    raise exception 'sonnet cache pricing is %, expected 7500', v_cost;
  end if;

  -- Haiku input rate is 1, the case integer division would silently zero.
  -- 10000 cache reads = 10000*1*10/100 = 1000, NOT 0.
  select private.ai_metered_cost('claude-haiku-4-5', 0, 0, 0, 10000) into v_cost;
  if v_cost <> 1000 then
    raise exception 'haiku cache reads priced at %, expected 1000 (integer division bug)', v_cost;
  end if;

  -- A cache write must cost more than the same number of ordinary input tokens.
  if private.ai_metered_cost('claude-opus-5', 0, 0, 1000, 0)
     <= private.ai_metered_cost('claude-opus-5', 1000, 0, 0, 0) then
    raise exception 'a cache write is not priced above ordinary input';
  end if;

  -- Old three-argument behaviour must be unchanged when no cache is involved.
  if private.ai_metered_cost('claude-sonnet-5', 1412, 316) <> 5984 then
    raise exception 'uncached pricing changed; expected 1412*2 + 316*10 = 5984';
  end if;
end $$;
