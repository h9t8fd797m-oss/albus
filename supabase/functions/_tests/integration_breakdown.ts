// _tests/integration_breakdown.ts
//
// Manual integration check: real rubric -> real prompt -> real Claude call ->
// real validation. Spends a few cents, so it is NOT part of `deno task test`.
//
//   deno run --allow-net --allow-env _tests/integration_breakdown.ts

import {
  type BreakdownInput,
  buildSystemPrompt,
  buildUserPrompt,
  type RubricContext,
  selectModel,
} from "../_shared/prompt.ts";
import { generateBreakdown } from "../_shared/anthropic.ts";
import { validateAndNormalise } from "../_shared/breakdown_schema.ts";

const IB_HISTORY_IA: RubricContext = {
  curriculumName: "International Baccalaureate Diploma Programme",
  courseName: "History HL",
  assessmentName: "Internal Assessment",
  criteria: [
    {
      id: "a",
      code: "A",
      name: "Identifying and evaluating sources",
      marks: 6,
      guidance: "Pick two sources, say why each is useful, and be honest about their limits.",
    },
    {
      id: "b",
      code: "B",
      name: "Investigation",
      marks: 15,
      guidance: "The argument itself, built on evidence you can point to.",
    },
    {
      id: "c",
      code: "C",
      name: "Reflection",
      marks: 4,
      guidance: "What the research taught you about how historians actually work.",
    },
  ],
};

const CASES: Array<{ label: string; input: BreakdownInput }> = [
  {
    label: "rubric-bound (IB History IA)",
    input: {
      title: "History IA on the 1848 revolutions",
      taskType: "essay",
      deadlineISO: "2026-09-05T23:59:00Z",
      estimatedMinutes: 480,
      nowISO: new Date().toISOString(),
      rubric: IB_HISTORY_IA,
    },
  },
  {
    label: "generic (no rubric)",
    input: {
      title: "Read chapter 12 of the biology textbook",
      taskType: "reading",
      deadlineISO: "2026-08-24T23:59:00Z",
      estimatedMinutes: 90,
      nowISO: new Date().toISOString(),
      rubric: null,
    },
  },
  {
    label: "ugly: 20h task due tomorrow",
    input: {
      title: "Physics revision for the whole unit",
      taskType: "revision",
      deadlineISO: new Date(Date.now() + 86_400_000).toISOString(),
      estimatedMinutes: 1200,
      nowISO: new Date().toISOString(),
      rubric: null,
    },
  },
  {
    label: "ugly: one-word title",
    input: {
      title: "Maths",
      taskType: "problem_set",
      deadlineISO: new Date(Date.now() + 3 * 86_400_000).toISOString(),
      estimatedMinutes: 60,
      nowISO: new Date().toISOString(),
      rubric: null,
    },
  },
];

let failures = 0;

for (const { label, input } of CASES) {
  const model = selectModel(input);
  const t0 = Date.now();
  try {
    const gen = await generateBreakdown(
      model,
      buildSystemPrompt(input.rubric),
      buildUserPrompt(input),
    );
    const plan = validateAndNormalise(gen.raw, input.estimatedMinutes);
    const total = plan.steps.reduce((n, s) => n + s.estimated_minutes, 0);
    const codes = plan.steps.map((s) => s.rubric_criterion_code).filter(Boolean);
    const validCodes = new Set(input.rubric?.criteria.map((c) => c.code) ?? []);
    const bogus = codes.filter((c) => !validCodes.has(c!));

    console.log(`\n── ${label}`);
    console.log(
      `   model=${model}  ${
        Date.now() - t0
      }ms  in=${gen.inputTokens} out=${gen.outputTokens} cacheRead=${gen.cacheReadTokens}`,
    );
    console.log(
      `   steps=${plan.steps.length}  total=${total}min (budget ${input.estimatedMinutes})`,
    );
    if (bogus.length) {
      console.log(`   !! HALLUCINATED CRITERION CODES: ${bogus.join(",")}`);
      failures++;
    }
    if (input.rubric && codes.length === 0) {
      console.log("   !! rubric supplied but no step cited a criterion");
      failures++;
    }
    for (const s of plan.steps) {
      console.log(
        `     ${String(s.estimated_minutes).padStart(3)}m [${
          s.rubric_criterion_code ?? "-"
        }] ${s.title}`,
      );
    }
    console.log(`     first-step guidance: ${plan.steps[0].guidance.slice(0, 110)}`);
  } catch (e) {
    console.log(`\n── ${label}\n   FAILED: ${e instanceof Error ? e.message : e}`);
    failures++;
  }
}

console.log(`\n${failures === 0 ? "ALL CASES OK" : `${failures} PROBLEM(S)`}`);
Deno.exit(failures === 0 ? 0 : 1);
