-- Stop deleting an account from erasing what it cost.
--
-- `docs/security-model.md` § 7 says: "Successful AI rows remain for cost
-- reconciliation but contain counts and model names, not submitted work."
-- That was not true. `ai_usage_user_id_fkey` was `ON DELETE CASCADE`, so
-- deleting an `auth.users` row took every one of that user's AI cost records
-- with it — including the completed ones the sentence promises to keep.
--
-- The consequence is narrow but real: an account deleted after spending money
-- leaves the spend unaccounted for, and the monthly safety ceiling and any
-- reconciliation against the provider's own bill both go quiet about it. A
-- deletion is also exactly the moment an abusive account is most likely to be
-- removed, which is when its cost history is most worth having.
--
-- `SET NULL` rather than `RESTRICT`, and the row is anonymised rather than
-- retained whole: what survives is a model name, token counts and a cost. No
-- prompt, no submitted work, and after this no user either. That is the same
-- shape `security_events` and `subscription_transactions` already use for
-- records that must outlive the account — this table was the one that did not
-- follow the pattern.
--
-- RLS needs no change. Both policies compare `auth.uid() = user_id`, and
-- `NULL = uid` is NULL rather than true, so an orphaned row is visible to
-- nobody through the API. Quota and rate windows filter by `user_id` too, so a
-- null row matches no living account's allowance — a deleted user cannot leave
-- quota behind for anyone to inherit.

alter table public.ai_usage
  alter column user_id drop not null;

alter table public.ai_usage
  drop constraint ai_usage_user_id_fkey;

alter table public.ai_usage
  add constraint ai_usage_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

-- Prove the thing this migration exists for, rather than trusting the DDL.
do $$
declare
  v_rule text;
  v_notnull boolean;
begin
  select case con.confdeltype when 'n' then 'SET NULL' when 'c' then 'CASCADE'
                              when 'a' then 'NO ACTION' when 'r' then 'RESTRICT'
                              when 'd' then 'SET DEFAULT' end
    into v_rule
    from pg_constraint con
   where con.conrelid = 'public.ai_usage'::regclass
     and con.contype = 'f'
     and con.conname = 'ai_usage_user_id_fkey';

  if v_rule is distinct from 'SET NULL' then
    raise exception 'ai_usage.user_id delete rule is %, expected SET NULL', v_rule;
  end if;

  select attnotnull into v_notnull
    from pg_attribute
   where attrelid = 'public.ai_usage'::regclass and attname = 'user_id';

  if v_notnull then
    raise exception 'ai_usage.user_id is still NOT NULL; SET NULL could never fire';
  end if;
end $$;
