---
name: pbi-quality-gates
description: Use before claiming any Power BI change is done, before opening or updating a pull request, and before any deployment. Runs the repository quality gate profiles (structure and hygiene, Best Practice Analyzer, report conventions, DAX tests, attended visual review), interprets failures, and posts the evidence summary to the pull request - the Power BI implementation of Superpowers verification-before-completion.
argument-hint: "[profile: commit | pr | deploy-dev | deploy-test | release]"
---

# Quality gates and evidence

Superpowers `verification-before-completion` says: no completion claim without fresh evidence. Here the evidence is the gate output.

## Levels
| Level | Checks | Needs |
|---|---|---|
| **L0 Structure and hygiene** | `RepoHygiene` (no IDs, secrets, personal data, local Desktop files), `PbipStructure`, `TmdlConventions`, `PbirValidate` (`powerbi-report-author validate`), `AgentAssets` (skills, agents, instructions, hooks lint), `McpParity`, `SuperpowersManifest` (only when vendored) | Offline, seconds |
| **L1 Static analysis** | `ModelBpa` (Tabular Editor 2 CLI + Microsoft and repository BPA rules), `ReportConventions` (titles, alt text, overlap, visual count, legacy visuals), `ReportInspector` (optional, Fab Inspector) | Windows for BPA |
| **L2 Behaviour** | `DaxTests` (`*.ALL.Tests.dax` + target scope) | Desktop open (Local) or a deployed model (DEV/TEST/PROD) |
| **L3 Visual review** | `Screenshots` of every page — a human reviews them | Desktop open; attended |

## Profiles (config/quality/gates.json)
| Profile | When | Levels |
|---|---|---|
| `commit` | Before every commit (also run by `.githooks/pre-push`) | L0 |
| `pr` | Before opening / updating a PR | L0, L1, L2 |
| `deploy-dev`, `deploy-test` | Run automatically by `Deploy-PbiProject.ps1` | L0, L1 (+ post-deploy DAX tests) |
| `release` | Before asking for `gate:release-approved` | L0–L3 |

## Commands
```powershell
pwsh scripts/quality/Invoke-PbiQualityGate.ps1 -Profile commit
pwsh scripts/quality/Invoke-PbiQualityGate.ps1 -Profile pr -Target Local
pwsh scripts/quality/Invoke-PbiQualityGate.ps1 -Profile pr -Target DEV          # tests against DEV instead of Desktop
pwsh scripts/quality/Invoke-PbiQualityGate.ps1 -Check ModelBpa,DaxTests -Target Local
pwsh scripts/quality/Invoke-PbiQualityGate.ps1 -Profile release -Target Local -AttendedConfirmed   # after a human reviewed screenshots
```
Exit code 0 = passed, 1 = failed, 2 = configuration problem. Evidence: `.evidence/<timestamp>-quality-gate-<sha>.json` and `.md`.

## Rules
- **Skipped is never passed.** A skipped required check fails the gate unless it is listed in `optionalChecks` or explicitly allowed with `-AllowSkip <Check>` — and then the reason goes into the PR.
- Fix the cause, not the rule. Changing thresholds or disabling BPA rules needs an ADR and CODEOWNERS approval.
- Re-run the full profile after the last change; evidence must match the commit you push (the file name contains the short SHA).

## Posting evidence
Paste the `.md` summary into the PR body section "Validation evidence" (or post it as a PR comment with the GitHub MCP server). It masks GUIDs and e-mail addresses — do not unmask them.

## Common failures
| Failure | Usual cause | Fix |
|---|---|---|
| `RepoHygiene` GUID in `config/` | ID pasted into config | Replace with `${env:NAME}`; add to `.env.example` |
| `PbipStructure` report missing | Report not scaffolded | `pwsh scripts/build/New-PbipReport.ps1 -ProjectPath src/<Project>` |
| `TmdlConventions` measure without format string | New measure | Add `formatString:` and `///` description |
| `PbirValidate` unknown role "Fields" | Legacy card role | Use `cardVisual` with role `Data` |
| `ModelBpa` errors | Rule violation | Read the TRX in `.evidence/`, fix, re-run |
| `DaxTests` skipped (Local) | Desktop not open on the project | Open `src/<Project>/<Project>.pbip` or use `-Target DEV` |
