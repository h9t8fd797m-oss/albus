// _shared/curriculum.ts — fetch the rubric that grounds a breakdown.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import type { RubricContext } from "./prompt.ts";

/**
 * Read through the caller's own client so RLS applies. Curriculum data is
 * world-readable to signed-in users, so this succeeds for any authenticated
 * caller and returns null when the assignment has no assessment attached.
 */
export async function loadRubric(
  db: SupabaseClient,
  assessmentTypeId: string | null,
): Promise<RubricContext | null> {
  if (!assessmentTypeId) return null;

  const { data, error } = await db
    .from("assessment_types")
    .select(`
      name,
      course_templates ( name, curricula ( name ) ),
      rubric_criteria ( id, code, name, marks, guidance, ordinal )
    `)
    .eq("id", assessmentTypeId)
    .maybeSingle();

  // A missing rubric must not fail the request — it degrades to a generic
  // breakdown, which is still useful.
  if (error || !data) {
    if (error) console.warn("rubric lookup failed, continuing generic:", error.message);
    return null;
  }

  // PostgREST embeds a to-one relation as either an object or a single-element
  // array depending on how it infers the relationship. Handle both.
  const one = <T>(v: unknown): T | null =>
    Array.isArray(v) ? (v[0] as T ?? null) : ((v as T) ?? null);

  const course = one<{ name: string; curricula: unknown }>(data.course_templates);
  const curriculum = one<{ name: string }>(course?.curricula);

  const criteria = ((data.rubric_criteria ?? []) as Array<{
    id: string;
    code: string;
    name: string;
    marks: number | null;
    guidance: string | null;
    ordinal: number;
  }>)
    .sort((a, b) => a.ordinal - b.ordinal)
    .map(({ id, code, name, marks, guidance }) => ({ id, code, name, marks, guidance }));

  if (criteria.length === 0) return null;

  return {
    kind: "curriculum",
    curriculumName: curriculum?.name ?? "General",
    courseName: course?.name ?? "Course",
    assessmentName: data.name as string,
    criteria,
    body: null,
  };
}

/**
 * Read the student's own saved rubric.
 *
 * Loaded server-side by id through the caller's client, never taken from the
 * request body. Two reasons: RLS makes a rubric belonging to someone else return
 * nothing, and the size caps that keep this affordable are enforced by the
 * column definitions rather than by whatever the client chose to send.
 */
export async function loadPersonalRubric(
  db: SupabaseClient,
  rubricId: string | null,
): Promise<RubricContext | null> {
  if (!rubricId) return null;

  const { data, error } = await db
    .from("rubrics")
    .select(`name, body, total_marks, rubric_items ( id, code, name, marks, guidance, ordinal )`)
    .eq("id", rubricId)
    .maybeSingle();

  if (error || !data) {
    if (error) console.warn("personal rubric lookup failed, continuing generic:", error.message);
    return null;
  }

  const criteria = ((data.rubric_items ?? []) as Array<{
    id: string;
    code: string | null;
    name: string;
    marks: number | null;
    guidance: string | null;
    ordinal: number;
  }>)
    .sort((a, b) => a.ordinal - b.ordinal)
    .map(({ id, code, name, marks, guidance }) => ({
      id,
      code: code ?? "",
      name,
      marks,
      guidance,
    }));

  const body = typeof data.body === "string" ? data.body : null;
  if (criteria.length === 0 && !(body ?? "").trim()) return null;

  return {
    kind: "personal",
    curriculumName: "the student's own rubric",
    courseName: "",
    assessmentName: data.name as string,
    criteria,
    body,
  };
}
