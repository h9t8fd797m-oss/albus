-- 0001_foundation
-- Extensions, shared helpers, and the profile bootstrap trigger.
-- Security notes:
--   * SECURITY DEFINER functions pin `search_path = ''` so a malicious
--     search_path cannot redirect an unqualified reference. Every object
--     inside them is therefore schema-qualified.
--   * EXECUTE is revoked from public/anon; nothing here is client-callable.

create extension if not exists "pgcrypto" with schema extensions;

-- ── updated_at maintenance ────────────────────────────────────────────────
create or replace function public.set_updated_at()
returns trigger
language plpgsql
security invoker           -- runs as the caller; no elevation needed
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke all on function public.set_updated_at() from public, anon;

-- ── profile bootstrap ─────────────────────────────────────────────────────
-- Fires on auth.users insert. Needs DEFINER because the signing-up user has
-- no rights on public.profiles at that instant.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id)
  values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke all on function public.handle_new_user() from public, anon, authenticated;
