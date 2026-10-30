---
name: pbi-deploy
description: Use when provisioning Fabric or Power BI workspaces or deploying PBIP semantic models and reports to DEV, TEST or PROD with the repository's PowerShell infrastructure-as-code scripts (no GitHub Actions). Explains environments and guards, the deployment steps (workspace, capacity, roles, item definitions, parameters, report rebinding, refresh, post-deployment DAX tests), the human-only PROD release procedure, rollback and troubleshooting.
argument-hint: "<DEV | TEST | PROD> [project path]"
---

# Deploy with PowerShell infrastructure as code

## Environments
| Env | Workspace | Who deploys | Guards (`config/environments/*.json`) |
|---|---|---|---|
| DEV | `Power BI Superpower [DEV]` | Developer or agent, any branch | none |
| TEST | `Power BI Superpower [TEST]` | Release manager (agent allowed), `main` only | clean tree, merged to `main` |
| PROD | `Power BI Superpower` | **Human release approver only** | clean tree, merged to `main`, TEST evidence for the same commit, `gate:release-approved` on the release issue, typed confirmation |

## What `Deploy-PbiProject.ps1` does
1. Loads the environment file (placeholders from environment variables or `.env.local`), checks the guards.
2. Runs the deploy gate profile (L0 + L1); stops on failure.
3. Signs in (Az.Accounts) and ensures the workspace, capacity assignment and role assignments (`Deploy-PbiInfrastructure.ps1` logic; add/update only, never remove).
4. Publishes each semantic model from its TMDL folder through the Fabric item definition API (create or `updateDefinition`), with M parameter values for the environment. `.pbi/`, `DAXQueries/`, `TMDLScripts/` and `.platform` are not uploaded.
5. Refreshes the model (enhanced refresh API) and waits.
6. Publishes each report with `definition.pbir` rewritten from `byPath` to `byConnection` (`semanticmodelid=<id>`).
7. Runs `*.ALL.Tests.dax` + `*.<ENV>.Tests.dax` against the deployed model (executeQueries).
8. Writes `.evidence/<timestamp>-deployment-<ENV>-<sha>.json/.md` — paste the `.md` into the PR (DEV) or the release issue (TEST/PROD).

## Commands
```powershell
pwsh scripts/deploy/Deploy-PbiProject.ps1 -Environment DEV -WhatIf      # plan only
pwsh scripts/deploy/Deploy-PbiProject.ps1 -Environment DEV
pwsh scripts/deploy/Deploy-PbiProject.ps1 -Environment TEST             # after merge, on main
pwsh scripts/infra/Deploy-PbiInfrastructure.ps1 -Environment TEST -WhatIf
```

## Release to PROD (agent prepares, human executes)
1. Agent: after TEST passes, create a release issue (`type:release`) with the TEST evidence summary, the list of merged PRs, release notes draft and the exact PROD command.
2. Human release approver: reviews TEST, applies `gate:release-approved`.
3. Human, on a clean `main` checkout: `pwsh scripts/deploy/Deploy-PbiProject.ps1 -Environment PROD -ReleaseIssue <n>`; types the workspace name to confirm.
4. Agent (afterwards): attach the PROD evidence summary to the release issue, update `CHANGELOG.md`, tag `vX.Y.Z` through a PR if the team uses tags.

The `preToolUse` hook blocks agents from running PROD deployments; do not try to work around it.

## Rollback
Roll forward when possible. Otherwise check out the last good commit or tag on a branch, deploy it to TEST, then follow the PROD procedure. Item definitions are replaced as a whole, so redeploying the previous commit restores the previous model and report. Data is restored by the post-deployment refresh.

## First-time setup and tenant prerequisites
See `references/first-time-setup.md` (tenant settings, permissions, capacity, environment variables, service principal option).

## Troubleshooting
| Symptom | Cause | Action |
|---|---|---|
| 401 Unauthorized | Wrong token audience or expired sign-in | `Connect-AzAccount` again; Fabric calls use `https://api.fabric.microsoft.com`, refresh/executeQueries use `https://analysis.windows.net/powerbi/api` |
| 403 / `InsufficientPrivileges` | Not Admin/Member/Contributor on the workspace or capacity | Ask the workspace or capacity admin; do not retry in a loop |
| `ItemDisplayNameAlreadyInUse` | An item with that name exists but of another type, or duplicates | Clean up in the service (human) |
| LRO `Failed` on semantic model | Invalid TMDL or unsupported feature | Run `-Profile commit`, open the project in Desktop, fix, redeploy |
| Refresh fails with credentials | Data source credentials / gateway not set in the service | Human sets credentials or binds the connection in the service; do not retry |
| 429 `CapacityLimitExceeded` | Capacity throttled | Wait and retry later; consider a larger SKU for TEST |
| Report shows "can't connect" | Binding not rewritten or wrong model ID | Redeploy the report; never commit `byConnection` |
