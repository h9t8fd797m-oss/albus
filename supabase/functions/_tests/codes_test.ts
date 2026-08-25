import { assertEquals } from "jsr:@std/assert@1";
import { curriculumCode } from "../_shared/codes.ts";

Deno.test("accepts the codes the generator actually emits", () => {
  for (const code of ["AQA_ALEVEL_BIOLOGY", "PAPER_3", "IA", "NEA", "A1"]) {
    assertEquals(curriculumCode(code), code);
  }
});

Deno.test("rejects anything that is not a bare code", () => {
  const rejected = [
    "",                       // empty
    "paper_3",                // lower case: our codes are upper
    "PAPER 3",                // whitespace
    "PAPER-3",                // punctuation
    "PAPER_3;drop",           // separator
    "PAPER_3.code",           // PostgREST reads dots as embedded paths
    "*",                      // PostgREST select-all
    "A".repeat(65),           // over length
    "PAPER_3\n",              // trailing newline — `$` alone would allow this
  ];
  for (const value of rejected) {
    assertEquals(curriculumCode(value), null, `should have rejected ${JSON.stringify(value)}`);
  }
});

Deno.test("rejects non-strings rather than coercing them", () => {
  for (const value of [null, undefined, 3, {}, [], { toString: () => "PAPER_3" }]) {
    assertEquals(curriculumCode(value), null);
  }
});
