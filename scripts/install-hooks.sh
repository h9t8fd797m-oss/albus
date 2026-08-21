#!/usr/bin/env bash
# Points git at the committed hooks in .githooks/.
#
# Needed because `core.hooksPath` is local repository config — it is not
# committed and does not survive `git clone`. Without this, a fresh clone has
# no protection against pushing straight to main.
#
# Safe to run repeatedly.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -d .githooks ]; then
  echo "error: .githooks/ not found — run this from inside the repo." >&2
  exit 1
fi

chmod +x .githooks/* 2>/dev/null || true
git config core.hooksPath .githooks

configured=$(git config core.hooksPath || echo "")
if [ "$configured" != ".githooks" ]; then
  echo "error: failed to set core.hooksPath (got '${configured:-unset}')" >&2
  exit 1
fi

echo "hooks installed — pushes to main will be refused."
echo "deliberate override: ALBUS_ALLOW_MAIN_PUSH=1 git push origin main"
