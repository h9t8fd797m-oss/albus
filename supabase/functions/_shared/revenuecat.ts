// Pure RevenueCat webhook primitives. No server, environment, or database, so
// signature and replay-window behaviour can be tested without live secrets.

/** Constant-time comparison over a fixed maximum length. */
export function constantTimeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

/** Milliseconds since epoch to ISO, rejecting values that could become no expiry. */
export function isoFromMilliseconds(value: unknown): string | null {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

/** Translate RevenueCat's exact public enum; anything else fails closed. */
export function normaliseRevenueCatEnvironment(
  value: unknown,
): "Production" | "Sandbox" | null {
  if (typeof value !== "string") return null;
  switch (value.toUpperCase()) {
    case "PRODUCTION":
      return "Production";
    case "SANDBOX":
      return "Sandbox";
    default:
      return null;
  }
}

/**
 * Only EXPIRATION means access has ended immediately.
 *
 * RevenueCat's SUBSCRIPTION_PAUSED event schedules a pause at the end of the
 * current paid period. Revoking on that event takes away time the student has
 * already paid for; the later EXPIRATION event is the revocation signal.
 */
export function revokesImmediately(eventType: string): boolean {
  return eventType === "EXPIRATION";
}

/** A webhook integration can cover several apps; only Albus app ids may grant. */
export function revenueCatAppIsAllowed(
  appId: unknown,
  configuredIds: string,
): boolean {
  if (typeof appId !== "string" || appId.length === 0) return false;
  const allowed = configuredIds.split(",").map((id) => id.trim()).filter(Boolean);
  return allowed.length > 0 && allowed.includes(appId);
}

/** Verify `t=<unix>,v1=<hex>` over the exact raw JSON bytes. */
export async function verifyRevenueCatSignature(
  raw: Uint8Array,
  header: string,
  secret: string,
  nowMs: number = Date.now(),
  toleranceSeconds = 300,
): Promise<boolean> {
  if (!secret) return false;
  const timestamp = /(?:^|,)\s*t=(\d+)/.exec(header)?.[1] ?? "";
  const provided = /(?:^|,)\s*v1=([0-9a-f]{64})/i.exec(header)?.[1]?.toLowerCase() ?? "";
  const unix = Number(timestamp);
  if (
    !Number.isSafeInteger(unix) ||
    Math.abs(nowMs / 1000 - unix) > toleranceSeconds
  ) return false;

  const prefix = new TextEncoder().encode(`${timestamp}.`);
  const signed = new Uint8Array(prefix.length + raw.length);
  signed.set(prefix);
  signed.set(raw, prefix.length);

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, signed));
  const expected = [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
  return constantTimeEqual(provided, expected);
}
