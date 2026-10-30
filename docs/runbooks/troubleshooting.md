# Troubleshooting

Before changing anything, reproduce the failure, record the exact child-command exit code and compare the [readiness baseline](../analysis/development-readiness.md). Do not relax a gate, accept a licence for the user or attempt a forbidden write to test a guard.

| Symptom | Likely cause | Fix |
|---|---|---|
| Script "is not digitally signed" under RemoteSigned | Downloaded-file `Zone.Identifier` | Follow [trusted-download setup](../getting-started/setup.md#downloaded-scripts-and-execution-policy). Do not bypass an enforced signing policy |
| `Cannot bind argument to parameter 'List' because it is an empty collection` | Known `Add-PbiFinding` first-finding regression | Track R01 in [intake #1](../analysis/development-readiness.md#proposed-readiness-backlog); implement with regression tests after plan approval. It is not a reason to suppress checks |
| Sprint 0 cannot be created or status treats it as missing | Scripts currently require numbers 1-99 | Agree numbered Sprint 01 or approve consistent zero support; see [sprint setup](../sprints/README.md) |
| Installer `-WhatIf` exits 0 but a tool is still missing | Only the plan ran | Review/authorize the install, run without `-WhatIf`, then verify actual version and functionality |
| Agent does not follow Superpowers | Plugin not installed or session started before install | `copilot plugin list`; `pwsh scripts/bootstrap/Install-AgentPlugins.ps1`; start a new session |
| SessionStart hook error on Windows | Git for Windows bash missing (Superpowers hook) | Install Git for Windows; `Test-Prerequisites.ps1` |
| `pbi-*` skills or agents not visible | Folder not trusted (CLI) or old VS Code | Trust the folder; update VS Code / Copilot CLI |
| MCP server fails to start (`npx` not found) | PATH or Windows `.cmd` shim | Use `"command": "cmd", "args": ["/c", "npx", …]` in the MCP config, or install Node 22 |
| Modeling MCP tools all blocked | Licence (EULA) not accepted | A human reads and decides on the terms. Agents must not set acceptance flags or environment variables |
| Two overlapping Modeling MCP tool sets | Plugin-bundled server plus repository registration | Keep one local server and align agent references; do not mix local/hosted authoring paths |
| Modeling MCP edits not visible in Git | Desktop not saved | Save in Desktop (Ctrl+S) — TMDL is written on save |
| TMDL edits not visible in Desktop | Desktop open during file edits | `powerbi-report-author preview "<Report>" --host desktop --reload-with-model` or reopen Desktop |
| "This version of Power BI does not support the version you have provided" | Scaffolded schema newer than your Desktop | Update Desktop, or `New-PbipReport.ps1 -Force -Offline` |
| Report opens with "can't connect" | `definition.pbir` changed to `byConnection` in Git | Restore `byPath` (`../<Project>.SemanticModel`) |
| `DaxTests` skipped (Local) | Desktop not running the project | Open `src/<Project>/<Project>.pbip`; one window only |
| `PbirValidate` is NotApplicable | No report has been scaffolded | This is not a report pass. Complete the approved scaffold task, then validate/render the report |
| `RepoHygiene` passed but imported files are untracked | Check uses `git ls-files` | Review/stage intended source on the approved branch and rerun before committing; do not blindly add the whole tree |
| `ModelBpa` skipped | Tabular Editor 2 not installed or not Windows | `Install-PbiTooling.ps1`; run on Windows |
| `RepoHygiene` fails on a GUID | ID in a tracked file | Use `${env:NAME}`; add `pbi-allow-guid` comment only for public, non-sensitive GUIDs |
| 401 from Fabric API | Expired sign-in / wrong audience | `Connect-AzAccount`; retry |
| 403 / insufficient privileges | Missing workspace or capacity role | Ask the admin |
| Post-deploy tests fail with "not allowed" | Tenant setting *Dataset Execute Queries REST API* off | Ask the Fabric admin |
| Refresh fails with credentials | Source credentials not configured | Human configures in the service |
| Hook denies a legitimate command | Rule too broad | Open an `area:agent-assets` issue; adjust `scripts/hooks/GuardrailRules.ps1` with a Pester case |
| Ruleset creation fails (403/422) | Private repo on a plan without rulesets | Upgrade plan or protect `main` manually |
| CRLF/LF noise in diffs | Git `core.autocrlf` | `git config core.autocrlf true` on Windows; `.gitattributes` normalises |

## Baseline vs regression

The intake run found **160 passed / 20 failed / 0 skipped** Pester tests, commit/PR gate failures, missing tools and no loaded Desktop model. Those are existing blockers, not proof that documentation changes broke automation. After a code fix, rerun the focused tests and full relevant gate; do not carry the baseline's failing evidence forward as readiness evidence.
