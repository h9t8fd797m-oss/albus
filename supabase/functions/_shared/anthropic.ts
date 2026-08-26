// _shared/anthropic.ts — the only place that talks to Claude.

import Anthropic from "npm:@anthropic-ai/sdk@0.120.0";
import { BREAKDOWN_JSON_SCHEMA } from "./breakdown_schema.ts";
import { GRADE_JSON_SCHEMA } from "./grade_prompt.ts";
import type { ChatTurn } from "./chat_prompt.ts";
import { HttpError } from "./http.ts";

let client: Anthropic | null = null;

function getClient(): Anthropic {
  if (client) return client;
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) throw new HttpError(500, "MISCONFIGURED", "ANTHROPIC_API_KEY is not set");
  client = new Anthropic({ apiKey, maxRetries: 2 });
  return client;
}

export interface GenerationResult {
  raw: unknown;
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
}

export async function generateBreakdown(
  model: string,
  systemPrompt: string,
  userPrompt: string,
): Promise<GenerationResult> {
  try {
    const response = await getClient().messages.create({
      model,
      max_tokens: 2000,
      // cache_control on the system block: the rubric is identical for every
      // student taking this assessment. Below ~1024 tokens Anthropic will not
      // cache at all, so generic breakdowns simply miss — that is expected.
      system: [{
        type: "text",
        text: systemPrompt,
        cache_control: { type: "ephemeral" },
      }],
      messages: [{ role: "user", content: userPrompt }],
      output_config: {
        format: { type: "json_schema", schema: BREAKDOWN_JSON_SCHEMA },
      },
    } as Anthropic.MessageCreateParamsNonStreaming);

    if (response.stop_reason === "refusal") {
      throw new HttpError(422, "REFUSED", "The assignment could not be planned.");
    }

    const block = response.content.find((b) => b.type === "text");
    if (!block || block.type !== "text") {
      throw new HttpError(502, "EMPTY_RESPONSE", "Model returned no text block");
    }

    let raw: unknown;
    try {
      raw = JSON.parse(block.text);
    } catch {
      throw new HttpError(502, "MALFORMED_RESPONSE", "Model output was not valid JSON");
    }

    const u = response.usage;
    return {
      raw,
      model,
      inputTokens: u.input_tokens ?? 0,
      outputTokens: u.output_tokens ?? 0,
      cacheReadTokens: u.cache_read_input_tokens ?? 0,
    };
  } catch (e) {
    if (e instanceof HttpError) throw e;
    if (e instanceof Anthropic.APIError) {
      const status = e.status ?? 0;

      // 429 and 5xx are genuinely transient: the client should fall back to
      // its local planner and try again later.
      if (status === 429 || status >= 500) {
        console.error("anthropic transient error", status, e.message);
        throw new HttpError(503, "UPSTREAM_UNAVAILABLE", "Plan generation is unavailable.");
      }

      // Anything else — a 400 above all — means WE sent something invalid.
      // Log it loudly; a quiet "try again later" would hide a real bug.
      console.error(
        "ANTHROPIC REQUEST REJECTED (this is a bug in our request):",
        status,
        e.message,
      );
      throw new HttpError(502, "UPSTREAM_REJECTED", "Plan generation failed.");
    }
    throw e;
  }
}

export interface ChatResult {
  text: string;
  inputTokens: number;
  outputTokens: number;
}

/**
 * A grounded reply. max_tokens is held deliberately low: Ask Albus answers a
 * question about a plan, and an essay-length response is both slower and a
 * sign the model has wandered off task.
 */
export async function chatReply(
  model: string,
  systemPrompt: string,
  history: ChatTurn[],
  message: string,
): Promise<ChatResult> {
  try {
    const response = await getClient().messages.create({
      model,
      max_tokens: 700,
      system: [{ type: "text", text: systemPrompt, cache_control: { type: "ephemeral" } }],
      messages: [...history, { role: "user", content: message }],
    });

    if (response.stop_reason === "refusal") {
      throw new HttpError(422, "REFUSED", "Albus could not answer that.");
    }

    const block = response.content.find((b) => b.type === "text");
    const text = block && block.type === "text" ? block.text.trim() : "";
    if (!text) throw new HttpError(502, "EMPTY_RESPONSE", "Model returned no text");

    return {
      text,
      inputTokens: response.usage.input_tokens ?? 0,
      outputTokens: response.usage.output_tokens ?? 0,
    };
  } catch (e) {
    if (e instanceof HttpError) throw e;
    if (e instanceof Anthropic.APIError) {
      const status = e.status ?? 0;
      if (status === 429 || status >= 500) {
        console.error("anthropic transient error", status, e.message);
        throw new HttpError(503, "UPSTREAM_UNAVAILABLE", "Albus is unavailable right now.");
      }
      console.error("ANTHROPIC REQUEST REJECTED (bug in our request):", status, e.message);
      throw new HttpError(502, "UPSTREAM_REJECTED", "Albus could not answer that.");
    }
    throw e;
  }
}

/**
 * Mark a piece of work against a rubric.
 *
 * `max_tokens` is generous where the breakdown's is not: useful feedback on an
 * essay is genuinely long, and truncating it mid-criterion would produce a
 * grade with half its reasons missing.
 *
 * A refusal is surfaced as a refusal rather than dressed up as a server error.
 * The student pasted the text; they are owed a straight answer about why it was
 * not marked.
 */
export async function gradeWork(
  systemPrompt: string,
  userPrompt: string,
  /** Chosen by the caller from the grading basis — see `gradeModelFor`. */
  model: string,
): Promise<GenerationResult> {
  try {
    const response = await getClient().messages.create({
      model,
      max_tokens: 4000,
      system: [{ type: "text", text: systemPrompt, cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: userPrompt }],
      output_config: {
        format: { type: "json_schema", schema: GRADE_JSON_SCHEMA },
      },
    } as Anthropic.MessageCreateParamsNonStreaming);

    if (response.stop_reason === "refusal") {
      throw new HttpError(422, "REFUSED", "Albus could not mark this work.");
    }

    const block = response.content.find((b) => b.type === "text");
    if (!block || block.type !== "text") {
      throw new HttpError(502, "EMPTY_RESPONSE", "Model returned no text block");
    }

    let raw: unknown;
    try {
      raw = JSON.parse(block.text);
    } catch {
      throw new HttpError(502, "MALFORMED_RESPONSE", "Model output was not valid JSON");
    }

    const u = response.usage;
    return {
      raw,
      model,
      inputTokens: u.input_tokens ?? 0,
      outputTokens: u.output_tokens ?? 0,
      cacheReadTokens: u.cache_read_input_tokens ?? 0,
    };
  } catch (e) {
    if (e instanceof HttpError) throw e;
    if (e instanceof Anthropic.APIError) {
      const status = e.status ?? 0;
      if (status === 429 || status >= 500) {
        console.error("anthropic transient error", status, e.message);
        throw new HttpError(503, "UPSTREAM_UNAVAILABLE", "Marking is unavailable right now.");
      }
      console.error("ANTHROPIC REQUEST REJECTED (bug in our request):", status, e.message);
      throw new HttpError(502, "UPSTREAM_REJECTED", "Albus could not mark this work.");
    }
    throw e;
  }
}
