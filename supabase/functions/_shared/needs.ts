// _shared/needs.ts — what a plan step can need doing to it.
//
// Generated from scripts/tools/capabilities.py — do not edit by hand.
//
// One vocabulary, three consumers: the list the planner is offered, the set the
// server validates against, and the tags the tool catalogue carries. Generating
// all three from one file is what stops the model emitting a need no tool
// serves, which would silently show a student no tools at all.

export const STUDY_NEEDS = [
  "source_research",
  "reading",
  "note_taking",
  "outlining",
  "drafting",
  "editing",
  "proofreading",
  "citation",
  "feedback",
  "worked_examples",
  "problem_practice",
  "error_analysis",
  "computation",
  "graphing",
  "data_analysis",
  "simulation",
  "diagramming",
  "translation",
  "vocabulary",
  "listening_speaking",
  "memorisation",
  "spaced_practice",
  "self_testing",
  "coding",
  "debugging",
  "presentation",
  "design",
  "planning",
  "focus",
  "wellbeing",
] as const;

export type StudyNeed = typeof STUDY_NEEDS[number];

const SET: ReadonlySet<string> = new Set(STUDY_NEEDS);

/** The need, or null for anything that is not one. Never throws: an unknown
 *  need costs a step its tool suggestions, not the student their plan. */
export function studyNeed(value: unknown): StudyNeed | null {
  return typeof value === "string" && SET.has(value) ? value as StudyNeed : null;
}
