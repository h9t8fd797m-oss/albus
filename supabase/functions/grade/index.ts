// grade/index.ts
//
// Mark finished work against the student's own rubric.
//
// The first paid endpoint, and the most expensive call the app makes. Three
// things about it are deliberate:
//
//   * **The paywall is in Postgres.** `check_and_record_ai_usage` refuses
//     kind='grade' for anyone who is not Plus, in the same transaction that
//     reserves the usage slot. A gate in this file — or on the device — would
//     be one `curl` away from free unlimited marking.
//   * **The rubric is loaded by id, never read from the body.** It comes back
//     through the caller's own client, so RLS decides what the id resolves to.
//     A forged id resolves to nothing, not to a stranger's rubric.
//   * **The work is never stored.** Marks, feedback and a character count are
//     written; the essay itself exists only for the length of the request.

import { requireUser, adminClient } from "../_shared/auth.ts";
import { errorResponse, HttpError, jsonResponse, mapPostgresError } from "../_shared/http.ts";
import { recordTokensInBackground } from "../_shared/quota.ts";
import { loadPersonalRubric, resolveGradingRubric } from "../_shared/curriculum.ts";
import { gradeWork } from "../_shared/anthropic.ts";
import {
  buildGradeSystemPrompt,
  buildGradeUserPrompt,
  type GradeBasis,
  gradeModelFor,
  InvalidGradeError,
  MAX_PRESENTATION_CHARS,
  MAX_WORK_CHARS,
  MIN_WORK_CHARS,
  normaliseGrade,
} from "../_shared/grade_prompt.ts";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

interface RequestBody {
  assignment_id?: unknown;
  rubric_id?: unknown;
  work?: unknown;
  presentation?: unknown;
}

function parseBody(body: RequestBody) {
  const uuid = (v: unknown): string | null =>
    typeof v === "string" && UUID_RE.test(v) ? v : null;

  // The assignment is what makes this work: it carries the subject, the
  // component and any rubric the student attached, so Albus can find the right
  // mark scheme instead of asking them to name it again.
  const assignmentId = uuid(body.assignment_id);
  if (!assignmentId) {
    throw new HttpError(422, "ASSIGNMENT_REQUIRED",
      "Albus needs to know which assignment this is.");
  }

  // Optional, and only an override. Absent is the normal case now.
  const rubricId = uuid(body.rubric_id);

  const work = typeof body.work === "string" ? body.work.trim() : "";

  // Rejected, not truncated. Silently marking the first 40,000 characters of a
  // longer essay would return a grade for work the student did not submit.
  if (work.length > MAX_WORK_CHARS) {
    throw new HttpError(413, "WORK_TOO_LONG",
      `That's longer than Albus can mark in one go (${MAX_WORK_CHARS.toLocaleString()} characters).`);
  }
  if (work.length < MIN_WORK_CHARS) {
    throw new HttpError(422, "WORK_TOO_SHORT",
      "There isn't enough here to mark yet.");
  }

  // Truncated rather than rejected, unlike the work. A preference that runs
  // long is someone typing a paragraph about how they like their feedback, not
  // a submission that would be silently half-marked — there is nothing lost by
  // taking the first 400 characters of it.
  const presentation = typeof body.presentation === "string"
    ? body.presentation.trim().slice(0, MAX_PRESENTATION_CHARS)
    : null;

  return { assignmentId, rubricId, work, presentation };
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");

    const caller = await requireUser(req);

    let body: RequestBody;
    try {
      body = await req.json();
    } catch {
      throw new HttpError(400, "INVALID_JSON");
    }
    const input = parseBody(body);

    // What are we marking against?
    //
    // An explicit rubric_id is an override and still wins; otherwise Albus
    // works it out from the assignment. Either way the read goes through the
    // caller's own client, so RLS is what makes a foreign id resolve to
    // nothing rather than to someone else's criteria.
    //
    // **No rubric is a supported outcome, not a failure.** It used to 404 here,
    // which is why a student without a saved rubric could never grade anything
    // at all. Now it grades blind and says so — the honesty is the feature.
    let rubric = null;
    let basis: GradeBasis = "blind";

    if (input.rubricId) {
      rubric = await loadPersonalRubric(caller.db, input.rubricId);
      if (!rubric) {
        throw new HttpError(404, "RUBRIC_NOT_FOUND",
          "That rubric isn't available. Try saving it again.");
      }
      basis = "personal";
    } else {
      const resolved = await resolveGradingRubric(caller.db, input.assignmentId);
      rubric = resolved.rubric;
      basis = resolved.basis;
    }

    // Which model marks is decided by what we found above, so the usage row
    // records the model actually billed rather than a constant.
    const model = gradeModelFor(basis);

    // Entitlement, rate limit and the usage slot, atomically. Everything below
    // this line costs money, and nothing above it does.
    const { data: usageId, error: quotaError } = await caller.db.rpc(
      "check_and_record_ai_usage",
      { p_kind: "grade", p_model: model },
    );
    if (quotaError) throw mapPostgresError(quotaError.message);

    let title = "Your work";
    let taskType = "other";
    if (input.assignmentId) {
      const { data: assignment } = await caller.db
        .from("assignments")
        .select("title, task_type")
        .eq("id", input.assignmentId)
        .maybeSingle();
      if (assignment) {
        title = (assignment.title as string) ?? title;
        taskType = (assignment.task_type as string) ?? taskType;
      }
    }

    const generated = await gradeWork(
      buildGradeSystemPrompt(basis),
      buildGradeUserPrompt({
        taskTitle: title, taskType, rubric,
        work: input.work, presentation: input.presentation,
      }),
      model,
    );

    let grade;
    try {
      grade = normaliseGrade(generated.raw, rubric);
    } catch (e) {
      if (e instanceof InvalidGradeError) {
        console.error("model produced an unusable grade:", e.message);
        throw new HttpError(502, "MALFORMED_RESPONSE", "Marking failed. Nothing was charged.");
      }
      throw e;
    }

    // Written with the service role because `authenticated` deliberately has no
    // INSERT on this table: a student who could write their own grading row
    // could award themselves full marks, and could fabricate the record the
    // paywall exists to sell. user_id comes from the verified JWT, never the
    // body, so the row cannot be attributed to anyone else.
    // Serialised explicitly rather than by spreading the internal shape.
    //
    // `normaliseGrade` returns camelCase because it is TypeScript; every other
    // response this API sends is snake_case. Leaking `outOf` into the payload
    // meant the iOS client decoded `out_of` as nil and lost every per-criterion
    // denominator — a bug that type-checked on both sides and only showed up
    // against the live endpoint.
    const criteriaPayload = grade.criteria.map((c) => ({
      code: c.code,
      name: c.name,
      marks: c.marks,
      out_of: c.outOf,
      comment: c.comment,
      quote: c.quote,
      where: c.where,
    }));

    const { data: saved, error: writeError } = await adminClient()
      .from("gradings")
      .insert({
        user_id: caller.id,
        assignment_id: input.assignmentId,
        rubric_id: basis === "personal" ? input.rubricId : null,
        model: generated.model,
        input_chars: input.work.length,
        overall_marks: grade.overallMarks,
        total_marks: grade.totalMarks,
        breakdown: criteriaPayload,
        feedback: grade.feedback,
        improvements: grade.improvements,
        // Stored, not inferred. A blind reading and a rubric grading that
        // awarded no marks are identical on the wire — both nulls — so without
        // this a saved blind reading could later be rendered as a grade.
        basis,
      })
      .select("id, created_at")
      .single();
    if (writeError) throw mapPostgresError(writeError.message);

    if (usageId) {
      recordTokensInBackground(
        caller.db,
        usageId as string,
        generated.inputTokens,
        generated.outputTokens,
      );
    }

    return jsonResponse({
      id: saved.id,
      created_at: saved.created_at,
      overall_marks: grade.overallMarks,
      total_marks: grade.totalMarks,
      criteria: criteriaPayload,
      feedback: grade.feedback,
      improvements: grade.improvements,
      model: generated.model,
      // The client must never infer this from whether marks came back. A
      // curriculum rubric with no marks and a blind reading both return nulls,
      // and only one of them is allowed to call itself a grade.
      basis,
      rubric_name: rubric?.assessmentName ?? null,
    }, 201);
  } catch (e) {
    return errorResponse(e);
  }
});
