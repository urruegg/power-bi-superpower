---
name: pbi-sprint-review
description: Use at the end of a sprint to prepare the sprint review and retrospective - list what was released, draft release notes and the CHANGELOG from merged pull requests, compute simple flow and quality metrics, run a keep/drop/try retro, and turn lessons into new or updated skills with the Superpowers writing-skills skill.
argument-hint: "[sprint number]"
---

# Sprint review and retrospective

## 1. Collect facts
- `pwsh scripts/sprint/Get-PbiSprintStatus.ps1 -Number <N>` — done vs not done by phase.
- Merged PRs in the sprint: GitHub MCP `search_issues` / `list_pull_requests` (or `gh pr list --state merged --search "milestone:\"Sprint NN\""`).
- Evidence: TEST/PROD deployment summaries on release issues.

## 2. Draft release notes and CHANGELOG
Use `templates/release-notes.md`. Write for report users: what changed, why it matters, any action needed. Add an entry under `## [Unreleased]` → version in `CHANGELOG.md` (Keep a Changelog). Commit on `chore/sprint-NN-review` and open a PR.

## 3. Metrics (no individual performance — teams and flow only)
| Metric | How |
|---|---|
| Committed vs done | Issues in milestone, closed / total |
| Lead time (spec approved → TEST) | Dates of `gate:spec-approved` label event and TEST deployment comment |
| Gate first-pass rate | PRs whose first `-Profile pr` evidence passed |
| Escaped defects | `type:bug` opened after release for this sprint's features |
| Agent assist share (optional) | PRs authored with agent help / total |

## 4. Retrospective
Run keep / drop / try with the team using `templates/retro.md`. For every recurring problem decide: fix a script, tighten a gate, or **write or update a skill** (Superpowers `writing-skills`, labelled `area:agent-assets`).

## 5. Close the sprint (human confirms)
After the product owner accepts the review: close the milestone (`gh api -X PATCH repos/{owner}/{repo}/milestones/<number> -f state=closed`), move unfinished issues to the next milestone, and start the next sprint with `pbi-sprint-start`.
