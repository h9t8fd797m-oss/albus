# Backend

Three endpoints carry the product. Only `breakdown` is implemented; `chat` and
`receipt` are scaffolds with the auth boundary enforced and a 501 body.

| Endpoint | Auth | Job |
|---|---|---|
| `POST /breakdown` | user JWT | Assignment → rubric-grounded, startable steps, persisted atomically |
| `POST /chat` | user JWT | Ask Albus, grounded in one assignment the caller owns |
| `POST /receipt` | user JWT | Verifies a StoreKit 2 signed transaction; derives the entitlement |
| `POST /app-store-notifications` | **none — Apple** | Renewals, cancellations, refunds. Signature is the only gate. |

Almost everything else in the app runs on-device. Scheduling, re-planning,
tool matching, notifications, progress and per-user calibration need no
server — see the architecture notes for the full ledger.

---

## Model routing

Applying a rubric to a specific prompt is genuine reasoning and is the
differentiator, so it gets the stronger model. "Read chapter 12" is
decomposition, not reasoning, and is roughly two thirds of real volume.

| Case | Model | Rate /MTok |
|---|---|---|
| Has rubric criteria | `claude-sonnet-5` | $3 in / $15 out |
| No rubric | `claude-haiku-4-5` | $1 in / $5 out |

Routing lives in `selectModel()` in `_shared/prompt.ts` and is unit-tested.

**Measured latency** (integration run, 2026-08-21): Sonnet with an 8-step
rubric plan ≈ **19s**; Haiku generic ≈ **3–5s**. Comfortably inside the
90-second first-plan target, but it is the dominant term — worth streaming
before adding anything else to that path.

## Prompt caching

`buildSystemPrompt()` is the cacheable half: identical for every student
taking the same assessment in the same course. `buildUserPrompt()` holds
everything volatile. A test asserts the system prompt contains no task title
and no dates, because a single volatile byte above the breakpoint destroys the
hit rate.

**Caching does not currently engage.** Anthropic will not cache a prefix below
roughly 1024 tokens, and the seeded three-criterion rubric produces ~900 input
tokens total. Expect `cache_read_tokens: 0` until rubric blocks grow. This is
correct behaviour, not a bug — but it means the per-call cost today is the
uncached figure.

## Structured output

`output_config.format` with a raw JSON Schema. No zod dependency.

The supported schema subset is narrower than full JSON Schema — verified by
the API rejecting these outright:

- `minItems` above 1 → rejected
- `minimum` / `maximum` on integers → rejected

So `BREAKDOWN_JSON_SCHEMA` encodes **shape only**, and every bound lives in
`validateAndNormalise()`. A schema can guarantee a field is an integer; it
cannot guarantee it is a sane number of minutes.

The validator clamps what is merely implausible and rejects only what cannot
be salvaged — a student waiting on a plan is better served by an adjusted plan
than an error. It also scales a plan down when the model's total overshoots
the student's stated budget by more than 50%.

## Quota

Free tier caps **active** plans at three. Finishing one frees a slot, so a
student in exam season is never walled off mid-week.

Enforced in **two** places, deliberately:

1. `assertCanGeneratePlan()` — a pre-flight check so we never pay Anthropic
   for a generation we are about to reject. Fails *open* on infrastructure
   error, because the authoritative check still runs.
2. `create_assignment_with_plan()` — inside the same transaction as the
   insert, where it cannot race two concurrent requests.

> **Bug found and fixed here (migration 0009).** Only a purchase creates an
> `entitlements` row, so for free users the tier lookup returned NULL. In SQL
> `NULL = 'plus'` is NULL, not false, so `not (NULL and …)` was NULL and the
> `if` never fired — the cap was skipped for exactly the users it exists to
> limit. `coalesce(v_tier = 'plus', false)` is load-bearing.

## Trust boundary

`requireUser()` resolves identity from the verified JWT and ignores the body
entirely. A payload claiming `{"user_id": "..."}` is a claim, not a statement.

Functions get a caller-scoped Supabase client by default, so RLS applies
*inside* the function — a logic bug cannot read another user's rows. The admin
client is reached for explicitly, only for writes the user must not control
(`entitlements`, `ai_usage`).

The model only ever sees rubric **codes** (`A`, `B`), never criterion UUIDs.
Codes are mapped back to ids server-side against the rubric that was actually
loaded, so a hallucinated code becomes `null` rather than a foreign key into
another course's rubric.

## Testing

```bash
cd supabase/functions
deno task test     # 17 unit tests — pure logic, no network, no Docker
deno task check    # type-check every entrypoint
deno task lint
```

Integration test (real API call, costs a few cents, not in the default suite):

```bash
deno run --allow-net --allow-env _tests/integration_breakdown.ts
```

It exercises the rubric path, the generic path, a 20-hour task due tomorrow,
and a one-word title — and asserts the model never invents a criterion code.

Database-side behaviour (RLS, quota, atomicity) is verified by
`scripts/verify-rls.sql` and the probes in the PR description.


---

## Ask Albus

Grounded in exactly one assignment, loaded through the **caller-scoped** client
so RLS decides what can enter the context window. A forged `assignment_id`
finds nothing and the reply degrades to ungrounded planning advice — it never
errors in a way that reveals whether the id exists.

Routing mirrors breakdown: rubric present → `claude-sonnet-5`, otherwise
`claude-haiku-4-5`. `max_tokens` is held at 700; this answers questions about a
plan, and an essay-length reply means the model has wandered.

`sanitiseHistory()` is a security boundary, not a formatting helper. It drops
anything that is not a `user`/`assistant` turn — a client sending
`{"role":"system"}` is attempting to rewrite the instructions — truncates each
turn, caps the number of turns, and forces the sequence to start with a user
message.

## Payments

Two paths, one source of truth.

**`receipt`** takes a StoreKit 2 signed transaction from the client and
verifies it against Apple's root certificates, which ship embedded in
`_shared/apple_roots.ts` rather than being fetched at runtime. Nothing about
tier, price or expiry is read from the request body; only the fields inside the
verified payload count.

**`app-store-notifications`** receives Apple's server notifications. It is
deployed `--no-verify-jwt` because Apple cannot present a user token — the JWS
signature *is* the authentication, and every path refuses to act on anything
that fails verification.

Three properties worth stating explicitly:

- **Replay is blocked by the primary key.** `subscription_transactions` is keyed
  on `original_transaction_id`, and `apply_subscription_state` returns
  `conflict` if a second user presents a receipt already bound to someone else.
  A leaked receipt cannot be redeemed twice.
- **Entitlements are written from exactly one function**, which is revoked from
  every client role. There is no code path by which a client sets its own tier.
- **Sandbox is gated.** `APPLE_ALLOW_SANDBOX` must be `true` for sandbox
  receipts to be accepted. Leave it unset in production or a free sandbox
  tester account becomes free Plus.

Apple does not know our user ids, so a notification for an unknown subscription
is stored as `unlinked` and grants nothing until a signed client call binds it
to an account.

## Rate limiting

`check_and_record_ai_usage` reserves a slot **before** the model is called, in
the same transaction as the count. Two concurrent requests cannot both read the
last remaining unit. A failed generation still consumes its slot, which is the
correct direction to err.

| | free / hour | free / day | plus / hour | plus / day |
|---|---|---|---|---|
| breakdown | 8 | 25 | 30 | 150 |
| chat | 20 | 60 | 120 | 600 |

Separate budgets per kind, so exhausting chat does not block planning.

## Advisor findings that are intentional

The database advisor reports three classes of finding on this schema. All are
expected; none is an oversight.

- **`rls_enabled_no_policy` on `subscription_transactions`** — deliberate. RLS
  on, no grants, no policies means every client role is denied outright. This is
  the strongest posture available, and the linter reads the absence of policies
  as an omission.
- **`authenticated_security_definer_function_executable`** — the two usage RPCs
  must be DEFINER, because `authenticated` holds no write grant on `ai_usage`.
  Both derive the user from `auth.uid()` and scope every write to that user.
  Migration 0012 additionally bounds what they will persist.
- **`auth_allow_anonymous_sign_ins`** — the entire product is anonymous-first.
  Every user holds the `authenticated` role via an anonymous session; this is
  the design, not a leak.
