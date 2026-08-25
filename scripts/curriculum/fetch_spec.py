#!/usr/bin/env python3
"""Download an exam-board specification and dump the pages that matter.

Research aid, not part of the build. It exists so that adding a subject is
"fetch, read the real pages, hand-write the JSON" rather than "remember what a
specification probably says" — the second of which is how a study planner ends
up confidently telling a student about a paper that does not exist.

    python3 fetch_spec.py <url> [regex]

Prints every page whose text matches the regex (default: the assessment
sections). Nothing here writes to data/ — a human reads the output and records
the figures deliberately.
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

DEFAULT_PATTERN = (
    r"scheme of assessment|assessment objectives?|weighting|"
    r"written exam|non-exam assessment|what'?s assessed|paper \d"
)

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"


def fetch(url: str) -> Path:
    target = Path(tempfile.gettempdir()) / ("spec_" + re.sub(r"\W+", "_", url)[-60:] + ".pdf")
    if not target.exists() or target.stat().st_size == 0:
        subprocess.run(
            ["curl", "-sL", "--max-time", "90", "-A", UA, "-o", str(target), url],
            check=True,
        )
    if target.stat().st_size < 10_000:
        raise SystemExit(f"download looks wrong ({target.stat().st_size} bytes) — check the URL")
    return target


def main() -> int:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    url = sys.argv[1]
    pattern = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_PATTERN

    try:
        from pypdf import PdfReader
    except ImportError:
        raise SystemExit(
            "needs pypdf + cryptography. Board PDFs are AES-encrypted (readable, "
            "but pypdf needs the cipher):\n"
            "  python3 -m venv .venv && .venv/bin/pip install pypdf cryptography"
        )

    path = fetch(url)
    reader = PdfReader(str(path))
    print(f"# {url}\n# {len(reader.pages)} pages\n")

    hits = 0
    for number, page in enumerate(reader.pages, 1):
        text = page.extract_text() or ""
        if not re.search(pattern, text, re.I):
            continue
        hits += 1
        print(f"───── page {number} ─────")
        print(re.sub(r"[ \t]+", " ", text).strip(), "\n")

    if hits == 0:
        print("no matching pages — try a different regex, or the spec may be image-only")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
