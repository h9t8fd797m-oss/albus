import { assertEquals } from "jsr:@std/assert@1";
import { loadKnowledge } from "../_shared/knowledge.ts";

/** Just enough of a Supabase client to drive `loadKnowledge`. */
function fakeDb(result: { data?: unknown; error?: { message: string } }) {
  const calls: Array<Record<string, unknown>> = [];
  return {
    calls,
    db: { rpc: (_fn: string, params: Record<string, unknown>) => {
      calls.push(params);
      return Promise.resolve(result);
    } } as unknown as Parameters<typeof loadKnowledge>[0],
  };
}

const row = (section: string, body: string) => ({
  section, title: `Section ${section}`, parent_title: "A part", body,
});

Deno.test("no corpus means no query at all, not an empty one", async () => {
  // A student on a qualification Albus holds nothing for must not pay a round
  // trip on every message.
  const { db, calls } = fakeDb({ data: [] });
  assertEquals(await loadKnowledge(db, null, "how many words?"), []);
  assertEquals(calls.length, 0);
});

Deno.test("an empty question is not searched either", async () => {
  const { db, calls } = fakeDb({ data: [] });
  assertEquals(await loadKnowledge(db, "IB_DP", "   "), []);
  assertEquals(calls.length, 0);
});

Deno.test("the corpus and question are passed as parameters, never interpolated", async () => {
  const { db, calls } = fakeDb({ data: [] });
  await loadKnowledge(db, "IB_DP", "'; drop table knowledge_sections; --");
  assertEquals(calls[0].p_corpus, "IB_DP");
  assertEquals(calls[0].p_query, "'; drop table knowledge_sections; --");
});

Deno.test("a failed lookup answers without the corpus rather than failing", async () => {
  // Losing the reference costs a less specific answer. Returning an error costs
  // the student their question.
  const { db } = fakeDb({ error: { message: "connection reset" } });
  assertEquals(await loadKnowledge(db, "IB_DP", "how many words?"), []);
});

Deno.test("a section too large for the remaining budget is dropped, not truncated", async () => {
  // Half a rule reads exactly like a whole rule, and this corpus is mostly
  // rules. The smaller section after it still fits and is kept.
  const { db } = fakeDb({
    data: [row("7.3", "a".repeat(11_000)), row("7.5", "b".repeat(5_000)), row("5.3", "c".repeat(500))],
  });
  const got = await loadKnowledge(db, "IB_DP", "q");
  assertEquals(got.map((s) => s.section), ["7.3", "5.3"]);
});

Deno.test("total retrieved text stays under the ceiling however many rows come back", async () => {
  const { db } = fakeDb({ data: Array.from({ length: 8 }, (_, i) => row(`${i}`, "x".repeat(4_000))) });
  const got = await loadKnowledge(db, "IB_DP", "q");
  const total = got.reduce((n, s) => n + s.body.length, 0);
  assertEquals(total <= 12_000, true, `retrieved ${total} chars`);
});

Deno.test("rows with no body are skipped rather than fenced as empty reference", async () => {
  const { db } = fakeDb({ data: [row("1", ""), row("2", "real text")] });
  assertEquals((await loadKnowledge(db, "IB_DP", "q")).map((s) => s.section), ["2"]);
});
