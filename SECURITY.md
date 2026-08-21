# Security

## Reporting

This is a solo project. Mail fgutort@icloud.com. Please don't open a public
issue for anything exploitable.

## What we hold

Albus stores schoolwork belonging to teenagers. That shapes every decision:

- **Anonymous by default.** No email, no name, no PII is required to use the
  app. A user becomes identifiable only if they buy a subscription.
- **Calibration data carries no content.** `completion_logs` stores task type,
  subject code, estimates and actuals. It never stores titles, notes or any
  free text. What a student is working on never leaves their device.
- **No cross-user reads are possible.** Enforced by RLS at the database, not
  by application code. See `docs/security-model.md`.

## If a key leaks

1. Rotate it in the Supabase dashboard (publishable and secret keys rotate
   independently — that is why we use them instead of legacy `anon`/`service_role`).
2. Rotate `ANTHROPIC_API_KEY` in the Anthropic console.
3. `supabase secrets set --env-file .env` to redeploy function secrets.
4. Force-expire sessions if the JWT secret was involved.

Keys live in `.env` (gitignored) and in Supabase's secret store. CI fails any
PR that adds something matching a live key shape.
