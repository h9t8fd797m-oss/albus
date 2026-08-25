// _shared/knowledge.ts — the reference corpus, retrieved a few sections at a time.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";

export interface KnowledgeSection {
  section: string;
  title: string;
  parentTitle: string | null;
  body: string;
}

/** How many question-matched sections to pull. The always-included rules are extra. */
const DEFAULT_LIMIT = 4;

/**
 * A ceiling on what retrieval can put in a prompt, independent of the row limit.
 *
 * The row limit bounds how many sections come back; this bounds how large they
 * can be. Two sections of the corpus are long reference tables, and four of
 * those would be most of a prompt. Cheaper to cut here than to discover it on a
 * bill.
 */
const MAX_CHARS = 12_000;

/**
 * Sections of the curriculum's knowledge base relevant to what the student asked.
 *
 * Retrieval is the student's own question, matched against a corpus every
 * signed-in student can read. There is nothing per-user in the table, so this
 * cannot leak between students — the only per-user input is which corpus, and
 * that comes from the caller's own profile row, never from the request body.
 *
 * Fails soft. A chat that answers without the corpus is worse than one that
 * answers with it, and far better than one that returns an error.
 */
export async function loadKnowledge(
  db: SupabaseClient,
  corpus: string | null,
  question: string,
  limit: number = DEFAULT_LIMIT,
): Promise<KnowledgeSection[]> {
  if (!corpus || !question.trim()) return [];

  const { data, error } = await db.rpc("search_knowledge", {
    p_corpus: corpus,
    p_query: question,
    p_limit: limit,
  });

  if (error || !Array.isArray(data)) {
    if (error) console.warn("knowledge lookup failed, answering without it:", error.message);
    return [];
  }

  const sections: KnowledgeSection[] = [];
  let budget = MAX_CHARS;
  for (const row of data as Array<Record<string, unknown>>) {
    const body = typeof row.body === "string" ? row.body : "";
    if (!body) continue;
    // Drop the section rather than truncate it: half a rule reads like a whole
    // rule, and this corpus is mostly rules.
    if (body.length > budget) continue;
    budget -= body.length;
    sections.push({
      section: String(row.section ?? ""),
      title: String(row.title ?? ""),
      parentTitle: typeof row.parent_title === "string" ? row.parent_title : null,
      body,
    });
  }
  return sections;
}
