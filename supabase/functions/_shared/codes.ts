// _shared/codes.ts — curriculum codes as they arrive from a client.

/**
 * Curriculum codes are ours and we generate them: `AQA_ALEVEL_BIOLOGY`,
 * `PAPER_3`, `IA`. Bounded and narrow on purpose, so a code can only ever be a
 * lookup key and never a payload — no whitespace to smuggle, no punctuation
 * PostgREST would read as an operator, no length worth logging.
 */
const CODE_RE = /^[A-Z0-9_]{1,64}$/;

/**
 * Returns the code, or null for anything that is not one.
 *
 * Null rather than an error: an unrecognised code costs the student their
 * curriculum grounding, which is a less specific plan — not a failed request.
 * Refusing to plan someone's assignment because a client sent a stale subject
 * code would be the wrong trade every time.
 */
export function curriculumCode(value: unknown): string | null {
  return typeof value === "string" && CODE_RE.test(value) ? value : null;
}
