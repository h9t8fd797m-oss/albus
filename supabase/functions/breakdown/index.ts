// breakdown/index.ts
//
// Turns an assignment into rubric-grounded, startable steps and persists them
// atomically. The one endpoint that carries the product's differentiator.

import { requireUser } from "../_shared/auth.ts";
import { errorResponse, HttpError, jsonResponse, mapPostgresError } from "../_shared/http.ts";
import { assertCanGeneratePlan } from "../_shared/quota.ts";
import { loadRubric } from "../_shared/curriculum.ts";
import { generateBreakdown } from "../_shared/anthropic.ts";
import {
  type BreakdownInput,
  buildSystemPrompt,
  buildUserPrompt,
  selectModel,
} from "../_shared/prompt.ts";
import { InvalidPlanError, validateAndNormalise } from "../_shared/breakdown_schema.ts";

const TASK_TYPES = new Set([
  "essay",
  "problem_set",
  "lab_report",
  "reading",
  "revision",
  "project",
  "presentation",
  "other",
]);

interface RequestBody {
  title?: unknown;
  task_type?: unknown;
  deadline?: unknown;
  estimated_minutes?: unknown;
  course_id?: unknown;
  assessment_type_id?: unknown;
  notes?: unknown;
}

/** Everything here is attacker-controlled. Validate before it reaches the model. */
function parseBody(body: RequestBody) {
  const title = typeof body.title === "string" ? body.title.trim() : "";
  if (title.length < 2 || title.length > 200) {
    throw new HttpError(422, "INVALID_TITLE", "Title must be 2–200 characters.");
  }

  const taskType = typeof body.task_type === "string" ? body.task_type : "other";
  if (!TASK_TYPES.has(taskType)) {
    throw new HttpError(422, "INVALID_TASK_TYPE", `Unknown task type: ${taskType}`);
  }

  const deadlineRaw = typeof body.deadline === "string" ? body.deadline : "";
  const deadlineMs = Date.parse(deadlineRaw);
  if (!Number.isFinite(deadlineMs)) {
    throw new HttpError(422, "INVALID_DEADLINE", "Deadline must be an ISO-8601 timestamp.");
  }

  const minutes = Number(body.estimated_minutes);
  if (!Number.isFinite(minutes) || minutes < 5 || minutes > 12_000) {
    throw new HttpError(422, "INVALID_ESTIMATE", "Estimated minutes must be 5–12000.");
  }

  const uuid = (v: unknown): string | null =>
    typeof v === "string" && /^[0-9a-f-]{36}$/i.test(v) ? v : null;

  return {
    title,
    taskType,
    deadlineISO: new Date(deadlineMs).toISOString(),
    estimatedMinutes: Math.round(minutes),
    courseId: uuid(body.course_id),
    assessmentTypeId: uuid(body.assessment_type_id),
    notes: typeof body.notes === "string" ? body.notes.slice(0, 2000) : null,
  };
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");

    // Identity comes from the verified JWT. Anything in the body is a claim.
    const caller = await requireUser(req);

    let body: RequestBody;
    try {
      body = await req.json();
    } catch {
      throw new HttpError(400, "INVALID_JSON");
    }
    const input = parseBody(body);

    // Cheap pre-check so we never pay for a generation we're going to reject.
    // The authoritative check lives in the RPC, inside the insert transaction.
    await assertCanGeneratePlan(caller);

    const rubric = await loadRubric(caller.db, input.assessmentTypeId);

    const promptInput: BreakdownInput = {
      title: input.title,
      taskType: input.taskType,
      deadlineISO: input.deadlineISO,
      estimatedMinutes: input.estimatedMinutes,
      nowISO: new Date().toISOString(),
      rubric,
    };

    const model = selectModel(promptInput);

    // Reserve a usage slot atomically before spending anything. The active-plan
    // cap bounds how much work a user can have open; this bounds how fast they
    // can burn tokens, which is the axis that actually costs money.
    const { data: usageId, error: rateError } = await caller.db.rpc(
      "check_and_record_ai_usage",
      { p_kind: "breakdown", p_model: model },
    );
    if (rateError) throw mapPostgresError(rateError.message);

    const generated = await generateBreakdown(
      model,
      buildSystemPrompt(rubric),
      buildUserPrompt(promptInput),
    );

    let plan;
    try {
      plan = validateAndNormalise(generated.raw, input.estimatedMinutes);
    } catch (e) {
      if (e instanceof InvalidPlanError) {
        console.error("model produced an unusable plan:", e.message);
        throw new HttpError(502, "MALFORMED_RESPONSE", "Plan generation failed.");
      }
      throw e;
    }

    // Map criterion codes back to real ids. The model only ever sees codes,
    // so it cannot fabricate a foreign key into another course's rubric.
    const codeToId = new Map(rubric?.criteria.map((c) => [c.code, c.id]) ?? []);
    const subtasks = plan.steps.map((s) => ({
      title: s.title,
      guidance: s.guidance,
      estimated_minutes: s.estimated_minutes,
      rubric_criterion_id: s.rubric_criterion_code
        ? codeToId.get(s.rubric_criterion_code) ?? null
        : null,
    }));

    const { data: assignmentId, error } = await caller.db.rpc(
      "create_assignment_with_plan",
      {
        p_title: input.title,
        p_task_type: input.taskType,
        p_deadline: input.deadlineISO,
        p_estimated_minutes: input.estimatedMinutes,
        p_subtasks: subtasks,
        p_course_id: input.courseId,
        p_assessment_type_id: input.assessmentTypeId,
        p_notes: input.notes,
      },
    );
    if (error) throw mapPostgresError(error.message);

    if (usageId) {
      // Fire and forget: token accounting must never fail a student's request.
      void (async () => {
        try {
          await caller.db.rpc("record_ai_usage_tokens", {
            p_usage_id: usageId,
            p_input_tokens: generated.inputTokens,
            p_output_tokens: generated.outputTokens,
          });
        } catch (e) {
          console.warn("token accounting failed:", e);
        }
      })();
    }

    return jsonResponse({
      assignment_id: assignmentId,
      model: generated.model,
      rubric_grounded: rubric !== null,
      cache_read_tokens: generated.cacheReadTokens,
      steps: plan.steps,
    }, 201);
  } catch (e) {
    return errorResponse(e);
  }
});
