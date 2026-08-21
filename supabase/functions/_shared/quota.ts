// _shared/quota.ts
//
// The free tier caps ACTIVE plans, not plans per month — a student in exam
// season must never hit a wall mid-week. Finishing an assignment frees a slot.
//
// This is the *pre-flight* check: it exists so we never pay Anthropic for a
// generation we are about to reject. The authoritative check lives inside
// create_assignment_with_plan, in the same transaction as the insert, where
// it cannot race.

import { adminClient, type Caller } from "./auth.ts";
import { HttpError } from "./http.ts";

export const FREE_ACTIVE_PLAN_LIMIT = 3;

export async function assertCanGeneratePlan(caller: Caller): Promise<void> {
  const admin = adminClient();

  const { data: ent } = await admin
    .from("entitlements")
    .select("tier, expires_at")
    .eq("user_id", caller.id)
    .maybeSingle();

  const isPlus = ent?.tier === "plus" &&
    (!ent.expires_at || new Date(ent.expires_at) > new Date());
  if (isPlus) return;

  const { count, error } = await admin
    .from("assignments")
    .select("id", { count: "exact", head: true })
    .eq("user_id", caller.id)
    .eq("status", "active");

  // Fail open on an infrastructure error: the RPC will still enforce the cap,
  // so the worst case is a wasted generation, not a bypassed limit.
  if (error) {
    console.warn("quota pre-check failed, deferring to RPC:", error.message);
    return;
  }

  if ((count ?? 0) >= FREE_ACTIVE_PLAN_LIMIT) {
    throw new HttpError(
      402,
      "FREE_PLAN_LIMIT_REACHED",
      "Free plans cover three active assignments at a time.",
    );
  }
}

export async function recordUsage(
  userId: string,
  kind: "breakdown" | "chat",
  model: string,
  inputTokens?: number,
  outputTokens?: number,
): Promise<void> {
  const { error } = await adminClient().from("ai_usage").insert({
    user_id: userId,
    kind,
    model,
    input_tokens: inputTokens ?? null,
    output_tokens: outputTokens ?? null,
  });
  if (error) throw new Error(error.message);
}
