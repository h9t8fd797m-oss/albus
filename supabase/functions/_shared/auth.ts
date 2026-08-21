// _shared/auth.ts
//
// One rule, enforced here so no function can forget it:
//   the caller's identity comes from their verified JWT, never from the body.
//
// A request that says {"user_id": "..."} is making a claim, not a statement.
// requireUser() ignores the body entirely and resolves the user from the
// Authorization header, which Supabase Auth has already signed.

import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { HttpError } from "./http.ts";

export interface Caller {
  id: string;
  isAnonymous: boolean;
  /** Scoped to the caller — RLS applies. Use for anything user-owned. */
  db: SupabaseClient;
}

function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new HttpError(500, "MISCONFIGURED", `${name} is not set`);
  return v;
}

/** Bypasses RLS. Only for writes the user must not control (entitlements, usage). */
export function adminClient(): SupabaseClient {
  return createClient(
    requireEnv("SUPABASE_URL"),
    requireEnv("SUPABASE_SECRET_KEY"),
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
}

export async function requireUser(req: Request): Promise<Caller> {
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) {
    throw new HttpError(401, "MISSING_TOKEN", "Missing bearer token");
  }

  // Client bound to the caller's token: every query it runs is subject to RLS,
  // so even a bug in a function cannot read another user's rows.
  const db = createClient(
    requireEnv("SUPABASE_URL"),
    requireEnv("SUPABASE_PUBLISHABLE_KEY"),
    {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    },
  );

  const { data, error } = await db.auth.getUser();
  if (error || !data.user) {
    throw new HttpError(401, "INVALID_SESSION", "Invalid or expired session");
  }

  return { id: data.user.id, isAnonymous: data.user.is_anonymous === true, db };
}
