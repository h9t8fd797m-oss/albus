// ⚠️  SUPERSEDED — payments move to RevenueCat.
//
// This verifies Apple JWS transactions directly. RevenueCat performs that
// verification on its own servers, so this path will not be used. Kept for now
// rather than deleted: the decision is recent, and if RevenueCat is ever
// dropped this is a working direct-to-Apple implementation.
//
// Do not extend it. When RevenueCat lands, either delete this or repoint it —
// see docs/backend.md § Payments.
// _shared/appstore.ts
//
// Everything Apple-signed enters through here.
//
// The security property that matters: a subscription is believed only when its
// JWS signature chains to an Apple root certificate we ship ourselves. Nothing
// the client sends about tier, price or expiry is ever read — only the fields
// inside the verified payload. A client that lies simply fails verification.

import { Environment, SignedDataVerifier } from "npm:@apple/app-store-server-library@1";
import { appleRootCertificates } from "./apple_roots.ts";
import { HttpError } from "./http.ts";

export interface VerifiedSubscription {
  originalTransactionId: string;
  transactionId: string;
  productId: string;
  environment: "Sandbox" | "Production";
  purchaseDate: Date | null;
  expiresAt: Date | null;
  revokedAt: Date | null;
}

function bundleId(): string {
  const v = Deno.env.get("APPLE_BUNDLE_ID");
  if (!v) throw new HttpError(500, "MISCONFIGURED", "APPLE_BUNDLE_ID is not set");
  return v;
}

/**
 * Sandbox receipts must never grant production entitlements — otherwise anyone
 * with a free sandbox tester account gets Plus for nothing. Production refuses
 * sandbox payloads; a non-production deploy accepts both so TestFlight works.
 */
function allowSandbox(): boolean {
  return (Deno.env.get("APPLE_ALLOW_SANDBOX") ?? "false").toLowerCase() === "true";
}

function verifierFor(env: Environment): SignedDataVerifier {
  const appAppleId = Deno.env.get("APPLE_APP_APPLE_ID");
  return new SignedDataVerifier(
    appleRootCertificates(),
    // Online OCSP checks: correct for production, and the library requires an
    // appAppleId for Production verification.
    true,
    env,
    bundleId(),
    appAppleId ? Number(appAppleId) : undefined,
  );
}

/**
 * Apple does not tell you up front which environment signed a payload, and the
 * verifier is environment-specific. Try production first, then sandbox only if
 * this deploy permits it.
 */
async function verifyEither<T>(
  attempt: (v: SignedDataVerifier) => Promise<T>,
): Promise<{ result: T; environment: "Sandbox" | "Production" }> {
  try {
    return {
      result: await attempt(verifierFor(Environment.PRODUCTION)),
      environment: "Production",
    };
  } catch (prodError) {
    if (!allowSandbox()) {
      console.warn("production verification failed and sandbox is disabled:", prodError);
      throw new HttpError(400, "INVALID_TRANSACTION", "Could not verify this purchase.");
    }
    try {
      return { result: await attempt(verifierFor(Environment.SANDBOX)), environment: "Sandbox" };
    } catch (sandboxError) {
      console.warn("verification failed in both environments:", prodError, sandboxError);
      throw new HttpError(400, "INVALID_TRANSACTION", "Could not verify this purchase.");
    }
  }
}

const toDate = (ms: number | undefined | null): Date | null =>
  typeof ms === "number" && Number.isFinite(ms) ? new Date(ms) : null;

/** A StoreKit 2 signed transaction, straight from the client. Untrusted until verified. */
export async function verifyTransaction(signedTransaction: string): Promise<VerifiedSubscription> {
  const { result, environment } = await verifyEither((v) =>
    v.verifyAndDecodeTransaction(signedTransaction)
  );

  if (!result.originalTransactionId || !result.transactionId) {
    throw new HttpError(400, "INVALID_TRANSACTION", "Transaction is missing its identifiers.");
  }

  return {
    originalTransactionId: result.originalTransactionId,
    transactionId: result.transactionId,
    productId: result.productId ?? "",
    environment,
    purchaseDate: toDate(result.purchaseDate),
    expiresAt: toDate(result.expiresDate),
    revokedAt: toDate(result.revocationDate),
  };
}

export interface VerifiedNotification {
  notificationType: string;
  subtype: string | null;
  subscription: VerifiedSubscription | null;
}

/** An App Store Server Notification V2. The endpoint is public, so this is the only gate. */
export async function verifyNotification(signedPayload: string): Promise<VerifiedNotification> {
  const { result, environment } = await verifyEither((v) =>
    v.verifyAndDecodeNotification(signedPayload)
  );

  const signedTx = result.data?.signedTransactionInfo;
  const signedRenewal = result.data?.signedRenewalInfo;

  let subscription: VerifiedSubscription | null = null;

  if (signedTx) {
    // Nested payloads are separately signed; verify rather than trust the wrapper.
    const { result: tx } = await verifyEither((v) => v.verifyAndDecodeTransaction(signedTx));
    if (tx.originalTransactionId && tx.transactionId) {
      let revokedAt = toDate(tx.revocationDate);

      if (signedRenewal) {
        const { result: renewal } = await verifyEither((v) =>
          v.verifyAndDecodeRenewalInfo(signedRenewal)
        );
        // An expired-and-not-renewing subscription is revoked for our purposes.
        if (renewal.expirationIntent && !revokedAt) {
          const exp = toDate(tx.expiresDate);
          if (exp && exp <= new Date()) revokedAt = exp;
        }
      }

      subscription = {
        originalTransactionId: tx.originalTransactionId,
        transactionId: tx.transactionId,
        productId: tx.productId ?? "",
        environment,
        purchaseDate: toDate(tx.purchaseDate),
        expiresAt: toDate(tx.expiresDate),
        revokedAt,
      };
    }
  }

  return {
    notificationType: String(result.notificationType ?? "UNKNOWN"),
    subtype: result.subtype ? String(result.subtype) : null,
    subscription,
  };
}
