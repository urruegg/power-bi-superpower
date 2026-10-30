# Copilot instructions — power-bi-superpower

Power BI semantic models (TMDL) and reports (PBIR) as code, deployed by PowerShell 7 scripts to Fabric / Power BI workspaces. Workflow rules for agents are in `AGENTS.md`; follow them. These instructions apply to every Copilot surface, including code review.

## Conventions

- **TMDL:** tabs for indentation; one table per file in `definition/tables/`; measures before columns; every measure has `formatString` and a `///` description; display folders group measures; keys and technical columns are hidden; relationships single-direction unless the spec says otherwise; a marked date table (`dataCategory: Time`) drives time intelligence; auto date/time stays off.
- **DAX:** use `DIVIDE` not `/`; variables for repeated expressions; no `FILTER` over whole tables where a column predicate works; no `IFERROR`; measure names in business language with units in the format string, not the name.
- **Tests:** every new or changed measure has a test in `<Model>.SemanticModel/DAXQueries/<Area>.ALL.Tests.dax` returning `TestName`, `ExpectedValue`, `ActualValue`, `Passed`; expected values come from an independent source, never from the measure under test.
- **PBIR:** new reports are scaffolded (`scripts/build/New-PbipReport.ps1`), never hand-written; keep existing `$schema` versions; use `cardVisual` (not legacy `card`); every visual has a title and alt text; validate with `powerbi-report-author validate`.
- **Bindings:** reports in Git use `byPath` to the co-located model; `byConnection` is created only at deploy time.
- **PowerShell:** PowerShell 7.4, `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, approved verbs, comment-based help, `-WhatIf` for remote writes, no aliases, no secrets in output, exit codes 0 / 1 / 2.
- **Config:** no GUIDs, tenant names, e-mail addresses or secrets in tracked files; use `${env:NAME}` placeholders.
- **Commits:** Conventional Commits with the issue number, for example `feat(model): add Sales YTD measure (#12)`. Branches: `feat/<issue>-<slug>`, `fix/<issue>-<slug>`, `chore/<slug>`.

## When reviewing a pull request

Check, in this order: (1) the PR body has pasted quality-gate evidence and links the issue, spec and plan; (2) changes stay inside the plan; (3) DAX tests exist for every new or changed measure and were written first; (4) no identifiers, secrets or personal data; (5) TMDL / PBIR conventions above; (6) RLS impact stated; (7) environment config changes are intentional. Report findings by severity (blocking, should fix, nit).
