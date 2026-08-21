// receipt/index.ts
//
// SCAFFOLD — the auth boundary is enforced; the body is not implemented yet.
// Sequenced separately in the build plan; see docs/backend.md.

import { requireUser } from "../_shared/auth.ts";
import { errorResponse, HttpError, jsonResponse } from "../_shared/http.ts";

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "METHOD_NOT_ALLOWED");
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
