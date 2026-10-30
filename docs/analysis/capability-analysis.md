# Capability analysis: GitHub agents for Power BI delivery

**Question:** Which GitHub Copilot skills, plugins, custom agents, hooks and MCP tools exist today to run Power BI work end to end — idea intake → spec → plan → build → test → deploy, sprint by sprint — with the Superpowers methodology, PowerShell infrastructure-as-code and **no GitHub Actions**?

**State:** 30 October 2026. Labels: **GA**, **Preview**, **Community**, ⚠ = unverified or sources disagree. Numbers in brackets point to the source list at the end. Re-verify preview items with the Microsoft Learn MCP server before relying on them (principle P11 of the Agent Factory concept).

---

## 1. Summary

1. **Everything needed runs locally.** VS Code agent mode and GitHub Copilot CLI share one runtime ("Copilot harness") and the same customization files: instructions, `AGENTS.md`, agent skills, custom agents, hooks, plugins and MCP configuration [S18][S22]. No GitHub Actions are required for any phase.
2. **Superpowers v7.0.1 (MIT, 15 skills) installs into Copilot CLI as a plugin** from `obra/superpowers-marketplace`; VS Code picks up CLI-installed plugins [S1][S3][S24]. Its flow (brainstorming → worktrees → writing-plans → subagent-driven development with TDD → review → finish) maps one-to-one onto the sprint phases.
3. **Microsoft now ships first-party Power BI agent tooling:** the Power BI Authoring (Modeling) MCP server — local server **GA**, hosted endpoint **Preview** [P1][P2]; the `powerbi-authoring` plugin with the `semantic-model-authoring` and `powerbi-report-cli` skills [P3]; the `powerbi-report-author` CLI (scaffold, validate, pack, preview, screenshots) and the Power BI Desktop bridge CLI [P4][P5].
4. **PBIP is GA and PBIR is the default report format** in Power BI Desktop and the service since September 2026 [P6][P7] — the source format is stable enough to build a factory on.
5. **GitHub work management is covered by the built-in GitHub MCP server** (issues, sub-issues, labels, projects, pull requests, reviews, branches) [S58][S61]. Gap: **no milestone-creation tool** → small `gh` scripts fill it.
6. **Deployment without Actions is straightforward** with PowerShell 7 + Fabric REST item-definition APIs (create / `updateDefinition`, long-running operations) and Power BI REST (refresh, `executeQueries`) [D1–D8]. Reports must be rebound from `byPath` to `byConnection` (`semanticmodelid=<id>`) at deploy time [D3].
7. **Testing is mature enough for a TDD loop:** DAX query view tests (Kerski pattern) [D12], Tabular Editor 2 CLI Best Practice Analyzer (MIT) [D13], `powerbi-report-author validate`, Desktop/service screenshots [P4]. Visual review stays attended.
8. **What Actions would have added** — server-side gates, OIDC, scheduled jobs and the Copilot cloud agent's Actions environment — is replaced by local gates, git hooks, Copilot `preToolUse` hooks, PR evidence and human merge and release gates (section 10). The Copilot cloud agent is not usable for Power BI builds anyway: Power BI Desktop is Windows-only and the cloud sandbox is Linux [S43].

---

## 2. Constraints that shaped the design

| Constraint | Consequence |
|---|---|
| No GitHub Actions | All automation is PowerShell run by a developer or an agent; gates run locally and evidence is pasted into PRs; humans merge and release. |
| Windows + Power BI Desktop | Live authoring through the Modeling MCP server and the Desktop bridge; DAX tests against the local engine; Tabular Editor 2 CLI is Windows-only. |
| Superpowers methodology | Phases, artefact locations and execution discipline follow Superpowers; repository skills add Power BI specifics only. |
| PowerShell IaC | Environments as JSON (no IDs), idempotent scripts with `-WhatIf`, evidence files, guarded PROD. |
| Agent Factory principles (P1–P11) | Specify before build, everything as code, tests first, humans own gates, evidence over claims, pinned supply chain. |

---

## 3. Agent runtime surfaces

| Surface | Status | What it gives this repository | Limits |
|---|---|---|---|
| **VS Code — Copilot harness** | GA; default harness, same SDK runtime as Copilot CLI [S22] | Skills from `.github/skills`, custom agents, hooks (**Preview** in VS Code [S21]), MCP from `.vscode/mcp.json` (forwarded unless it uses `${input:…}`) and the portable `mcpServers` format [S23] | Prompt files and agent *handoffs* do not run here; user tool sets deprecated [S18][S19] |
| **VS Code — Local harness** | GA (`chat.editor.localAgent.enabled`) [S22] | Prompt files, handoff buttons between custom agents, subagents via `agents:` [S18] | VS Code only |
| **GitHub Copilot CLI** | GA since 25 Feb 2026; v1.0.103 (22 Oct 2026) [S46][S47] | `/agent`, `/skills`, `/plugin`, `/mcp`, `/delegate`, `/fleet`; plugins and marketplaces; repository hooks; project MCP in `.mcp.json` / `.github/mcp.json`; built-in GitHub MCP server; tool allow/deny flags [S30–S32][S37] | Does not read `.vscode/mcp.json` [S32]; does not run prompt files [S45] |
| **Copilot cloud agent** | GA; cloud sandbox **Preview** (Linux) [S43] | Could edit docs or agent assets from an issue | Runs in a Linux sandbox or an Actions job; Windows needs larger/self-hosted Actions runners; no Power BI Desktop → **not used for Power BI builds** |
| **Copilot code review** | GA | Optional extra reviewer on PRs, reads `copilot-instructions.md` | ⚠ Agentic review features may consume Actions minutes — verify in Sprint 0; the local `pbi-reviewer` agent is the default |

**Design consequence:** build on the primitives both main surfaces share — skills, custom agents, hooks, instructions, `AGENTS.md`, plugins and MCP. Do not rely on prompt files or handoffs (they are a Local-harness bonus).

---

## 4. Customization primitives used

| Primitive | Location | Read by | Use in this repository |
|---|---|---|---|
| Repository instructions | `.github/copilot-instructions.md` | All surfaces incl. code review [S40] | Conventions and review order |
| `AGENTS.md` | Repo root (nested optional) | CLI, VS Code, cloud agent [S34][S40] | Workflow rules, phase matrix, non-delegable work |
| Path instructions | `.github/instructions/*.instructions.md` with `applyTo` (`excludeAgent` optional) | All [S34] | TMDL, DAX tests, PBIR, PowerShell, specs and plans, configuration, agent assets |
| Agent skills | `.github/skills/<name>/SKILL.md` (`name` = folder, `description` ≤ 1,024 chars, `argument-hint`, `user-invocable`, `disable-model-invocation`) [S16][S27] | CLI, VS Code, cloud agent, code review [S27] | 12 `pbi-*` skills; invocable as `/pbi-…` |
| Custom agents | `.github/agents/*.agent.md` (`description` required; `tools`, `model`, `target`, `handoffs` VS Code-only, `mcp-servers` cloud-only) [S26] | CLI, VS Code, cloud agent | 8 role agents with scoped tools |
| Prompt files | `.github/prompts/*.prompt.md` | VS Code Local harness only [S19][S45] | **Not used** (Microsoft recommends converting them to skills [S19]) |
| Hooks | `.github/hooks/*.json` (`version: 1`; `sessionStart`, `preToolUse`, …; command hooks with `bash`/`powershell`) [S33] | CLI, cloud agent; VS Code Preview | Session context + guardrails (PROD, merges, force-push, gate labels, secrets) |
| Plugins and marketplaces | `copilot plugin marketplace add OWNER/REPO`, `copilot plugin install NAME@MARKETPLACE`; default marketplace `awesome-copilot` [S31] | CLI; VS Code discovers CLI-installed plugins [S24] | Superpowers, Microsoft `powerbi-authoring`, optional `power-bi-development` |
| Repository plugin defaults | `.github/copilot/settings.json` keys `enabledPlugins`, `extraKnownMarketplaces` [S38] | CLI | Declares the plugins this repo expects ⚠ JSON shape follows the Claude-compatible format; verify in Sprint 0 |
| MCP configuration | `.vscode/mcp.json` (`servers`) and `.github/mcp.json` (`mcpServers`) [S23][S32] | VS Code / CLI | Same servers in both, checked by the `McpParity` gate |

**Hook facts that matter** [S33]: command `preToolUse` hooks **fail closed** on crash or non-zero exit, **fail open** on timeout; output `{"permissionDecision":"deny","permissionDecisionReason":"…"}` blocks the tool; input carries `toolName`, `toolArgs`, `cwd`; tool names include `bash`, `powershell`, `view`, `edit`, `create`, `task`, `web_fetch`. The repository's hook scripts catch every error and allow (documented fail-open) so a hook bug cannot freeze the agent; the real controls stay human (merge, gate labels, PROD confirmation).

---

## 5. Methodology layer

### 5.1 Superpowers (obra/superpowers)

**Version:** v7.0.1 (21 Oct 2026), MIT, Prime Radiant / Jesse Vincent; `commands/` and the `code-reviewer` agent were removed in v5.1.0 (review template now lives in `requesting-code-review`) [S1][S3].
**Install for Copilot CLI (official):** `copilot plugin marketplace add obra/superpowers-marketplace` → `copilot plugin install superpowers@superpowers-marketplace` [S1]. The plugin's `SessionStart` hook injects `using-superpowers`; it needs Git for Windows bash on Windows [S3][S7].
**VS Code:** no official path; VS Code discovers plugins installed by Copilot CLI [S24]. Vendoring the skills into `.github/skills` works but loses the SessionStart bootstrap — this repository's `AGENTS.md` and session hook compensate, and `Install-AgentPlugins.ps1 -VendorSuperpowers` vendors a pinned tag with a SHA-256 manifest when needed.

| Superpowers skill | Purpose [S1][S4–S15] | Sprint phase in this repo |
|---|---|---|
| `using-superpowers` | Session bootstrap; enforces skill use | Every session (AGENTS.md step 1) |
| `brainstorming` | Questions one at a time, 2–3 approaches, design doc | Intake (questions), **Spec** |
| `using-git-worktrees` | Isolated branch/worktree | Start of Spec (`feat/<issue>-<slug>`) |
| `writing-plans` | Bite-sized plan with Files/Interfaces and `- [ ]` steps | **Plan** |
| `subagent-driven-development` | Fresh subagent per task + review | **Build** (default) |
| `executing-plans` | Inline execution with final review | Build (fallback) |
| `dispatching-parallel-agents` | Concurrent independent tasks | Build (independent pages/areas only) |
| `test-driven-development` | RED-GREEN-REFACTOR | Build → `pbi-dax-tdd` |
| `systematic-debugging` | Root cause before fix | Build / Test / bugs |
| `verification-before-completion` | Evidence before claims | **Test** → `pbi-quality-gates` |
| `requesting-code-review` / `receiving-code-review` | Review against plan; handle feedback | **Review** |
| `finishing-a-development-branch` | Merge / PR / keep decision | **Deploy** hand-over |
| `writing-skills` | Author and test new skills | Sprint review (lessons → skills) |
| `diagnosing-superpowers` | Diagnose a misbehaving session | Support |

**Artefact locations** (honoured by this repo): specs `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`, plans `docs/superpowers/plans/YYYY-MM-DD-<feature>.md`, execution ledger `.superpowers/sdd/` (git-ignored), worktrees `.worktrees/` [S5][S6][S3]. Related repos: `superpowers-marketplace` (catalog), `superpowers-lab` (experimental, incl. `windows-vm`), `superpowers-chrome` (browser skill + MCP); `superpowers-skills` archived [S16–S20].

### 5.2 GitHub Spec Kit (comparison)

Spec Kit 1.2.4 (MIT) installs for Copilot as skills `.github/skills/speckit-*` (`/speckit-constitution`, `-specify`, `-clarify`, `-plan`, `-checklist`, `-tasks`, `-analyze`, `-implement`, `-converge`) with `specify init <name> --integration copilot --script ps`; `taskstoissues` moved to an extension [S48–S53]. It overlaps with Superpowers in spec → plan → tasks; its strength is governance artefacts (constitution, checklists, analyze), Superpowers' strength is execution discipline (TDD, worktrees, subagent review, verification). Community bridges exist but are not verified on Copilot [S55]. **Decision (ADR-0001):** do not install both; use Superpowers and borrow Spec Kit's ideas — the constitution becomes `AGENTS.md` plus the principles in `docs/architecture/operating-model.md`, and the acceptance-test table in the spec plays the role of Spec Kit checklists.

### 5.3 Generic sprint helpers (awesome-copilot)

`create-specification`, `create-implementation-plan`, `gen-specs-as-issues`, `create-github-issues-feature-from-implementation-plan`, `spec-driven-workflow-v1.instructions.md` [S68][S69]. Not installed: they duplicate Superpowers + `pbi-plan`; useful as reference.

---

## 6. Power BI and Fabric agent assets

### 6.1 MCP servers

| Server | Endpoint / package | Status | Tools that matter | Role here |
|---|---|---|---|---|
| **Power BI Authoring (Modeling) MCP — local** | `npx -y @microsoft/powerbi-modeling-mcp@latest --start`; VS Code extension `analysis-services.powerbi-modeling-mcp` | **GA** (extension v1.0.0, 25 Sep 2026) [P1][P2] | connection, database (TMDL import/export, deploy), transaction, model/table/column/measure/relationship, partition, calculation group, security role, perspective, culture/translation, function (UDF), calendar, DAX query (≤100k rows), trace | **Build**: live model edits against Power BI Desktop or a PBIP folder; DAX iteration. EULA acceptance is human-only. ⚠ npm shows a 0.5.0-beta tag vs extension 1.0.0 |
| Power BI Authoring MCP — hosted | `https://api.fabric.microsoft.com/v1/mcp/powerbi/authoring` | **Preview** [P2] | Same authoring surface for workspace models (no transactions/traces) | Optional for DEV workspace work; never register together with the local server |
| Power BI consumption MCP / Fabric IQ | `…/v1/mcp/powerbi`; `https://fabriciq.svc.cloud.microsoft/v1/mcp/FabricIQ` | Preview [P2][S76] | Schema, generate/execute query | Not needed for delivery; useful for UAT questions |
| **Fabric MCP — local** | `npx -y @microsoft/fabric-mcp@latest server start --mode all` (Node 22+) | GA per Fabric blog ⚠ [P8] | `docs_item-definitions`, `docs_item-api-spec`, `docs_best-practices`, `core_*`, OneLake | **Spec/Build**: authoritative item definitions and API specs; read-mostly |
| Fabric MCP — remote core | `https://api.fabric.microsoft.com/v1/mcp/core` | ⚠ status unverified [P9] | Workspaces, items, roles | Not used (scripts own writes) |
| **Microsoft Learn MCP** | `https://learn.microsoft.com/api/mcp` (no auth) [P10] | Available | `microsoft_docs_search/fetch`, `microsoft_code_sample_search` | Capability verification, evidence register |
| **GitHub MCP server** | Built into Copilot CLI; remote `https://api.githubcopilot.com/mcp/` with `X-MCP-Toolsets` | v2.0.3 [S58][S63] | `issue_read`/`issue_write` (labels, milestone assignment, type), `sub_issue_write`, `search_issues`, `label_write`, `projects_*`, `create_pull_request`, `pull_request_review_write`, `request_copilot_review`, `create_branch`, `push_files` | **Intake → Deploy** work tracking. No milestone creation, no issue-form tool [S61][S64] |
| **Playwright MCP** | `npx @playwright/mcp@latest --browser msedge` | Available | navigate, wait, screenshot | Optional visual smoke of DEV/TEST reports (Power BI renders on canvas — use screenshots) [P11] |
| Azure MCP 3.0 | `npx -y @azure/mcp@latest server start` | GA (12 Oct 2026) | No Fabric/Power BI namespace [P12] | Not used; capacity IaC via Az.Fabric |

### 6.2 Skills, plugins and agents

| Asset | Source / licence | Contents | Use here |
|---|---|---|---|
| **`powerbi-authoring` plugin** | `microsoft/skills-for-fabric` v0.3.19, MIT; `copilot plugin marketplace add microsoft/skills-for-fabric` → `copilot plugin install powerbi-authoring@fabric-collection` [P3] | `semantic-model-authoring` (**Preview**; tool priority MCP → TMDL, modeling/DAX/TMDL guidelines, deploy via REST, never change RLS membership) and `powerbi-report-cli` (PBIR authoring, design, management modes; "never hand-author the report shell, scaffold it") [P3][P13][P14] | **Required.** Repository skills reference it for mechanics |
| `power-bi-development` plugin | `github/awesome-copilot`, MIT; `copilot plugin install power-bi-development@awesome-copilot` [S67] | Agents: data-modeling, DAX, performance, visualization experts; skills: dax-optimization, model-design-review, performance-troubleshooting, report-design-consultation | Optional consultants for review and performance |
| awesome-copilot instructions | `power-bi-*-best-practices.instructions.md` (modeling, DAX, devops-alm, report design, security-rls, custom visuals) [S68] | Path instructions | Reference; this repo ships its own shorter rules |
| `powerbi-modeling` skill | `github/awesome-copilot` [S69] | Star schema, relationships, DAX, performance, RLS with the Modeling MCP | Covered by Microsoft's skill |
| Fabric CLI AI assets | `microsoft/fabric-cli/.ai-assets` — skills `fabric-cli-core`, `fabric-cli-powerbi`; agent `fab.agent.md` [P9] | Fabric CLI usage | Optional if the team adopts `fab` |
| `microsoft/gh-copilot-fabric-agents` | ⚠ licence not checked [S78] | Fabric semantic model / optimization agents + skill | Reference only |
| data-goblin `power-bi-agentic-development` | **GPL-3.0**, weekly releases (v26.40.7) [S73] | Plugins pbip, tmdl, pbir-format, semantic-models, reports, tabular-editor, pbi-desktop, fabric-cli; validation hooks | Optional personal install; **do not vendor** into this repository (licence) |
| `microsoft/skills` | MIT | Azure SDK / Foundry skills (incl. Fabric capacity mgmt SDK) — no Power BI skills [S79] | Not used |

### 6.3 Command-line tools

| Tool | Status | Role |
|---|---|---|
| `powerbi-report-author` (`@microsoft/powerbi-report-authoring-cli`) | **Preview** 0.x, MIT [P4] | `scaffold` (valid PBIP shell with real base theme), `validate`, `catalog`/`formatting` (roles, properties), `pack`/`unpack` (Fabric definition payloads), `preview` Desktop/service with screenshots |
| `powerbi-desktop` (`@microsoft/powerbi-desktop-bridge-cli`) | v1.0.0; Desktop Bridge **Preview** [P5] | `status`, `open`, `reload`, `screenshot` against a running Desktop |
| Tabular Editor 2 CLI | 2.29.0, MIT, Windows; no TE3 licence needed [D13] | BPA with `-A rules -T trx`; exit 1 on error-severity violations |
| Tabular Editor `te` CLI / TE3 MCP | Limited preview (expiry date ⚠) / TE3 3.27 [P15] | Optional |
| Fab Inspector (PBI Inspector V2) | Community, MIT, v3.4.0 [D14] | Optional PBIR rule engine |
| Invoke-DQVTesting | Community 0.0.16 [D12] | Reference implementation of DAX query view tests; this repo has its own runner |
| Fabric CLI `fab` 1.8.0 / fabric-cicd 1.4.0 | GA / MIT, Python [D10][D11] | Alternative deploy engines (ADR-0003) |
| Semantic Link Labs 0.17.1 | Alpha, Fabric notebooks [D15] | Optional in-service model/report BPA |

---

## 7. Source format: PBIP, TMDL, PBIR

- **Status:** PBIP and developer mode **GA** (MC1465770, 1 Sep 2026); PBIR is the default in Desktop and the service; TMDL GA since 2024 [P6][P7].
- **Layout:** `<Name>.SemanticModel/` (`definition.pbism`, `definition/` TMDL, `DAXQueries/`, `.platform`) and `<Name>.Report/` (`definition.pbir`, `definition/version.json`, `report.json`, `pages/…/page.json`, `visuals/…/visual.json`, `StaticResources/`) [P7].
- **Git hygiene:** ignore `**/.pbi/localSettings.json` and `**/.pbi/cache.abf`; Desktop writes CRLF and UTF-8 without BOM [P7].
- **Schemas:** `.pbip` 1.0.0, `.platform` 2.0.0, `definition.pbism` 1.0.0 (version 4.x for TMDL), `definition.pbir` 2.0.0 (`version` 4.0), report 3.3.0, page 2.1.0, visualContainer 2.13.0 (2.9.0 is Microsoft's fallback) [P16][P14]. Rule: preserve existing `$schema`; never guess new ones — scaffold instead [P14].
- **Caveats:** sensitivity labels not in PBIP; 260-character paths; no direct save to OneDrive/SharePoint; external-edit reload is Preview; RLS membership and incremental-refresh partitions cannot be set through the definition API [P7].

---

## 8. Deployment and infrastructure as code (PowerShell, no Actions)

| Need | API / tool | Notes |
|---|---|---|
| Workspace | `POST /v1/workspaces` (`displayName`, `capacityId`), `assignToCapacity`, `roleAssignments` (User/Group/ServicePrincipal; Admin/Member/Contributor/Viewer); list with `continuationToken` [D1] | Add/update only; never remove in automation |
| Semantic model | `POST /workspaces/{ws}/semanticModels` with `definition{format:TMDL, parts[]}` or `…/{id}/updateDefinition` (replace-all; `allowPurgeData` option) [D2] | Required parts: `definition.pbism`, `definition/database.tmdl`, `definition/model.tmdl`, tables; exclude `.pbi/`, `DAXQueries/`, `TMDLScripts/` |
| Report | `POST /workspaces/{ws}/reports` / `updateDefinition` with PBIR parts [D2] | **`definition.pbir` must use `byConnection`** — schema 2.0.0: only `connectionString: "semanticmodelid=<id>"` [D3] |
| Long-running operations | 202 + `Location` / `x-ms-operation-id` + `Retry-After` → `GET /v1/operations/{id}` → `/result`; 429 `RequestBlocked` vs `CapacityLimitExceeded` [D4] | Implemented once in `Invoke-PbiFabricApi` |
| Refresh | Power BI REST `POST …/datasets/{id}/refreshes` (enhanced) + poll [D5] | Credentials and gateways stay human |
| Post-deploy tests | `POST …/datasets/{id}/executeQueries` (one query, one table, 100k rows; tenant setting) [D5] | No `INFO.*` → keep those tests `LOCAL` |
| Parameters | Rewrite M parameter values in `expressions.tmdl` before upload (FabricPS-PBIP pattern) [D9] | `UpdateParameters` is not supported for XMLA-modified models |
| Capacity | `Microsoft.Fabric/capacities` 2023-11-01; Az.Fabric 1.0.0 `New/Update/Suspend/Resume-AzFabricCapacity` [D6] | Optional; pause DEV capacity off-hours |
| Alternatives | Fabric Git integration (`git/connect`, `updateFromGit`, GitHub needs a PAT connection), deployment pipelines (`deploy` ≤300 items) [D7]; fabric-cicd / `fab deploy` (Python) [D10][D11] | ADR-0003 explains why native PowerShell is the default |
| Identity | Az.Accounts ≥5 returns SecureString tokens; audiences `https://api.fabric.microsoft.com` and `https://analysis.windows.net/powerbi/api` [D8] | Human sign-in by default; certificate-based service principal optional for TEST |

---

## 9. End-to-end mapping (the answer in one table)

| Phase | Custom agent | Skills (Superpowers + repo + Microsoft) | MCP tools | Scripts | Artefact | Human gate |
|---|---|---|---|---|---|---|
| Sprint start | `pbi-sprint-lead` | `pbi-sprint-start` | GitHub (`issue_write`, `projects_write`) | `New-PbiSprint.ps1`, `Get-PbiSprintStatus.ps1` | Milestone, sprint doc, tracking issue | Goal agreed |
| Intake | `pbi-sprint-lead` | `pbi-idea-intake`, `brainstorming` | GitHub (`issue_write`, `search_issues`, `add_issue_comment`) | — | Idea issue + intake score | Accept → `phase:spec` |
| Spec | `pbi-spec-architect` | `brainstorming`, `using-git-worktrees`, `pbi-spec`, `pbi-rls-security` | Learn, Fabric (item definitions), Modeling MCP (read), GitHub (`create_pull_request` draft) | — | Spec, blueprint, draft PR | `gate:spec-approved` |
| Plan | `pbi-planner` | `writing-plans`, `pbi-plan` | GitHub (`issue_write`, `sub_issue_write`) | — | Plan, sub-issues | `gate:plan-approved` |
| Build | `pbi-model-engineer`, `pbi-report-engineer` | `subagent-driven-development`, `test-driven-development`, `systematic-debugging`, `pbi-semantic-model`, `pbi-dax-tdd`, `pbi-report-pbir`, `semantic-model-authoring`, `powerbi-report-cli` | Modeling MCP (live), Fabric docs, Learn | `New-PbipReport.ps1`, `Invoke-PbiDaxTests.ps1`, `Invoke-PbiQualityGate.ps1 -Profile commit` | Commits per task | Task review |
| Test | `pbi-quality-engineer` | `verification-before-completion`, `pbi-quality-gates` | Modeling MCP (DAX), Playwright (optional) | `Invoke-PbiQualityGate.ps1 -Profile pr`, `Deploy-PbiProject.ps1 -Environment DEV` | `.evidence/*.md` in PR | All checks pass |
| Review | `pbi-reviewer` (+ Copilot code review optional) | `requesting-code-review`, `receiving-code-review` | GitHub (`pull_request_read`, `pull_request_review_write`) | — | Review | **Human merges** |
| Deploy | `pbi-release-manager` | `finishing-a-development-branch`, `pbi-deploy` | GitHub (release issue) | `Deploy-PbiInfrastructure.ps1`, `Deploy-PbiProject.ps1 -Environment TEST` | TEST evidence, release issue | `gate:release-approved`; **human runs PROD** |
| Sprint review | `pbi-sprint-lead` | `pbi-sprint-review`, `writing-skills` | GitHub (search, PRs) | `Get-PbiSprintStatus.ps1` | Release notes, CHANGELOG, retro, skill PRs | Sprint accepted |

---

## 10. What GitHub Actions would have added — and the replacement

| Capability normally in Actions | Replacement in this repository | Residual risk |
|---|---|---|
| Required status checks on PRs | Local gate profiles + pasted evidence (PR template) + `pbi-reviewer` + human merge; `.githooks/pre-push` runs L0 | Evidence could be stale → file names carry the commit SHA; reviewer checks it |
| OIDC deployment identity | Interactive human sign-in (DEV/TEST/PROD) or certificate service principal (TEST) | Workstation hygiene; PROD only by humans |
| Environment approvals | `gate:release-approved` label (human), `prod.json` guards, typed confirmation, hooks block agents | Process discipline |
| Promotion of an immutable artefact | Same commit deployed to TEST and PROD; PROD requires TEST evidence for that SHA | Rebuild from source is deterministic (definitions are files) |
| Scheduled checks (drift, nightly tests) | Run `Invoke-PbiDaxTests.ps1 -Target TEST` in the sprint rhythm; optional Windows Task Scheduler | Not automatic |
| Copilot cloud agent environment (`copilot-setup-steps.yml`) | Local agents in VS Code / CLI on Windows | No unattended issue-to-PR automation for Power BI work |

---

## 11. Gaps, risks and Sprint 0 spikes

| # | Item | Risk | Spike / mitigation |
|---|---|---|---|
| G1 | `.github/copilot/settings.json` plugin keys (shape inferred) | Plugins not auto-enabled | Bootstrap installs plugins explicitly; verify keys in Sprint 0 |
| G2 | Hooks in VS Code are Preview; `powershell` hook host version | Guardrails not active in VS Code | Verify deny in both surfaces; PROD also guarded by the script itself |
| G3 | Modeling MCP npm vs extension version mismatch | Different behaviour | Pin after Sprint 0; record versions in evidence |
| G4 | `powerbi-report-author` is 0.x Preview | Breaking CLI changes | Wrapper script isolates calls; re-scaffold with `-Offline` if schemas are too new |
| G5 | Desktop external-edit reload Preview | TMDL edits not picked up | Prefer MCP for live edits; reopen Desktop |
| G6 | `executeQueries` needs a tenant setting; no RLS with service principals | Post-deploy tests skipped | Tenant setting in first-time setup; RLS tests local |
| G7 | Rulesets on private repos need GitHub Pro/Team | No branch protection | Script warns; team plan or public repo |
| G8 | Copilot code review and Actions minutes ⚠ | Unexpected dependency | Default to local reviewer agent |
| G9 | Superpowers SessionStart hook needs bash on Windows | Bootstrap missing | Git for Windows prerequisite; AGENTS.md step 1 |
| G10 | Tabular Editor 2 model path argument for TMDL ⚠ | BPA does not load model | `modelArgument` switch in `tools/versions.json` |

---

## 12. Decisions

See `docs/architecture/adr/`: 0001 methodology (Superpowers, Spec Kit not installed) · 0002 source format (PBIP with TMDL + PBIR, byPath in Git) · 0003 deployment engine (PowerShell 7 + Fabric REST, no Actions) · 0004 agent surfaces and MCP allow-list · 0005 environments and identity · 0006 testing strategy (DAX TDD, gate levels) · 0007 agent supply chain (plugins, pinning, vendoring) · 0008 work management on GitHub (labels as gates, milestones via `gh`).

---

## Sources

**GitHub / Copilot / methodology**
S1 https://github.com/obra/superpowers · S3 https://github.com/obra/superpowers/blob/main/RELEASE-NOTES.md · S4 https://github.com/obra/superpowers/tree/main/skills · S5 …/skills/brainstorming/SKILL.md · S6 …/skills/writing-plans/SKILL.md · S7 …/hooks/hooks.json · S16 https://github.com/obra/superpowers-marketplace · S18 https://code.visualstudio.com/docs/agents/reference/custom-agent-file-reference · S19 https://code.visualstudio.com/docs/agent-customization/prompt-files · S21 https://code.visualstudio.com/docs/agent-customization/hooks · S22 https://code.visualstudio.com/docs/agents/run/agent-harnesses · S23 https://code.visualstudio.com/docs/agents/reference/mcp-configuration · S24 https://code.visualstudio.com/docs/agent-customization/agent-plugins · S26 https://docs.github.com/en/copilot/reference/custom-agents-configuration · S27 https://docs.github.com/en/copilot/concepts/customizations/agent-skills · S30 https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference · S31 https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference · S32 https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers · S33 https://docs.github.com/en/copilot/reference/hooks-reference · S34 https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions · S37 https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/allowing-tools · S38 https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference · S40 https://docs.github.com/en/copilot/reference/custom-instructions-support · S43 https://docs.github.com/en/enterprise-cloud@latest/copilot/concepts/security-governance-and-network-settings/about-cloud-sandboxes · S45 https://docs.github.com/en/copilot/concepts/prompting-and-context/prompt-files · S46 https://github.com/github/copilot-cli/blob/main/changelog.md · S47 https://github.blog/changelog/2026-02-25-github-copilot-cli-is-now-generally-available/ · S48 https://github.com/github/spec-kit · S50 https://github.com/github/spec-kit/blob/main/docs/integrations/copilot.md · S53 https://github.com/github/spec-kit/blob/main/docs/reference/core.md · S55 https://github.com/lihan3238/speckit-superpowers-bridge · S58 https://github.com/github/github-mcp-server · S61 https://github.com/github/github-mcp-server/tree/main/pkg/github/__toolsnaps__ · S63 https://github.com/github/github-mcp-server/releases · S64 https://github.com/github/github-mcp-server/blob/main/pkg/github/__toolsnaps__/projects_write.snap · S67 https://github.com/github/awesome-copilot/tree/main/plugins/power-bi-development · S68 https://github.com/github/awesome-copilot/tree/main/instructions · S69 https://github.com/github/awesome-copilot/blob/main/skills/powerbi-modeling/SKILL.md · S73 https://github.com/data-goblin/power-bi-agentic-development · S76 https://learn.microsoft.com/en-us/power-bi/developer/mcp/mcp-servers-overview · S78 https://github.com/microsoft/gh-copilot-fabric-agents · S79 https://github.com/microsoft/skills

**Power BI / Fabric authoring**
P1 https://github.com/microsoft/powerbi-modeling-mcp · P2 https://learn.microsoft.com/en-us/power-bi/developer/mcp/power-bi-authoring-mcp · P3 https://github.com/microsoft/skills-for-fabric · P4 https://www.npmjs.com/package/@microsoft/powerbi-report-authoring-cli · P5 https://www.npmjs.com/package/@microsoft/powerbi-desktop-bridge-cli · P6 https://msmessagecenter.com/MC1465770/ · P7 https://learn.microsoft.com/en-us/power-bi/developer/projects/projects-report and …/projects-dataset · P8 https://github.com/microsoft/mcp/tree/main/servers/Fabric.Mcp.Server · P9 https://learn.microsoft.com/en-us/rest/api/fabric/articles/mcp-servers/what-is-fabric-mcp-server · P10 https://learn.microsoft.com/en-us/training/support/mcp-developer-reference · P11 https://learn.microsoft.com/en-us/power-platform/developer/playwright-samples/ai-mcp · P12 https://devblogs.microsoft.com/azure-sdk/azure-mcp-server-3-0-stable-release/ · P13 https://github.com/microsoft/skills-for-fabric/blob/main/skills/semantic-model-authoring/SKILL.md · P14 https://github.com/microsoft/skills-for-fabric/blob/main/skills/powerbi-report-cli/references/authoring-part-02.md · P15 https://docs.tabulareditor.com/en/features/te-cli/te-cli.html · P16 https://github.com/microsoft/json-schemas/blob/main/fabric/item/report/README.md

**Deployment and testing**
D1 https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces · D2 https://learn.microsoft.com/en-us/rest/api/fabric/semanticmodel/items and …/report/items · D3 https://learn.microsoft.com/en-us/rest/api/fabric/articles/item-management/definitions/report-definition · D4 https://learn.microsoft.com/en-us/rest/api/fabric/articles/long-running-operation and …/throttling · D5 https://learn.microsoft.com/en-us/rest/api/power-bi/datasets/refresh-dataset-in-group and …/execute-queries-in-group · D6 https://learn.microsoft.com/en-us/rest/api/microsoftfabric/fabric-capacities/create-or-update · https://www.powershellgallery.com/packages/Az.Fabric · D7 https://learn.microsoft.com/en-us/rest/api/fabric/core/git and …/deployment-pipelines · D8 https://learn.microsoft.com/en-us/powershell/azure/migrate-az-14.0.0 · D9 https://github.com/microsoft/Analysis-Services/tree/master/pbidevmode/fabricps-pbip · D10 https://pypi.org/project/ms-fabric-cli/ · D11 https://microsoft.github.io/fabric-cicd/ · D12 https://github.com/kerski/fabric-dataops-patterns · D13 https://docs.tabulareditor.com/te2/Command-line-Options.html · https://github.com/TabularEditor/TabularEditor/releases · D14 https://github.com/NatVanG/fab-inspector · D15 https://pypi.org/project/semantic-link-labs/

**Agent Factory context:** *Copilot Studio Agent Factory — Part 1: Common setup v1.1* (25 Oct 2026) — principles P1–P11, Superpowers adaptation, phase matrix, evidence rules.
