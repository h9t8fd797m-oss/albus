// supabase/functions/_shared/quota.ts
//
// The free tier caps ACTIVE plans, not plans per month — a student in exam
// season must never hit a wall mid-week. Finishing an assignment frees a slot.
//
// Enforced server-side because a client-side check is a boolean the user owns.

import { adminClient, HttpError, type Caller } from "./auth.ts";

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

  if (error) throw new HttpError(500, "Could not verify quota");

  if ((count ?? 0) >= FREE_ACTIVE_PLAN_LIMIT) {
    throw new HttpError(402, "FREE_PLAN_LIMIT_REACHED");
  }
}

export async function recordUsage(
  userId: string,
  kind: "breakdown" | "chat",
  model: string,
  inputTokens?: number,
  outputTokens?: number,
): Promise<void> {
  await adminClient().from("ai_usage").insert({
    user_id: userId, kind, model,
    input_tokens: inputTokens ?? null,
    output_tokens: outputTokens ?? null,
  });
}
