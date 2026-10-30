---
name: pbi-plan
description: Use after a Power BI spec has gate:spec-approved, together with the Superpowers writing-plans skill, to produce an implementation plan of small test-first tasks (exact TMDL/PBIR file paths, DAX tests before measures, verification commands, commit messages) and to create one GitHub sub-issue per task so agents can build it.
argument-hint: "<issue number>"
---

# Power BI implementation plan

Superpowers `writing-plans` defines the plan format (header with `**Spec:**`, Global Constraints, Review Focus, tasks with Files/Interfaces and `- [ ]` steps, 2–5 minute steps). This skill adds the Power BI rules.

## Inputs
Approved spec (`gate:spec-approved` on the issue), `report-blueprint.json`, the current model files.

## Plan location
`docs/superpowers/plans/YYYY-MM-DD-<issue>-<slug>.md`, first lines `**Issue:** #<n>` and `**Spec:** <path>`.

## Global constraints to copy into every plan
- Work on branch `feat/<issue>-<slug>` (worktree), never on `main`.
- Semantic model changes via `powerbi-modeling-mcp` against Desktop when it is open, otherwise TMDL edits (see `pbi-semantic-model`); never both at once.
- **Test first:** every measure task starts with a failing test in `DAXQueries/<Area>.ALL.Tests.dax` (`pbi-dax-tdd`).
- Reports are scaffolded (`scripts/build/New-PbipReport.ps1`), then refined (`pbi-report-pbir`); validate after each batch.
- No IDs, secrets or personal data in Git. Deploy only with the scripts.

## Task order (dependencies)
1. Parameters and data access (`expressions.tmdl`, partitions) → refresh works in Desktop.
2. Tables and columns (types, hidden keys, sort-by, date table).
3. Relationships.
4. Measures — one task per KPI group, each RED → GREEN → REFACTOR.
5. Security roles and RLS tests (`pbi-rls-security`).
6. Report scaffold from blueprint, then one task per page (visuals, interactions), then formatting and accessibility.
7. Environment configuration (`config/environments/*.json`: new project, parameters).
8. Documentation (project README, release notes draft).

## Task template
Use `templates/plan-task.md`. Every task names: files to touch (exact paths), the test to write first and its expected result, the command that proves it (`Invoke-PbiDaxTests.ps1 …`, `Invoke-PbiQualityGate.ps1 -Profile commit`, `powerbi-report-author validate …`), and the commit message.

## After writing the plan
1. Self-review: every spec KPI and acceptance test appears in a task; no task larger than half a day; no task without a verification command.
2. Commit the plan on the feature branch and push.
3. Create one sub-issue per task with the GitHub MCP server (`issue_write` to create, `sub_issue_write` to attach to the feature issue) — title `T<k>: <task title>`, labels `type:task`, `area:*`, `size:*`, milestone of the parent.
4. Comment on the feature issue: plan link, task list, estimated size; ask the tech lead to apply `gate:plan-approved`.
5. When the gate is applied, add `agent:ready` to the tasks that have no open questions, and move the feature to `phase:build`.

## Execution handover
Recommend Superpowers `subagent-driven-development` (fresh subagent per task with review) for model and report tasks; `executing-plans` when subagents are not available. Tasks touching the same TMDL table file must run sequentially, not in parallel.
