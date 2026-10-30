# Your first sprints

Sprint 0 proves the tool chain with `src/SalesStarter`. Sprint 1 delivers the first real report from an idea. Prompts below work in VS Code agent mode (pick the agent in the agent picker) and in Copilot CLI (`/agent <name>` then the prompt).

> **Current baseline:** no sprint is active. Review [intake #1](https://github.com/urruegg/power-bi-superpower/issues/1) and the [readiness assessment](../analysis/development-readiness.md) first. The current sprint scripts accept numbers **1-99**, while this guide uses "Sprint 0" as the walking-skeleton concept. Agree to use numbered **Sprint 01** for readiness, or approve/test support for zero before running `New-PbiSprint.ps1 -Number 0`. Do not hand-write a current-sprint pointer to hide the mismatch.

## Sprint 0 — walking skeleton (2–3 days, provisional)

**Agree the sprint before creating it**
> Agent `pbi-sprint-lead`: *"Use using-superpowers, pbi-sprint-flow, pbi-sprint-start and brainstorming. Read intake #1. Propose a walking-skeleton goal, scope, numbering and capacity for agreement; do not start implementation or apply gate labels."*

Suggested goal: **prove the SalesStarter toolchain from local tests to TEST before real reports**. Dates and capacity are unconfirmed; the original 2-3 day estimate is not a commitment. After human agreement, the sprint lead uses the sprint script to create the milestone, tracking issue and current pointer. If readiness uses number 1, use number 2 for the first business-delivery sprint.

**Proposed backlog** (create/commit issues only after human scope agreement; spec and plan gates still apply)

| # | Title | Labels | Done when |
|---|---|---|---|
| 1 | Automation, workstation and agents ready | `type:task`, `area:agent-assets`, `size:s` | Resolve the findings-helper regression and numbering mismatch; all 180 current Pester tests pass; prerequisites exit 0; tool/plugin versions reconciled; hook deny/allow behavior verified using inert fixtures in the intended harnesses |
| 2 | Scaffold the SalesStarter report | `type:task`, `area:report`, `size:xs` | `New-PbipReport.ps1 -ProjectPath src/SalesStarter` succeeded; Desktop opens `SalesStarter.pbip`; screenshot attached |
| 3 | Local DAX tests green | `type:task`, `area:model`, `size:xs` | `Invoke-PbiDaxTests.ps1 -Target Local` all PASS (Measures, ModelIntegrity, Environment.LOCAL) |
| 4 | PR gate and attended visual review | `type:task`, `size:s` | `Invoke-PbiQualityGate.ps1 -Profile pr -Target Local` passed; staged-source hygiene verified; screenshots reviewed by a human; evidence pasted in the PR |
| 5 | DEV workspace and deployment | `type:task`, `area:infra`, `size:s` | Service prerequisites/access agreed; review `-WhatIf`, then `Deploy-PbiProject.ps1 -Environment DEV` passes including post-deployment tests (`Environment.DEV`) |
| 6 | Merge and TEST | `type:task`, `area:infra`, `size:s` | Human merged; release manager deployed `main` to TEST; `Environment.TEST` passes |
| 7 | Sprint 0 retro | `type:task`, `size:xs` | Retro actions turned into issues or skill updates |

**Typical prompts** (task numbers below are backlog rows, not actual GitHub issue numbers; pass the created issue number and approved plan)
- Task 2 — agent `pbi-report-engineer`: *"The plan has gate:plan-approved. Scaffold SalesStarter from its blueprint, validate it, and tell me when to open it in Desktop."*
- Task 3 — agent `pbi-quality-engineer`: *"Desktop has SalesStarter open. Run the local DAX tests and post the summary on the task issue."*
- Task 5 — agent `pbi-quality-engineer`: *"Deploy the current branch to DEV with -WhatIf first, show me the plan, then deploy and post the evidence on the PR."*
- Task 6 — after you merged: agent `pbi-release-manager`: *"Release main to TEST and post the evidence."*
- Task 7 — agent `pbi-sprint-lead`: *"Run the sprint 0 review and retro."*

**Safe guardrail verification:** run the existing fixtures, which submit inert tool payloads and assert denials without executing the forbidden command:

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path .\tests\powershell\Guardrails.Tests.ps1 -Output Detailed"
```

Confirm actual hook dispatch and crash/timeout handling in each intended harness separately. Do **not** test guards with a real push to `main`, merge, PROD call or approval-label mutation.

## Sprint 1 — first real report (two weeks)

1. **Intake.** Create an issue with the *Report or dashboard idea* form, or tell agent `pbi-sprint-lead`: *"New idea: <paste the request>. Run intake."* Answer its questions. Then you (product owner) decide and relabel `phase:spec`.
2. **Sprint start.** `pbi-sprint-lead`: *"Start sprint 1 with goal '<goal>', capacity <n> days; propose the scope from the backlog."* Confirm the scope.
3. **Spec.** `pbi-spec-architect`: *"Write the specification for issue #<n>."* It brainstorms with you one question at a time, writes the spec and report blueprint, and prepares them for review. Review and apply `gate:spec-approved`. Do not scaffold product code in this phase.
4. **Plan.** `pbi-planner`: *"Plan issue #<n>."* Review the plan and sub-issues, apply `gate:plan-approved`.
5. **Build.** For a new project, execute the approved scaffold task first (replace `MyReport` with the agreed project name):
   ```powershell
   pwsh -NoProfile -File .\scripts\build\New-PbipProject.ps1 -Name MyReport
   # Implement the approved model, tests and report-blueprint.json, then scaffold the report:
   pwsh -NoProfile -File .\scripts\build\New-PbipReport.ps1 -ProjectPath .\src\MyReport
   ```
   Expected outputs are `src/MyReport/MyReport.SemanticModel`, DAX tests, a report blueprint, then `MyReport.Report` and `MyReport.pbip`. The current report wrapper applies the blueprint's first page; additional pages require explicit report tasks. Add the project/model/report paths and environment parameter mappings to the environment configuration through the approved plan.

   Open the PBIP in Desktop. `pbi-model-engineer`: *"Execute the approved model tasks for issue #<n>, DAX tests first."* Save in Desktop when asked. Then `pbi-report-engineer`: *"Execute the approved report tasks and validate after each batch."* Do not edit the live model and its files concurrently.
6. **Test.** `pbi-quality-engineer`: *"Verify #<n>: PR gate, DEV deployment, evidence on the PR."* Review the screenshots (attended L3).
7. **Review.** `pbi-reviewer`: *"Review PR #<m>."* Fix findings with the engineer agents (Superpowers `receiving-code-review`). **Merge yourself.**
8. **Release.** `pbi-release-manager`: *"Release #<n> to TEST and prepare the PROD release issue."* The release approver applies `gate:release-approved` and runs:
   ```powershell
   # Human release approver only: set $releaseIssue to the approved release issue number.
   pwsh -NoProfile -File .\scripts\deploy\Deploy-PbiProject.ps1 -Environment PROD -ReleaseIssue $releaseIssue
   ```
9. **Sprint review.** `pbi-sprint-lead`: *"Run the sprint 1 review and retro; draft release notes and the changelog PR."*

## When the request says "dashboard"

Confirm whether the user means a dashboard-style **report page** or a **Power BI service dashboard**. PBIR supports the former. The latter is a service canvas made of pinned tiles, not a Desktop/PBIP report; this kit has no dashboard/tile deployment automation. After the approved report release, a human service owner creates/pins the dashboard and verifies tile links, refresh and audience access. Treat that as a separate acceptance/release step, not an implied output of the report script.
