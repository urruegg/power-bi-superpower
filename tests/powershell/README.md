# PowerShell tests

Pester 5 tests for the automation layer: the `PbiSuperpower` module (`scripts/modules/PbiSuperpower`) and the agent
guardrail hooks (`scripts/hooks`). They run **offline** on Windows, Linux and macOS. Nothing calls Fabric, Power BI,
Azure, GitHub or Power BI Desktop: `Invoke-WebRequest`, `Get-PbiAccessToken`, `Start-Sleep`, `Invoke-PbiDaxQuery`
and `Invoke-PbiLocalDaxQuery` are mocked, and fixtures are created in Pester's `TestDrive:`.

## Requirements

| Requirement | Version | Install |
|---|---|---|
| PowerShell | 7.4 or later | `winget install --id Microsoft.PowerShell` |
| Pester | 5.5.0 or later | `Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck` |

`scripts/bootstrap/Install-PbiTooling.ps1` installs the pinned Pester version from `tools/versions.json`.
Windows ships Pester 3.4 with Windows PowerShell; the tests need Pester 5, so run them in `pwsh`.

## Run

From the repository root:

```powershell
Invoke-Pester -Path tests/powershell -Output Detailed
```

One file, or one test by name:

```powershell
Invoke-Pester -Path tests/powershell/Guardrails.Tests.ps1 -Output Detailed
Invoke-Pester -Path tests/powershell -FullNameFilter '*R7*' -Output Detailed
```

Result file for a pull request or a release issue (NUnit XML):

```powershell
$config = New-PesterConfiguration
$config.Run.Path = 'tests/powershell'
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = '.evidence/pester-results.xml'
Invoke-Pester -Configuration $config
```

`.evidence/` is git-ignored. Run the tests after every change to `scripts/` and before opening a pull request that
touches the module, the hooks or the scripts.

## What is covered

| File | Covers |
|---|---|
| `PbiSuperpower.Config.Tests.ps1` | `Get-PbiProperty` (case-insensitive, defaults, StrictMode-safe, arrays); `Expand-PbiPlaceholder` (nested objects and arrays, optional entries dropped with a warning, one error listing every missing variable); `Get-PbiEnvironmentConfig` (`.env.local`, deep merge with `<env>.local.json`, empty variables, required fields). |
| `PbiSuperpower.Definition.Tests.ps1` | `Get-PbipDefinitionPart` (default exclusions, ordering, forward slashes, exact base64 round trip); `Set-PbipReportBinding` (2.0.0 and 1.0.0 `definition.pbir` schemas, `byPath` removal, input not modified); `Set-PbipSemanticModelParameter` (text, number, decimal, boolean, quoted names, missing parameter throws). |
| `PbiSuperpower.Checks.Tests.ps1` | Repository hygiene on a fixture repository (GUIDs, secrets, tracked secret files, service connections, e-mail addresses); TMDL conventions (missing `formatString` = Error, missing `///` = Warning, `ref` mismatches, indentation, compatibility level, duplicate lineage tags); report conventions (overlap, legacy card, alt text, titles, visuals per page); agent asset lint; MCP configuration parity. |
| `PbiSuperpower.DaxTests.Tests.ps1` | Test file selection per target; `// @role:` and `// @effectiveUserName:` directives; column name normalisation; `Passed` parsing; executeQueries request (impersonation, `includeNulls`); role tests reported as Skipped on service targets; query errors, slow queries and local connection options. |
| `PbiSuperpower.FabricApi.Tests.ps1` | `Invoke-PbiFabricApi` with a mocked `Invoke-WebRequest`: 429 retry with `Retry-After`, bearer token and UTF-8 JSON body, Power BI base URL, 202 long-running operations (Running, Succeeded, result; Failed), `-NoLongRunning`, masked error messages, retry limit; `Invoke-PbiFabricApiPaged` (`continuationToken`, `continuationUri`, empty lists). |
| `Guardrails.Tests.ps1` | Every deny rule R1-R7 of `scripts/hooks/GuardrailRules.ps1` with positive and negative cases, including normal commands that must stay allowed (`pwsh scripts/deploy/Deploy-PbiProject.ps1 -Environment DEV`, `git push origin feature/x`); `git push` while `main` is checked out; end-to-end runs of `Test-PreToolUse.ps1` (Copilot CLI and VS Code input shapes, invalid input, audit log with masked identifiers) and `Invoke-SessionStart.ps1` (ASCII-only JSON, at most 1,500 characters). The end-to-end tests start a child `pwsh` process. |

## Writing tests

- Import the module in `BeforeAll`:
  `Import-Module "$PSScriptRoot/../../scripts/modules/PbiSuperpower/PbiSuperpower.psd1" -Force`.
- Mock external calls inside the module with `-ModuleName PbiSuperpower`, for example
  `Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -MockWith { ... }`. Never call a real service.
- Build fixtures under `TestDrive:`; never read or write the working tree.
- Use `InModuleScope` only for private functions, and `Should -Throw -ExpectedMessage '*...*'` for errors.
- Do not put real tenant, workspace, capacity or object identifiers, e-mail addresses or secrets in tests. Use
  obviously fake values (`11111111-2222-3333-4444-555555555555`, `user@contoso.com`); the repository hygiene check
  skips `tests/**` but reviewers do not.
