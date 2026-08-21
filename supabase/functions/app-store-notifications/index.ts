// app-store-notifications/index.ts
//
// Apple's App Store Server Notifications V2 webhook: renewals, cancellations,
// refunds, billing failures.
//
// This endpoint is PUBLIC — Apple cannot present a user JWT — so the signature
// is the only thing standing between an attacker and forged premium. Every
// path below refuses to act on anything that does not verify, and no field
// from the request body is trusted before the signature check passes.
//
// Deploy with --no-verify-jwt. That is deliberate and safe here precisely
// because verification happens in-process against Apple's root certificates.

import { adminClient } from "../_shared/auth.ts";
import { errorResponse, HttpError, jsonResponse } from "../_shared/http.ts";
import { verifyNotification } from "../_shared/appstore.ts";

const MAX_PAYLOAD_BYTES = 65_536;

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");

    const raw = await req.text();
    if (raw.length > MAX_PAYLOAD_BYTES) throw new HttpError(413, "PAYLOAD_TOO_LARGE");

    let body: { signedPayload?: unknown };
    try {
      body = JSON.parse(raw);
    } catch {
      throw new HttpError(400, "INVALID_JSON");
    }

    if (typeof body.signedPayload !== "string" || body.signedPayload.length === 0) {
      throw new HttpError(400, "MISSING_PAYLOAD");
    }

    const notification = await verifyNotification(body.signedPayload);

    if (!notification.subscription) {
      // Verified, but carries no transaction (e.g. TEST notifications).
      console.log("notification with no transaction:", notification.notificationType);
      return jsonResponse({ received: true, applied: false });
    }

    const sub = notification.subscription;
    const { data, error } = await adminClient().rpc("apply_subscription_state", {
      p_original_transaction_id: sub.originalTransactionId,
      // Apple does not know our user ids. Ownership comes from the existing
      // row, established when the client redeemed the purchase.
      p_user_id: null,
      p_latest_transaction_id: sub.transactionId,
      p_product_id: sub.productId,
      p_environment: sub.environment,
      p_purchase_date: sub.purchaseDate?.toISOString() ?? null,
      p_expires_at: sub.expiresAt?.toISOString() ?? null,
      p_revoked_at: sub.revokedAt?.toISOString() ?? null,
    });

    if (error) {
      // 500 makes Apple retry, which is what we want for a transient fault.
      console.error("apply_subscription_state failed:", error.message);
      throw new HttpError(500, "INTERNAL_ERROR");
    }

    console.log("applied", notification.notificationType, notification.subtype ?? "", "->", data);
    return jsonResponse({ received: true, applied: true, state: data });
  } catch (e) {
    return errorResponse(e);
  }
});
