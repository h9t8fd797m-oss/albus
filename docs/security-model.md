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

**Account farming is bounded by a global fuse.** Per-user limits cap what one
account can spend; nothing capped what a thousand accounts could. Anonymous
sign-up is the entire onboarding, so it cannot be removed, and CAPTCHA cannot
be enabled until the client can present a challenge — Supabase rejects every
sign-up without a token the moment it is switched on.

`check_and_record_ai_usage` therefore checks a **global ceiling before the
per-user ones**: total AI calls across every account in the last hour, read
from `app_config` so it can be raised without a migration. A flood of fresh
accounts, each individually within its allowance, still stops at a known
number. It is a fuse, not a quota — it should never fire in normal operation.

Per-IP anonymous sign-ups were also lowered from 30/hour to 10. A genuine
student needs one; a shared school NAT might need a handful.

### Account risk (migration 0035)

The fuse bounds the damage; it does not notice the farm. `account_risk(uid)`
does, and its whole design is shaped by what it must **not** do.

**A device is not a person and an IP is not a household.** A sixth-form college
hands out shared iPads. A family runs four students off one router. A carrier
can put a city behind a handful of addresses. Blocking on either signal alone
does not catch a farm; it catches a class.

Six signals in four families — device sharing, network, behaviour, account age —
each contributing a graduated score, never a verdict. Three rules are enforced
in the function rather than merely intended:

1. **No single signal can escalate past `elevated`.** Two independent families
   are required. Account age is deliberately excluded from that count: every
   real student is minutes old exactly once, and being new is not evidence.
2. **A paid account is never escalated past `elevated`.** Somebody who completed
   a payment has passed the strongest identity check this system has. Rate
   limits still apply — a stolen account must not run away — but they are never
   asked to prove themselves again.
3. **Escalation buys friction, not a door.** `elevated` halves burst limits.
   `high` quarters them and asks for a real sign-in — but only once there is one
   to ask for, because a door with no key is a wall (`risk_verification_available`
   is 0 until Turnstile or Apple Sign-In is switched on). Only `severe` refuses,
   and only model calls: every screen, every saved plan and every rubric the
   student has already written stays reachable at every band.

Every band recovers without us. The signals age out of their own windows, so a
score falls on its own — there is no list to be on and nothing to appeal to.

Verified against the live database, through the real signup and HTTP path:

| scenario | score | band | outcome |
|---|---|---|---|
| 30 fresh accounts, one school network, 30 devices | 40 | `elevated` | tightened, not blocked |
| 6 accounts, one device, one afternoon | 90 | `severe` | refused at account 5 |
| the same six signals on a paying account | — | `elevated` | allowed |
| the same farm, 25 hours later | 40 | `elevated` | recovered by itself |

### What the risk layer stores

**Hashes, and nothing else.** The Edge Function computes
`HMAC-SHA256(value, pepper)` and sends only the digest, so no raw IP address and
no device identifier ever reaches Postgres — not in a column, not in a query
log, not in a backup. The pepper lives in function secrets; rotating it retires
the entire correlation set by design.

- **The device identifier is iOS `identifierForVendor`** — per-vendor, reset
  when the user deletes every app of ours, and not a hardware serial. It is the
  weakest identifier that answers the question, which is the correct one to
  pick. The client may withhold it and everything still works.
- **The IP is reduced to a prefix first** — /24 for IPv4, /48 for IPv6. Less
  identifying, and the right granularity: consumer addresses rotate and carriers
  hand one address to thousands of people, so scoring the full address would be
  simultaneously more invasive and less useful.
- **`x-forwarded-for` is read from the last entry, not the first.** The first is
  the conventional "original client" and is exactly the entry a client can
  forge. A signal the attacker chooses is worse than no signal, because it looks
  like evidence.
- **`security_events` records the code and the endpoint** — never a request
  body, never the work, never a message. It is written from the Edge Function
  rather than from the gate because a raised exception rolls back its own
  transaction: a log line written next to the `raise` would be discarded exactly
  when it mattered.

`prune_security_data()` drops links at 90 days and events at 180 — both longer
than any window the model reads, so pruning cannot change a live score. It is
written but **not scheduled**, the same position `reap_abandoned_anonymous_users`
is in and for the same reason.

**Before launch:** turn on CAPTCHA for anonymous sign-ins
(`[auth.captcha]` in `config.toml`), and set `risk_verification_available` to 1
in the same change.

## 7. Entitlements

Three tiers — Free, Plus, Pro — and **every limit is a row in `public.plans`**,
read by the gate, the meter and the paywall alike. The client is never trusted
to decide access; `EntitlementService` exists to show the right screen, and a
tampered value there buys a nicer paywall and nothing else.

The chain, in order: **authentication → authorization → entitlement → usage →
rate limit → abuse detection.** Each layer assumes the one above it may have
failed.

- **`entitlements` is server-written.** Clients hold SELECT and nothing else. A
  user cannot grant themselves Pro; that is not a check in application code, it
  is the absence of a policy. A foreign key to `plans` and a CHECK constraint
  mean a bad webhook cannot write a tier that silently compares false everywhere.
- **`plans` is readable and not writable.** It is a price list. A student who
  reads it learns what Plus costs, which is what the paywall tells them anyway.
- **Functions that take a uid stay internal.** `effective_tier(uuid)`,
  `account_risk(uuid)` and `ai_spend_count(uuid, …)` are revoked from
  `authenticated`; any one of them made callable turns "cannot read another
  user's data" into "can, one row at a time". The client-facing `my_plan()` and
  `my_tier()` take **no arguments**, which makes asking about somebody else
  structurally impossible rather than merely forbidden.
- **Row-count limits are triggers, not RPCs.** `authenticated` holds INSERT on
  `assignments`, `rubrics` and `subtasks`, so a limit living only inside an RPC
  is bypassed by a client that does not call it — which was a live bypass until
  migration 0036.
- **Counting is serialised per user.** `pg_advisory_xact_lock` keyed on the
  caller, because reserve-then-spend races under READ COMMITTED and did.

`scripts/verify-entitlements.sql` attacks all of this with real accounts: 46
checks covering plan spoofing, cross-account reads, usage tampering, every tier
boundary, the direct-insert bypasses, and the risk model's two headline
scenarios. Every row must return `pass = true`.

**It cannot test concurrency.** One connection cannot demonstrate a race, and
worse, it will report a race-prone gate as clean — which is exactly what
happened. That check has to go over HTTP with real sockets; the recipe is in the
script's header.

## 8. Deliberately not done yet

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

## 9. After any schema change

Run **both** harnesses. `scripts/verify-rls.sql` audits the policy surface and
tries to read, forge and update across the boundary.
`scripts/verify-entitlements.sql` assumes the policies are right and tries to
get past them anyway. Every row of both must return `pass = true`.

Then run the Supabase Security Advisor and confirm it is empty.
