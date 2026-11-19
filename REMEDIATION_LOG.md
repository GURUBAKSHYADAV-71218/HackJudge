# HackJudge Remediation Log

This file tracks implementation work completed in the repository so future passes can build on it instead of repeating it. It is an engineering change log, not a claim that production is secure or that the database migration has been deployed.

## 2026-10-10 — Security and reliability tranche

### Database access and judge authorization

- Removed anonymous read policies on events, rounds, criteria, teams, tracks, and panels. Judge reads are scoped to their event and assigned work; team reads are additionally scoped to the active round, assigned track, and finalized prior-round shortlist.
- Revoked access to the legacy `public_leaderboard` view. The canonical fresh schema no longer creates that view.
- Added verified-email enforcement to judge invitation claiming and removed direct broad judge-row updates in favor of the restricted claim function.
- Added atomic, one-use invite-token consumption. The token is rotated on exchange, has an expiry, and is accepted only for a live event.
- Restricted score inserts through database authorization checks for judge identity, event/team/round/criterion relationships, active event and round state, score bounds, criterion and judge round assignments, track assignments, and shortlist eligibility.
- Added database-generated score revision ordering and timestamp stamping so the client timestamp no longer selects the winning revision.
- Added same-event integrity constraints/triggers for relevant panel, track, criterion, round, and override relationships, plus validation for new writes and per-event collection limits.
- Added audited score adjustments with a bounded amount, event/round/team checks, and organizer identity recorded on insert.
- Added database RPCs for event setup, round transitions, shortlist finalization, round reordering, and event deletion. These operations validate ownership/state and run transactionally.
- The legacy event-deletion RPC was later revoked and removed from the app as documented in the data-retention safeguard entry below.
- Enforced sequential round starts and required the prior round shortlist to be finalized before advancing. Empty finalized shortlists are treated as selecting no teams.

### Edge Function, authentication, and configuration

- Hardened `resolve-judge-token`: exact configured origins, method checks, input validation, required secret checks, one-time token consumption, shorter-lived judge JWTs, generic failure responses, and no-store response headers.
- Enabled email confirmation in local Supabase configuration and updated setup guidance to keep confirmation enabled.
- Updated auth role resolution to fail closed on role lookup errors and clear user-scoped query cache and active-event state when identity changes.
- Updated README setup instructions for the migration and required Edge Function configuration.

### Frontend behavior and input reliability

- Event setup now creates the event, rounds, and criteria through one RPC rather than separate partial writes. Verification-required signup now prompts the user to confirm email and retry.
- Event deletion uses the atomic database RPC. Round start, close, shortlist, and reorder actions use guarded RPCs.
- Event and judge data queries now surface related-query errors instead of silently returning empty data. Active event selection recovers from stale stored IDs.
- Judge scoring waits for a successful save before moving to the next team, and score revision selection uses the server revision.
- Round display and progression use persisted `order_index`; organizers can reorder rounds. Criteria and rounds can also be reordered during setup.
- CSV import now handles escaped quotes and multiline quoted fields, rejects malformed quoting, caps file size and field lengths, checks duplicates within the upload and against existing teams, and respects remaining team capacity. Removed the leader-email mapping that was not persisted.
- Score adjustments now store a real amount and round association, check insert errors, and are included in organizer results and reports.
- Updated React Query v5 pending/invalidation usage and cleaned up lint/purity issues, including toast handling.

### Files changed in this tranche

- `hackjudge-schema.sql`
- `supabase/migrations/202610100001_security_hardening.sql` (new)
- `supabase/functions/resolve-judge-token/index.ts`
- `supabase/config.toml`
- `README.md`
- `src/App.jsx`
- `src/security.js`
- `src/lib/toast.js` (new)
- `src/hooks/useAuth.jsx`
- `src/hooks/useEventData.jsx`
- `src/hooks/useJudgeData.jsx`
- `src/hooks/useTheme.jsx`
- `src/utils/scoring.js`
- `src/components/CsvImporter.jsx`
- `src/components/Sidebar.jsx`
- `src/components/ui.jsx`
- `src/pages/EventWizard.jsx`
- `src/pages/JudgeDashboard.jsx`
- `src/pages/Landing.jsx`
- `src/pages/MagicLinkAuth.jsx`
- `src/pages/organizer/OtherTabs.jsx`
- `src/pages/organizer/SetupTab.jsx`
- `src/pages/organizer/index.jsx`
- `PLATFORM_REVIEW.md` (status notes added)

`package-lock.json` was already modified in the workspace and was not intentionally changed as part of this tranche.

## Verification performed

- `npm.cmd run lint` — passed.
- `npm.cmd run build` — passed. Vite reports a 563 kB minified JavaScript chunk, above its 500 kB advisory threshold.
- `git diff --check` — passed.
- Supabase local database lint was attempted but could not connect because the local Postgres service was not running. SQL syntax and behavior therefore remain unverified against a live PostgreSQL instance.
- No automated test suite was run.

## 2026-10-10 — Canonical scoring and result handling

### Scoring policy implemented

- Each criterion contributes `(score / max_score) * weight`; each judge total is the sum across the round's applicable active criteria.
- A judge counts toward a team's round average only after submitting every applicable active criterion. Missing criteria are incomplete, not zero. An explicitly submitted score of zero is valid.
- A team with no complete judge result is unscored (`NULL` in the result view), not a zero-score team. Organizer rankings and score cutoffs put unscored teams last or exclude them; manual shortlisting can still select any team.
- The round score is the two-decimal average of complete judge totals, plus any audited adjustment. Overall score is the equal average across rounds with a result; zero-score rounds count.
- Ranking ties share the same rank. Top N includes every team tied at the Nth score, so the shortlist can contain more than N teams. Equal-score ordering is deterministic by team name and ID.

### Changes

- Added `team_round_results`, an RLS-aware database view, to both the canonical schema and the new `supabase/migrations/202610100002_canonical_scoring.sql` migration. It normalizes criterion scores, excludes incomplete judge totals, preserves zero scores, applies adjustments, and exposes result/completion metadata.
- Organizer event loading now fetches the canonical view; organizer scoreboard, overall results, printable report, and shortlist consume its scores rather than independently recomputing team averages.
- Centralized client-side weighted judge-total calculation for the judge's live score preview and organizer judge breakdown.
- Changed judge progress and organizer coverage to count complete submissions for applicable criteria and assigned active judges.
- Updated rankings to show unscored teams distinctly, use competition ranking for ties, exclude unscored teams from Top N/cutoff selection, and include ties at the Top N boundary.

### Files changed

- `hackjudge-schema.sql`
- `supabase/migrations/202610100002_canonical_scoring.sql` (new)
- `src/hooks/useEventData.jsx`
- `src/utils/scoring.js`
- `src/pages/JudgeDashboard.jsx`
- `src/pages/organizer/OtherTabs.jsx`
- `src/components/ReportTemplate.jsx`
- `src/components/ui.jsx`
- `PLATFORM_REVIEW.md`

### Verification and remaining decision

- `npm.cmd run lint` — passed.
- `npm.cmd run build` — passed; Vite reports a 564 kB minified JavaScript chunk above its 500 kB advisory threshold.
- `git diff --check` — passed.
- The migration has not been run against PostgreSQL; the local Supabase database is unavailable. Apply `202610100002_canonical_scoring.sql` after the earlier security migration, then validate the view with organizer and judge roles and a mix of complete, incomplete, zero, and adjusted scores.
- The equal average across rounds is the implemented overall ranking rule. Confirm its suitability for multi-stage event formats before using overall rankings as a final award result.

## 2026-10-10 — Judge invite resolver rate limiting

### Changes

- Added `invite_rate_limits` and service-role-only `allow_invite_resolution()` in the canonical schema and `supabase/migrations/202610100003_invite_rate_limit.sql`.
- The RPC atomically permits at most 60 attempts per client IP per fixed one-minute bucket across Edge Function instances. Old counters are pruned opportunistically after 24 hours.
- The Edge Function reads the forwarded client IP, HMAC-SHA256 hashes it with the server-only `INVITE_RATE_LIMIT_HMAC_SECRET`, sends only the digest to Postgres, returns HTTP 429 with `Retry-After` after the limit, and fails closed if the counter cannot be checked.
- Added a 1 KiB streaming request-body cap and documented the required secret and proxy-header requirement in README.

### Files changed

- `hackjudge-schema.sql`
- `supabase/migrations/202610100003_invite_rate_limit.sql` (new)
- `supabase/functions/resolve-judge-token/index.ts`
- `README.md`
- `PLATFORM_REVIEW.md`

### Deployment and limits

- Apply the ordered migration and configure a unique high-entropy `INVITE_RATE_LIMIT_HMAC_SECRET` in Supabase Edge Function secrets before deploying this function version.
- The rate limit depends on a trusted gateway-provided `X-Forwarded-For` header. Do not deploy behind a proxy that passes through a client-supplied value unchanged.
- This only limits invite resolution. Judge score submission rate limiting and broader abuse monitoring remain open.
- Rate-limit behavior has not been validated against a live Supabase/Postgres deployment; update verification results after deployment checks.
- `npm.cmd run lint`, `npm.cmd run build`, and `git diff --check` pass. The build still reports a 564 kB JavaScript chunk above Vite's 500 kB advisory threshold.
- Deno and PostgreSQL clients are unavailable in this environment, so the Edge Function was not type-checked with Deno and the migration was not executed here.

## Deployment and validation still required

- Apply the ordered migrations in `supabase/migrations/` to each existing Supabase project; changing the canonical schema alone does not change deployed projects.
- Validate the migration against a running PostgreSQL/Supabase instance and review any existing-data constraint failures it reports.
- Configure `APP_ALLOWED_ORIGINS` and the Edge Function secrets in the deployed Supabase project; verify the deployed function and actual allowed origins.
- Verify RLS with anonymous, organizer, assigned judge, unassigned judge, unverified judge, expired/replayed invite, closed round, and cross-event cases.
- Verify email-confirmation behavior and the judge invite lifecycle against the deployed Auth configuration.

## 2026-10-10 — Revoked judge read scope and deployment audit

### Changes

- Added `is_active_current_judge()` and updated judge read policies so revoking a judge immediately blocks access to event metadata, assignments, and prior scores even while their signed JWT remains unexpired.
- Restricted `team_round_results` to organizer-owned events at the view layer, in both the canonical schema and upgrade migration.
- Added Vercel baseline security response headers: MIME sniffing protection, frame denial, referrer policy, permissions policy, and HSTS.
- Added the missing `.env.example` with only public Vite variables, corrected stale React/feature claims in README, and wrote `DEPLOYMENT_RUNBOOK.md` with repository-root PowerShell, Supabase Dashboard, CLI, Edge Function, and hosting steps.

### Files changed

- `hackjudge-schema.sql`
- `supabase/migrations/202610100004_active_judge_read_scope.sql` (new)
- `vercel.json`
- `.env.example` (new)
- `README.md`
- `DEPLOYMENT_RUNBOOK.md` (new)
- `PLATFORM_REVIEW.md`

### Verification and remaining limitations

- `npm.cmd run lint` — passed.
- `npm.cmd run build` — passed; Vite still reports a 564 kB minified JS chunk over its 500 kB advisory threshold.
- `git diff --check` — passed.
- Supabase migration status and SQL behavior were not verified because PostgreSQL/Supabase CLI are unavailable in this environment. Deno is also unavailable, and ESLint's configured file patterns do not cover the Edge Function TypeScript file.
- The Vercel headers are source configuration only; verify the deployed response headers after deployment. HSTS with `includeSubDomains` assumes all subdomains under the production hostname are HTTPS.

## 2026-10-10 — Judge session compatibility and renewal

### Finding

- The invite resolver minted a custom PostgREST JWT without a Supabase Auth user, while `MagicLinkAuth` passed it to `supabase.auth.setSession()`. The installed Supabase Auth client validates `setSession()` access tokens through the Auth `/user` endpoint, so this custom JWT is not a valid GoTrue session and could fail before the judge dashboard loads.

### Changes

- Added a dedicated `judgeSupabase` client using Supabase JS's `accessToken` option. It sends custom judge JWTs to the Data API without attempting GoTrue user lookup.
- Judge invitation authentication now stores the custom token separately and exposes a minimal judge identity to the existing app router; sign-out clears this token.
- The resolver now issues seven-day judge JWTs and supports renewal while the existing JWT remains valid. Renewal checks the current judge row is active before minting another token; revoked judges cannot renew.
- The dedicated client renews when a session has less than 24 hours remaining. The existing 30-day rotated invite link remains the recovery route after a judge has been away longer than the JWT lifetime.

### Files changed

- `src/lib/judgeSession.js` (new)
- `src/lib/supabase.js`
- `src/hooks/useAuth.jsx`
- `src/hooks/useJudgeData.jsx`
- `src/App.jsx`
- `src/pages/MagicLinkAuth.jsx`
- `src/pages/JudgeDashboard.jsx`
- `supabase/functions/resolve-judge-token/index.ts`
- `REMEDIATION_LOG.md`
- `PLATFORM_REVIEW.md`

### Verification and limitations

- `npm.cmd run lint` — passed.
- `npm.cmd run build` — passed; Vite reports a 565 kB minified JS chunk above its 500 kB advisory threshold.
- `git diff --check` — passed.
- The Edge Function was not run/type-checked with Deno, and the session exchange/renewal path has not been exercised against a deployed Supabase project. Confirm in staging that a judge can open an invitation, reload, renew, sign out, and loses access immediately after organizer revocation.
- A session that remains unused for the full seven-day JWT lifetime must be reopened from the organizer's current invitation link. This is still an organizer-assisted renewal path.

## 2026-10-10 — Existing Supabase data preservation review

### Findings

- Reviewed the first four migration files for destructive schema operations. None drops tables or columns, truncates business tables, or deletes existing events, teams, judges, scores, or overrides as part of migration execution.
- Migration 001 created `delete_event()` but did not invoke it. At the time of the review, calling that RPC or using the app's event-delete action permanently deleted related business rows; deleting teams, criteria, or judges could also cascade to scores. The new retention safeguard below disables those application-role paths.
- Existing override rows are preserved when columns are added; legacy rows receive `amount = 0` and `round_id = NULL`, because the previous schema did not persist these values.
- Migration 003 periodically deletes only old rows from its newly introduced transient rate-limit table.
- The runbook now requires a fresh backup, an isolated staging restore, and rehearsal before production migration. It warns against `db reset --linked` and clarifies that the full SQL schema is for a new project only.

### Scope limits

- The actual Supabase schema, migration history, backup state, and row contents have not been inspected. No Supabase command or SQL migration was run against the account.
- A read-only `supabase.cmd migration list --linked` check returned `LegacyProjectNotLinkedError`; this repository is not linked to a Supabase project, so no remote migration history was read. No project was linked as part of this review.
- This static audit cannot guarantee zero data-loss risk. Confirm that staging matches the migration baseline, restore a production backup to staging, and rehearse the exact migration set before production rollout.

## 2026-10-10 — Prevent accidental permanent deletion

### Finding and changes

- Confirmed that organizer DELETE policies allowed direct API deletion, bypassing UI confirmation, and that foreign-key cascades could erase score history with teams, judges, criteria, and events.
- Removed the app's permanent-delete controls and the `useDeleteEvent` mutation. Setup now explains that saved event records are retained.
- Added migration `202610100005_prevent_accidental_data_deletion.sql`: removes broad/delete policies for criteria, teams, tracks, panels, and judges; removes the event delete policy; revokes application-role DELETE privileges on events, rounds, and those score-linked entities; and revokes access to the legacy `delete_event(uuid)` RPC.
- Updated the canonical schema to match. It retains panel assignment removal, which only removes a judge-to-panel mapping and does not delete score history.
- Hardened Setup navigation against invalid/stale session-storage values and unavailable storage, and surfaced clipboard permission failures when copying judge links.
- No existing Supabase rows are modified by this migration. Database-side cascades remain part of the schema for administrative/owner-level operations, so production-role grants and account lifecycle still require staging review.

### Files changed

- `supabase/migrations/202610100005_prevent_accidental_data_deletion.sql` (new)
- `hackjudge-schema.sql`
- `src/hooks/useEventData.jsx`
- `src/pages/organizer/SetupTab.jsx`
- `PLATFORM_REVIEW.md`
- `DEPLOYMENT_RUNBOOK.md`
- `REMEDIATION_LOG.md`

### Verification and limits

- `npm.cmd run lint` — passed.
- `npm.cmd run build` — passed; Vite reports a 561 kB minified JS chunk above its 500 kB advisory threshold.
- `git diff --check` — passed.
- Migration SQL has not been executed against PostgreSQL or Supabase. The repository remains unlinked, and existing project policies/grants are unknown until a staging project is linked and inspected.
- Existing data is not deleted by the source changes or migration. No production database action was performed.

## 2026-10-10 — Linked project migration and data preflight

### Findings

- Retrieved the linked project's `public` schema dump and remote migration list using the Supabase CLI. The remote migration history is empty; all five repository migrations (001–005) are pending. The schema matches the older application baseline the migrations target: it contains `current_scores` and `public_leaderboard`, and does not yet contain `team_round_results` or `invite_rate_limits`.
- Ran `supabase db push --dry-run --linked`; it proposed migrations 001–005 and applied nothing.
- Added and ran `supabase/preflight_existing_data.sql`, a SELECT-only diagnostic. It found no duplicate round order, multiple live rounds, cross-event team/track/panel/judge/score/tiebreak references, or out-of-range scores.
- One existing event has a whitespace-only name. Migration 001 adds the event-name check as `NOT VALID`, so the migration can retain that row, but PostgreSQL will enforce the check on future updates to it. That event needs a valid name before normal edits to it can safely continue after migration.
- Follow-up on 2026-10-11, after the user re-ran the query in the Dashboard, found two draft events with whitespace-only names (IDs `20fff5fe-7e38-441a-ae6d-b6828ae02272` and `3d2ab970-621b-4db1-9aab-9675ce13323f`). A repeated read-only CLI query returned the same two rows, superseding the earlier count of one. Neither row was modified.
- Moved the local schema export to `supabase/current_public_schema.sql` and ignored it plus Supabase CLI `.temp` metadata so project-specific state is not accidentally committed.

### Safety boundary

- All commands against Supabase were read-only: migration listing, schema dump, `db query` containing only SELECT statements, and migration dry run. No migration, business-row update, or deployment was executed.
- A dry run confirms the migration plan, not that migrations will execute successfully. Rehearse against a staging restore, and choose/fix the whitespace-only event name before applying the migrations to production.

## Not yet resolved

- **SQL/deployment validation:** schema and migration changes need execution against a staging Supabase project, followed by role-specific access checks before production deployment.
- **Judge magic-link access:** intentionally paused for the fresh-core path. Judges use verified Supabase Auth accounts and claim assignments by email. Re-enabling magic links requires a supported signing-key design, Edge Function review, and tests.
- **Criterion weight editing:** active criterion weights must total 100. Newly added criteria start at 0% to avoid silently changing results; the organizer UI still needs a transactional weight-rebalancing editor.
- **SaaS product and operations:** organization tenancy and roles, billing/entitlements, audit coverage for all configuration changes, delivery workflows, retention/privacy requests, backup/recovery, monitoring/alerting, rate limiting, and incident operations remain open as described in `PLATFORM_REVIEW.md`.
- **Bundle size:** the production bundle exceeds Vite's advisory chunk threshold; code splitting/performance work remains.

## 2026-10-11 — Fresh core database path (judge magic links deferred)

### Findings and changes

- Prepared `HACKJUDGE_CORE_SCHEMA.sql` as a separate installer for a new, empty Supabase project. It does not alter or migrate the current Supabase project.
- Removed custom judge JWT, invite-token consumption, and invite-rate-limit dependencies from this fresh-core installer. Judges use verified Supabase Auth accounts and claim assignments using the email stored by the organizer.
- Added an email-only judge assignment requirement and case-insensitive unique email-per-event protection. Unclaimed judges can read only the event header needed to claim; judging data is returned after account claim.
- Added database checks that keep criterion/judge round assignments within the same event and require active criterion weights to total 100 at commit. Newly added criteria use 0% weight until weights are rebalanced.
- Fixed round reorder swaps by making `(event_id, order_index)` deferrable and deferring it during the reorder RPC.
- Added explicit least-privilege table, view, enum, and function grants because fresh Supabase projects may not automatically grant Data API access to newly created objects.
- Disabled the broken magic-link UI action and replaced the old token route with instructions for regular judge account sign-in/claim. Updated `README.md`, `DEPLOYMENT_RUNBOOK.md`, and `FRESH_PROJECT_SETUP.md` to describe this flow.

### Files changed

- `HACKJUDGE_CORE_SCHEMA.sql` (new fresh-project installer)
- `src/App.jsx`
- `src/hooks/useAuth.jsx`
- `src/hooks/useJudgeData.jsx`
- `src/lib/supabase.js`
- `src/pages/MagicLinkAuth.jsx`
- `src/pages/JudgeDashboard.jsx`
- `src/pages/organizer/SetupTab.jsx`
- `README.md`
- `DEPLOYMENT_RUNBOOK.md`
- `FRESH_PROJECT_SETUP.md`
- `REMEDIATION_LOG.md`

### Verification and limits

- `npm.cmd run lint` — passed.
- `npm.cmd run build` — passed; Vite reports a minified JavaScript chunk above its 500 kB advisory threshold.
- The SQL has **not** been executed against PostgreSQL. Docker previously failed during Supabase image extraction with storage I/O errors. Do not treat the installer as production-certified until it passes a fresh-project SQL run and role-based workflow checks.
- No command in this work changed the linked/current Supabase database or its data.

## 2026-10-11 — Google sign-in and email-matched judge access

### Changes

- Replaced organizer and judge email/password forms with Google OAuth sign-in.
- Removed email/password account creation from the event wizard. It preserves the event setup draft in the browser tab across Google’s redirect, then creates the event under the authenticated organizer.
- Kept organizer entry of judge name/email in the dashboard. Judge sign-in now matches the Google account email against the event assignment and calls the restricted `claim_judge_row` RPC automatically.
- Added an explicit no-assignment result for users who choose Judge Login but whose Google email is not assigned.
- Updated setup and deployment documentation with the Google Cloud and Supabase provider/redirect configuration requirements.

### Files changed

- `src/pages/Landing.jsx`
- `src/pages/EventWizard.jsx`
- `src/App.jsx`
- `src/hooks/useJudgeData.jsx`
- `src/pages/organizer/SetupTab.jsx`
- `README.md`
- `DEPLOYMENT_RUNBOOK.md`
- `FRESH_PROJECT_SETUP.md`
- `REMEDIATION_LOG.md`

### Verification and limits

- `npm.cmd run lint` — passed.
- `npm.cmd run build` — passed; Vite still reports the existing >500 kB bundle advisory.
- Google OAuth credentials and redirect allow lists must be configured in Google Cloud and Supabase before sign-in can work. This workspace cannot configure those external project settings.
- The fresh project SQL is unchanged; judge auto-claim uses the existing verified-email `claim_judge_row` RPC. A live OAuth and RLS flow still needs testing in the configured Supabase project.

## 2026-10-11 — Resume event setup after Google OAuth

### Changes

- Event setup is restored from the current browser tab's saved draft after Google OAuth, even when the auth callback replaces or consumes the URL fragment.
- Canceling the event wizard clears its saved draft so a later login does not reopen stale setup.
- The OAuth callback now uses the clean page URL; the saved draft determines the wizard resume step.

### Files changed

- `src/App.jsx`
- `src/pages/Landing.jsx`
- `src/pages/EventWizard.jsx`
- `REMEDIATION_LOG.md`

### Verification and limits

- `npm.cmd run lint` — passed.
- `npm.cmd run build` — passed; Vite reports the existing >500 kB bundle advisory.
- Browser-level Google OAuth was not exercised here. Retest in the configured browser/Supabase project; the pasted `webextension.js` exception is extension-injected and does not show a HackJudge/Supabase auth error.

## 2026-10-11 — Fix panel query RLS recursion and onboarding fallback

### Changes

- Replaced the mutually recursive `panels` / `panel_judges` policy lookups with narrowly scoped `SECURITY DEFINER` helper functions.
- Added an idempotent migration for projects that already installed the core schema. Apply `supabase/migrations/202610110001_fix_panel_rls_recursion.sql` to the linked Supabase project; do not rerun the installer on a database containing data.
- Changed the organizer dashboard to show the actual event-data query error and a retry action instead of interpreting a failed query as a missing event and reopening onboarding.

### Files changed

- `HACKJUDGE_CORE_SCHEMA.sql`
- `supabase/migrations/202610110001_fix_panel_rls_recursion.sql`
- `src/pages/organizer/index.jsx`
- `REMEDIATION_LOG.md`

### Verification and limits

- `npm.cmd run lint` — passed.
- `npm.cmd run build` — passed; existing >500 kB bundle advisory remains.
- The migration has not been applied to the hosted Supabase project and needs to be run there before reloading the app.
- The provided browser log has no PostgREST response body, so the policy recursion is the code-level cause identified from the installed policy definitions; if the migration does not clear the 500, capture the failing request's Response body / Supabase Postgres log entry.

## 2026-10-11 — Prevent repeated track and judge inserts

### Changes

- Setup insert mutations now add their returned database row to the event cache immediately. Refreshing the rest of the event data happens separately, so a failed refresh cannot make a committed insert appear unsaved.
- Added same-tab submission guards and case-insensitive duplicate checks for track names and judge emails.
- Added a non-destructive database migration that blocks future duplicate track names and judge emails, including concurrent/retried requests. Existing rows are not deleted or rewritten.

### Files changed

- `src/hooks/useEventData.jsx`
- `src/pages/organizer/SetupTab.jsx`
- `HACKJUDGE_CORE_SCHEMA.sql`
- `supabase/migrations/202610110002_prevent_duplicate_setup_rows.sql`
- `REMEDIATION_LOG.md`

### Verification and limits

- `npm.cmd run lint` — passed.
- `npm.cmd run build` — passed; Vite reports the existing >500 kB bundle advisory.
- The new database migration has not been applied to the hosted project. Apply it from the Supabase SQL Editor before relying on database-side duplicate protection.
- Existing duplicate records are intentionally preserved. Check their references before any cleanup, because tracks may be referenced by teams/panels and judges may be referenced by assignments/scores.

## 2026-10-11 — Fix judge dashboard crash when a round starts

### Changes

- The live-round screen now reads criteria from `data.criteria`, matching the judge data hook response. It previously tried `event.criteria`, which is not part of the event row and caused `.filter()` to throw as soon as a round became live.
- Added safe defaults for scores and team arrays at the dashboard boundary.

### Files changed

- `src/pages/JudgeDashboard.jsx`
- `REMEDIATION_LOG.md`

### Verification and limits

- `npm.cmd run lint` — passed.
- `npm.cmd run build` — passed; Vite reports the existing >500 kB bundle advisory.
- A live organizer/judge two-window round start was not exercised against the hosted Supabase project.

## 2026-10-11 — Keep score adjustment controls open

### Changes

- Stopped clicks inside the audited score adjustment panel from bubbling to the clickable scoreboard row, which had collapsed the expanded row as soon as the organizer interacted with the inputs or button.
- The adjustment form now clears only after a successful insert; a failed insert keeps the entered amount and justification for retry.
- A successful adjustment updates the cached override history and score immediately, while the background refresh runs independently.

### Files changed

- `src/pages/organizer/OtherTabs.jsx`
- `REMEDIATION_LOG.md`

### Verification and limits

- `npm.cmd run lint` — passed.
- `npm.cmd run build` — passed; Vite reports the existing >500 kB bundle advisory.
- A live Supabase score adjustment was not submitted from this workspace.

## 2026-10-11 — Local migration and workflow validation

### Changes found during validation

- Fixed migration ordering in `202610100001_security_hardening.sql`: it attempted to add a composite override foreign key before adding the legacy table's `round_id` column. The column is now added first.
- Mirrored the corrected migration and the two recent migrations into the ignored `scratch/local-supabase` test project.
- Created a separate ignored `scratch/core-e2e` Supabase project to validate the exact fresh-project installer independently from the legacy upgrade path.

### Checks run

- `npm.cmd run lint` — passed.
- `npm.cmd run build` — passed; Vite reports the >500 kB minified-chunk advisory.
- `npm.cmd audit --omit=dev` — passed, 0 production dependency vulnerabilities.
- The legacy baseline plus all seven migrations applied without SQL errors in local Supabase.
- `HACKJUDGE_CORE_SCHEMA.sql` applied without SQL errors to a separate fresh local Supabase database.
- Rollback-only database workflow checks passed on both databases: event setup visibility, starting a round, non-recursive panel assignment queries, event isolation, assigned judge team visibility, score submission, audited adjustment totals, and same-name tracks / same-email judges blocked within one event while the same track name is allowed in another event.
- All test rows were rolled back. No hosted Supabase project was linked, changed, or queried.

### Limits

- Supabase CLI reports the local Kong gateway unhealthy/restarting, so browser/API end-to-end sign-in and UI flows could not be completed. PostgreSQL was available and the SQL/RLS workflow checks ran successfully.
- Google OAuth provider behavior could not be tested against a real Google account in this isolated local environment.
- No load or concurrency benchmark was run. Production-scale capacity is not established by lint/build or functional smoke checks.

## How to keep this log useful

For each follow-up remediation, add a dated section with the affected review finding IDs, concrete behavior changed, files touched, checks actually run, deployment steps, and remaining limitations. Update the “Not yet resolved” list only after the corresponding behavior is implemented and verified; do not treat source changes alone as proof of production deployment.

## 2026-10-11 — Freeze scoring rules and validate judging coverage

### Changes

- Added a database guard that freezes criteria and scoring configuration after the first round starts, including direct authenticated API writes. Criterion edits remain possible during setup.
- Round start now verifies that the round has at least one applicable active criterion and that every team participating in that round has an eligible judge for its assigned track and round. For later rounds, coverage is checked only for teams shortlisted from the previous round.
- The organizer dashboard now previews missing judge coverage before enabling round start; the database remains authoritative.
- Locked the team roster, panel mappings, judge emails, and judge round assignments after the first round starts so coverage and historical completion do not drift. Invitation claiming remains allowed; a judge can still move from invited to active after sign-in.
- Round history progress now counts an assigned judge as complete only after scoring every team assigned to that judge in the round. Invited judges are included in the expected judging roster.
- Kept the ability to revise a previous shortlist after later rounds start, per product requirement.
- Renamed the cross-round score to “Average Across Scored Rounds” and show each team’s recorded-round count in the organizer view and printable report. The average remains the equal average of rounds with a recorded result; teams can have different round counts.

### Files changed

- `HACKJUDGE_CORE_SCHEMA.sql`
- `supabase/migrations/202610110003_lock_scoring_and_validate_round_coverage.sql` (new)
- `src/utils/scoring.js`
- `src/pages/organizer/OtherTabs.jsx`
- `src/components/ReportTemplate.jsx`
- `REMEDIATION_LOG.md`

### Verification and limits

- `npm.cmd run lint` — passed.
- `npm.cmd run build` — passed; Vite continues to warn that the minified JavaScript chunk is above 500 kB.
- `git diff --check` — passed.
- Local PostgreSQL verification could not be run: Docker failed to start the isolated local Supabase database because its containerd overlay snapshot was missing. The new migration has not been applied to the hosted Supabase project. Apply the migration to a disposable/local database and run coverage/criteria lock checks before deploying it to production.

## 2026-10-11 — CI and repeatable local database checks

### Changes

- Added a GitHub Actions workflow for Node unit tests, ESLint, the Vite production build, and a disposable local Supabase database run.
- Added Node tests for weighted scoring, incomplete versus explicit-zero scoring, and the documented average-across-scored-rounds behavior.
- Added rollback-only SQL checks for RLS/event isolation, judge scoring, duplicate setup rows, score adjustments, active-judge round coverage, criteria/roster locks, and shortlist edits after a later round starts.
- Updated setup/review notes to distinguish local SQL validation from hosted-project verification and to avoid applying legacy migrations to the fresh core schema.

### Verification and limits

- `npm test` — passed (3 tests).
- `npm run lint` — passed.
- `npm run build` — passed; Vite reports a 562 kB minified chunk above its 500 kB advisory threshold.
- The fresh core installer, migration `202610110003_lock_scoring_and_validate_round_coverage.sql`, and both rollback-only SQL suites passed against a disposable local Supabase database.
- The CI database uses test Auth users and JWT claims; no Google OAuth account, hosted Supabase project, Edge Function deployment, browser flow, load benchmark, backup, or restore was tested. The user reports applying migration 003 to the live project, but that live schema was not independently queried.
- The GitHub Actions workflow itself has been exercised locally through its constituent commands, but has not yet run on GitHub Actions.

## 2026-10-11 — Deployment-readiness review: API pagination and dependency advisories

### Changes

- Added a shared Supabase pagination helper and applied it to organizer event lists, event overrides, team-round results, organizer current scores, and judge current scores. Score screens now query the canonical `current_scores` view instead of downloading append-only score revisions.
- Added unit checks for pagination across multiple pages, exact-page boundaries, malformed results, and database errors.
- Ran `npm.cmd audit fix` to update compatible dependency versions in the lockfile. No application dependency versions outside their declared ranges were intentionally upgraded.

### Verification

- `npm.cmd test` — passed (5 tests).
- `npm.cmd run lint` — passed.
- `npm.cmd run build` — passed with Vite 8.3.4; minified JS remains 562.86 kB, above the 500 kB advisory threshold.
- `npm.cmd audit fix` — reported 0 vulnerabilities after updating 37 packages; the post-fix audit commands could not reach npm's advisory endpoint in the sandbox and need an online rerun.
- `git diff --check` — passed; only pre-existing LF/CRLF notices were printed.

### Remaining deployment blockers

- Pagination fixes the 1,000-row truncation risk but does not make a large event load scalable: the UI still loads all current scores into browser memory. No concurrency or load benchmark has been run.
- Production readiness still requires verified hosted schema/migration state, Google OAuth/browser rehearsal, tested backup restore, monitoring/alerts, score submission abuse controls, and a clear policy for closing a round with incomplete scores.
- CI has not yet run on GitHub Actions for the current working tree. Do not claim a production-scale capacity target or zero-defect guarantee from local checks.

## 2026-10-11 — Public SEO metadata and analytics URL filtering

### Changes

- Refreshed the public page title, description, canonical URL, and social metadata; removed references to a social preview image that is not present in `public/`.
- Updated the existing sitemap's stale modification date. `robots.txt` already allowed public crawling and referenced this sitemap.
- Added a Vercel Analytics `beforeSend` filter that strips URL fragments and rejects judge-invitation URLs so invitation tokens are not sent as page-view URLs.

### Verification and limits

- `npm.cmd run lint` and `npm.cmd run build` — passed. The build still has the existing >500 kB minified-chunk warning.
- SEO and OAuth documentation use `https://hack-judge-v2.vercel.app/` as the production app hostname.
- Vercel Web Analytics is present in code, but the project dashboard setting and live event ingestion cannot be verified from this repository. Google Analytics/GA4 is not installed.
- Search ranking and indexing cannot be guaranteed by metadata or sitemap files alone.
