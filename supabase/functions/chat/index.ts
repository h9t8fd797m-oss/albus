// chat/index.ts
//
// Ask Albus: a question about one assignment, answered against that
// assignment's own plan and rubric.
//
// Not a general chatbot, deliberately. Every turn is grounded in work the
// caller owns, which is both the product argument and the security one: the
// assignment is loaded through the caller-scoped client, so RLS decides what
// can enter the context window. A forged assignment_id simply finds nothing.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { requireUser } from "../_shared/auth.ts";
import { errorResponse, HttpError, jsonResponse, mapPostgresError } from "../_shared/http.ts";
import { chatReply } from "../_shared/anthropic.ts";
import { recordTokensInBackground } from "../_shared/quota.ts";
import {
  buildChatSystemPrompt,
  type ChatContext,
  MAX_MESSAGE_CHARS,
  sanitiseHistory,
  type StudentContext,
} from "../_shared/chat_prompt.ts";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const MODEL_CHAT_RUBRIC = "claude-sonnet-5";
const MODEL_CHAT_PLAIN = "claude-haiku-4-5";

/**
 * Who is asking: curriculum and subjects.
 *
 * One round trip, and it fails soft — a chat that works without knowing the
 * student is better than one that refuses because a profile row is missing.
 */
async function loadStudent(db: SupabaseClient): Promise<StudentContext | null> {
  const [profile, courses] = await Promise.all([
    db.from("profiles").select("curriculum_code").maybeSingle(),
    db.from("courses").select("display_name").order("display_name").limit(20),
  ]);

  const code = profile.data?.curriculum_code as string | null | undefined;
  let curriculumName: string | null = null;
  if (code) {
    const { data } = await db.from("curricula").select("name").eq("code", code).maybeSingle();
    curriculumName = (data?.name as string) ?? code;
  }

  const names = (courses.data ?? [])
    .map((c) => (c as { display_name: string }).display_name)
    .filter(Boolean);

  if (!curriculumName && names.length === 0) return null;
  return { curriculumName, courses: names };
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
      rubric_items: Array<{ code: string | null; name: string; marks: number | null; ordinal: number }>;
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
    rubricSummary: personalSummary
      ?? (criteria.size > 0 ? [...criteria.values()].join("\n") : null),
    focusStep,
  };
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");

    const caller = await requireUser(req);

    let body: {
      message?: unknown;
      assignment_id?: unknown;
      history?: unknown;
      step?: unknown;
    };
    try {
      body = await req.json();
    } catch {
      throw new HttpError(400, "INVALID_JSON");
    }

    const message = typeof body.message === "string" ? body.message.trim() : "";
    if (message.length < 1) throw new HttpError(422, "EMPTY_MESSAGE");
    if (message.length > MAX_MESSAGE_CHARS) throw new HttpError(413, "MESSAGE_TOO_LONG");

    const assignmentId =
      typeof body.assignment_id === "string" && UUID_RE.test(body.assignment_id)
        ? body.assignment_id
        : null;

    // 1-based step number the student is looking at. Bounds are checked against
    // the loaded plan below; anything out of range is simply ignored rather than
    // rejected, because it is a stale tap, not an attack.
    const step = Number(body.step);
    const focusStep = Number.isInteger(step) && step >= 1 && step <= 64 ? step : null;

    // Both loads in parallel: one is about the assignment, one about the
    // student, and neither needs the other.
    const [context, student] = await Promise.all([
      assignmentId ? loadContext(caller.db, assignmentId, focusStep) : Promise.resolve(null),
      loadStudent(caller.db),
    ]) as [ChatContext | null, StudentContext | null];

    const model = context?.rubricSummary ? MODEL_CHAT_RUBRIC : MODEL_CHAT_PLAIN;

    // Reserve a slot before spending anything. Atomic in Postgres, so two
    // concurrent requests cannot both pass the last remaining unit of quota.
    const { data: usageId, error: quotaError } = await caller.db.rpc(
      "check_and_record_ai_usage",
      { p_kind: "chat", p_model: model },
    );
    if (quotaError) throw mapPostgresError(quotaError.message);

    const result = await chatReply(
      model,
      buildChatSystemPrompt(context, student),
      sanitiseHistory(body.history),
      message,
    );

    if (usageId) {
      recordTokensInBackground(
        caller.db,
        usageId as string,
        result.inputTokens,
        result.outputTokens,
      );
    }

    return jsonResponse({
      reply: result.text,
      model,
      grounded: context !== null,
    });
  } catch (e) {
    return errorResponse(e);
  }
});
