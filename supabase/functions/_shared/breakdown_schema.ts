// _shared/breakdown_schema.ts
// The contract for what the model must return, plus defensive validation.
//
// `output_config.format` already constrains the model, but we re-validate:
// a schema guarantees shape, not sanity. A step claiming 40 hours, or ten
// steps for a 30-minute reading, is well-formed and still wrong.

export interface PlanStep {
  title: string;
  guidance: string;
  estimated_minutes: number;
  rubric_criterion_code: string | null;
}

export interface BreakdownResult {
  steps: PlanStep[];
}

/**
 * Shape only — deliberately minimal.
 *
 * `output_config.format` supports a restricted JSON Schema subset: it rejects
 * minItems above 1, and rejects minimum/maximum/maxLength entirely. Encoding
 * bounds here also duplicates logic that validateAndNormalise must perform
 * regardless, since a schema can guarantee a field is an integer but not that
 * it is a sane number of minutes.
 *
 * So: the schema guarantees shape, the validator guarantees sanity.
 */
export const BREAKDOWN_JSON_SCHEMA = {
  type: "object",
  properties: {
    steps: {
      type: "array",
      items: {
        type: "object",
        properties: {
          title: { type: "string" },
          guidance: { type: "string" },
          estimated_minutes: { type: "integer" },
          rubric_criterion_code: { type: ["string", "null"] },
        },
        required: ["title", "guidance", "estimated_minutes", "rubric_criterion_code"],
        additionalProperties: false,
      },
    },
  },
  required: ["steps"],
  additionalProperties: false,
} as const;

export const MAX_STEPS = 12;
const MIN_STEP_MINUTES = 5;
const MAX_STEP_MINUTES = 480;

export class InvalidPlanError extends Error {}

/**
 * Clamp rather than reject where a value is merely implausible, and reject
 * only what cannot be salvaged. A student waiting on a plan is better served
 * by a slightly-adjusted plan than by an error.
 */
export function validateAndNormalise(
  raw: unknown,
  totalEstimatedMinutes: number,
): BreakdownResult {
  if (typeof raw !== "object" || raw === null || !("steps" in raw)) {
    throw new InvalidPlanError("response had no steps array");
  }
  const steps = (raw as { steps: unknown }).steps;
  if (!Array.isArray(steps) || steps.length === 0) {
    throw new InvalidPlanError("steps array was empty");
  }

  const normalised: PlanStep[] = steps.slice(0, MAX_STEPS).map((s, i) => {
    const step = s as Record<string, unknown>;
    const title = typeof step.title === "string" ? step.title.trim() : "";
    if (!title) throw new InvalidPlanError(`step ${i} had no title`);

    const rawMinutes = Number(step.estimated_minutes);
    const minutes = Number.isFinite(rawMinutes)
      ? Math.min(MAX_STEP_MINUTES, Math.max(MIN_STEP_MINUTES, Math.round(rawMinutes)))
      : 30;

    const code = typeof step.rubric_criterion_code === "string"
      ? step.rubric_criterion_code.trim() || null
      : null;

    return {
      title: title.slice(0, 200),
      guidance: typeof step.guidance === "string" ? step.guidance.trim().slice(0, 1000) : "",
      estimated_minutes: minutes,
      rubric_criterion_code: code,
    };
  });

  // If the model's total wildly overshoots what the student said they had,
  // scale proportionally rather than handing back a plan that cannot fit.
  const total = normalised.reduce((n, s) => n + s.estimated_minutes, 0);
  const ceiling = totalEstimatedMinutes * 1.5;
  if (total > ceiling && total > 0) {
    const factor = ceiling / total;
    for (const s of normalised) {
      s.estimated_minutes = Math.max(
        MIN_STEP_MINUTES,
        Math.round(s.estimated_minutes * factor),
      );
    }
  }

  return { steps: normalised };
}
