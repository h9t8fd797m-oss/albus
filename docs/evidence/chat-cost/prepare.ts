import {
  buildChatSystemPrompt,
  buildChatUserPrompt,
} from "../../../supabase/functions/_shared/chat_prompt.ts";
const sql = await Deno.readTextFile(
  new URL("../../../scripts/knowledge/seed.sql", import.meta.url),
);
const rows = [
  ...sql.matchAll(
    /values \('IB_DP', '((?:[^']|'')*)', '((?:[^']|'')*)', (null|'(?:[^']|'')*'), '((?:[^']|'')*)', '((?:[^']|'')*)', (true|false), (\d+)\);/g,
  ),
].map((m) => ({
  section: m[1],
  title: m[2].replaceAll("''", "'"),
  parentTitle: m[3] === "null" ? null : m[3].slice(1, -1).replaceAll("''", "'"),
  body: m[4].replaceAll("''", "'"),
  always: m[6] === "true",
}));
if (rows.length !== 94) {
  throw new Error(`Expected 94 seeded sections, got ${rows.length}`);
}
const snapshots: Array<{ variant: string; promptSections: string[] }> = JSON
  .parse(
    await Deno.readTextFile(
      new URL("./retrieval-results.json", import.meta.url),
    ),
  );
const system = buildChatSystemPrompt({
  assignmentTitle: "Biology exam revision",
  taskType: "exam",
  deadlineISO: "2026-10-01T12:00:00Z",
  steps: [{
    title: "Practise command terms",
    estimatedMinutes: 30,
    completed: false,
    criterionCode: null,
  }],
  rubricSummary: null,
  focusStep: 1,
}, {
  curriculumName: "International Baccalaureate Diploma Programme",
  curriculumCode: "IB_DP",
  subjects: [{
    name: "Biology HL",
    components: ["Paper 1 36%", "Paper 2 44%", "Internal assessment 20%"],
  }],
});
const question = "What do analyse and evaluate require?";
const variants = ["before", "after", "before-repeat", "after-repeat"].map(
  (name) => {
    const ids =
      snapshots.find((r) =>
        r.variant === (name.startsWith("after") ? "after" : "before")
      )!.promptSections;
    const sections = ids.map((id) => {
      const row = rows.find((r) => r.section === id);
      if (!row) throw new Error(`Missing captured section ${id}`);
      return row;
    });
    return {
      name,
      sections: ids,
      payload: {
        model: "claude-sonnet-5",
        max_tokens: 128,
        system: [{
          type: "text",
          text: system,
          cache_control: { type: "ephemeral" },
        }],
        messages: [{
          role: "user",
          content: buildChatUserPrompt(
            sections,
            question,
          ),
        }],
      },
    };
  },
);
await Deno.writeTextFile(
  Deno.args[0] ?? "/tmp/albus-chat-measure-payloads.json",
  JSON.stringify(variants),
);
console.log(JSON.stringify({
  seededSections: rows.length,
  callsPrepared: variants.length,
  maxOutputEach: 128,
}));
