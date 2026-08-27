// _shared/quota.ts
//
// The free tier caps ACTIVE plans, not plans per month — a student in exam
// season must never hit a wall mid-week. Finishing an assignment frees a slot.
//
// This is the *pre-flight* check and it is an optimisation, not a control: it
// exists so we never pay Anthropic for a generation we are about to reject.
// The enforcement is a trigger on `public.assignments` (migration 0036), which
// holds whatever path the write arrives by — including the one that skips this
// file entirely by POSTing straight to the table, which is how the cap was
// bypassed before that trigger existed.

import { adminClient, type Caller } from "./auth.ts";
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { HttpError } from "./http.ts";

/**
 * Refuse early if the student is already holding as many open tasks as their
 * plan allows.
 *
 * The limit is read from `public.plans` rather than written here. Three tiers
 * with five limits each is fifteen numbers, and a copy of any of them in this
 * file is a number that will eventually disagree with the one the database
 * enforces — which is the bug migration 0033 had to fix on the meter.
 */
export async function assertCanGeneratePlan(caller: Caller): Promise<void> {
  const admin = adminClient();

  const { data: tier, error: tierError } = await admin
    .rpc("effective_tier", { p_uid: caller.id });

  // Fail open on an infrastructure error: the trigger still enforces the cap,
  // so the worst case is a wasted generation, not a bypassed limit.
  if (tierError) {
    console.warn("quota pre-check could not resolve tier:", tierError.message);
    return;
  }

  const { data: plan } = await admin
    .from("plans")
    .select("active_tasks")
    .eq("tier", (tier as string) ?? "free")
    .maybeSingle();

  const limit = plan?.active_tasks as number | null | undefined;
  // null is unlimited; undefined means the lookup failed and the trigger has it.
  if (limit === null || limit === undefined) return;

  const { count, error } = await admin
    .from("assignments")
    .select("id", { count: "exact", head: true })
    .eq("user_id", caller.id)
    .eq("status", "active");

  if (error) {
    console.warn("quota pre-check failed, deferring to the trigger:", error.message);
    return;
  }

  if ((count ?? 0) >= limit) {
    throw new HttpError(
      402,
      "PLAN_TASK_LIMIT_REACHED",
      "That's as many tasks as your plan keeps open at once. Finish one, or upgrade.",
    );
  }
}

/**
 * Records token usage after the response has been sent.
 *
 * `void (async () => ...)()` was losing these writes: Supabase Edge Runtime may
 * tear the isolate down as soon as the response is returned, so a promise with
 * nothing holding it is not guaranteed to run. `EdgeRuntime.waitUntil` keeps
 * the worker alive until it settles. Still fire-and-forget from the caller's
 * point of view — token accounting must never fail a student's request — but
 * now it actually happens.
 */
export function recordTokensInBackground(
  db: SupabaseClient,
  usageId: string,
  inputTokens: number,
  outputTokens: number,
): void {
  const write = (async () => {
    try {
      await db.rpc("record_ai_usage_tokens", {
        p_usage_id: usageId,
        p_input_tokens: inputTokens,
        p_output_tokens: outputTokens,
      });
    } catch (e) {
      console.warn("token accounting failed:", e);
    }
  })();

  const runtime = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } })
    .EdgeRuntime;
  if (runtime?.waitUntil) runtime.waitUntil(write);
}
