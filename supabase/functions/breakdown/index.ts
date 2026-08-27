// breakdown/index.ts
//
// Turns an assignment into rubric-grounded, startable steps and persists them
// atomically. The one endpoint that carries the product's differentiator.

import { requireUser } from "../_shared/auth.ts";
import { errorResponse, HttpError, jsonResponse, mapPostgresError } from "../_shared/http.ts";
import { assertCanGeneratePlan, recordTokensInBackground } from "../_shared/quota.ts";
import { noteRefusal, recordSignals, type Signals } from "../_shared/signals.ts";
import { loadCurriculumComponent, loadPersonalRubric } from "../_shared/curriculum.ts";
import { curriculumCode } from "../_shared/codes.ts";
import { generateBreakdown } from "../_shared/anthropic.ts";
import {
  type BreakdownInput,
  buildSystemPrompt,
  buildUserPrompt,
  selectModel,
} from "../_shared/prompt.ts";
import { InvalidPlanError, validateAndNormalise } from "../_shared/breakdown_schema.ts";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

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
  course_template_code?: unknown;
  assessment_code?: unknown;
  notes?: unknown;
  rubric_id?: unknown;
  priority?: unknown;
  daily_capacity_minutes?: unknown;
}

const PRIORITIES = new Set(["low", "normal", "high"]);

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

  // Real UUID shape. The previous /^[0-9a-f-]{36}$/i accepted 36 hyphens,
  // which Postgres then rejected as a cast error — a 500 for what is plainly
  // a malformed request.
  const uuid = (v: unknown): string | null =>
    typeof v === "string" && UUID_RE.test(v) ? v : null;

  return {
    title,
    taskType,
    deadlineISO: new Date(deadlineMs).toISOString(),
    estimatedMinutes: Math.round(minutes),
    courseId: uuid(body.course_id),
    // Dropped rather than rejected when malformed: an unrecognised code costs
    // the student their grounding, which is a worse plan, not a failed one.
    courseTemplateCode: curriculumCode(body.course_template_code),
    assessmentCode: curriculumCode(body.assessment_code),
    notes: typeof body.notes === "string" ? body.notes.slice(0, 2000) : null,
    // Bounded, not trusted. It only sizes a sitting, so a hostile value costs
    // the sender their own plan's shape and nothing else — but an unbounded
    // number here would reach the prompt as text.
    dailyCapacityMinutes: (() => {
      const raw = Number(body.daily_capacity_minutes);
      return Number.isFinite(raw) ? Math.max(30, Math.min(960, Math.round(raw))) : 150;
    })(),
    rubricId: uuid(body.rubric_id),
    // Normalised, not rejected: an unknown priority is a client bug and is not
    // worth refusing to plan the student's assignment over.
    priority: (typeof body.priority === "string" && PRIORITIES.has(body.priority)
      ? body.priority
      : "normal") as "low" | "normal" | "high",
  };
}

Deno.serve(async (req) => {
  // Hoisted so the `catch` can attribute a refusal. A denial that cannot
  // be attributed is a denial the risk model cannot count.
  let callerId: string | null = null;
  let signals: Signals = { deviceHash: null, ipPrefixHash: null };
  try {
    if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");

    // Identity comes from the verified JWT. Anything in the body is a claim.
    const caller = await requireUser(req);
    callerId = caller.id;
    // Hashed here and only here. What reaches Postgres is two digests.
    signals = await recordSignals(req, caller.id);

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

    // Resolve the component the client named, so the assignment records which
    // paper it is even when the student also pasted their own rubric.
    const component = await loadCurriculumComponent(
      caller.db,
      input.courseTemplateCode,
      input.assessmentCode,
    );

    // The student's own rubric wins over the curriculum default: they pasted it
    // off the sheet they are actually being marked against.
    const rubric = (await loadPersonalRubric(caller.db, input.rubricId))
      ?? component?.rubric
      ?? null;

    const promptInput: BreakdownInput = {
      title: input.title,
      taskType: input.taskType,
      deadlineISO: input.deadlineISO,
      estimatedMinutes: input.estimatedMinutes,
      nowISO: new Date().toISOString(),
      dailyCapacityMinutes: input.dailyCapacityMinutes,
      rubric,
      notes: input.notes,
      priority: input.priority,
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
      plan = validateAndNormalise(
        generated.raw, input.estimatedMinutes, input.dailyCapacityMinutes);
    } catch (e) {
      if (e instanceof InvalidPlanError) {
        console.error("model produced an unusable plan:", e.message);
        throw new HttpError(502, "MALFORMED_RESPONSE", "Plan generation failed.");
      }
      throw e;
    }

    // Map criterion codes back to real ids. The model only ever sees codes,
    // so it cannot fabricate a foreign key into another course's rubric.
    //
    // Only curriculum rubrics map: subtasks.rubric_criterion_id references the
    // shared rubric_criteria table, and a personal rubric's criteria do not live
    // there. Personal codes still reach the client on the response and are shown
    // against the step — the link is by code, which is all any screen reads.
    const codeToId = new Map(
      rubric?.kind === "curriculum" ? rubric.criteria.map((c) => [c.code, c.id]) : [],
    );
    const subtasks = plan.steps.map((s) => ({
      title: s.title,
      guidance: s.guidance,
      estimated_minutes: s.estimated_minutes,
      rubric_criterion_id: s.rubric_criterion_code
        ? codeToId.get(s.rubric_criterion_code) ?? null
        : null,
      // Already validated against the shared vocabulary; the column's check
      // constraint is the second line of defence, not the first.
      tool_need: s.tool_need,
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
        p_assessment_type_id: component?.assessmentTypeId ?? null,
        p_notes: input.notes,
        p_rubric_id: input.rubricId,
        p_priority: input.priority,
      },
    );
    if (error) throw mapPostgresError(error.message);

    if (usageId) {
      recordTokensInBackground(
        caller.db,
        usageId as string,
        generated.inputTokens,
        generated.outputTokens,
      );
    }

    return jsonResponse({
      assignment_id: assignmentId,
      model: generated.model,
      rubric_grounded: rubric !== null,
      rubric_source: rubric?.kind ?? null,
      cache_read_tokens: generated.cacheReadTokens,
      steps: plan.steps,
    }, 201);
  } catch (e) {
    noteRefusal(e, callerId, "breakdown", signals);
    return errorResponse(e);
  }
});
