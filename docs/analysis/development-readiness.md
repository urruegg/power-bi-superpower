# Development readiness intake

**Assessed:** 2026-10-30

**Intake:** [#1](https://github.com/urruegg/power-bi-superpower/issues/1), `phase:intake`, awaiting human acceptance

**Verdict:** ready for readiness planning; **not ready for report development or deployment**

**Scope:** the existing, dirty local working tree at HEAD `27faa18`; not a verified published release

## Outcome and boundaries

Make it possible for a contributor to move a Power BI idea through an approved specification and plan, build a tested TMDL model and PBIR report, and prove the same artifact in Desktop, DEV and TEST. Keep all `gate:*` approvals, merges and PROD execution human-owned. Do not add GitHub Actions.

The supplied **Power BI Superpower - Capability Analysis.md** was SHA-256 compared with [the repository analysis](capability-analysis.md): the files were byte-identical before this intake. There was no separate patch to import. The analysis is retained as the dated input; the observations below distinguish its intended capabilities from the actual workstation and repository state.

Assumptions: SalesStarter is the synthetic walking skeleton; real customer data is out of scope; owners, dates and team capacity must be agreed by humans. No sprint has been activated, specification approved or implementation plan approved.

## Brainstorming decision

| Approach | Benefit | Cost / risk | Recommendation |
|---|---|---|---|
| Documentation only | Fast onboarding clarification | Leaves failing checks and missing tools | Useful slice, insufficient outcome |
| Evidence-gated readiness sprint | Repairs the baseline, then proves Desktop and DEV/TEST separately | Needs human decisions, licence review and workstation/service setup | **Recommended** |
| Build a real report immediately | Appears to deliver business output sooner | Failing baseline, unverified tooling and missing approvals make progress unreliable | Do not start |

Decompose the recommended approach into offline automation readiness, attended Desktop proof, then DEV/TEST proof. These are proposed work packages, **not approved implementation tasks**.

Provisional intake score: Value 5 x Reach 4 x Confidence 0.8 / Effort 3 = **5.3**. Reach means recurring contributor workflow, not a measured user count; effort is an estimate pending decomposition. Recommend accept candidate. Product owner acceptance into `phase:spec` is still required.

## Verification results

Commands ran from the repository root in PowerShell 7.6.9. Explicit markers below report each child command's exit code, not the exit code of a later successful shell statement.

| Check / exact command | Observed result |
|---|---|
| `pwsh -NoLogo -NoProfile -File .\scripts\sprint\Get-PbiSprintStatus.ps1` | **Exit 2:** no current sprint; `current.json` absent |
| `gh issue list --repo urruegg/power-bi-superpower --state all --limit 30 --json number,title,state,labels` | Exit 0; empty before intake #1 was created |
| `gh api 'repos/urruegg/power-bi-superpower/milestones?state=all&per_page=30'` | Exit 0; no milestones |
| `pwsh -NoLogo -NoProfile -File .\scripts\bootstrap\Test-Prerequisites.ps1` | **Exit 2:** required Az.Accounts missing |
| `Import-Module Pester -MinimumVersion 5.5.0; $result = Invoke-Pester -Path .\tests\powershell -Output Detailed -PassThru` | **180 tests: 160 passed, 20 failed, 0 skipped**; the validation wrapper exited 1 when `FailedCount` was nonzero |
| `pwsh -NoLogo -NoProfile -File .\scripts\quality\Invoke-PbiQualityGate.ps1 -Profile commit` | **Exit 1:** `PbipStructure` fails while adding its first finding |
| `pwsh -NoLogo -NoProfile -File .\scripts\quality\Invoke-PbiQualityGate.ps1 -Profile pr -Target Local` | **Exit 1:** `PbipStructure` fails; `ModelBpa` and `DaxTests` skipped and blocking |
| PowerShell parser over automation and Pester source | 27 files, 0 syntax errors; syntax is not behavioral correctness |
| `ConvertFrom-Json` over repository configuration/asset JSON | 18 files, 0 parse errors; not schema or live API validation |

The commit gate reported `TmdlConventions`, `AgentAssets` and `McpParity` passed. Report validation and report conventions were **NotApplicable**, because no report exists. This is not a successful report build. `SuperpowersManifest` was NotApplicable because Superpowers is not vendored.

`RepoHygiene` passed only over the **three tracked files** selected by `git ls-files`. Most factory files are untracked; that result does not certify the imported tree. Review and stage the intended files on an approved branch, then rerun the gates before committing. Do not stage the whole tree blindly.

Evidence produced by the scripts:

- `.evidence/20261030-085659-quality-gate-27faa18.json` and `.md` (commit profile).
- `.evidence/20261030-085956-quality-gate-27faa18.json` and `.md` (PR profile).
- `.evidence/20261030-090825-quality-gate-27faa18.json` and `.md` (PR recheck after onboarding changes: same three blockers, exit 1).

These are dirty-tree baseline evidence, not release evidence for the HEAD commit. Later documentation edits do not repair the recorded automation failures.

Documentation validation checked **11 revised files, 54 local links and 18 PowerShell code blocks** with zero missing targets or PowerShell parse errors. `git diff --check` exited 0 (line-ending warnings only). No automated Markdown test suite is configured; this does not certify external URLs or execute the example deployments.

### Downloaded-file marking

The first script invocation was blocked by `RemoteSigned` and `Zone.Identifier`, not by PowerShell syntax. `MachinePolicy` and `UserPolicy` were Undefined. The delivered PowerShell files under `scripts` and `tests/powershell` were unblocked locally, after checking the cause, and the commands then ran. No execution policy was weakened. Organization-enforced signing policies must never be bypassed.

## Tool inventory

| Tool | Observation | Readiness |
|---|---|---|
| Windows / PowerShell | PowerShell 7.6.9; required minimum 7.4 | Available |
| Git / Git Bash | Git 2.56.0; Git for Windows bash found | Available |
| Long paths | `core.longpaths` unset; Windows LongPathsEnabled = 0 | Warning; use a short checkout path and review admin setup |
| Git hooks | `core.hooksPath` unset | Not wired by Git in this checkout |
| GitHub CLI | 2.103.3; authenticated; issue/milestone reads worked | Read and intake writes verified; rulesets/project not verified |
| Node / npm | 24.11.0 / 11.6.1 | Available |
| Copilot CLI / VS Code | CLI 1.0.87; VS Code command present | Available; not a full two-harness certification |
| Power BI Desktop | MSI 2.159.883.0 (26.10) detected; no loaded Desktop model found | Installed, authoring not verified |
| Pester | 5.7.1 | Available; baseline has 20 failures |
| Az.Accounts | Missing | Blocks service setup/authentication |
| Report author CLI / Desktop bridge | Neither command on PATH | Blocks scaffolding/preview |
| Tabular Editor 2 / ADOMD | Not installed under `tools/.bin` | Blocks BPA / local DAX client path |
| Az.Fabric / SqlServer | Missing | Optional; install only when the chosen workflow requires them |
| Fab Inspector | Optional, no download URL configured | Not an entry requirement |

Public registry metadata was checked without installing or executing packages:

```powershell
npm view @microsoft/powerbi-report-authoring-cli version bin --json
npm view @microsoft/powerbi-desktop-bridge-cli version bin --json
npm view @microsoft/powerbi-modeling-mcp version bin --json
npm view @microsoft/fabric-mcp version bin --json
```

All four commands exited 0: versions **0.5.0**, **1.0.0**, **1.0.0** and **1.6.0**, respectively. These are available package versions on the assessment date, not proof of installation or compatibility. The Modeling MCP npm/extension mismatch in the original analysis needs re-evaluation against these newer observations.

`copilot plugin list` exited 0 and showed:

- `superpowers@superpowers-marketplace` **5.1.0**.
- `powerbi-authoring@fabric-collection` **0.3.20**.

The manifest's Superpowers `v7.0.1` ref applies to vendoring; the plugin installer skips already installed plugins and does not enforce that ref. `latest` npm/MCP references and PowerShell minimum versions are not exact pins. Reconcile versions through a reviewed change; do not silently upgrade the user's other plugins.

## MCP verification

| Repository server | Probe | Result / next evidence |
|---|---|---|
| `microsoft-learn` | Documentation search and fetch | Responded; source findings recorded in [the evidence register](../evidence-register.md#readiness-reverification-2026-10-30) |
| `fabric-mcp` | `docs_item-definitions` with `report` | Success; report definition documentation returned. No workspace API, authentication or write tested |
| `powerbi-modeling-mcp` | `connection_operations`, `ListLocalInstances` | **Blocked:** EULA acceptance required. No connection or model mutation occurred |
| `github` | `gh` issue/milestone reads and intake creation | GitHub CLI path verified; MCP tools discoverable, but direct MCP calls and custom-agent tool restrictions not exercised |
| `playwright` | Navigate to `about:blank` | Browser transport worked; no Power BI rendering, screenshot review or authenticated report tested |

Both `powerbi-modeling-mcp` and `powerbi-authoring-local` tool namespaces are exposed in this session. The Microsoft authoring plugin can bundle its own server. Choose a single local registration and align agent references with it; do not enable a hosted server as a workaround for local EULA acceptance. License acceptance remains human-only.

VS Code and CLI MCP configuration passed static parity, with GitHub intentionally supplied by the CLI's built-in integration. Static parity does not verify server startup, authentication, installed versions or host permissions.

## Agent, skill and guardrail intake

All **8 custom agents**, **12 repository skills**, **7 path-instruction files**, the shared instructions, hook configuration and supporting templates were inventoried. `AgentAssets` passed the repository's frontmatter/JSON lint. This does not prove each agent can execute every phase.

| Workflow | Agent / skills checked | Remaining live proof |
|---|---|---|
| Routing / sprint start / intake | `pbi-sprint-lead`; `pbi-sprint-flow`, `pbi-sprint-start`, `pbi-idea-intake` | Agree goal and ownership; fix/agree numbering; create and query the first milestone |
| Spec | `pbi-spec-architect`; `pbi-spec`, Superpowers brainstorming | Accepted intake; reviewed spec and human `gate:spec-approved` |
| Plan | `pbi-planner`; `pbi-plan` | Approved spec; task decomposition and human `gate:plan-approved` |
| Model / security | `pbi-model-engineer`; `pbi-semantic-model`, `pbi-dax-tdd`, `pbi-rls-security` | Live connection, independent failing/passing DAX test cycle; role tests when security is in scope |
| Report | `pbi-report-engineer`; `pbi-report-pbir`, Microsoft `powerbi-report-cli` | Official scaffold, structural validation, Desktop render and attended review |
| Test / review | `pbi-quality-engineer`, `pbi-reviewer`; `pbi-quality-gates` | Green PR evidence, DEV proof and actual review |
| Deploy / retrospective | `pbi-release-manager`, `pbi-sprint-lead`; `pbi-deploy`, `pbi-sprint-review` | Human merge, TEST proof, release handover and retrospective |

Superpowers `using-superpowers`, `brainstorming`, repository routing/start/intake/quality skills and customization/debugging guidance loaded during this assessment. The Microsoft authoring skills are discoverable and their plugin is installed; no semantic model or report was changed to test them.

Offline guardrail tests exercised deny/allow decisions and hook-script input/output without real forbidden operations. **Do not test safety by actually pushing main, invoking PROD, merging or applying an approval label.** Live hook dispatch in both harnesses is still unverified. In particular, inspect the existing command wrappers (`exit 0` / `|| true`) and test crash/timeout behavior against the intended failure policy; passing rule tests alone does not establish fail-closed dispatch.

## Proposed readiness backlog

| ID | Priority / owner role | Finding and acceptance evidence |
|---|---|---|
| R01 | Blocking / automation maintainer | `Add-PbiFinding` has a mandatory `List[object]` parameter without empty-collection allowance. The first finding throws, affecting hygiene, TMDL, report, asset and parity fixtures. Write/retain failing regression tests, preserve diagnostic severity, and obtain **180/180 current tests passing** without skips or weakened checks |
| R02 | Blocking for Sprint 0 / sprint lead + automation maintainer | Creation accepts only 1-99; status treats 0 as missing. Agree Sprint 01 as the numbered readiness sprint, or approve consistent support for 0 across creation/status/session context/tests/docs. Do not create a misleading `current.json` manually |
| R03 | Blocking / workstation owner | Install missing required tooling through reviewed bootstrap steps; reconcile plugin versions; record actual versions/hashes; prerequisites exit 0 and CLI help/scaffold/validate work |
| R04 | Blocking for agent-led build / agent-assets maintainer | Choose one local Modeling MCP registration; verify tool allowlists and actual hook dispatch in VS Code/CLI using inert fixtures; human reviews EULA. Align skill wording with actual profiles: `commit` is L0, while report conventions are L1 |
| R05 | Blocking / model + report engineers | Scaffold SalesStarter, open/refresh in Desktop, pass local DAX/BPA/PR checks and get attended visual review. Never substitute NotApplicable or Skipped for this evidence |
| R06 | Before service delivery / release manager + tenant/workspace owners | Configure local environment placeholders, confirm tenant/licensing/capacity/access, prove DEV plan/deploy/tests, human merge, then TEST for the same source |
| R07 | Before publication / repository maintainer | Review imported untracked factory files on a branch; verify staged hygiene and ruleset/project setup; retain fresh evidence for the reviewed source. Do not push this dirty tree to main |
| R08 | Documentation / contributor experience | Clarify artifact scope, existing-checkout setup, first-project lifecycle, evidence meanings and manual dashboard/service work. Documentation refined by this intake; acceptance does not approve R01-R07 |

`R01` already has red evidence; this intake deliberately does not change automation or relax gates without an approved plan. The report wrapper currently applies the first blueprint page; multi-page requirements need explicit plan tasks, not an assumption that all wireframe pages are scaffolded automatically.

Tooling/plugin installation plans were also exercised with `-WhatIf`; both exited 0. No missing tool was installed and no existing plugin upgraded. The installers' final success-shaped messages in dry-run mode must not be interpreted as readiness.

## Development-entry criteria

Before **real report development**, require:

- Product owner accepts intake and confirms accountable approvers, sprint goal, dates, numbering and capacity.
- Human-reviewed spec and plan have the appropriate `gate:*` labels; tasks are ready.
- Automation regressions and prerequisites are green; tool versions and MCP routing are reconciled.
- SalesStarter report exists, opens and refreshes; DAX, BPA and full PR checks pass; a human has reviewed rendered pages.
- Evidence covers the intended/staged source, not only the original three tracked files.

Before claiming **end-to-end delivery readiness**, also require DEV and TEST deployment plus post-deployment evidence, agreed service access and human merge/release procedures. PROD is never an agent validation target.

## Human handoff

The next action belongs to the **product owner**: review [issue #1](https://github.com/urruegg/power-bi-superpower/issues/1), confirm the proposed goal (*prove the SalesStarter toolchain from local tests to TEST before real reports*), nominate approvers and agree sprint capacity/dates/numbering. If accepted, move the intake to `phase:spec`.

The spec architect can then prepare the specification for `gate:spec-approved`; only after that does the planner produce the implementation plan for `gate:plan-approved`. No labels, document checkboxes or this assessment substitute for those human gates.
