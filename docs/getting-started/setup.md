# Setup (Windows workstation)

Everything runs locally; GitHub Actions are not used. Separate **workstation setup**, **Desktop authoring proof** and **service delivery proof**. Installing tools alone is not readiness. Start with the [measured baseline and blockers](../analysis/development-readiness.md).

Run commands below from the repository root in PowerShell 7. A new clone of the current default branch may not yet contain the imported factory files: they require a reviewed initial PR.

## 1. Install the prerequisites

| Tool | Install | Why |
|---|---|---|
| PowerShell 7.4+ | `winget install Microsoft.PowerShell` | All scripts |
| Git for Windows | `winget install Git.Git` | Git, plus the bash that the Superpowers SessionStart hook needs |
| GitHub CLI ≥ 2.90 | `winget install GitHub.cli`, then `gh auth login` | Repository bootstrap, milestones, sprint scripts |
| Node.js 22 or later | `winget install OpenJS.NodeJS.LTS` | MCP servers (`npx`) and Power BI report CLIs; check compatibility when selecting versions |
| GitHub Copilot CLI | `winget install GitHub.Copilot` (or `npm i -g @github/copilot`) | Agents in the terminal, plugins |
| VS Code | `winget install Microsoft.VisualStudioCode` | Agent mode, MCP, editing |
| Current Power BI Desktop with PBIP, TMDL and PBIR support | Microsoft Store or organization-managed installer | Authoring, local DAX tests, screenshots |

Use a short checkout path such as `C:\src\power-bi-superpower`. Enable Git long paths for this checkout with `git config core.longpaths true`. An administrator can review the Windows `LongPathsEnabled` setting; do not change organization policy or assume Git configuration removes Desktop path limits.

A GitHub Copilot licence with access to Copilot CLI and agent mode is required.

## 2. Choose the correct repository setup path

### Existing checkout or fork

Do **not** run the repository-creation script again. It creates/configures a remote and can push source. Inspect your working tree and remote, sign in if necessary, then continue with the tooling plan:

```powershell
git status --short
git remote -v
gh auth login
pwsh -NoProfile -File .\scripts\sprint\Get-PbiSprintStatus.ps1
```

With no active sprint, status exits **2** and directs you to `/pbi-sprint-start`. This does not create a sprint. The product owner must first agree the goal, scope and capacity.

### New GitHub repository (human bootstrap)

Only when deliberately creating a new repository, review the script and substitute your own owner. Do not copy an existing maintainer's account:

```powershell
$owner = 'your-github-owner'
gh auth login
gh auth refresh -s project
pwsh -NoProfile -File .\scripts\bootstrap\Initialize-GitHubRepo.ps1 -Owner $owner -Name power-bi-superpower -Visibility private -CreateProject -WhatIf
# Human: review the plan before running without -WhatIf.
```

The non-WhatIf script initializes Git, sets Git hooks, creates/configures the repository and can push; it also provisions labels, a ruleset and a Project. Private-repository rulesets depend on the GitHub plan. Agents must not run a bootstrap that pushes to `main`.

Set the intended reviewers in [CODEOWNERS](../../.github/CODEOWNERS), and verify ruleset/Project results instead of treating warnings as success.

### Downloaded scripts and execution policy

For a trusted archive, unblock the archive **before** extracting it:

```powershell
Unblock-File .\power-bi-superpower.zip
Expand-Archive .\power-bi-superpower.zip -DestinationPath C:\src
```

If already extracted, inspect `Get-ExecutionPolicy -List` and the affected file's `Zone.Identifier`. Under `RemoteSigned`, after trusting/reviewing this source, unblock only the delivered automation:

```powershell
Get-ChildItem -LiteralPath .\scripts,.\tests\powershell -Recurse -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' } |
    Unblock-File
```

Do not use `Set-ExecutionPolicy`, `-ExecutionPolicy Bypass` or indirect script execution to defeat signing controls. If MachinePolicy/UserPolicy requires signatures, ask the administrator for the approved signing process.

## 3. Plan tooling, then prove it

```powershell
pwsh -NoProfile -File .\scripts\bootstrap\Test-Prerequisites.ps1
pwsh -NoProfile -File .\scripts\bootstrap\Install-PbiTooling.ps1 -WhatIf
pwsh -NoProfile -File .\scripts\bootstrap\Install-AgentPlugins.ps1 -WhatIf
copilot plugin list
```

The tooling installer supplies Az.Accounts, Pester, optional Az.Fabric, the report/bridge npm CLIs, Tabular Editor 2, BPA rules and ADOMD. See [tool version policy](../../tools/README.md): not every dependency is exactly pinned, and an already installed plugin is not automatically reconciled to the vendoring ref.

After the tool selection has been reviewed:

```powershell
pwsh -NoProfile -File .\scripts\bootstrap\Install-PbiTooling.ps1
pwsh -NoProfile -File .\scripts\bootstrap\Install-AgentPlugins.ps1
pwsh -NoProfile -File .\scripts\bootstrap\Test-Prerequisites.ps1
copilot plugin list
```

Record actual versions, not just package availability. Restart the agent session after installing plugins. Required skills are Superpowers plus Microsoft's `semantic-model-authoring` and `powerbi-report-cli`; `power-bi-development` is optional.

The convenience `Initialize-PbiSuperpower.ps1` also sets `core.hooksPath`, scaffolds missing reports and runs the commit gate. It is **not** the read-only setup check and does not replace human plan approval. Use it only during approved walking-skeleton implementation, or select `-SkipReport` while preparing tooling. Resolve the [known baseline failures](../analysis/development-readiness.md#proposed-readiness-backlog) before expecting it to finish green.

## 4. Open the repository with the agents

**VS Code:** `code .` → review workspace trust → open Chat in **Agent** mode. Inspect `MCP: List Servers`, the eight `pbi-*` agents and the twelve repository skills. Use `using-superpowers`, then `pbi-sprint-flow`. Installed assets may need a new session before discovery.

**Modeling MCP:** the Microsoft authoring plugin can bundle a local server as well as the repository registration. Choose **one local authoring registration** and keep agent tool names aligned. Do not enable both `powerbi-authoring-local` and `powerbi-modeling-mcp` aliases for the same work, or both hosted and local variants. The hosted endpoint cannot reach local Desktop/PBIP files. A **human** must review and accept the EULA; an agent must not set an acceptance flag or environment variable.

**Copilot CLI:** run `copilot` in the repository root and confirm folder trust (project MCP servers and hooks only load in trusted folders). Useful commands: `/plugin list`, `/skills`, `/agent`, `/mcp`. Programmatic example:
```powershell
copilot --agent pbi-sprint-lead -p "Show the sprint status" --allow-tool 'shell(pwsh:*)' --allow-tool 'shell(git:*)' --allow-tool 'shell(gh:*)'
```
Never use `--allow-all-tools` or `--yolo` here. Repository hooks are defense in depth, not a substitute for human gates or least-privilege tool permissions.

Verify the layers separately:

| Layer | Safe proof |
|---|---|
| Learn / Fabric documentation | Read-only documentation query succeeds |
| Modeling | After human licence acceptance, discover/connect to SalesStarter in Desktop without changing it |
| GitHub | Read the intake issue; verify host permissions before allowing work-management writes |
| Playwright | Browser smoke is distinct from rendering a real DEV/TEST report |
| Hooks | Run inert Pester fixtures, then verify actual host dispatch and failure behavior; never attempt a real forbidden operation |

## 5. Complete the local readiness proof

After human-approved spec/plan tasks:

1. Repair the failing automation regression tests; confirm every existing test passes.
2. Resolve the Sprint 0 numbering mismatch described in the [first-sprint guide](first-sprint.md).
3. Scaffold SalesStarter with the official CLI, open the resulting PBIP in Desktop, refresh, run local DAX tests and the PR gate.
4. Have a human review screenshots. No report folder means report checks are NotApplicable, **not** evidence that authoring works.
5. Review the intended files on a branch and rerun hygiene over staged/tracked source. The initial local import is mostly untracked.

## 6. Connect DEV after local proof and approvals

1. Copy `.env.example` to `.env.local` and set approved capacity/group values. Never paste them into tracked files or evidence comments.
2. Have the tenant/workspace owners verify [first-time service prerequisites](../../.github/skills/pbi-deploy/references/first-time-setup.md), licence/capacity and access.
3. A human signs in, if necessary, with `Connect-AzAccount`; agents do not handle credentials.
4. Plan infrastructure and the project deployment:

```powershell
pwsh -NoProfile -File .\scripts\infra\Deploy-PbiInfrastructure.ps1 -Environment DEV -WhatIf
pwsh -NoProfile -File .\scripts\deploy\Deploy-PbiProject.ps1 -Environment DEV -WhatIf
# After review/authorization, the project deploy also ensures its infrastructure:
pwsh -NoProfile -File .\scripts\deploy\Deploy-PbiProject.ps1 -Environment DEV
```

`-WhatIf` is not provisioning. The real project deployment ensures the workspace, publishes definitions, refreshes and runs post-deployment tests. Record its masked summary. TEST follows human merge on clean `main`; PROD is human-only. See the [deployment runbook](../runbooks/deploy.md).

## 7. Record the result, not just the command

```powershell
pwsh -NoProfile -File .\scripts\bootstrap\Test-Prerequisites.ps1
pwsh -NoProfile -Command "Invoke-Pester -Path .\tests\powershell -Output Detailed"
pwsh -NoProfile -File .\scripts\quality\Invoke-PbiQualityGate.ps1 -Profile commit
pwsh -NoProfile -File .\scripts\quality\Invoke-PbiQualityGate.ps1 -Profile pr -Target Local
```

Exit codes for repository scripts: **0** passed, **1** failed, **2** prerequisite/usage error. Required skipped checks block a gate. Pester reports failures separately; use a `-PassThru` result and check `FailedCount` when scripting it. Do not infer success from the last statement of a multi-command shell.

Paste masked `.evidence/*.md` summaries into the PR with the source revision and dirty/staged state. The PR profile is L0-L2; attended screenshots are L3, included by the release profile. Then continue with the [first-sprint walkthrough](first-sprint.md).
