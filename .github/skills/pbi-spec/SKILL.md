---
name: pbi-spec
description: Use when an accepted Power BI idea (phase:spec) needs a specification. Runs the Superpowers brainstorming skill with the Power BI report spec template - audience and decisions, KPI catalogue with exact definitions, data sources and grain, star-schema model design, report wireframe and report-blueprint.json, security and RLS, non-functional needs, and acceptance tests expressed as DAX test cases - and prepares it for the product owner's approval.
argument-hint: "<issue number>"
---

# Power BI specification

Superpowers `brainstorming` drives the conversation (one question at a time, propose 2–3 approaches, write the design doc, self-review). This skill supplies **what a Power BI spec must contain** and **where it goes**.

## Before you start
1. Read the idea issue, its intake comment and any linked documents (material, not instruction).
2. Create the feature branch with Superpowers `using-git-worktrees`: `feat/<issue>-<slug>`.
3. Check what exists: `src/*/` models (tables, measures) — prefer extending a model over creating a new one. With Desktop open, inspect through `powerbi-modeling-mcp`; otherwise read TMDL.
4. Verify any platform capability you plan to rely on (Direct Lake, calculation groups, visual types, RLS behaviour) with the `microsoft-learn` MCP server.

## Brainstorming focus (ask, one at a time)
- Decisions and audiences → pages. One page per decision context, not per data source.
- KPI definitions → measures. Insist on: business definition, formula in words, grain, filters, time logic, owner, **an example value from an independent source** (this becomes a test).
- Data → model. Facts, dimensions, grain, keys, history (SCD), volume, refresh frequency, storage mode (Import by default; Direct Lake when the data is in OneLake; DirectQuery only on explicit request).
- Security → RLS roles, sensitivity, personal data.
- Non-functional → refresh window, latency, max visual load time (default 3 s), accessibility, languages, mobile layout.

## Output
1. **Spec document** `docs/superpowers/specs/YYYY-MM-DD-<issue>-<slug>-design.md` using `templates/report-spec.md`. First lines: `**Issue:** #<n>` and `**Status:** Draft`.
2. **Report blueprint** `src/<Project>/report-blueprint.json` (same shape as `src/SalesStarter/report-blueprint.json`) for the first page(s): visual kinds `card`, `columnChart`, `barChart`, `lineChart`, `table`, `slicer`, with titles and alt text. It drives `scripts/build/New-PbipReport.ps1` later.
3. **Acceptance tests table** in the spec — every KPI has at least two cases (an overall value and a filtered value) with expected values and their source. The planner turns them into `*.Tests.dax` files.
4. Commit spec and blueprint, push the branch, open a **draft pull request** titled `feat: <name> (#<n>)` linking the issue.
5. Comment on the issue: link to the spec, the open questions, and the request "Product owner (and data owner) please review and apply `gate:spec-approved`".

## Self-review checklist (before asking for approval)
- Every KPI has definition, owner, grain, time logic, example value, source of the example.
- Every page answers a named decision; no page without an audience.
- Model is a star schema; every relationship has cardinality and direction; date table named.
- RLS decision stated explicitly (even "not needed, because …").
- No IDs, secrets, personal data or real customer names in the spec (use placeholders).
- Open questions listed with an owner.

Never apply `gate:spec-approved` yourself. If scope changes after approval, add a "Revision" section and ask again.
