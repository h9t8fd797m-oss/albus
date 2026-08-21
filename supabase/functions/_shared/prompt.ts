// _shared/prompt.ts
// Model routing and prompt construction. Deliberately pure — no network, no
// database — so the interesting decisions are unit-testable without Docker.

export interface RubricCriterion {
  id: string;
  code: string;
  name: string;
  marks: number | null;
  guidance: string | null;
}

export interface RubricContext {
  curriculumName: string;
  courseName: string;
  assessmentName: string;
  criteria: RubricCriterion[];
}

export interface BreakdownInput {
  title: string;
  taskType: string;
  deadlineISO: string;
  estimatedMinutes: number;
  nowISO: string;
  rubric: RubricContext | null;
}

/** Rate table lives in docs/backend.md; these are the routing targets. */
export const MODEL_RUBRIC = "claude-sonnet-5";
export const MODEL_GENERIC = "claude-haiku-4-5";

/**
 * Applying a rubric to a specific prompt is genuine reasoning and is the
 * product's differentiator, so it gets the stronger model. "Read chapter 12"
 * is decomposition, not reasoning — roughly two thirds of real volume — and
 * goes to the cheap one. See docs/backend.md for the cost working.
 */
export function selectModel(input: BreakdownInput): string {
  return input.rubric && input.rubric.criteria.length > 0 ? MODEL_RUBRIC : MODEL_GENERIC;
}

/**
 * Whole calendar days between now and the deadline.
 *
 * Compares dates, not elapsed hours: a deadline at 18:00 today is "due today",
 * not "due tomorrow", which is what counting 9 remaining hours as a day would
 * produce. Uses UTC — the client does not yet send its timezone, so a student
 * near midnight can be a day out. Worth fixing when the app sends an offset.
 */
export function daysUntil(deadlineISO: string, nowISO: string): number {
  const dayIndex = (iso: string): number => {
    const d = new Date(iso);
    return Math.floor(
      Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()) / 86_400_000,
    );
  };
  return Math.max(0, dayIndex(deadlineISO) - dayIndex(nowISO));
}

const VOICE = `You are Albus, a study planner for IB, AP and university students.

Break an assignment into a small number of concrete, startable steps.

Rules:
- Every step must name a specific action the student can begin immediately.
  "Research the topic" is useless. "Find and skim three sources on X" is not.
- The first step must be the smallest one. Starting is the hard part.
- Step durations must sum to roughly the time the student has budgeted.
- Between two and eight steps. Fewer, larger steps beat many trivial ones.
- guidance is one sentence on how to do the step, in plain language.
- Never mention being an AI, never pad, never moralise about time management.`;

/**
 * The cacheable half: identical for every student doing this assessment in
 * this course, which is exactly what makes a per-course knowledge layer
 * affordable. Nothing volatile may appear here — a timestamp or a task title
 * above the cache breakpoint silently destroys the hit rate.
 */
export function buildSystemPrompt(rubric: RubricContext | null): string {
  if (!rubric || rubric.criteria.length === 0) return VOICE;

  const criteria = rubric.criteria
    .map((c) => {
      const marks = c.marks != null ? ` (${c.marks} marks)` : "";
      const note = c.guidance ? ` — ${c.guidance}` : "";
      return `- ${c.code}: ${c.name}${marks}${note}`;
    })
    .join("\n");

  return `${VOICE}

This assignment is assessed work: ${rubric.assessmentName}, ${rubric.courseName} (${rubric.curriculumName}).

It is marked against these criteria:
${criteria}

Shape the steps around these criteria in the order a student would actually
work through them. Set rubric_criterion_code to the matching code for steps
that serve one criterion, and null for genuinely general steps such as
proofreading or submitting. Use only the codes listed above — never invent one.`;
}

/** The volatile half: everything specific to this task, after the breakpoint. */
export function buildUserPrompt(input: BreakdownInput): string {
  const days = daysUntil(input.deadlineISO, input.nowISO);
  const when = days === 0 ? "due today" : days === 1 ? "due tomorrow" : `due in ${days} days`;

  const hours = (input.estimatedMinutes / 60).toFixed(1).replace(/\.0$/, "");

  return `Assignment: ${input.title}
Type: ${input.taskType}
Deadline: ${when}
Time the student has budgeted: ${hours} hours (${input.estimatedMinutes} minutes)

Break this into steps.`;
}
