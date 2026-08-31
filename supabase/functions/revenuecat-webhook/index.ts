// revenuecat-webhook/index.ts
//
// RevenueCat tells us what a student bought. This is the ONLY path by which
// anyone becomes Plus or Pro.
//
// This endpoint is PUBLIC — RevenueCat cannot present a user JWT — so the
// shared Authorization secret and RevenueCat's signed raw body are both
// checked before any event field is trusted.
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
import {
  constantTimeEqual,
  isoFromMilliseconds,
  normaliseRevenueCatEnvironment,
  revenueCatAppIsAllowed,
  revokesImmediately,
  verifyRevenueCatSignature,
} from "../_shared/revenuecat.ts";

const MAX_BODY_BYTES = 65_536;

/// Events that change entitlement. Anything else is acknowledged and ignored:
/// returning 200 stops RevenueCat retrying something we deliberately skipped.
const HANDLED = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "CANCELLATION",
  "UNCANCELLATION",
  "EXPIRATION",
  "SUBSCRIPTION_PAUSED",
  "SUBSCRIPTION_EXTENDED",
  "REFUND_REVERSED",
]);

interface RevenueCatEvent {
  type?: unknown;
  id?: unknown;
  app_id?: unknown;
  event_timestamp_ms?: unknown;
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
function requireAuthorised(req: Request): void {
  const expected = Deno.env.get("REVENUECAT_WEBHOOK_SECRET") ?? "";
  if (!expected) {
    // Refuse rather than accept-everything. An unconfigured secret must never
    // mean an open endpoint that grants entitlements.
    console.error("REVENUECAT_WEBHOOK_SECRET is not set; rejecting.");
    throw new HttpError(503, "NOT_CONFIGURED");
  }
  const provided = req.headers.get("Authorization") ?? "";
  if (!constantTimeEqual(provided, expected)) {
    throw new HttpError(401, "UNAUTHORISED");
  }
}

/**
 * Verify RevenueCat's HMAC over the exact request bytes.
 *
 * The Authorization header protects the endpoint from casual forgery. HMAC
 * additionally proves the body itself is what RevenueCat signed, and the
 * five-minute delivery timestamp prevents a captured request being replayed
 * indefinitely. RevenueCat re-signs legitimate retries with a fresh delivery
 * timestamp while keeping the event id stable.
 */
async function requireValidSignature(req: Request, raw: Uint8Array): Promise<void> {
  const secret = Deno.env.get("REVENUECAT_WEBHOOK_SIGNING_SECRET") ?? "";
  if (!secret) {
    console.error("REVENUECAT_WEBHOOK_SIGNING_SECRET is not set; rejecting.");
    throw new HttpError(503, "NOT_CONFIGURED");
  }

  const header = req.headers.get("x-revenuecat-webhook-signature") ?? "";
  if (!await verifyRevenueCatSignature(raw, header, secret)) {
    throw new HttpError(401, "UNAUTHORISED");
  }
}

/** Milliseconds since epoch to ISO, or null. Rejects nonsense rather than
 *  letting `new Date(NaN)` become a silent null expiry — which would read as
 *  "never expires". */
function asString(v: unknown, max = 255): string | null {
  return typeof v === "string" && v.length > 0 ? v.slice(0, max) : null;
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

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");

    // Authenticate BEFORE reading the body, so an unauthorised caller cannot
    // make us parse arbitrary input.
    requireAuthorised(req);

    const announced = Number(req.headers.get("content-length"));
    if (Number.isFinite(announced) && announced > MAX_BODY_BYTES) {
      throw new HttpError(413, "PAYLOAD_TOO_LARGE");
    }
    const raw = new Uint8Array(await req.arrayBuffer());
    if (raw.byteLength > MAX_BODY_BYTES) throw new HttpError(413, "PAYLOAD_TOO_LARGE");
    await requireValidSignature(req, raw);

    let payload: { event?: RevenueCatEvent };
    try {
      payload = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw));
    } catch {
      throw new HttpError(400, "INVALID_JSON");
    }

    const event = payload.event ?? {};
    const type = asString(event.type, 64) ?? "";
    if (!HANDLED.has(type)) {
      // Acknowledged, deliberately ignored.
      return jsonResponse({ ok: true, ignored: type || "unknown" });
    }

    // A RevenueCat project may contain several apps and a webhook can be
    // configured for all of them. A valid HMAC proves RevenueCat sent the
    // event; it does not prove the event belongs to Albus. Product ids alone
    // are not a safe namespace, so entitlement-changing events must also name
    // an explicitly configured Albus app id.
    const configuredAppIDs = Deno.env.get("REVENUECAT_APP_IDS") ?? "";
    if (!configuredAppIDs.trim()) {
      console.error("REVENUECAT_APP_IDS is not set; rejecting.");
      throw new HttpError(503, "NOT_CONFIGURED");
    }
    if (!revenueCatAppIsAllowed(event.app_id, configuredAppIDs)) {
      console.warn("ignoring RevenueCat event for another app", { type });
      return jsonResponse({ ok: true, ignored: "app" });
    }

    // The Supabase user id. RevenueCat is configured to use it as app_user_id,
    // which is what removes Apple's "notification about a user we cannot
    // identify" case. Anything that is not a UUID is not one of our users.
    const appUserID = asString(event.app_user_id) ?? asString(event.original_app_user_id);
    const userID = appUserID && UUID_RE.test(appUserID) ? appUserID : null;

    // The stable identity of the subscription across renewals.
    const originalID = asString(event.original_transaction_id);
    if (!originalID) throw new HttpError(422, "NO_SUBSCRIPTION_ID");

    const environment = normaliseRevenueCatEnvironment(event.environment);
    if (!environment) throw new HttpError(422, "INVALID_ENVIRONMENT");
    if (environment === "Sandbox" && !sandboxAllowed()) {
      // Acknowledged so RevenueCat stops retrying, but nothing is granted.
      console.warn("ignoring sandbox event", { type, originalID });
      return jsonResponse({ ok: true, ignored: "sandbox" });
    }

    const expiresAt = isoFromMilliseconds(event.expiration_at_ms);
    const eventID = asString(event.id);
    const eventAt = isoFromMilliseconds(event.event_timestamp_ms);
    if (!eventID || !eventAt) throw new HttpError(422, "INVALID_EVENT_IDENTITY");
    // Only EXPIRATION means access ends now. CANCELLATION runs to the paid
    // period's expiry, and SUBSCRIPTION_PAUSED merely schedules a pause at that
    // boundary. RevenueCat sends EXPIRATION when either has actually ended.
    const revokedAt = revokesImmediately(type) ? new Date().toISOString() : null;

    const { data, error } = await adminClient().rpc("apply_subscription_state", {
      p_original_transaction_id: originalID,
      p_user_id: userID,
      p_latest_transaction_id: asString(event.transaction_id),
      p_product_id: asString(event.product_id),
      p_environment: environment,
      p_purchase_date: isoFromMilliseconds(event.purchased_at_ms),
      p_expires_at: expiresAt,
      p_revoked_at: revokedAt,
      p_event_id: eventID,
      p_event_at: eventAt,
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
