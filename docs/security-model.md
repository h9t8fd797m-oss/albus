# Security model

Written against Supabase's current guidance (RLS, anonymous sign-ins,
production checklist, publishable/secret keys). Re-read it before adding a
table.

---

## 1. Identity

Every Albus user is a real row in `auth.users`. The first launch calls
`signInAnonymously()`, which issues a genuine JWT with a stable `sub`. There is
no "no account" state — there is an *unlabelled* account.

This matters for policy design: **anonymous users hold the `authenticated`
Postgres role, exactly like permanent users.** They are not `anon`. The `anon`
role belongs to unauthenticated requests carrying only the publishable key, and
in this project `anon` can read nothing at all.

A JWT carries `is_anonymous`, so a policy can distinguish the two if it ever
needs to. Today nothing does: every user owns their own work regardless of how
they signed in. At purchase, the anonymous user is *linked* to Apple Sign-In
rather than replaced, so no data migration happens and no row changes owner.

The session lives in the iOS Keychain, which survives app deletion. That is
deliberate: it stops "delete and reinstall" resetting the free-tier quota.

## 2. Row Level Security

Every table in `public` has RLS enabled. `anon` and `public` are revoked from
all of them; `authenticated` is granted only the verbs it actually needs.

User-owned tables carry **five** policies:

```sql
-- four permissive, one per verb, each scoped to the owner
create policy t_select_own on public.t for select to authenticated
  using ((select auth.uid()) = user_id);
-- ... insert / update / delete ...

-- one restrictive, the invariant
create policy t_owner_only on public.t as restrictive for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
```

Three deliberate choices in there:

**`as restrictive`** — permissive policies combine with `OR`, so one careless
policy added later can widen access to everything. Restrictive policies combine
with `AND`. The owner-only policy is the invariant that survives future
mistakes: on this table, `uid()` equals `user_id`, always.

**`to authenticated`** — a policy with no role applies to every role. Naming
the role keeps `anon` out even if a grant is ever added by accident.

**`(select auth.uid())`** not `auth.uid()` — wrapping it in a subquery lets
Postgres evaluate it once per statement instead of once per row. Supabase lints
the unwrapped form as `0003_auth_rls_initplan`. On a table with thousands of
sessions this is the difference between a fast query and a slow one.

Reference tables (curriculum, rubrics, priors) are readable by any signed-in
user and have **no** write policy for `authenticated`. An operation with no
matching policy is denied — that is the enforcement, not an oversight.

`entitlements` and `ai_usage` are read-only to their owner and written only by
the service role. A user cannot grant themselves Plus; it is not a check in
application code, it is the absence of a policy.

## 3. Keys

| Key | Where it lives | Bypasses RLS |
|---|---|---|
| `sb_publishable_...` | inside the iOS app | no |
| `sb_secret_...` | Edge Function secrets only | **yes** |
| `ANTHROPIC_API_KEY` | Edge Function secrets only | n/a |

We use the new publishable/secret keys rather than legacy `anon`/`service_role`
because they rotate independently — one leak forces one rotation, not a
project-wide JWT secret change. Secret keys also return 401 if used from a
browser.

The publishable key is designed to be public; RLS is what protects data. It is
still kept out of git so it can be rotated without a code change.

## 4. Edge Functions

`_shared/auth.ts` enforces the rule that matters: **identity comes from the
verified JWT, never from the request body.** `requireUser()` ignores the body
entirely. A payload claiming `{"user_id": "..."}` is an untrusted claim.

Functions get a caller-scoped client by default, so RLS still applies inside
the function — a bug in function logic cannot read another user's rows. The
admin client is reached for explicitly and only for writes the user must not
control.

## 5. SECURITY DEFINER

Two functions run elevated: `handle_new_user` (creates a profile before the
user has rights on the table) and `reap_abandoned_anonymous_users`.

Both pin `set search_path = ''` and schema-qualify every reference. Without
that, a caller who controls `search_path` can shadow a table name and redirect
the function's writes. `EXECUTE` is revoked from `public`, `anon` and
`authenticated` on both.

## 6. Abuse

Anonymous sign-up is rate-limited by Supabase to 30/hour per IP. Every
abandoned first launch still leaves a row, and Supabase does not clean these
up, so `reap_abandoned_anonymous_users(30)` deletes anonymous users older than
30 days who never created an assignment or logged a completion. It is written
but **not scheduled** — enable `pg_cron` and schedule it once there is traffic.

**Before launch:** turn on CAPTCHA for anonymous sign-ins
(`[auth.captcha]` in `config.toml`). It is the single most effective control
against someone inflating the user table.

## 7. Deliberately not done yet

Honest list, so none of these are mistaken for oversights:

- **CAPTCHA is off.** Needed before launch, not before the first build.
- **Apple Sign-In is off.** Needs the Apple Developer account configured.
- **`force row level security` is not set.** It would apply RLS to the table
  owner too, which locks the dashboard SQL editor out of its own tables. The
  service role bypasses RLS by role attribute regardless, so FORCE buys little
  here and costs real debugging time.
- **No SSL enforcement / network restrictions.** Free-plan project; revisit at
  launch per the Supabase production checklist.
- **No custom SMTP.** Not needed — the app sends no email.
- **MFA on the Supabase account** is a dashboard setting only you can enable.
  Do it: that account is the root of everything here.

## 8. After any schema change

Run `scripts/verify-rls.sql`. Part 1 audits the policy surface; part 2 creates
two users and actively tries to read, forge and update across the boundary.
Every row must return `pass = true`.

Then run the Supabase Security Advisor and confirm it is empty.
