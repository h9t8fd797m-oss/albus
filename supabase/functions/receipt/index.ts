// supabase/functions/receipt/index.ts
//
// SCAFFOLD — the security shape is correct and enforced; the body is not
// implemented yet. See docs/backend.md and build-plan P3.

import { requireUser, errorResponse, jsonResponse, HttpError } from "../_shared/auth.ts";

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "POST only");

    // Identity from the signed token. Anything in the body is untrusted input.
    const caller = await requireUser(req);

    return jsonResponse({
      error: "NOT_IMPLEMENTED",
      function: "receipt",
      caller_is_anonymous: caller.isAnonymous,
    }, 501);
  } catch (e) {
    return errorResponse(e);
  }
});
