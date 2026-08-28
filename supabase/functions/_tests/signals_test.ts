// Tests for the abuse-detection layer's inputs.
//
// These matter more than most: every one of them is a case where getting it
// wrong either invents a signal that is not there (and refuses a real student)
// or lets a client choose its own signal (and defeats the whole thing).

import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert";
import { deviceId, ipPrefix, peppered } from "../_shared/signals.ts";
import { mapPostgresError } from "../_shared/http.ts";

const req = (headers: Record<string, string>) =>
  new Request("https://example.test", { headers });

Deno.test("an IPv4 address is reduced to its /24", () => {
  assertEquals(ipPrefix(req({ "x-forwarded-for": "203.0.113.42" })), "v4:203.0.113");
});

Deno.test("two addresses in one /24 produce the same prefix", () => {
  assertEquals(
    ipPrefix(req({ "x-forwarded-for": "203.0.113.1" })),
    ipPrefix(req({ "x-forwarded-for": "203.0.113.254" })),
  );
});

Deno.test("different /24s stay different", () => {
  assertNotEquals(
    ipPrefix(req({ "x-forwarded-for": "203.0.113.1" })),
    ipPrefix(req({ "x-forwarded-for": "203.0.114.1" })),
  );
});

Deno.test("an IPv6 address is reduced to its /48", () => {
  assertEquals(
    ipPrefix(req({ "x-forwarded-for": "2001:db8:1234:5678::1" })),
    "v6:2001:db8:1234",
  );
});

// The one that decides whether any of this is worth having. `x-forwarded-for`
// is a list a client can prepend to freely; only the entries our own edge
// appended mean anything. Reading the FIRST entry — the conventional "original
// client" — would let anyone pick their own network signal, which is worse than
// having no signal at all because it looks like evidence.
Deno.test("a client prepending a forged hop cannot change its own prefix", () => {
  const honest = ipPrefix(req({ "x-forwarded-for": "203.0.113.42" }));
  const forged = ipPrefix(req({
    "x-forwarded-for": "8.8.8.8, 1.1.1.1, 203.0.113.42",
  }));
  assertEquals(forged, honest);
  assertNotEquals(forged, "v4:8.8.8");
});

Deno.test("a missing or unparseable forwarded-for yields no signal", () => {
  assertEquals(ipPrefix(req({})), null);
  assertEquals(ipPrefix(req({ "x-forwarded-for": "not-an-address" })), null);
  assertEquals(ipPrefix(req({ "x-forwarded-for": "999.1.1" })), null);
  assertEquals(ipPrefix(req({ "x-forwarded-for": "  " })), null);
});

Deno.test("the device header is accepted only in the shape of an IDFV", () => {
  const idfv = "9F1A2B3C-4D5E-4F60-8A1B-2C3D4E5F6071";
  assertEquals(deviceId(req({ "x-albus-device": idfv })), idfv.toLowerCase());
  assertEquals(deviceId(req({ "x-albus-device": "not-a-uuid" })), null);
  assertEquals(deviceId(req({ "x-albus-device": "x".repeat(4096) })), null);
  assertEquals(deviceId(req({})), null);
});

Deno.test("a hash is 64 hex characters and does not contain its input", async () => {
  const h = await peppered("ip|v4:203.0.113");
  assert(/^[0-9a-f]{64}$/.test(h), `not a digest: ${h}`);
  assert(!h.includes("203"), "the raw value survived the hash");
});

Deno.test("the same input hashes the same way twice, different inputs do not", async () => {
  assertEquals(await peppered("device|abc"), await peppered("device|abc"));
  assertNotEquals(await peppered("device|abc"), await peppered("device|abd"));
  // Namespaced, so a device id can never collide with an address that happens
  // to look like it.
  assertNotEquals(await peppered("device|x"), await peppered("ip|x"));
});

// ── The two families of refusal must not be confused ────────────────────────

Deno.test("not on your plan is 402 and says so", () => {
  const e = mapPostgresError("PLAN_UPGRADE_REQUIRED");
  assertEquals(e.status, 402);
  assertEquals(e.code, "PLAN_UPGRADE_REQUIRED");
});

Deno.test("an allowance you bought and used is 402, not a rate limit", () => {
  const weekly = mapPostgresError("ALLOWANCE_WEEKLY");
  assertEquals(weekly.status, 402);
  assertEquals(weekly.code, "ALLOWANCE_WEEKLY");

  const monthly = mapPostgresError("ALLOWANCE_MONTHLY");
  assertEquals(monthly.status, 402);
  assertEquals(monthly.code, "ALLOWANCE_MONTHLY");
});

Deno.test("going too fast is 429, and stays distinct from running out", () => {
  assertEquals(mapPostgresError("RATE_LIMIT_HOURLY").status, 429);
  assertEquals(mapPostgresError("RATE_LIMIT_DAILY").status, 429);
  assertNotEquals(
    mapPostgresError("RATE_LIMIT_HOURLY").code,
    mapPostgresError("ALLOWANCE_WEEKLY").code,
  );
});

// A refusal that names the signal that produced it is a refusal that tells the
// attacker which knob to turn. The detail belongs in the log, not the response.
Deno.test("a risk refusal never names the signal that caused it", () => {
  const e = mapPostgresError("ABUSE_SUSPECTED");
  assertEquals(e.status, 403);
  for (const leak of ["device", "ip", "score", "risk", "address", "band"]) {
    assert(
      !e.message.toLowerCase().includes(leak),
      `the message leaks "${leak}": ${e.message}`,
    );
  }
});

Deno.test("verification is 403 and offers a way forward", () => {
  const e = mapPostgresError("VERIFICATION_REQUIRED");
  assertEquals(e.status, 403);
  assert(e.message.toLowerCase().includes("sign in"));
});

// Postgres error text can name tables, columns and constraints. It goes to the
// logs; the caller gets a code.
Deno.test("an unmapped Postgres error reaches the client as nothing at all", () => {
  const e = mapPostgresError(
    'duplicate key value violates unique constraint "entitlements_pkey"',
  );
  assertEquals(e.status, 500);
  assertEquals(e.code, "INTERNAL_ERROR");
  assert(!e.message.includes("entitlements"));
});

Deno.test("the old FREE_PLAN_LIMIT_REACHED name still maps", () => {
  // Rows and clients predating migration 0034 can still raise it.
  assertEquals(mapPostgresError("FREE_PLAN_LIMIT_REACHED").code, "PLAN_TASK_LIMIT_REACHED");
});
