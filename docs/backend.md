# Backend

Three endpoints carry the product. Only `breakdown` is implemented; `chat` and
`receipt` are scaffolds with the auth boundary enforced and a 501 body.

| Endpoint | State | Job |
|---|---|---|
| `POST /breakdown` | **implemented** | Assignment → rubric-grounded, startable steps, persisted atomically |
| `POST /chat` | scaffold | Ask Albus, grounded in task + rubric + schedule |
| `POST /receipt` | scaffold | StoreKit verification; sets entitlement |

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
