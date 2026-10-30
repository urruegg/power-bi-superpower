# Scripts

PowerShell 7.4 automation for **power-bi-superpower**. Everything runs locally on the developer's Windows machine:
there is no CI pipeline. Humans run the scripts from the VS Code terminal or tasks (`.vscode/tasks.json`); GitHub
Copilot agents run them through their skills (`.github/skills/pbi-*`) and agents (`.github/agents/*.agent.md`).

| Folder | Scripts |
|---|---|
| [`bootstrap/`](#bootstrap) | `Test-Prerequisites.ps1`, `Install-PbiTooling.ps1`, `Install-AgentPlugins.ps1`, `Initialize-GitHubRepo.ps1`, `Initialize-PbiSuperpower.ps1` |
| [`build/`](#build) | `New-PbipProject.ps1`, `New-PbipReport.ps1` |
| [`quality/`](#quality) | `Invoke-PbiQualityGate.ps1`, `Invoke-PbiDaxTests.ps1`, `Invoke-PbiModelBpa.ps1` |
| [`infra/`](#infra) | `Deploy-PbiInfrastructure.ps1`, `Deploy-FabricCapacity.ps1`, `Set-FabricCapacityState.ps1` |
| [`deploy/`](#deploy) | `Deploy-PbiProject.ps1` |
| [`sprint/`](#sprint) | `New-PbiSprint.ps1`, `Get-PbiSprintStatus.ps1` |
| [`hooks/`](#hooks) | `Test-PreToolUse.ps1`, `Invoke-SessionStart.ps1`, `GuardrailRules.ps1` |
| [`modules/PbiSuperpower/`](#module-pbisuperpower) | The shared module used by all scripts |

Git hooks live in `.githooks/` (see [Git hooks](#git-hooks)); the Pester tests in `tests/powershell/`.

## Conventions

- **Run** with `pwsh -NoProfile -File scripts/<folder>/<Script>.ps1 ...` (or `./scripts/...` in a `pwsh` terminal).
  Scripts find the repository root themselves, so the current folder does not matter. Every script has
  comment-based help: `Get-Help ./scripts/deploy/Deploy-PbiProject.ps1 -Full`.
- **Exit codes**

  | Code | Meaning | What to do |
  |---|---|---|
  | 0 | Success (gate passed, deployment done, nothing failed) | Continue |
  | 1 | The operation or a check failed (gate failed, test failed, guard refused, a remote call failed) | Read the message, fix the cause, re-run |
  | 2 | Configuration, usage or prerequisite error (missing tool, invalid parameter, missing configuration) | Fix the setup (often `scripts/bootstrap/Test-Prerequisites.ps1` tells you how), re-run |

  A missing mandatory parameter is reported by PowerShell itself (exit code 1 with `pwsh -File`).
- **`-WhatIf`** is supported by every script that changes something remotely (workspace, items, capacity, GitHub).
  It reads the current state and prints the plan without changing anything.
- **`-Json`** prints exactly one JSON document on stdout (for agents); progress goes to the information stream and
  warnings and errors to stderr.
- **Lists** can be passed comma-separated, also through `pwsh -File`: `-Check RepoHygiene,AgentAssets`.
- **Evidence**: gates, tests and deployments write `.evidence/<timestamp>-<kind>-...json` plus a markdown summary
  (`.md`) to paste into the pull request or release issue. `.evidence/` is git-ignored. Workspace, item, capacity
  and tenant identifiers are masked in console output and summaries; tokens and secrets are never printed.
- **Configuration**: `config/environments/<env>.json` (with `${env:NAME}` placeholders resolved from environment
  variables or `.env.local`, and optional git-ignored `<env>.local.json` overrides), `config/quality/gates.json`,
  `config/quality/bpa-rules.json`, `config/github/*.json` and `tools/versions.json`. See `.env.example` for the
  variables.
- **Sign-in** for Fabric and Power BI uses Az.Accounts (`Connect-AzAccount`): an existing session is reused,
  otherwise the browser opens. Pass `-TenantId` or set `PBI_TENANT_ID`. Service principals authenticate with a
  certificate only.
- **Human-only operations**: PROD deployments and capacity changes. The scripts enforce the PROD guards (typed
  confirmation, clean tree, merged to main, TEST evidence, `gate:release-approved` on the release issue) and the
  agent guardrail hook blocks these commands for agents.

## bootstrap

### Test-Prerequisites.ps1

Checks the tools needed to work in the repository: PowerShell 7.4, Windows, git 2.45 (plus Git for Windows `bash.exe`
and long paths), GitHub CLI 2.90 and `gh auth status`, Node.js 22 and npm, the Copilot CLI, Power BI Desktop, VS Code
(optional), PowerShell modules (Az.Accounts, Pester, Az.Fabric, SqlServer), the npm CLIs `powerbi-report-author` and
`powerbi-desktop`, Tabular Editor 2 and ADOMD.NET in `tools/.bin`. Prints `Name, Required, Status, Found, Expected,
Fix` per check.

| Parameter | Description |
|---|---|
| `-Json` | One JSON object `{ outcome, checks[] }` instead of the table |
| `-BeforeTooling` | Do not fail on checks that `Install-PbiTooling.ps1` fixes (used by `Initialize-PbiSuperpower.ps1`) |

```powershell
pwsh -NoProfile -File scripts/bootstrap/Test-Prerequisites.ps1
```

Exit codes: 0 all required checks pass, 2 a required check fails.
Used by: developers (setup), the `pbi-sprint-start` skill, the VS Code task, `Initialize-PbiSuperpower.ps1`.

### Install-PbiTooling.ps1

Installs the versions pinned in `tools/versions.json`: PowerShell modules (current user), global npm CLIs and
binaries in `tools/.bin/` (Tabular Editor 2, Microsoft BPA rules, ADOMD.NET, optionally Fab Inspector). Records what
was installed, with SHA-256 hashes of downloads, in `tools/.bin/installed.json`.

| Parameter | Description |
|---|---|
| `-SkipModules` / `-SkipNpm` / `-SkipBinaries` | Skip a part |
| `-Force` | Reinstall and re-download even when already present |
| `-WhatIf` | Show what would be installed |

```powershell
pwsh -NoProfile -File scripts/bootstrap/Install-PbiTooling.ps1
pwsh -NoProfile -File scripts/bootstrap/Install-PbiTooling.ps1 -SkipNpm -Force
```

Exit codes: 0 success, 1 an installation failed, 2 configuration/prerequisite error.
Used by: developers (setup), `Initialize-PbiSuperpower.ps1`.

### Install-AgentPlugins.ps1

Installs the Copilot CLI plugins listed in `tools/versions.json` (adding their marketplaces when needed), or vendors
the Superpowers skills into `.github/skills/` pinned by tag, with a SHA-256 manifest
(`.github/skills/superpowers.manifest.json`) that the quality gate verifies.

| Parameter | Description |
|---|---|
| `-IncludeOptional` | Also install plugins marked optional |
| `-VendorSuperpowers` | Copy the Superpowers skills into `.github/skills/` (pbi-* skills are never touched) |
| `-SuperpowersRef` | Tag or branch to vendor (default: `tools/versions.json`) |
| `-Verify` | Only re-hash the vendored files against the manifest (exit 1 on drift) |
| `-WhatIf` | Show what would be installed or copied |

```powershell
pwsh -NoProfile -File scripts/bootstrap/Install-AgentPlugins.ps1
pwsh -NoProfile -File scripts/bootstrap/Install-AgentPlugins.ps1 -VendorSuperpowers
pwsh -NoProfile -File scripts/bootstrap/Install-AgentPlugins.ps1 -Verify
```

Exit codes: 0 success, 1 failure or drift, 2 missing prerequisite or configuration.
Used by: developers (setup), `Initialize-PbiSuperpower.ps1`; the session-start hook suggests it when Superpowers is
missing.

### Initialize-GitHubRepo.ps1

One-time, idempotent GitHub setup: `git init` (if needed) and `core.hooksPath`, `gh repo create`, labels from
`config/github/labels.json`, the main-branch ruleset from `config/github/ruleset-main.json` (rulesets on private
repositories need GitHub Pro or Team; a warning otherwise) and, optionally, the GitHub Project from
`config/github/project.json`. Requires `gh auth login`.

| Parameter | Description |
|---|---|
| `-Owner` | GitHub user or organisation |
| `-Name` | Repository name (default `power-bi-superpower`) |
| `-Visibility` | `private` (default), `internal` or `public` |
| `-CreateProject` | Also create and link the GitHub Project (needs `gh auth refresh -s project`) |
| `-SkipRuleset` / `-SkipPush` | Skip the ruleset / the push of `main` |
| `-WhatIf` | Show every remote change without making it |

```powershell
pwsh -NoProfile -File scripts/bootstrap/Initialize-GitHubRepo.ps1 -Owner <owner> -Visibility private -CreateProject
```

Exit codes: 0 success, 1 a step failed, 2 missing prerequisite or invalid arguments.
Used by: the repository owner, once.

### Initialize-PbiSuperpower.ps1

One-command developer setup: prerequisites, tooling, agent plugins, `git config core.hooksPath .githooks`, scaffolds
missing reports from `report-blueprint.json`, runs the commit gate and prints the next steps.

| Parameter | Description |
|---|---|
| `-SkipInstall` | Skip `Install-PbiTooling.ps1` |
| `-SkipPlugins` | Skip `Install-AgentPlugins.ps1` |
| `-SkipReport` | Do not scaffold missing reports |

```powershell
pwsh -NoProfile -File scripts/bootstrap/Initialize-PbiSuperpower.ps1
```

Exit codes: 0 ready, 1 the quality gate or a setup step failed, 2 prerequisites missing.
Used by: developers after cloning (see `docs/getting-started/setup.md`).

## build

### New-PbipProject.ps1

Creates `src/<Name>/` from `templates/`: the TMDL semantic model (`<Name>.SemanticModel`, new logical and database
ids), `report-blueprint.json` and a README. Refuses when the folder exists.

| Parameter | Description |
|---|---|
| `-Name` | PascalCase name, `^[A-Z][A-Za-z0-9]{2,40}$` (for example `SalesStarter`) |
| `-Description` | One-line description |
| `-WithReport` | Also scaffold the report (`New-PbipReport.ps1`) |

```powershell
pwsh -NoProfile -File scripts/build/New-PbipProject.ps1 -Name Finance -Description 'Finance KPIs' -WithReport
```

Exit codes: 0 success, 1 report scaffolding failed, 2 usage error.
Used by: developers when a spec introduces a new project (see `docs/getting-started/first-sprint.md`).

### New-PbipReport.ps1

Scaffolds the PBIR report with the official `powerbi-report-author` CLI (never hand-written), lays out the visuals of
`report-blueprint.json` on the first page (12-column grid, deterministic visual folder names, title and alt text on
every visual) and validates the result with `powerbi-report-author validate`.

| Parameter | Description |
|---|---|
| `-ProjectPath` | Project folder, for example `src/SalesStarter` (mandatory) |
| `-Name` | Report and model base name (default: the folder name) |
| `-PageName` | First page name (default `Overview` or the blueprint's page name) |
| `-Blueprint` | Blueprint file (default `<ProjectPath>/report-blueprint.json`) |
| `-Force` | Re-scaffold an existing report |
| `-Offline` | Pass `--offline` to the CLI (for example when Desktop is older than the latest schema) |

```powershell
pwsh -NoProfile -File scripts/build/New-PbipReport.ps1 -ProjectPath src/SalesStarter
pwsh -NoProfile -File scripts/build/New-PbipReport.ps1 -ProjectPath src/SalesStarter -Force -Offline
```

Exit codes: 0 success, 1 the CLI failed (scaffold or validate), 2 usage/prerequisite error.
Used by: the `pbi-report-pbir` skill and the `pbi-report-engineer` agent; `Initialize-PbiSuperpower.ps1`.

## quality

### Invoke-PbiQualityGate.ps1

Runs the quality gate defined in `config/quality/gates.json` and records evidence.

| Level | Checks |
|---|---|
| L0 Structure and hygiene | `RepoHygiene`, `PbipStructure`, `TmdlConventions`, `PbirValidate`, `AgentAssets`, `McpParity`, `SuperpowersManifest` |
| L1 Static analysis | `ModelBpa`, `ReportConventions`, `ReportInspector` (optional) |
| L2 Behaviour | `DaxTests` |
| L3 Visual review (attended) | `Screenshots` |

Profiles: `commit` (L0), `pr` (L0-L2), `deploy-dev` and `deploy-test` (L0-L1), `release` (L0-L3). Check status is
`Passed`, `Failed`, `Warning` (passes), `Skipped` (fails the gate unless the check is optional or allowed with
`-AllowSkip`) or `NotApplicable` (passes).

| Parameter | Description |
|---|---|
| `-Profile` | `commit` (default), `pr`, `deploy-dev`, `deploy-test` or `release` |
| `-Level` | Run these levels instead of the profile (`L0,L1`) |
| `-Check` | Run exactly these checks (`ModelBpa,DaxTests`) |
| `-ProjectPath` | Limit project checks to these folders |
| `-Target` | `Local` (default, Power BI Desktop), `DEV`, `TEST` or `PROD` for `DaxTests` and `Screenshots` |
| `-AllowSkip` | Checks that may be skipped without failing (recorded in the evidence) |
| `-AttendedConfirmed` | A human reviewed the L3 screenshots |
| `-TenantId` | Tenant for service DAX tests |
| `-NoEvidence` | Do not write evidence (Git hooks) |
| `-Json` | Print the result object as JSON |

```powershell
pwsh -NoProfile -File scripts/quality/Invoke-PbiQualityGate.ps1 -Profile commit
pwsh -NoProfile -File scripts/quality/Invoke-PbiQualityGate.ps1 -Profile pr -Target Local
pwsh -NoProfile -File scripts/quality/Invoke-PbiQualityGate.ps1 -Check ModelBpa,DaxTests -Target Local
pwsh -NoProfile -File scripts/quality/Invoke-PbiQualityGate.ps1 -Profile release -Target Local -AttendedConfirmed
```

Exit codes: 0 passed, 1 failed, 2 configuration/usage error.
Used by: the `pbi-quality-gates` skill; the `pbi-quality-engineer`, `pbi-model-engineer` and `pbi-report-engineer`
agents; the pull request template; `.githooks/`; `Deploy-PbiProject.ps1` (in-process, profile from
`deployProfiles`).

### Invoke-PbiDaxTests.ps1

Runs the DAX tests of a project (`<Model>.SemanticModel/DAXQueries/*.<SCOPE>.Tests.dax`, scope `ALL`, `LOCAL`,
`DEV`, `TEST` or `PROD`; each query returns `TestName`, `ExpectedValue`, `ActualValue`, `Passed`) against Power BI
Desktop or a deployed model, prints PASS / FAIL / SLOW / SKIP per test and writes evidence.

Test files may start with directives (case-insensitive; other `//` comments are ignored):

```dax
// @role: Sales Region North
// @effectiveUserName: someone@contoso.com
```

`Local` adds `Roles=` and `EffectiveUserName=` to the connection; on service targets `@effectiveUserName` becomes
the executeQueries `impersonatedUserName`, and a file with `@role` is reported as **Skipped** (not supported by
executeQueries), not as failed.

| Parameter | Description |
|---|---|
| `-ProjectPath` | Project folder (optional when the repository has exactly one project) |
| `-Target` | `Local` (default; the `.pbip` must be open in Power BI Desktop), `DEV`, `TEST` or `PROD` |
| `-TenantId` | Tenant for service targets |
| `-Json` | Print the result object as JSON |

```powershell
pwsh -NoProfile -File scripts/quality/Invoke-PbiDaxTests.ps1 -ProjectPath src/SalesStarter -Target Local
pwsh -NoProfile -File scripts/quality/Invoke-PbiDaxTests.ps1 -ProjectPath src/SalesStarter -Target DEV
```

Exit codes: 0 no test failed (skipped tests are reported), 1 a test failed, 2 configuration/usage error (for
example Power BI Desktop is not running with the project open).
Used by: the `pbi-dax-tdd` and `pbi-sprint-start` skills, the `pbi-model-engineer` agent, the VS Code task; the
`DaxTests` gate check and `Deploy-PbiProject.ps1` use the same module function.

### Invoke-PbiModelBpa.ps1

Runs the Best Practice Analyzer of Tabular Editor 2 (Windows) on a TMDL model with the repository rules
(`config/quality/bpa-rules.json`) merged with the Microsoft rules when enabled, and compares the findings with the
`bpaMaxErrors` and `bpaMaxWarnings` thresholds. Output files are kept in `.evidence/bpa/`.

| Parameter | Description |
|---|---|
| `-SemanticModelPath` | The `*.SemanticModel` folder |
| `-RulesPath` | Rule files to use instead of the defaults |
| `-Json` | Print the result object as JSON |

```powershell
pwsh -NoProfile -File scripts/quality/Invoke-PbiModelBpa.ps1 -SemanticModelPath src/SalesStarter/SalesStarter.SemanticModel
```

Exit codes: 0 within thresholds, 1 thresholds exceeded, 2 prerequisite/usage error (not Windows, Tabular Editor 2
missing, rules or model not found).
Used by: the `pbi-semantic-model` skill; the `ModelBpa` gate check uses the same module function.

## infra

### Deploy-PbiInfrastructure.ps1

Infrastructure as code for an environment's workspace: creates it when missing, assigns the capacity, updates the
description and adds or updates the role assignments of `config/environments/<env>.json` (never removes any).
Enforces all guards of the environment first and writes evidence.

| Parameter | Description |
|---|---|
| `-Environment` | `DEV`, `TEST` or `PROD` |
| `-ReleaseIssue` | Release issue number (required for PROD) |
| `-TenantId` | Tenant to sign in to |
| `-WhatIf` | Plan only |
| `-Json` | Print the result object as JSON |

```powershell
pwsh -NoProfile -File scripts/infra/Deploy-PbiInfrastructure.ps1 -Environment DEV -WhatIf
pwsh -NoProfile -File scripts/infra/Deploy-PbiInfrastructure.ps1 -Environment DEV
```

Exit codes: 0 success, 1 a guard or a deployment step failed, 2 configuration/usage error.
Used by: the `pbi-deploy` skill and the `pbi-release-manager` agent (DEV/TEST); PROD by humans.

### Deploy-FabricCapacity.ps1

**Human-only.** Creates a Fabric capacity (Azure resource, Az.Fabric) or changes its SKU. Capacities are shared by
all environments, so agents are blocked from running this script.

| Parameter | Description |
|---|---|
| `-SubscriptionId`, `-ResourceGroupName` | Where the capacity lives |
| `-Name` | Capacity name (lower-case letters and digits, 3-63 characters) |
| `-Location` | Azure region, for example `westeurope` |
| `-Sku` | `F2` (default) to `F2048` |
| `-AdministrationMember` | Capacity administrators (user principal names or service principal object ids) |
| `-Tag` | Azure tags |
| `-TenantId` | Tenant to sign in to |
| `-WhatIf` | Plan only |

```powershell
pwsh -NoProfile -File scripts/infra/Deploy-FabricCapacity.ps1 -SubscriptionId <subscription> -ResourceGroupName <rg> -Name <capacity> -Location westeurope -Sku F2 -AdministrationMember <admin upn> -WhatIf
```

Exit codes: 0 success, 1 an Azure operation failed, 2 usage/prerequisite error.
Used by: capacity administrators (see `.github/skills/pbi-deploy/references/first-time-setup.md`).

### Set-FabricCapacityState.ps1

**Human-only.** Resumes (`Active`) or pauses (`Paused`) a Fabric capacity to control cost. Pausing makes every
workspace on the capacity unavailable.

| Parameter | Description |
|---|---|
| `-SubscriptionId`, `-ResourceGroupName`, `-Name` | The capacity |
| `-State` | `Active` or `Paused` |
| `-TenantId` | Tenant to sign in to |
| `-WhatIf` | Plan only |

```powershell
pwsh -NoProfile -File scripts/infra/Set-FabricCapacityState.ps1 -SubscriptionId <subscription> -ResourceGroupName <rg> -Name <capacity> -State Paused
```

Exit codes: 0 success, 1 the Azure operation failed or the capacity was not found, 2 usage/prerequisite error.
Used by: capacity administrators (see `docs/runbooks/deploy.md`).

## deploy

### Deploy-PbiProject.ps1

Deploys the PBIP projects of `config/environments/<env>.json` with the Fabric REST APIs:

1. Loads the configuration and enforces the environment guards (PROD: typed confirmation by a human, clean tree,
   commit merged to main, passing TEST evidence for the same commit, `-ReleaseIssue` with `gate:release-approved`).
2. Runs the quality gate in-process (profile from `gates.json` `deployProfiles`).
3. Ensures the workspace (unless `-SkipInfrastructure`).
4. Per project: publishes the semantic model with its Power Query parameters, refreshes it, publishes the reports
   bound to the deployed model.
5. Runs the DAX tests against the deployed model (unless `-SkipTests`).
6. Writes evidence with the item ids and prints a masked markdown summary for the pull request or release issue.

| Parameter | Description |
|---|---|
| `-Environment` | `DEV`, `TEST` or `PROD` |
| `-Project` | Deploy only these projects (`src/SalesStarter` or `SalesStarter`) |
| `-ReleaseIssue` | Release issue number (required for PROD) |
| `-TenantId` | Tenant to sign in to |
| `-SkipInfrastructure` | Do not create or update the workspace (it must exist) |
| `-SkipRefresh` | Do not refresh the models |
| `-SkipTests` | Do not run the post-deployment DAX tests (such evidence does not unlock PROD) |
| `-WhatIf` | Plan only: reads the service, changes nothing |
| `-Json` | Print the result object as JSON |

```powershell
pwsh -NoProfile -File scripts/deploy/Deploy-PbiProject.ps1 -Environment DEV -WhatIf
pwsh -NoProfile -File scripts/deploy/Deploy-PbiProject.ps1 -Environment DEV
pwsh -NoProfile -File scripts/deploy/Deploy-PbiProject.ps1 -Environment TEST            # after merge, on main
pwsh -NoProfile -File scripts/deploy/Deploy-PbiProject.ps1 -Environment PROD -ReleaseIssue <n>   # humans only
```

Exit codes: 0 success, 1 a guard, the gate or a deployment step failed, 2 configuration/usage error.
Used by: the `pbi-deploy` skill, the `pbi-release-manager` and `pbi-quality-engineer` agents (DEV and TEST), the VS
Code task; PROD by the release approver (see `docs/runbooks/deploy.md`).

## sprint

### New-PbiSprint.ps1

Starts a sprint (idempotent): milestone `Sprint NN` with the goal and due date, `docs/sprints/sprint-NN/sprint.md`
from the template, `docs/sprints/current.json` (read by the session-start hook) and the tracking issue
(`type:sprint`).

| Parameter | Description |
|---|---|
| `-Number` | Sprint number (1-99) |
| `-Goal` | Sprint goal (one sentence) |
| `-StartDate` | First day (default: next Monday) |
| `-LengthDays` | Length in business days (default 10) |
| `-EndDate` | Last day (instead of `-LengthDays`) |
| `-Repo` | `owner/name` (default: the current repository) |
| `-WhatIf` | Show what would be created |

```powershell
pwsh -NoProfile -File scripts/sprint/New-PbiSprint.ps1 -Number 1 -Goal 'Sales overview report in TEST'
```

Exit codes: 0 success, 1 a GitHub call failed, 2 usage/prerequisite error.
Used by: the `pbi-sprint-start` skill.

### Get-PbiSprintStatus.ps1

Shows the issues of a sprint milestone grouped by `phase:*` label and state, the approval gates (`gate:*` labels)
and issues without a phase.

| Parameter | Description |
|---|---|
| `-Number` | Sprint number (default: `docs/sprints/current.json`) |
| `-Repo` | `owner/name` (default: the current repository) |
| `-Json` | Print the result object as JSON |

```powershell
pwsh -NoProfile -File scripts/sprint/Get-PbiSprintStatus.ps1
pwsh -NoProfile -File scripts/sprint/Get-PbiSprintStatus.ps1 -Number 2 -Json
```

Exit codes: 0 success, 2 usage/prerequisite error (no current sprint, `gh` missing or not signed in).
Used by: the `pbi-sprint-lead` agent, the `pbi-sprint-review` and `pbi-sprint-start` skills, the VS Code task.

## hooks

Agent hooks for the GitHub Copilot CLI and VS Code agent mode, registered in `.github/hooks/pbi-guardrails.json`.
They are compatible with Windows PowerShell 5.1 and PowerShell 7, print ASCII-only JSON and always exit 0.

| Script | Event | Behaviour |
|---|---|---|
| `Test-PreToolUse.ps1` | `preToolUse` | Reads the tool call (JSON on stdin), applies the guardrail rules and prints `{"permissionDecision":"deny","permissionDecisionReason":"..."}` when a rule matches (nothing otherwise). Denials are logged to `.evidence/hook-audit.jsonl` with identifiers masked. Fails open on internal errors. |
| `Invoke-SessionStart.ps1` | `sessionStart` | Prints `{"additionalContext":"..."}` (at most 1,500 characters): working rules, the current sprint and a warning when Superpowers is not installed. |
| `GuardrailRules.ps1` | - | The rules, dot-sourced by `Test-PreToolUse.ps1` and the tests (`Get-PbiToolUseDecision`). |

| Rule | Denies | Reason given to the agent |
|---|---|---|
| R1 | PROD deployments and capacity changes | Human-only; prepare the release issue and hand over to the release approver |
| R2 | `git push` to main (also a plain push while main is checked out) and force pushes | Push your feature branch and open a pull request |
| R3 | Destructive remote calls (HTTP DELETE, `Remove-Pbi*`, capacity deletion, `gh ... delete`) | Ask a maintainer |
| R4 | Applying `gate:*` approval labels | Ask the product owner or release approver |
| R5 | Reading or writing secret files (`.env*` except `.env.example`, `*.pfx`, `*.pem`, `*.key`, `*.publishsettings`, `id_rsa`) | Use environment variables or a key vault |
| R6 | Unrestricted Copilot sessions (`--allow-all-tools`, `--allow-all`, `--yolo`) | Use explicit `--allow-tool` / `--deny-tool` lists |
| R7 | Merging pull requests (`gh pr merge`, `merge_pull_request` tools) | Merging is a human decision; ask a maintainer to review and merge |

The hooks are a safety net for agents, not a security boundary: the main-branch ruleset, CODEOWNERS and the PROD
guards in the scripts remain the real controls.

Try a rule:

```powershell
'{"toolName":"bash","toolArgs":"{\"command\":\"gh pr merge 12\"}"}' | pwsh -NoProfile -File scripts/hooks/Test-PreToolUse.ps1
```

## Git hooks

Enabled with `git config core.hooksPath .githooks` (done by `Initialize-PbiSuperpower.ps1` and
`Initialize-GitHubRepo.ps1`). Both need `pwsh` on PATH.

| Hook | Runs |
|---|---|
| `pre-commit` | `Invoke-PbiQualityGate.ps1 -Profile commit -Check RepoHygiene,AgentAssets -NoEvidence` (fast) |
| `pre-push` | `Invoke-PbiQualityGate.ps1 -Profile commit -NoEvidence` (all L0 checks) |

## Module PbiSuperpower

`scripts/modules/PbiSuperpower/` holds the shared logic; the scripts are thin entry points. Import it to use the
functions interactively:

```powershell
Import-Module ./scripts/modules/PbiSuperpower/PbiSuperpower.psd1 -Force
Get-Command -Module PbiSuperpower
```

| Area | Functions |
|---|---|
| Logging and helpers | `Write-PbiLog`, `Write-PbiWarning`, `Invoke-PbiNativeCommand`, `Read-PbiJsonFile`, `Get-PbiProperty`, `Get-PbiContentHash`, `Protect-PbiText`, ... |
| Configuration | `Get-PbiRepoRoot`, `Get-PbiEnvironmentConfig`, `Expand-PbiPlaceholder`, `Get-PbiGateConfig`, `Get-PbiToolVersions`, `Get-PbiProject` |
| Git and guards | `Get-PbiGitContext`, `Assert-PbiDeploymentGuard`, `Invoke-PbiGh` |
| Fabric and Power BI REST | `Connect-PbiFabric`, `Get-PbiAccessToken`, `Invoke-PbiFabricApi`, `Invoke-PbiFabricApiPaged`, `Get-PbiCapacity`, `Get-PbiWorkspace`, `Deploy-PbiWorkspace`, `Get-PbiItem` |
| Definitions and publishing | `Get-PbipDefinitionPart`, `Set-PbipSemanticModelParameter`, `Set-PbipReportBinding`, `Publish-PbiSemanticModel`, `Publish-PbiReport`, `Invoke-PbiDatasetRefresh` |
| DAX | `Invoke-PbiDaxQuery`, `Get-PbiDesktopInstance`, `Import-PbiAdomdClient`, `Invoke-PbiLocalDaxQuery`, `Get-PbiDaxTestFile`, `Get-PbiDaxTestDirective`, `Invoke-PbiDaxTestSuite` |
| Checks and gate | `Test-PbiRepoHygiene`, `Test-PbipProjectStructure`, `Test-PbiTmdlConvention`, `Test-PbiReportConvention`, `Test-PbiAgentAsset`, `Test-PbiMcpConfigParity`, `Test-PbiModelBpa`, `Test-PbiSuperpowersManifest`, `Test-PbiQualityGate` |
| Evidence | `New-PbiEvidence`, `ConvertTo-PbiEvidenceMarkdown` |

Every exported function has comment-based help (`Get-Help Invoke-PbiFabricApi -Full`). Tests:
`Invoke-Pester -Path tests/powershell -Output Detailed` (see `tests/powershell/README.md`).
