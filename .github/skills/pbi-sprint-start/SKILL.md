---
name: pbi-sprint-start
description: Use when a new sprint starts (or for Sprint 0 of a new repository) to agree the sprint goal and capacity, create the GitHub milestone, the sprint document and the tracking issue, and pull ready backlog items into the sprint.
argument-hint: "<sprint number> <goal> [start date]"
---

# Start a sprint

## Inputs
Sprint number, goal (one sentence, outcome-focused), start date (default next Monday), length (default 10 working days), team capacity in person-days.

## Steps

1. **Close the loop on the previous sprint.** Run `pwsh scripts/sprint/Get-PbiSprintStatus.ps1`. If the previous sprint has open issues, list them and ask the product owner which ones carry over. Do not close milestones yourself; that is part of `pbi-sprint-review`.
2. **Draft the goal and scope** from the backlog: issues with `phase:spec`, `phase:plan` or `agent:ready`, ordered by `priority:*`, then by intake score. Plan to about 70 % of capacity (sizes: xs 0.25 d, s 0.5 d, m 1.5 d, l 4 d — split anything larger than `size:l`).
3. **Confirm with the product owner** (ask; do not assume). Record the agreed goal and the committed issues.
4. **Create the sprint artefacts:**
   ```powershell
   pwsh scripts/sprint/New-PbiSprint.ps1 -Number <N> -Goal "<goal>" -StartDate <yyyy-MM-dd>
   ```
   This creates milestone `Sprint NN`, `docs/sprints/sprint-NN/sprint.md`, `docs/sprints/current.json` and the tracking issue (`type:sprint`).
5. **Assign the committed issues** to the milestone with the GitHub MCP server (`issue_write`, field `milestone`) and set their `phase:*` labels. Add them to the project board if one exists.
6. **Fill in `docs/sprints/sprint-NN/sprint.md`**: goal, committed issues table, capacity, risks, demo plan. Commit it on a branch `chore/sprint-NN-start` and open a pull request.

## Sprint 0 — walking skeleton (first sprint of a new repository)

Goal: *prove the tool chain end to end with the `src/SalesStarter` project before real work starts.* Committed items (create them as issues from `docs/getting-started/first-sprint.md`):

1. Prerequisites green (`Test-Prerequisites.ps1`), tooling and plugins installed.
2. Report scaffolded from `src/SalesStarter/report-blueprint.json` and opened in Power BI Desktop.
3. DAX tests pass locally (`Invoke-PbiDaxTests.ps1 -Target Local`).
4. `-Profile pr` gate passes with evidence.
5. DEV workspace provisioned and SalesStarter deployed; post-deployment tests pass.
6. Pull request merged by a human; TEST deployment from `main`.
7. Retro: what to change in skills, gates or scripts before Sprint 1.

## Output
Milestone, sprint document, tracking issue, committed issues assigned, and a comment on the tracking issue summarising goal, scope and capacity.
