// _shared/http.ts — transport concerns only. No business logic.

export class HttpError extends Error {
  constructor(public status: number, public code: string, message?: string) {
    super(message ?? code);
  }
}

/** The iOS app is a native client, so no browser origin needs allowing. */
const BASE_HEADERS = { "Content-Type": "application/json" } as const;

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: BASE_HEADERS });
}

export function errorResponse(e: unknown): Response {
  if (e instanceof HttpError) {
    return jsonResponse({ error: e.code, message: e.message }, e.status);
  }
  // Never leak internals to the client; keep the detail in the logs.
  console.error("unhandled:", e);
  return jsonResponse({ error: "INTERNAL_ERROR" }, 500);
}

/**
 * Postgres errors surface as opaque strings. Map the ones the RPC raises
 * deliberately onto real HTTP codes; treat anything else as internal.
 */
export function mapPostgresError(message: string): HttpError {
  if (message.includes("FREE_PLAN_LIMIT_REACHED")) {
    return new HttpError(
      402,
      "FREE_PLAN_LIMIT_REACHED",
      "Free plans cover three active assignments at a time.",
    );
  }
  if (message.includes("NOT_AUTHENTICATED")) {
    return new HttpError(401, "NOT_AUTHENTICATED");
  }
  if (message.includes("RATE_LIMIT_HOURLY")) {
    return new HttpError(
      429,
      "RATE_LIMIT_HOURLY",
      "Too many requests in the last hour. Try again shortly.",
    );
  }
  if (message.includes("RATE_LIMIT_DAILY")) {
    return new HttpError(
      429,
      "RATE_LIMIT_DAILY",
      "You have reached today's limit. It resets tomorrow.",
    );
  }
  if (message.includes("SUBTASKS_REQUIRED") || message.includes("TOO_MANY_SUBTASKS")) {
    return new HttpError(422, "INVALID_PLAN");
  }
  // The global spend fuse (migration 0013). Without this case it fell through
  // to the branch below and reached the client as a 500 INTERNAL_ERROR, so the
  // app could not tell "we are at capacity, retry later" from "we are broken".
  if (message.includes("GLOBAL_CAPACITY_REACHED")) {
    return new HttpError(
      503,
      "GLOBAL_CAPACITY_REACHED",
      "Albus is at capacity right now. Try again shortly.",
    );
  }
  // Anything unmapped is a bug on our side. The message is a raw Postgres
  // string — it can name tables, columns and constraints — so it goes to the
  // logs and never to the caller.
  console.error("unmapped postgres error:", message);
  return new HttpError(500, "INTERNAL_ERROR");
}
