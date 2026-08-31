// chat/index.ts
//
// Ask Albus: a question about one assignment, answered against that
// assignment's own plan and rubric.
//
// Not a general chatbot, deliberately. Every turn is grounded in work the
// caller owns, which is both the product argument and the security one: the
// assignment is loaded through the caller-scoped client, so RLS decides what
// can enter the context window. Missing, forged and foreign ids are refused
// before retrieval, quota reservation, or an Anthropic call.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { requireUser } from "../_shared/auth.ts";
import { readJsonBody } from "../_shared/body.ts";
import { errorResponse, HttpError, jsonResponse } from "../_shared/http.ts";
import { chatReply } from "../_shared/anthropic.ts";
import {
  assertAPIRequestRate,
  finalizeAIUsage,
  reserveAIUsage,
  usageFailureCode,
} from "../_shared/quota.ts";
import { noteRefusal, recordSignals, type Signals } from "../_shared/signals.ts";
import {
  buildChatSystemPrompt,
  buildChatUserPrompt,
  type ChatContext,
  MAX_MESSAGE_CHARS,
  sanitiseHistory,
  type StudentContext,
  type StudentSubject,
} from "../_shared/chat_prompt.ts";
import { loadKnowledge } from "../_shared/knowledge.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const MODEL_CHAT_RUBRIC = "claude-sonnet-5";
const MODEL_CHAT_PLAIN = "claude-haiku-4-5";

/**
 * Who is asking: curriculum, subjects, and how those subjects are assessed.
 *
 * Every row here is read through the caller's own client, so RLS answers the
 * "whose data is this" question rather than this code doing it. A student's
 * curriculum and subjects are their own rows; there is no request-body input to
 * this function at all, which is what makes borrowing another student's
 * curriculum impossible rather than merely unlikely.
 *
 * Fails soft — a chat that works without knowing the student is better than one
 * that refuses because a profile row is missing.
 */
async function loadStudent(db: SupabaseClient): Promise<StudentContext | null> {
  const [profile, courses] = await Promise.all([
    db.from("profiles").select("curriculum_code").maybeSingle(),
    // The subject's link to a specification is `course_template_id`, set when
    // the student picked the subject. That link is what turns "Biology" into
    // "Biology, whose IA is worth 20%".
    db.from("courses")
      .select(`
        display_name,
        course_templates ( name, assessment_types ( code, name, typical_minutes ) )
      `)
      .order("display_name")
      .limit(20),
  ]);

  const code = profile.data?.curriculum_code as string | null | undefined;
  let curriculumName: string | null = null;
  if (code) {
    const { data } = await db.from("curricula").select("name").eq("code", code).maybeSingle();
    // Resolved name only. The first version of this fell back to `?? code`,
    // which put an unbounded, user-writable string straight into the system
    // prompt — above the breakpoint where the "fenced text is data" rule lives.
    // A 40KB code and an injecting code were both accepted by the API. Migration
    // 0023 added the foreign key that makes it impossible; this is the half that
    // would still hold if the constraint were ever dropped.
    curriculumName = typeof data?.name === "string" ? data.name : null;
  }

  const one = <T>(v: unknown): T | null =>
    Array.isArray(v) ? ((v[0] as T) ?? null) : ((v as T) ?? null);

  const subjects: StudentSubject[] = (courses.data ?? [])
    .map((row) => {
      const r = row as {
        display_name: string;
        course_templates: unknown;
      };
      const template = one<{
        name: string;
        assessment_types?: Array<{ code: string; name: string; typical_minutes: number | null }>;
      }>(r.course_templates);

      const components = (template?.assessment_types ?? [])
        .map((a) => a.name)
        .filter(Boolean);

      return { name: r.display_name, components };
    })
    .filter((s) => Boolean(s.name));

  if (!curriculumName && subjects.length === 0) return null;
  return { curriculumName, curriculumCode: code ?? null, subjects };
}

async function loadContext(
  db: SupabaseClient,
  assignmentId: string,
  focusStep: number | null,
): Promise<ChatContext | null> {
  // RLS applies here: another user's assignment returns no rows, not an error.
  const { data, error } = await db
    .from("assignments")
    .select(`
      title, task_type, deadline,
      rubrics ( name, body, rubric_items ( code, name, marks, ordinal ) ),
      subtasks ( title, estimated_minutes, completed_at, ordinal,
                 rubric_criteria ( code, name, marks ) )
    `)
    .eq("id", assignmentId)
    .maybeSingle();

  if (error || !data) return null;

  const row = data as unknown as {
    title: string;
    task_type: string;
    deadline: string;
    rubrics: {
      name: string;
      body: string | null;
      rubric_items: Array<
        { code: string | null; name: string; marks: number | null; ordinal: number }
      >;
    } | null;
    subtasks: Array<{
      title: string;
      estimated_minutes: number;
      completed_at: string | null;
      ordinal: number;
      rubric_criteria: { code: string; name: string; marks: number | null } | null;
    }>;
  };

  const subtasks = (row.subtasks ?? []).sort((a, b) => a.ordinal - b.ordinal);

  const criteria = new Map<string, string>();
  for (const s of subtasks) {
    const c = Array.isArray(s.rubric_criteria) ? s.rubric_criteria[0] : s.rubric_criteria;
    if (c?.code) {
      criteria.set(c.code, `${c.code}: ${c.name}${c.marks ? ` (${c.marks} marks)` : ""}`);
    }
  }

  // The student's own rubric wins over the curriculum criteria attached to
  // steps: it is the sheet they are actually being marked against.
  //
  // PostgREST embeds a to-one relation as either an object or a single-element
  // array depending on how it infers the relationship, so both are handled —
  // and the annotation is explicit, because indexing a declared object type
  // silently produces `any`.
  type PersonalRubric = NonNullable<typeof row.rubrics>;
  const embedded = row.rubrics as PersonalRubric | PersonalRubric[] | null;
  const personal: PersonalRubric | null = Array.isArray(embedded)
    ? (embedded[0] ?? null)
    : embedded;
  let personalSummary: string | null = null;
  if (personal) {
    const items = (personal.rubric_items ?? [])
      .sort((a, b) => a.ordinal - b.ordinal)
      .map((i) => `${i.code ? `${i.code}: ` : ""}${i.name}${i.marks ? ` (${i.marks} marks)` : ""}`);
    const parts = [items.join("\n"), personal.body ?? ""].filter((p) => p.trim().length > 0);
    if (parts.length > 0) personalSummary = `${personal.name}\n${parts.join("\n\n")}`;
  }

  return {
    assignmentTitle: row.title,
    taskType: row.task_type,
    deadlineISO: row.deadline,
    steps: subtasks.map((s) => {
      const c = Array.isArray(s.rubric_criteria) ? s.rubric_criteria[0] : s.rubric_criteria;
      return {
        title: s.title,
        estimatedMinutes: s.estimated_minutes,
        completed: s.completed_at !== null,
        criterionCode: c?.code ?? null,
      };
    }),
    rubricSummary: personalSummary ??
      (criteria.size > 0 ? [...criteria.values()].join("\n") : null),
    focusStep,
  };
}

Deno.serve(async (req) => {
  // Hoisted so the `catch` can attribute a refusal. A denial that cannot
  // be attributed is a denial the risk model cannot count.
  let callerId: string | null = null;
  let signals: Signals = { deviceHash: null, ipPrefixHash: null };
  try {
    if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");

    const caller = await requireUser(req);
    callerId = caller.id;
    await assertAPIRequestRate(caller.id, "chat");
    // Hashed here and only here. What reaches Postgres is two digests.
    signals = await recordSignals(req, caller.id);

    const body = await readJsonBody<{
      message?: unknown;
      assignment_id?: unknown;
      history?: unknown;
      step?: unknown;
    }>(req, 32_768);

    const message = typeof body.message === "string" ? body.message.trim() : "";
    if (message.length < 1) throw new HttpError(422, "EMPTY_MESSAGE");
    if (message.length > MAX_MESSAGE_CHARS) throw new HttpError(413, "MESSAGE_TOO_LONG");

    const assignmentId = typeof body.assignment_id === "string" && UUID_RE.test(body.assignment_id)
      ? body.assignment_id
      : null;
    if (!assignmentId) {
      throw new HttpError(422, "ASSIGNMENT_REQUIRED", "Open an assignment before asking Albus.");
    }

    // 1-based step number the student is looking at. Bounds are checked against
    // the loaded plan below; anything out of range is simply ignored rather than
    // rejected, because it is a stale tap, not an attack.
    const step = Number(body.step);
    const focusStep = Number.isInteger(step) && step >= 1 && step <= 64 ? step : null;

    // Both loads in parallel: one is about the assignment, one about the
    // student, and neither needs the other.
    const [context, student] = await Promise.all([
      loadContext(caller.db, assignmentId, focusStep),
      loadStudent(caller.db),
    ]) as [ChatContext | null, StudentContext | null];

    // Unknown and foreign ids deliberately have the same public result. RLS
    // makes both `null`; answering either one generally would reopen the exact
    // general-chat surface the product removed and would still cost money.
    if (!context) {
      throw new HttpError(404, "ASSIGNMENT_NOT_FOUND", "That assignment is unavailable.");
    }

    // Which corpus, if any, comes from the caller's own profile row — never
    // from the request. A student cannot ask for another qualification's
    // reference material by claiming to study it.
    const knowledge = await loadKnowledge(caller.db, student?.curriculumCode ?? null, message);

    const model = context.rubricSummary || knowledge.length > 0
      ? MODEL_CHAT_RUBRIC
      : MODEL_CHAT_PLAIN;

    // Reserve a slot before spending anything. Atomic in Postgres, so two
    // concurrent requests cannot both pass the last remaining unit of quota.
    const usageId = await reserveAIUsage(caller.id, "chat", model);
    let result: Awaited<ReturnType<typeof chatReply>> | null = null;
    try {
      result = await chatReply(
        model,
        buildChatSystemPrompt(context, student),
        sanitiseHistory(body.history),
        buildChatUserPrompt(knowledge, message),
      );

      await finalizeAIUsage(
        usageId,
        "completed",
        result.inputTokens,
        result.outputTokens,
      );

      return jsonResponse({
        reply: result.text,
        model,
        grounded: true,
        // Which sections shaped the answer. Cheap to return, and the difference
        // between trusting the retrieval and hoping it worked.
        knowledge: knowledge.map((k) => k.section),
      });
    } catch (e) {
      await finalizeAIUsage(
        usageId,
        "failed",
        result?.inputTokens ?? null,
        result?.outputTokens ?? null,
        usageFailureCode(e),
      );
      throw e;
    }
  } catch (e) {
    noteRefusal(e, callerId, "chat", signals);
    return errorResponse(e);
  }
});
