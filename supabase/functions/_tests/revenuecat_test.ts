import { assertEquals } from "jsr:@std/assert@1";
import {
  constantTimeEqual,
  isoFromMilliseconds,
  normaliseRevenueCatEnvironment,
  revenueCatAppIsAllowed,
  revokesImmediately,
  verifyRevenueCatSignature,
} from "../_shared/revenuecat.ts";

async function signature(
  raw: Uint8Array,
  timestamp: number,
  secret: string,
): Promise<string> {
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
  return [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.test("RevenueCat HMAC accepts the exact signed bytes", async () => {
  const now = 1_800_000_000_000;
  const timestamp = Math.floor(now / 1000);
  const raw = new TextEncoder().encode('{"event":{"id":"evt_1"}}');
  const secret = "test-signing-secret";
  const digest = await signature(raw, timestamp, secret);
  assertEquals(
    await verifyRevenueCatSignature(raw, `t=${timestamp},v1=${digest}`, secret, now),
    true,
  );
});

Deno.test("RevenueCat HMAC rejects a changed body and wrong secret", async () => {
  const now = 1_800_000_000_000;
  const timestamp = Math.floor(now / 1000);
  const original = new TextEncoder().encode('{"event":{"id":"evt_1"}}');
  const changed = new TextEncoder().encode('{"event":{"id":"evt_2"}}');
  const digest = await signature(original, timestamp, "right-secret");
  const header = `t=${timestamp},v1=${digest}`;
  assertEquals(
    await verifyRevenueCatSignature(changed, header, "right-secret", now),
    false,
  );
  assertEquals(
    await verifyRevenueCatSignature(original, header, "wrong-secret", now),
    false,
  );
});

Deno.test("RevenueCat HMAC rejects stale and malformed delivery timestamps", async () => {
  const now = 1_800_000_000_000;
  const stale = Math.floor(now / 1000) - 301;
  const raw = new TextEncoder().encode("{}");
  const digest = await signature(raw, stale, "secret");
  assertEquals(
    await verifyRevenueCatSignature(raw, `t=${stale},v1=${digest}`, "secret", now),
    false,
  );
  assertEquals(await verifyRevenueCatSignature(raw, "garbage", "secret", now), false);
});

Deno.test("RevenueCat timestamps never turn invalid data into no-expiry", () => {
  assertEquals(isoFromMilliseconds(null), null);
  assertEquals(isoFromMilliseconds(Number.NaN), null);
  assertEquals(isoFromMilliseconds(-1), null);
  assertEquals(isoFromMilliseconds(1_800_000_000_000), "2027-01-15T08:00:00.000Z");
});

Deno.test("RevenueCat environment accepts only the documented enum", () => {
  assertEquals(normaliseRevenueCatEnvironment("PRODUCTION"), "Production");
  assertEquals(normaliseRevenueCatEnvironment("sandbox"), "Sandbox");
  assertEquals(normaliseRevenueCatEnvironment("preview"), null);
  assertEquals(normaliseRevenueCatEnvironment(null), null);
});

Deno.test("constant-time comparator still compares value and length", () => {
  assertEquals(constantTimeEqual("abc", "abc"), true);
  assertEquals(constantTimeEqual("abc", "abd"), false);
  assertEquals(constantTimeEqual("abc", "abc0"), false);
});

Deno.test("only expiration revokes immediately", () => {
  assertEquals(revokesImmediately("EXPIRATION"), true);
  assertEquals(revokesImmediately("SUBSCRIPTION_PAUSED"), false);
  assertEquals(revokesImmediately("CANCELLATION"), false);
});

Deno.test("RevenueCat events must belong to an explicitly allowed app", () => {
  assertEquals(revenueCatAppIsAllowed("app_albus_ios", "app_albus_ios"), true);
  assertEquals(
    revenueCatAppIsAllowed("app_albus_ios", "app_other, app_albus_ios"),
    true,
  );
  assertEquals(revenueCatAppIsAllowed("app_other", "app_albus_ios"), false);
  assertEquals(revenueCatAppIsAllowed("app_albus_ios", ""), false);
  assertEquals(revenueCatAppIsAllowed(null, "app_albus_ios"), false);
});
