---
name: pbi-sprint-flow
description: Use at the start of any Power BI work in this repository or whenever you are unsure what to do next. Maps the current GitHub issue to its sprint phase (intake, spec, plan, build, test, review, deploy, sprint review), names the custom agent that owns it, the Superpowers and pbi-* skills to load, the artefact to produce and the human gate to wait for.
argument-hint: "[issue number or short description of the work]"
---

# Power BI sprint flow (router)

You orchestrate one GitHub issue through the sprint. Superpowers provides the engineering discipline; the `pbi-*` skills add the Power BI specifics; humans own every gate.

## 1. Establish context (always)

1. Read `docs/sprints/current.json` (sprint number, goal, milestone, dates). If it is missing, the next step is `pbi-sprint-start`.
2. Identify the issue: from the user, from the branch name (`feat/<issue>-<slug>`), or ask. Read it with the GitHub MCP server (`issue_read`) including labels, sub-issues and comments.
3. Derive the phase from the `phase:*` label. If there is none, the phase is **Intake**.
4. Check the gate for the next phase (table below). If the gate label is missing, do the current phase's work, then **stop and ask the named human** to review; do not continue past a gate.

## 2. Phase table

| Phase | Entry criterion | Agent | Load these skills | Exit artefact | Gate to leave the phase |
|---|---|---|---|---|---|
| Sprint start | No active sprint, or sprint ended | `pbi-sprint-lead` | `pbi-sprint-start` | Milestone `Sprint NN`, `docs/sprints/sprint-NN/sprint.md`, tracking issue | Product owner agrees goal |
| Intake | Idea issue exists (`type:idea`) | `pbi-sprint-lead` | `pbi-idea-intake` | Intake comment (summary, score, questions, recommendation) | Product owner relabels `phase:spec` |
| Spec | `phase:spec` | `pbi-spec-architect` | Superpowers `brainstorming` + `pbi-spec` (+ `pbi-rls-security` when data is restricted) | Spec in `docs/superpowers/specs/`, draft `report-blueprint.json`, draft PR | `gate:spec-approved` |
| Plan | `gate:spec-approved` | `pbi-planner` | Superpowers `writing-plans` + `pbi-plan` | Plan in `docs/superpowers/plans/`, one sub-issue per task | `gate:plan-approved` |
| Build | `gate:plan-approved`, `agent:ready` | `pbi-model-engineer` / `pbi-report-engineer` | Superpowers `subagent-driven-development` (or `executing-plans`), `test-driven-development`, `systematic-debugging`; `pbi-semantic-model`, `pbi-dax-tdd`, `pbi-report-pbir`, `pbi-rls-security` | Commits per task, DAX tests first | Every plan task checked and reviewed |
| Test | All tasks done | `pbi-quality-engineer` | Superpowers `verification-before-completion` + `pbi-quality-gates` | `-Profile pr` evidence, DEV deployment evidence | All required checks pass |
| Review | Evidence in PR | `pbi-reviewer` | Superpowers `requesting-code-review` / `receiving-code-review` | Review comments resolved | **Human merges** |
| Deploy | Merged to `main` | `pbi-release-manager` | Superpowers `finishing-a-development-branch` + `pbi-deploy` | TEST deployment evidence, release issue | `gate:release-approved`; **human runs PROD** |
| Sprint review | Sprint end date | `pbi-sprint-lead` | `pbi-sprint-review` + Superpowers `writing-skills` | Release notes, CHANGELOG, retro, skill updates | Product owner accepts |

## 3. Change types (which phases are mandatory)

| Change type | Intake | Spec | Plan | Build (TDD) | Test | Review | Deploy |
|---|---|---|---|---|---|---|---|
| New report or model (`type:feature`) | ✔ | ✔ full | ✔ | ✔ | ✔ | ✔ | ✔ |
| New or changed measure / page | ✔ light | ✔ light (one page) | ✔ | ✔ | ✔ | ✔ | ✔ |
| Bug (`type:bug`) | — | Superpowers `systematic-debugging` root cause note | ✔ light | ✔ regression test first | ✔ | ✔ | ✔ |
| Agent assets (`area:agent-assets`) | — | — | ✔ light | Superpowers `writing-skills` | ✔ (`-Profile commit`) | ✔ | — |
| Infrastructure / scripts (`area:infra`) | — | ✔ light (ADR if behaviour changes) | ✔ | ✔ Pester first | ✔ | ✔ | DEV first |

Skipping a mandatory phase needs a written approval from the product owner in the issue.

## 4. Moving an issue to the next phase

- Replace the `phase:*` label (GitHub MCP `issue_write`), never add a `gate:*` label yourself (the hook blocks it).
- Post a short comment: what was produced (links), evidence (pasted summary), what the human needs to decide.
- Update the project board `Phase` field when the project exists.

## 5. Handing over to another agent

- **VS Code, Local harness:** use the handoff button the agent offers.
- **VS Code, Copilot harness / Copilot CLI:** select the agent (`/agent pbi-planner`) or ask "use the pbi-planner agent for issue #12". Programmatic: `copilot --agent pbi-planner -p "Plan issue #12"`.
- Always pass: issue number, branch, spec/plan paths, and the last evidence file.

## 6. Branch and pull request convention

One branch per feature, created at the start of the Spec phase: `feat/<issue>-<slug>` (bugs: `fix/<issue>-<slug>`). Use Superpowers `using-git-worktrees` for isolation. Open a **draft pull request** as soon as the spec is committed so humans can review spec, plan and code in one place; mark it ready for review after the Test phase.
