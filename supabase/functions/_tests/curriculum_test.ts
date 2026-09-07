import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { loadCurriculumComponent } from "../_shared/curriculum.ts";
import { buildSystemPrompt } from "../_shared/prompt.ts";

Deno.test("curriculum lookup embeds and orders topics into the prompt even without marks", async () => {
  let selected = "";
  const course = {
    name: "Test subject", curricula: { name: "IB" }, assessment_objectives: [],
    syllabus_topics: [{ name: "Second", ordinal: 1 }, { name: "First", ordinal: 0 }],
  };
  for (const parent of [course, [course]]) {
    const query = {
      select(value: string) { selected = value; return query; },
      eq() { return query; },
      maybeSingle() { return Promise.resolve({ data: {
        id: "component", name: "Paper", course_templates: parent, rubric_criteria: [],
      }, error: null }); },
    };
    const db = { from: () => query } as unknown as SupabaseClient;
    const result = await loadCurriculumComponent(db, "subject", "paper");
    assertStringIncludes(selected, "syllabus_topics ( name, ordinal )");
    assertEquals(result?.rubric?.syllabusTopics, ["First", "Second"]);
    assertStringIncludes(buildSystemPrompt(result!.rubric), "- First\n- Second");
  }
});
