// supabase/functions/_shared/auth.ts
//
// One rule, enforced here so no function can forget it:
//   the caller's identity comes from their verified JWT, never from the body.
//
// A request that says {"user_id": "..."} is making a claim, not a statement.
// requireUser() ignores the body entirely and resolves the user from the
// Authorization header, which Supabase Auth has already signed.

import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

export interface Caller {
  id: string;
  isAnonymous: boolean;
  /** Scoped to the caller — RLS applies. Use for anything user-owned. */
  db: SupabaseClient;
}

/** Bypasses RLS. Only for writes the user must not control (entitlements, usage). */
export function adminClient(): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SECRET_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
}

export async function requireUser(req: Request): Promise<Caller> {
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) throw new HttpError(401, "Missing bearer token");

  // Client bound to the caller's token: every query it runs is subject to RLS,
  // so even a bug in this function cannot read another user's rows.
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_PUBLISHABLE_KEY")!,
    {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    },
  );

  const { data, error } = await db.auth.getUser();
  if (error || !data.user) throw new HttpError(401, "Invalid or expired session");

  return {
    id: data.user.id,
    isAnonymous: data.user.is_anonymous === true,
    db,
  };
}

export class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export function errorResponse(e: unknown): Response {
  if (e instanceof HttpError) return jsonResponse({ error: e.message }, e.status);
  console.error(e);                                    // never leak internals
  return jsonResponse({ error: "Internal error" }, 500);
}
