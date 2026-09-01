# Albus security and financial-safety model

This document describes the current system, not the intended one. The threat
model is simple: **the iOS client is hostile**. A student can inspect it, patch
it, replace every local entitlement value, replay requests, call Supabase
directly, and send arbitrary ids and documents. Nothing on the device decides
whether another person's data is visible or whether Albus pays for an AI call.

## 1. Identity

Every student is a real `auth.users` row. First launch creates an anonymous
Supabase user and stores its rotating session in the iOS Keychain. Anonymous
users hold the `authenticated` Postgres role; `anon` means no signed-in user and
has no table grants at all.

The Keychain survives ordinary app deletion, so reinstalling does not normally
mint a fresh allowance. It is not treated as proof of personhood: accounts can
still be created outside the app, which is why rate, risk, and global financial
controls exist underneath it.

`requireUser()` validates the bearer token with Supabase Auth. Identity always
comes from that JWT's `sub`; no Edge Function accepts `user_id` from a body.

## 2. Data isolation and the write surface

Every `public` table has RLS enabled. User-owned SELECT/DELETE operations compare
`(select auth.uid())` with the row owner, and restrictive owner policies remain
an invariant underneath permissive policies. Reference data is read-only.

Raw access is narrower than the policies:

- `entitlements`, `ai_usage`, subscription, risk, and security-event tables have
  no client grants in either direction.
- assignments are readable and owner-deletable; creation goes through
  `create_assignment_with_plan`.
- rubrics are readable and owner-deletable; writes go through `upsert_rubric`.
- courses are readable; creation goes through `create_course`.
- remote subtasks are read-only. Remote plan sessions and completion logs are
  outside the client surface because the current app schedules and estimates in
  SwiftData, not those tables.

The three write RPCs derive the owner from `auth.uid()` and run elevated only so
their base-table grants can stay closed. Their bodies schema-qualify every
relation. Triggers independently enforce course/rubric ownership, active-task
limits, rubric limits, child limits, and high absolute abuse ceilings. Thus a
future caller cannot bypass a rule by skipping the RPC.

`my_plan()` and `my_tier()` take no user argument. Internal functions which do
take a user id are revoked from `authenticated`, preventing one-row-at-a-time
subscription or usage enumeration.

## 3. Keys and Edge Functions

| Secret | Location | Property |
|---|---|---|
| Supabase publishable key | iOS app | public by design; RLS applies |
| `ALBUS_SUPABASE_SECRET_KEY` | Edge secrets | bypasses RLS; never in client/repo |
| `ANTHROPIC_API_KEY` | Edge secrets | pays for model calls |
| RevenueCat webhook secrets | Edge secrets | authenticate and sign payment events |
| `ALBUS_SIGNAL_PEPPER` | Edge secrets | makes stored signal hashes non-reversible |

Student functions have gateway JWT verification enabled and call `requireUser`
again. The RevenueCat webhook is the sole no-JWT function because RevenueCat is
not an Albus user; it has two independent checks described below.

Bodies are streamed through byte ceilings before JSON parsing: 16 KiB for plan
generation, 32 KiB for chat, 128 KiB for grading, and 64 KiB for RevenueCat.
Field-level limits then bound prompt content. A declared or streamed oversized
body is cancelled before full allocation.

User-owned ids are loaded through the caller-scoped client, so RLS decides what
they resolve to. Breakdown additionally rejects a foreign course/rubric before
calling Anthropic, avoiding a paid generation that is guaranteed to fail when
saved. Prompt inputs are fenced and tag-like student text is stripped; output
is schema-constrained and normalized before persistence.

## 4. AI financial protection

The order is intentional:

1. verify JWT;
2. enforce a compact per-account API request window (30/minute, 180/hour);
3. parse and validate bounded input;
4. load only caller-owned context;
5. acquire the global then per-user database locks;
6. check emergency stop, global calls, and conservative USD budgets;
7. evaluate account risk and server-side plan entitlement;
8. check delivered-result allowance and all-attempt rate limits;
9. reserve a worst-case cost row;
10. call Anthropic;
11. finalize the reservation once with server-derived token cost.

The app cannot execute reservation or finalization RPCs. The Edge Function uses
the service role and passes the id obtained from the verified JWT.

Automatic provider retries are disabled. The Messages API does not provide a
dependable idempotency guarantee for SDK retries, so one database reservation
maps to at most one Anthropic request. A user-initiated retry is a new attempt
and must pass every gate above again.

Allowance and financial exposure are deliberately different counters:

- completed work and genuinely in-flight reservations consume the student's
  purchased allowance;
- failed work gives the allowance back;
- every attempt, including failures, consumes the rate window;
- every reservation, including an abandoned one, consumes conservative global
  cost capacity for its hour/day.

This prevents both failure farming and a runtime crash erasing cost evidence.
Finalization is a one-way `reserved -> completed|failed` transition; replaying
it cannot alter outcome, model, owner, or cost.

Launch circuit breakers live in server-only `app_config`: 100 AI calls/hour,
US$2/hour and US$10/day of worst-case reservations, plus an immediate emergency
stop. These are intentionally low until real traffic establishes safe capacity.

Each account also has a private rolling 30-day loss ceiling: US$1 Free,
US$5.50 Plus and US$12 Pro. Completed calls count measured server-priced tokens;
unfinished or unknown calls retain their worst-case reservation. A crashed Edge
isolate therefore cannot erase cost, and one manipulated account cannot consume
an unbounded share of the project budget. This backstop is separate from, and
checked after, product entitlement so its refusal is never presented as a plan.

Current paid allowances are server rows, not UI literals: Free gets no chat or
grading; Plus gets two gradings per rolling seven days; Pro gets five and 300
assignment-grounded Ask Albus turns per rolling 30 days. "Unlimited tasks" has
a 500-active/2,000-total abuse ceiling that no honest student should encounter.

## 5. Account farming and privacy

The risk model combines account age, behavior, repeated account creation,
privacy-preserving device correlation, and a coarse network prefix. A device or
IP is never treated as a person:

- no single signal can escalate beyond `elevated`;
- `high`/`severe` requires at least two independent signal families;
- paid accounts are capped at `elevated` because payment is the strongest
  verification available;
- bands age away automatically; existing data never becomes inaccessible.

The app optionally sends iOS `identifierForVendor`, not an advertising id or
hardware fingerprint. The Edge Function reduces IPs to IPv4 `/24` or IPv6
`/48`, HMACs both values with the secret pepper, then discards the originals.
Postgres receives only 64-character digests.

Hostile telemetry is bounded: at most eight device and sixteen network hashes
per user, and at most fifty security events per user/hour. Security events carry
an endpoint and machine code, never a prompt, essay, message, raw IP, or raw
device id. Deleting an anonymous account does not erase its device/network
observations: the now-pseudonymous account UUID remains for the 90-day fraud
window, while the auth row and all student content delete normally. The daily
retention job then removes the observation.

Anonymous signup is limited to ten per IP/hour. CAPTCHA/Turnstile remains a
launch blocker because server-side CAPTCHA cannot be enabled until real
Cloudflare keys are configured on both client and Supabase.

## 6. RevenueCat and entitlements

The client never writes entitlement state. RevenueCat calls a public webhook
which requires:

1. a constant-time checked Authorization secret; and
2. RevenueCat's HMAC over `timestamp.raw_body`, with a five-minute delivery
   replay window.

The signed event id and event time are persisted. Replays and out-of-order
events are ignored, and a subscription already linked to one user cannot move
to another. Products grant nothing until explicitly mapped in the server-only
`subscription_products` allowlist. A second allowlist restricts signed events
to configured Albus RevenueCat app ids, because one RevenueCat project can
deliver events for several apps. Unknown apps/products, null expiry, and
Sandbox events fail closed. Sandbox is rejected independently in the Edge
Function and the database.

Cancellation keeps access until paid expiry. A `SUBSCRIPTION_PAUSED` event also
keeps access until paid expiry because it schedules a pause; only the later
`EXPIRATION` event revokes immediately. `PRODUCT_CHANGE` is informational and
does not change entitlement before the provider reports the actual transaction
state. A `TRANSFER` event never moves Albus entitlement state by itself: the
database refuses to bind an existing original transaction to a different user.
Production RevenueCat setup must use **Transfer if there are no active
subscriptions**, so an active paid period cannot be walked through fresh Free
accounts. This is verified again during the purchase launch checklist.

The RevenueCat SDK, App Store products, webhook secrets, and real product map
are not configured yet. Consequently the payment path is secure-by-closed but
not commercially usable. The removed direct Apple receipt endpoints must not be
redeployed.

## 7. Retention and operations

`prune-security-data` runs daily. It removes expired rate buckets after two
hours, failed/abandoned AI attempts after 30 days, identity links after at least
90 days, and security events after at least 180 days. Successful AI rows remain
for cost reconciliation but contain counts and model names, not submitted work.
The Grader stores result/feedback and a content hash; it never stores the essay.

Production operators must keep Supabase/GitHub MFA enabled, rotate any exposed
provider key, review security events and circuit-breaker usage, and test a kill
switch before launch. Logs must never include request bodies or secrets.

## 8. Verification

After any schema or entitlement change:

```bash
supabase start
supabase db reset --local --no-seed --yes
supabase db lint --local --level warning
supabase test db --local
scripts/security-concurrency-local.sh
```

The pgTAP suite performs 79 privilege, RLS, plan, rate, risk, cost, replay, and
cross-user checks in a rolled-back transaction. The shell test opens twelve
real Postgres connections for one remaining grading/task/rubric and requires
exactly one winner in each race. A one-connection test cannot prove locking.

Also run Edge unit tests, Swift core tests, and iOS unit tests. CI runs database
containers only when migrations/security tests change to keep GitHub cost low.

## 9. Explicit blockers before production

- Rotate the previously exposed Anthropic key and set the dedicated signal
  pepper.
- Configure Turnstile and enable CAPTCHA in client and Supabase together.
- Enable Apple Sign-In/account linking before taking payment.
- Configure RevenueCat products, SDK, dual webhook secrets, and product map;
  verify purchase, renewal, cancellation, expiry, refund, replay, and conflict
  in Sandbox before enabling Production products.
- Enable MFA on Supabase, GitHub, Apple, Anthropic, and RevenueCat accounts.
- Remove temporary Pro grants and old deployed Apple Edge Functions.
- Apply migrations/functions to production, run the live RLS/advisor audit, and
  test the AI emergency stop and budget alerts.
