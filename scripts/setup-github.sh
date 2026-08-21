#!/usr/bin/env bash
# scripts/setup-github.sh
#
# Creates the private repo, pushes, opens the first PR, and locks main.
# Run once, after `gh auth login`.
set -euo pipefail

REPO_NAME="albus"
BRANCH="feat/initial-infrastructure"

command -v gh >/dev/null || { echo "gh not installed: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged in. Run: gh auth login"; exit 1; }

OWNER=$(gh api user -q .login)
echo "==> Creating private repo $OWNER/$REPO_NAME"
gh repo create "$REPO_NAME" --private --source=. --remote=origin

echo "==> Pushing main (empty initial commit) and the work branch"
git push -u origin main
git push -u origin "$BRANCH"

echo "==> Protecting main"
# enforce_admins:true means this applies to you too — that is the point.
# required_approving_review_count is 0 because you are a solo maintainer and
# cannot approve your own PR; the PR + status checks are the gate.
gh api -X PUT "repos/$OWNER/$REPO_NAME/branches/main/protection" \
  -H "Accept: application/vnd.github+json" --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "No secrets committed",
      "Every table has RLS",
      "Migrations are append-only"
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": true,
  "required_conversation_resolution": true
}
JSON

echo "==> Opening the first PR"
gh pr create --base main --head "$BRANCH" \
  --title "Set up project infrastructure and Supabase foundation" \
  --body "Repo scaffolding, database schema with RLS from the first migration, and Edge Function scaffolds with the auth boundary enforced.

See \`docs/security-model.md\` for the security rationale and \`docs/database.md\` for the schema.

Verified: Supabase Security Advisor returns zero findings; \`scripts/verify-rls.sql\` passes all seven isolation checks."

echo ""
echo "Done. main is protected — direct pushes and force-pushes are now rejected."
echo "Repo secrets still needed for deploy-migrations.yml:"
echo "  gh secret set SUPABASE_ACCESS_TOKEN"
echo "  gh secret set SUPABASE_PROJECT_REF   # ssvehwhblgqtvqkfbkbj"
echo "  gh secret set SUPABASE_DB_PASSWORD"
