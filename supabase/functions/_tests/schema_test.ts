import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { InvalidPlanError, validateAndNormalise } from "../_shared/breakdown_schema.ts";

const ok = {
  steps: [
    {
      title: "Find sources",
      guidance: "Skim three.",
      estimated_minutes: 60,
      rubric_criterion_code: "A",
    },
    { title: "Draft", guidance: "Write it.", estimated_minutes: 120, rubric_criterion_code: "B" },
  ],
};

Deno.test("accepts a well-formed plan unchanged", () => {
  const r = validateAndNormalise(ok, 180);
  assertEquals(r.steps.length, 2);
  assertEquals(r.steps[0].rubric_criterion_code, "A");
});

Deno.test("rejects responses with no usable steps", () => {
  assertThrows(() => validateAndNormalise({}, 180), InvalidPlanError);
  assertThrows(() => validateAndNormalise({ steps: [] }, 180), InvalidPlanError);
  assertThrows(() => validateAndNormalise(null, 180), InvalidPlanError);
});

Deno.test("rejects a step with no title — unstartable by definition", () => {
  assertThrows(
    () =>
      validateAndNormalise({
        steps: [{ title: "  ", guidance: "x", estimated_minutes: 30, rubric_criterion_code: null }],
      }, 60),
    InvalidPlanError,
  );
});

Deno.test("clamps absurd durations instead of failing the request", () => {
  const r = validateAndNormalise({
    steps: [{
      title: "Do it",
      guidance: "",
      estimated_minutes: 99999,
      rubric_criterion_code: null,
    }],
  }, 120);
  assert(r.steps[0].estimated_minutes <= 480);
  assert(r.steps[0].estimated_minutes >= 5);
});

Deno.test("coerces a non-numeric duration to a sane default", () => {
  const r = validateAndNormalise({
    steps: [{
      title: "Do it",
      guidance: "",
      estimated_minutes: "soon",
      rubric_criterion_code: null,
    }],
  }, 120);
  assertEquals(r.steps[0].estimated_minutes, 30);
});

Deno.test("scales down a plan that overshoots the student's budget", () => {
  const r = validateAndNormalise({
    steps: [
      { title: "A", guidance: "", estimated_minutes: 400, rubric_criterion_code: null },
      { title: "B", guidance: "", estimated_minutes: 400, rubric_criterion_code: null },
    ],
  }, 120); // budget 2h, model asked for 13h
  const total = r.steps.reduce((n, s) => n + s.estimated_minutes, 0);
  assert(total <= 120 * 1.5 + 10, `expected ~<=180, got ${total}`);
});

Deno.test("caps runaway step counts", () => {
  const many = {
    steps: Array.from({ length: 40 }, (_, i) => ({
      title: `S${i}`,
      guidance: "",
      estimated_minutes: 10,
      rubric_criterion_code: null,
    })),
  };
  assertEquals(validateAndNormalise(many, 400).steps.length, 12);
});

Deno.test("normalises an empty criterion code to null", () => {
  const r = validateAndNormalise({
    steps: [{ title: "A", guidance: "", estimated_minutes: 30, rubric_criterion_code: "  " }],
  }, 60);
  assertEquals(r.steps[0].rubric_criterion_code, null);
});
