# Environment configuration

One file per environment: `dev.json`, `test.json`, `prod.json`. The deployment scripts read them; agents propose changes to them through pull requests (CODEOWNERS review applies).

| Field | Meaning |
|---|---|
| `workspace.displayName` | Workspace that holds this environment. Created if missing by `scripts/infra/Deploy-PbiInfrastructure.ps1`. |
| `workspace.capacityName` | Display name of the Fabric / Premium capacity. Resolved to its ID at run time. Empty string = no capacity assignment. |
| `workspace.roleAssignments[]` | Workspace roles to ensure (`Admin`, `Member`, `Contributor`, `Viewer`) for `User`, `Group` or `ServicePrincipal`. Assignments are added or updated, never removed. `optional: true` entries are skipped when their variable is not set. |
| `guards` | Rules checked before anything is deployed (branch, clean tree, merged to main, TEST evidence for the same commit, release approval label, human-only). |
| `projects[]` | PBIP projects to deploy: semantic model folder, display name, parameter values per environment, refresh after deploy, reports bound to the model. |
| `postDeploy.runDaxTests` | Run the `*.ALL.Tests.dax` and `*.<ENV>.Tests.dax` files against the deployed model. |

## No identifiers in Git

IDs (Entra group object IDs, capacity names that reveal tenants, workspace IDs) never go into these files. Use `${env:NAME}` placeholders and provide the values in one of these ways:

1. Environment variables in your session (`$env:PBI_DEV_ADMIN_GROUP_ID = '…'`).
2. A git-ignored `.env.local` file at the repository root (`KEY=VALUE` lines). Copy `.env.example`.
3. A git-ignored overlay `config/environments/<env>.local.json` that is deep-merged over the tracked file.

The repository hygiene check (`Invoke-PbiQualityGate.ps1 -Check RepoHygiene`) fails when a GUID appears in a tracked configuration file.
