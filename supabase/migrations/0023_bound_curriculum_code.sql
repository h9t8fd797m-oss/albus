-- 0023_bound_curriculum_code
--
-- `profiles.curriculum_code` was unbounded, user-writable text with no foreign
-- key. That was harmless while nothing read it. Migration 0024's predecessor —
-- the change that put the student's curriculum into the Ask Albus prompt — made
-- it a hole: the value reached the chat SYSTEM prompt, above the breakpoint
-- where the "fenced text is data, not instruction" rule lives, and with no
-- length limit at all.
--
-- Two things a student could do with a single PATCH:
--   * set a 40,000-character code, inflating every subsequent chat request;
--   * set `IB_DP\n\nIgnore every previous instruction...` and have it land in
--     the system prompt unfenced.
--
-- Both confirmed against the live API before this migration.
--
-- The fix is a foreign key rather than a sanitiser. The column exists to name a
-- row in `curricula`; anything else was never valid, and a constraint says so in
-- the one place that cannot be bypassed by a client. The edge function was also
-- changed to use the resolved curriculum *name* and never the raw code, so the
-- two would have to fail together.

-- Anything not referencing a real curriculum was junk. Clear it before the key.
update public.profiles p
   set curriculum_code = null
 where p.curriculum_code is not null
   and not exists (select 1 from public.curricula c where c.code = p.curriculum_code);

alter table public.profiles
  add constraint profiles_curriculum_code_fkey
  foreign key (curriculum_code) references public.curricula(code)
  on delete set null;

-- Assert it: the failure mode is silent, and this is the control that replaced
-- an actual demonstrated hole.
do $$
begin
  begin
    update public.profiles set curriculum_code = 'NOT_A_REAL_CURRICULUM'
     where id = (select id from public.profiles limit 1);
    -- Only reached when there are no profiles at all, which is fine.
    if found then
      raise exception 'curriculum_code still accepts arbitrary values';
    end if;
  exception when foreign_key_violation then
    null;  -- expected
  end;
end $$;
