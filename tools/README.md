# Tool versions and installation evidence

[versions.json](versions.json) declares the tooling used by the bootstrap scripts. **Not every entry is an exact pin:** npm/MCP references use `latest`, PowerShell modules have minimum versions, and the Superpowers ref pins vendoring rather than the installed plugin. See the [readiness intake](../docs/analysis/development-readiness.md#tool-inventory) for measured versions and missing dependencies.

The [tool installer](../scripts/bootstrap/Install-PbiTooling.ps1) records installation details in git-ignored `tools/.bin/installed.json`, including hashes for downloaded binary archives. That manifest is not a lockfile for every plugin or MCP server. The [plugin installer](../scripts/bootstrap/Install-AgentPlugins.ps1) skips already installed plugins; it does not automatically upgrade them to the Superpowers vendoring ref.

| Entry | Why | Upgrade rule |
|---|---|---|
| `superpowers` | Engineering methodology (brainstorming → plans → TDD → review → finish) | Upgrade through a PR; read the release notes; re-run Sprint 0 smoke checks |
| `plugins` | Copilot CLI / VS Code agent plugins: Superpowers, Microsoft `powerbi-authoring` (semantic-model-authoring + powerbi-report-cli skills, Power BI Modeling MCP), optional awesome-copilot `power-bi-development` | Same |
| `npm.globalCli` | `powerbi-report-author` (scaffold, validate, preview, screenshots) and `powerbi-desktop` (Desktop bridge) | Microsoft asks for `@latest`; record the version you used in the PR evidence |
| `psModules` | Az.Accounts (tokens), Pester (tests), Az.Fabric (optional capacity IaC) | Minimum versions |
| `tabularEditor2` | Best Practice Analyzer CLI (MIT, Windows) | Pin exact version |
| `bpaRules` | Microsoft's public BPA rule set, merged with `config/quality/bpa-rules.json` | Review rule changes |
| `adomd` | ADOMD.NET client used to run DAX tests against the local Power BI Desktop engine | Pin exact version |
| `fabInspector` | Optional PBIR rule engine (community). Set `url` to a release asset to enable | Optional |

## Verify before relying on a tool

```powershell
pwsh -NoProfile -File .\scripts\bootstrap\Test-Prerequisites.ps1
pwsh -NoProfile -File .\scripts\bootstrap\Install-PbiTooling.ps1 -WhatIf
copilot plugin list
```

For a selected missing tool, review the plan, install with the repository script and record its actual version plus a functional smoke test. Registry metadata only proves availability; `Get-Command` only proves discoverability. A report CLI must actually scaffold/validate; a Modeling MCP must connect after human licence acceptance. Do not upgrade unrelated user plugins.

Reconcile floating references through a PR with compatibility evidence. Review versions monthly; changes to the dependency policy still require the appropriate reviewers.
