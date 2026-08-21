import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import {
  type BreakdownInput,
  buildSystemPrompt,
  buildUserPrompt,
  daysUntil,
  MODEL_GENERIC,
  MODEL_RUBRIC,
  type RubricContext,
  selectModel,
} from "../_shared/prompt.ts";

const RUBRIC: RubricContext = {
  curriculumName: "International Baccalaureate Diploma Programme",
  courseName: "History HL",
  assessmentName: "Internal Assessment",
  criteria: [
    {
      id: "id-a",
      code: "A",
      name: "Identifying and evaluating sources",
      marks: 6,
      guidance: "Pick two sources.",
    },
    { id: "id-b", code: "B", name: "Investigation", marks: 15, guidance: null },
  ],
};

const base: BreakdownInput = {
  title: "History term paper",
  taskType: "essay",
  deadlineISO: "2026-05-23T23:59:00Z",
  estimatedMinutes: 480,
  nowISO: "2026-05-20T09:00:00Z",
  rubric: null,
};

Deno.test("routes rubric-bound work to the stronger model", () => {
  assertEquals(selectModel({ ...base, rubric: RUBRIC }), MODEL_RUBRIC);
});

Deno.test("routes generic work to the cheap model", () => {
  assertEquals(selectModel(base), MODEL_GENERIC);
});

Deno.test("a rubric with no criteria is treated as generic", () => {
  assertEquals(selectModel({ ...base, rubric: { ...RUBRIC, criteria: [] } }), MODEL_GENERIC);
});

Deno.test("system prompt embeds every criterion code", () => {
  const p = buildSystemPrompt(RUBRIC);
  assertStringIncludes(p, "A: Identifying and evaluating sources (6 marks)");
  assertStringIncludes(p, "B: Investigation (15 marks)");
  assertStringIncludes(p, "History HL");
});

Deno.test("system prompt is stable across tasks — the cache depends on it", () => {
  // Two different assignments in the same course must produce a byte-identical
  // prefix, or the prompt cache never hits.
  assertEquals(buildSystemPrompt(RUBRIC), buildSystemPrompt(structuredClone(RUBRIC)));
});

Deno.test("system prompt leaks no task specifics", () => {
  const p = buildSystemPrompt(RUBRIC);
  assert(!p.includes("History term paper"), "task title must stay below the cache breakpoint");
  assert(!p.includes("2026"), "no dates above the cache breakpoint");
});

Deno.test("deadline is phrased in human terms", () => {
  assertStringIncludes(
    buildUserPrompt({ ...base, deadlineISO: "2026-05-20T18:00:00Z" }),
    "due today",
  );
  assertStringIncludes(
    buildUserPrompt({ ...base, deadlineISO: "2026-05-21T09:00:00Z" }),
    "due tomorrow",
  );
  assertStringIncludes(buildUserPrompt(base), "due in 3 days");
});

Deno.test("a past deadline clamps to zero rather than going negative", () => {
  assertEquals(daysUntil("2026-05-01T00:00:00Z", "2026-05-20T09:00:00Z"), 0);
});

Deno.test("hours render without a trailing .0", () => {
  assertStringIncludes(buildUserPrompt({ ...base, estimatedMinutes: 120 }), "2 hours");
  assertStringIncludes(buildUserPrompt({ ...base, estimatedMinutes: 90 }), "1.5 hours");
});
