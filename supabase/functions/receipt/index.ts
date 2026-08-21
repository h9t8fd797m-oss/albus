// ⚠️  SUPERSEDED — payments move to RevenueCat.
//
// This verifies Apple JWS transactions directly. RevenueCat performs that
// verification on its own servers, so this path will not be used. Kept for now
// rather than deleted: the decision is recent, and if RevenueCat is ever
// dropped this is a working direct-to-Apple implementation.
//
// Do not extend it. When RevenueCat lands, either delete this or repoint it —
// see docs/backend.md § Payments.
// receipt/index.ts
//
// The client hands over a StoreKit 2 signed transaction; we verify it against
// Apple's root certificates and derive the entitlement ourselves.
//
// Nothing about tier, price or expiry is read from the request. The only
// input that matters is the signature, and the only source of truth for what
// was bought is the payload Apple signed.

import { adminClient, requireUser } from "../_shared/auth.ts";
import { errorResponse, HttpError, jsonResponse } from "../_shared/http.ts";
import { verifyTransaction } from "../_shared/appstore.ts";

const MAX_JWS_BYTES = 32_768;

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");

    const caller = await requireUser(req);

    let body: { signed_transaction_info?: unknown };
    try {
      body = await req.json();
    } catch {
      throw new HttpError(400, "INVALID_JSON");
    }

    const jws = body.signed_transaction_info;
    if (typeof jws !== "string" || jws.length === 0) {
      throw new HttpError(422, "MISSING_TRANSACTION", "signed_transaction_info is required.");
    }
    // Bound the input before it reaches a parser. A JWS this large is not real.
    if (jws.length > MAX_JWS_BYTES) {
      throw new HttpError(413, "TRANSACTION_TOO_LARGE");
    }

    const sub = await verifyTransaction(jws);

    const { data, error } = await adminClient().rpc("apply_subscription_state", {
      p_original_transaction_id: sub.originalTransactionId,
      p_user_id: caller.id,
      p_latest_transaction_id: sub.transactionId,
      p_product_id: sub.productId,
      p_environment: sub.environment,
      p_purchase_date: sub.purchaseDate?.toISOString() ?? null,
      p_expires_at: sub.expiresAt?.toISOString() ?? null,
      p_revoked_at: sub.revokedAt?.toISOString() ?? null,
    });

    if (error) {
      console.error("apply_subscription_state failed:", error.message);
      throw new HttpError(500, "INTERNAL_ERROR");
    }

    // Another account already redeemed this subscription. Reassigning premium
    // on the strength of a replayed receipt is exactly the attack this blocks.
    if (data === "conflict") {
      throw new HttpError(
        409,
        "ALREADY_LINKED",
        "This purchase is already attached to a different account.",
      );
    }

    return jsonResponse({
      tier: data === "active" ? "plus" : "free",
      expires_at: sub.expiresAt?.toISOString() ?? null,
      environment: sub.environment,
    });
  } catch (e) {
    return errorResponse(e);
  }
});
