// revenuecat-webhook/index.ts
//
// RevenueCat tells us what a student bought. This is the ONLY path by which
// anyone becomes Plus.
//
// This endpoint is PUBLIC — RevenueCat cannot present a user JWT — so the
// shared secret in the Authorization header is the only thing between an
// attacker and forged premium. Every path below refuses to act on anything
// that does not authenticate, and no field from the body is read before it
// does.
//
// Deploy with --no-verify-jwt. That is deliberate and safe here precisely
// because authentication happens in-process, against a secret the client never
// sees.
//
// Nothing about tier is decided here. The body says what was bought and when
// it expires; `apply_subscription_state` decides what that means, which is
// also where the stolen-subscription check lives.

import { adminClient } from "../_shared/auth.ts";
import { errorResponse, HttpError, jsonResponse } from "../_shared/http.ts";

const MAX_BODY_BYTES = 65_536;

/// Events that change entitlement. Anything else is acknowledged and ignored:
/// returning 200 stops RevenueCat retrying something we deliberately skipped.
const HANDLED = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "PRODUCT_CHANGE",
  "CANCELLATION",
  "UNCANCELLATION",
  "EXPIRATION",
  "BILLING_ISSUE",
  "SUBSCRIPTION_PAUSED",
  "TRANSFER",
]);

/// Events that revoke access the moment they arrive, rather than at expiry.
/// A refund must not leave someone Plus until their period would have ended.
const REVOKES_NOW = new Set(["EXPIRATION", "SUBSCRIPTION_PAUSED"]);

interface RevenueCatEvent {
  type?: unknown;
  id?: unknown;
  app_user_id?: unknown;
  original_app_user_id?: unknown;
  product_id?: unknown;
  environment?: unknown;
  purchased_at_ms?: unknown;
  expiration_at_ms?: unknown;
  cancel_reason?: unknown;
  original_transaction_id?: unknown;
  transaction_id?: unknown;
}

/**
 * Constant-time string comparison.
 *
 * `a === b` on secrets leaks length and prefix through timing. The difference
 * is small over the internet but free to avoid, and this is the single check
 * standing between a stranger and premium for everyone.
 */
function secretsMatch(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  // Compare a fixed number of bytes regardless of input length.
  let diff = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) {
    diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  }
  return diff === 0;
}

function requireAuthorised(req: Request): void {
  const expected = Deno.env.get("REVENUECAT_WEBHOOK_SECRET") ?? "";
  if (!expected) {
    // Refuse rather than accept-everything. An unconfigured secret must never
    // mean an open endpoint that grants entitlements.
    console.error("REVENUECAT_WEBHOOK_SECRET is not set; rejecting.");
    throw new HttpError(503, "NOT_CONFIGURED");
  }
  const provided = req.headers.get("Authorization") ?? "";
  if (!secretsMatch(provided, expected)) {
    throw new HttpError(401, "UNAUTHORISED");
  }
}

/** Milliseconds since epoch to ISO, or null. Rejects nonsense rather than
 *  letting `new Date(NaN)` become a silent null expiry — which would read as
 *  "never expires". */
function isoFromMs(v: unknown): string | null {
  if (typeof v !== "number" || !Number.isFinite(v) || v <= 0) return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

function asString(v: unknown, max = 255): string | null {
  return typeof v === "string" && v.length > 0 ? v.slice(0, max) : null;
}

/**
 * RevenueCat says PRODUCTION / SANDBOX; the column's check constraint predates
 * it and accepts Apple's casing, Production / Sandbox. Left unmapped, every
 * real webhook violated the constraint and returned 500 — which RevenueCat
 * retries forever, and which means nobody would ever have become Plus.
 *
 * Normalised here rather than by widening the constraint: one canonical
 * spelling in the database, providers translated at the edge.
 */
function normaliseEnvironment(v: unknown): "Production" | "Sandbox" {
  return String(asString(v, 32) ?? "").toUpperCase() === "SANDBOX"
    ? "Sandbox"
    : "Production";
}

/**
 * Sandbox purchases must not grant real entitlement.
 *
 * `apply_subscription_state` decides "active" from expiry and revocation only
 * — it never looks at environment — so without this check a sandbox
 * subscription, which anyone with a test account can create for free, would
 * hand out Plus exactly like a paid one. The Apple path had the same guard as
 * APPLE_ALLOW_SANDBOX=false; this is that guard for RevenueCat.
 *
 * Set ALBUS_ALLOW_SANDBOX_PURCHASES=true only in a test project.
 */
function sandboxAllowed(): boolean {
  return (Deno.env.get("ALBUS_ALLOW_SANDBOX_PURCHASES") ?? "").toLowerCase() === "true";
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");

    // Authenticate BEFORE reading the body, so an unauthorised caller cannot
    // make us parse arbitrary input.
    requireAuthorised(req);

    const raw = await req.text();
    if (raw.length > MAX_BODY_BYTES) throw new HttpError(413, "PAYLOAD_TOO_LARGE");

    let payload: { event?: RevenueCatEvent };
    try {
      payload = JSON.parse(raw);
    } catch {
      throw new HttpError(400, "INVALID_JSON");
    }

    const event = payload.event ?? {};
    const type = asString(event.type, 64) ?? "";
    if (!HANDLED.has(type)) {
      // Acknowledged, deliberately ignored.
      return jsonResponse({ ok: true, ignored: type || "unknown" });
    }

    // The Supabase user id. RevenueCat is configured to use it as app_user_id,
    // which is what removes Apple's "notification about a user we cannot
    // identify" case. Anything that is not a UUID is not one of our users.
    const appUserID = asString(event.app_user_id) ?? asString(event.original_app_user_id);
    const userID = appUserID && UUID_RE.test(appUserID) ? appUserID : null;

    // The stable identity of the subscription across renewals.
    const originalID = asString(event.original_transaction_id)
      ?? asString(event.transaction_id)
      ?? (userID ? `rc_${userID}_${asString(event.product_id) ?? "unknown"}` : null);

    if (!originalID) throw new HttpError(422, "NO_SUBSCRIPTION_ID");

    const environment = normaliseEnvironment(event.environment);
    if (environment === "Sandbox" && !sandboxAllowed()) {
      // Acknowledged so RevenueCat stops retrying, but nothing is granted.
      console.warn("ignoring sandbox event", { type, originalID });
      return jsonResponse({ ok: true, ignored: "sandbox" });
    }

    const expiresAt = isoFromMs(event.expiration_at_ms);
    // Revocation is explicit for the events that mean "access ends now".
    // CANCELLATION is deliberately NOT one: a cancelled subscription runs to
    // the end of the period the student already paid for.
    const revokedAt = REVOKES_NOW.has(type) ? new Date().toISOString() : null;

    const { data, error } = await adminClient().rpc("apply_subscription_state", {
      p_original_transaction_id: originalID,
      p_user_id: userID,
      p_latest_transaction_id: asString(event.transaction_id),
      p_product_id: asString(event.product_id),
      p_environment: environment,
      p_purchase_date: isoFromMs(event.purchased_at_ms),
      p_expires_at: expiresAt,
      p_revoked_at: revokedAt,
    });

    if (error) {
      // Do not leak the database's words to a caller we do not fully trust.
      console.error("apply_subscription_state failed:", error.message);
      throw new HttpError(500, "INTERNAL_ERROR");
    }

    // `conflict` means this subscription already belongs to a different
    // account. Nothing was granted; log it loudly so a human can look.
    if (data === "conflict") {
      console.error("subscription conflict", { originalID, userID, type });
    }

    return jsonResponse({ ok: true, result: data ?? "unknown" });
  } catch (e) {
    return errorResponse(e);
  }
});
