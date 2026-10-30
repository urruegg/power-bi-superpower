# Contributing

1. Every change starts from an issue (forms in `.github/ISSUE_TEMPLATE`) and follows the phase flow in `AGENTS.md`.
2. Work on a branch (`feat/<issue>-<slug>`, `fix/<issue>-<slug>`, `chore/<slug>`), ideally in a Superpowers worktree.
3. Tests first: DAX tests for model changes, Pester tests for script changes, a skill test scenario for skill changes (Superpowers `writing-skills`).
4. Run `pwsh scripts/quality/Invoke-PbiQualityGate.ps1 -Profile pr -Target Local` and paste the summary into the PR.
5. A human maintainer reviews and merges. Agents never merge, never apply `gate:*` labels and never deploy to PROD.
6. Keep identifiers, secrets and personal data out of Git; use `${env:…}` placeholders and `.env.local`.
7. Changes to `config/`, `scripts/`, `.github/` and RLS roles need CODEOWNERS review; relaxing a guard or a gate threshold needs an ADR.

## First contribution to this baseline

Read the [readiness intake](docs/analysis/development-readiness.md) before choosing work. Most factory files were imported into a dirty working tree; only three files were tracked at assessment time. Do not commit unrelated imported files or publish them to `main` as part of a small change.

The readiness issue is still in intake. A product owner must accept its scope; script/agent changes then need the appropriate reviewed specification and implementation plan. A documentation clarification is not an implicit approval to repair scripts, scaffold a report or deploy.

Run the [offline Pester tests](tests/powershell/README.md) and relevant gates for automation changes. For documentation, verify links and example commands against the actual scripts. When a full report gate cannot pass, record the exact failures/skips and request review rather than presenting a partial check as green.

Use inert guardrail fixtures, never real forbidden pushes, merges, approval-label changes or PROD calls. Human-only service work also includes EULA acceptance, credentials, tenant settings and RLS membership.
