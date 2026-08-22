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
} from "../_shared/chat_prompt.ts";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const MODEL_CHAT_RUBRIC = "claude-sonnet-5";
const MODEL_CHAT_PLAIN = "claude-haiku-4-5";

async function loadContext(
  db: SupabaseClient,
  assignmentId: string,
): Promise<ChatContext | null> {
  // RLS applies here: another user's assignment returns no rows, not an error.
  const { data, error } = await db
    .from("assignments")
    .select(`
      title, task_type, deadline,
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
    rubricSummary: criteria.size > 0 ? [...criteria.values()].join("\n") : null,
  };
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");

    const caller = await requireUser(req);

    let body: { message?: unknown; assignment_id?: unknown; history?: unknown };
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

    const context = assignmentId ? await loadContext(caller.db, assignmentId) : null;
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
      buildChatSystemPrompt(context),
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
