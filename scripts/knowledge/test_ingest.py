import unittest

from ingest import Section, emit, split_oversized


class ContinuationRetrievalTests(unittest.TestCase):
    def test_split_sections_keep_the_original_retrieval_hints(self):
        section = Section(number="4.2", title="Glossary", parent_title="Command terms", ordinal=0)
        section.body = ["Analyse: inspect the parts.", "", "Evaluate: weigh the evidence."]
        parts = split_oversized([section], 30)
        self.assertEqual([part.number for part in parts], ["4.2", "4.2p2"])
        self.assertEqual("\n\n".join(part.text for part in parts), section.text)
        for part in parts:
            self.assertIn("'command term evaluate discuss analyse", emit([part], "IB_DP", "source.md"))

    def test_sections_without_hints_do_not_borrow_another_sections_hints(self):
        section = Section(number="99.1p2", title="Other", parent_title=None, ordinal=0)
        section.body = ["Unrelated reference."]
        self.assertIn("'Unrelated reference.', '', false", emit([section], "IB_DP", "source.md"))


if __name__ == "__main__":
    unittest.main()
