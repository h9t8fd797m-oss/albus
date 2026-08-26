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
  normaliseWork,
  sha256,
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

  // Optional. When present it is what lets Albus find the right mark scheme
  // without asking — it carries the component and any attached rubric. When
  // absent the student is grading something loose, pasted or photographed,
  // which has no rubric to find and is marked blind unless they name one.
  const assignmentId = uuid(body.assignment_id);

  // Optional, and only an override. Absent is the normal case now.
  const rubricId = uuid(body.rubric_id);

  // Normalised before it is measured, not after: the caps should describe the
  // work as the model will see it, and OCR output can be a fifth whitespace.
  const work = typeof body.work === "string" ? normaliseWork(body.work) : "";

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
    } else if (input.assignmentId) {
      const resolved = await resolveGradingRubric(caller.db, input.assignmentId);
      rubric = resolved.rubric;
      basis = resolved.basis;
    }

    // Have we already produced exactly this answer?
    //
    // Before the quota call on purpose: no model call happens, so no grading
    // should be spent. A student who taps Grade twice, re-grades without
    // editing, or retries after a dropped connection gets the same marks back
    // for nothing — which is both the honest outcome and the largest saving
    // available on this endpoint.
    //
    // The hash covers what it was marked against as well as the work, so the
    // same essay against a different rubric is a different answer.
    const workHash = await sha256([
      input.work,
      basis,
      rubric?.assessmentName ?? "",
      (rubric?.criteria ?? []).map((c) => `${c.code}:${c.name}:${c.marks}`).join("|"),
      input.presentation ?? "",
    ].join("\u0000"));

    const { data: existing } = await caller.db
      .from("gradings")
      .select("id, created_at, overall_marks, total_marks, breakdown, feedback, improvements, model, basis")
      // RLS already scopes this; the explicit filter is here so a hash
      // collision cannot hand one student another student's marks even if RLS
      // were ever loosened.
      .eq("user_id", caller.id)
      .eq("work_hash", workHash)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (existing) {
      return jsonResponse({
        id: existing.id,
        created_at: existing.created_at,
        overall_marks: existing.overall_marks,
        total_marks: existing.total_marks,
        criteria: existing.breakdown,
        feedback: existing.feedback,
        improvements: existing.improvements,
        model: existing.model,
        basis: existing.basis,
        rubric_name: rubric?.assessmentName ?? null,
        // So the client can say "you already marked this" rather than silently
        // showing a result with a stale timestamp.
        reused: true,
      }, 200);
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

    // Everything from here can fail *after* a grading has been reserved, and a
    // student who gets no marks must not lose one of five for the week. The
    // slot is handed back on any failure below.
    //
    // Deleting the usage row rather than adding a credit: the row is the
    // accounting, and a failed call did not happen as far as the student is
    // concerned. Service role, because `authenticated` has no DELETE here.
    const refund = async () => {
      if (!usageId) return;
      const { error } = await adminClient()
        .from("ai_usage").delete().eq("id", usageId as string);
      if (error) console.error("could not refund grading slot:", error.message);
    };

    let generated;
    try {
      generated = await gradeWork(
        buildGradeSystemPrompt(basis),
        buildGradeUserPrompt({
          taskTitle: title, taskType, rubric,
          work: input.work, presentation: input.presentation,
        }),
        model,
      );
    } catch (e) {
      await refund();
      throw e;
    }

    let grade;
    try {
      grade = normaliseGrade(generated.raw, rubric);
    } catch (e) {
      await refund();
      if (e instanceof InvalidGradeError) {
        console.error("model produced an unusable grade:", e.message);
        throw new HttpError(502, "MALFORMED_RESPONSE",
          "Marking failed, and your grading has been given back.");
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
        work_hash: workHash,
        // Stored, not inferred. A blind reading and a rubric grading that
        // awarded no marks are identical on the wire — both nulls — so without
        // this a saved blind reading could later be rendered as a grade.
        basis,
      })
      .select("id, created_at")
      .single();
    if (writeError) {
      await refund();
      throw mapPostgresError(writeError.message);
    }

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
      reused: false,
    }, 201);
  } catch (e) {
    return errorResponse(e);
  }
});
