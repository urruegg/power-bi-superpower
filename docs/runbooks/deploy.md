# Runbook — deployments

| Step | DEV | TEST | PROD |
|---|---|---|---|
| Who | Developer or agent | Release manager (agent allowed) | **Release approver (human)** |
| Branch | any | `main`, clean, up to date | `main`, clean, same commit as TEST |
| Plan | `Deploy-PbiProject.ps1 -Environment DEV -WhatIf` | `… -Environment TEST -WhatIf` | `… -Environment PROD -ReleaseIssue <n> -WhatIf` |
| Deploy | `Deploy-PbiProject.ps1 -Environment DEV` | `… -Environment TEST` | `… -Environment PROD -ReleaseIssue <n>` (type the workspace name) |
| Evidence to | PR | Feature issue + release issue | Release issue |

## Before the first PROD release
- PROD workspace exists (`Deploy-PbiInfrastructure.ps1 -Environment PROD -WhatIf`, then without `-WhatIf` — human).
- Data source credentials / gateway bindings configured in the service (human), refresh schedule set, app audience and RLS membership assigned by the data owner.

## PROD procedure
1. `git switch main && git pull --ff-only`; `git status` is clean.
2. Confirm the release issue has the TEST evidence for `git rev-parse --short HEAD` and the label `gate:release-approved`.
3. `pwsh scripts/deploy/Deploy-PbiProject.ps1 -Environment PROD -ReleaseIssue <n>`; type the workspace name.
4. Paste `.evidence/*-deployment-PROD-*.md` into the release issue; spot-check the report in the service.
5. Ask the release manager agent to update `CHANGELOG.md` and close the issues.

## Rollback
1. Roll forward when the fix is small: normal flow, expedited review.
2. Otherwise revert: create `fix/rollback-<version>`, `git revert <merge commit of the bad release>`, open a PR, a human merges.
3. Deploy `main` to TEST, verify the post-deployment tests, then follow the PROD procedure with a new release issue.
Item definitions are replaced as a whole, so redeploying restores the previous model and report; the post-deployment refresh restores the data.

## Cost control (optional)
Pause the DEV capacity outside working hours: `pwsh scripts/infra/Set-FabricCapacityState.ps1 -SubscriptionId <id> -ResourceGroupName <rg> -Name <capacity> -State Paused` (human; capacity changes are non-delegable).
