import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { readJsonBody } from "../_shared/body.ts";
import { HttpError } from "../_shared/http.ts";

Deno.test("bounded JSON reader accepts a body below its byte ceiling", async () => {
  const request = new Request("https://example.test", {
    method: "POST",
    body: JSON.stringify({ work: "hello" }),
  });
  assertEquals(await readJsonBody<{ work: string }>(request, 128), { work: "hello" });
});

Deno.test("bounded JSON reader refuses an announced oversized body before reading", async () => {
  const request = new Request("https://example.test", {
    method: "POST",
    headers: { "content-length": "9999" },
    body: "{}",
  });
  const error = await assertRejects(() => readJsonBody(request, 32), HttpError);
  assertEquals(error.status, 413);
  assertEquals(error.code, "PAYLOAD_TOO_LARGE");
});

Deno.test("bounded JSON reader stops a streamed body that lies about its size", async () => {
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new TextEncoder().encode('{"x":"'));
      controller.enqueue(new TextEncoder().encode("a".repeat(100)));
      controller.enqueue(new TextEncoder().encode('"}'));
      controller.close();
    },
  });
  const request = new Request("https://example.test", { method: "POST", body: stream });
  const error = await assertRejects(() => readJsonBody(request, 32), HttpError);
  assertEquals(error.status, 413);
});

Deno.test("bounded JSON reader gives malformed input a safe public error", async () => {
  const request = new Request("https://example.test", { method: "POST", body: "not-json" });
  const error = await assertRejects(() => readJsonBody(request, 64), HttpError);
  assertEquals(error.status, 400);
  assertEquals(error.code, "INVALID_JSON");
});
