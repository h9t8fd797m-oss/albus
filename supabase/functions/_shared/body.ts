import { HttpError } from "./http.ts";

/** Read raw request bytes through a hard streaming ceiling. */
export async function readRawBody(req: Request, maxBytes: number): Promise<Uint8Array> {
  const announced = Number(req.headers.get("content-length"));
  if (Number.isFinite(announced) && announced > maxBytes) {
    throw new HttpError(413, "PAYLOAD_TOO_LARGE");
  }
  if (!req.body) throw new HttpError(400, "INVALID_JSON");

  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel("payload too large");
        throw new HttpError(413, "PAYLOAD_TOO_LARGE");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const raw = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    raw.set(chunk, offset);
    offset += chunk.byteLength;
  }

  return raw;
}

/**
 * Read JSON through a byte ceiling instead of calling `req.json()` unbounded.
 *
 * Field-level limits stop expensive prompts, but they happen after the entire
 * body has already been allocated. This closes the cheaper denial-of-service
 * path: stream until the endpoint's real maximum, cancel, and parse once.
 */
export async function readJsonBody<T>(req: Request, maxBytes: number): Promise<T> {
  const raw = await readRawBody(req, maxBytes);

  try {
    const text = new TextDecoder("utf-8", { fatal: true }).decode(raw);
    return JSON.parse(text) as T;
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(400, "INVALID_JSON");
  }
}
