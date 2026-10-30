# Evidence register

Capability source catalogue, initially assembled on **2026-10-30**. A source URL or GA label is not a successful local test. Entries not explicitly reverified below retain the original analysis's claims; do not infer that every version, host or deployment was tested. Re-verify preview items monthly with the `microsoft-learn` MCP server and update through a PR.

For actual workstation checks, gate failures and development-entry criteria, see the [readiness intake](analysis/development-readiness.md).

| # | Capability | Status | Source | Used by |
|---|---|---|---|---|
| E01 | PBIP stores model/report definitions as text; report-definition API defaults to PBIR | Supported; original GA timing not independently reverified | https://learn.microsoft.com/en-us/power-bi/developer/projects/projects-overview and E03 | Source format |
| E02 | TMDL folder format, indentation and expression rules | GA | https://learn.microsoft.com/en-us/analysis-services/tmdl/tmdl-overview | Models |
| E03 | Report definition `byConnection` = `semanticmodelid=<id>` for API deployment (schema 2.0.0) | GA | https://learn.microsoft.com/en-us/rest/api/fabric/articles/item-management/definitions/report-definition | Deploy |
| E04 | Fabric item create / updateDefinition for semantic models and reports, LRO pattern | GA | https://learn.microsoft.com/en-us/rest/api/fabric/semanticmodel/items | Deploy |
| E05 | Power BI enhanced refresh and executeQueries APIs | GA | https://learn.microsoft.com/en-us/rest/api/power-bi/datasets/execute-queries-in-group | Deploy, tests |
| E06 | Power BI Authoring (Modeling) MCP — local server | GA | https://learn.microsoft.com/en-us/power-bi/developer/mcp/power-bi-authoring-mcp | Build |
| E07 | Power BI Authoring MCP — hosted endpoint | Preview | same | Not enabled |
| E08 | `powerbi-authoring` plugin (semantic-model-authoring Preview, powerbi-report-cli) | Preview / OSS | https://github.com/microsoft/skills-for-fabric | Build |
| E09 | `powerbi-report-author` CLI (scaffold, validate, preview) | Preview 0.x | https://www.npmjs.com/package/@microsoft/powerbi-report-authoring-cli | Build, tests |
| E10 | Power BI Desktop Bridge | Preview | https://learn.microsoft.com/en-us/power-bi/developer/projects/projects-external-editing | Screenshots |
| E11 | Fabric MCP (local) | GA per Fabric blog ⚠ | https://github.com/microsoft/mcp/tree/main/servers/Fabric.Mcp.Server | Spec, build |
| E12 | Microsoft Learn MCP server | Available | https://learn.microsoft.com/api/mcp | All |
| E13 | GitHub MCP server v2.0.3 (issues, sub-issues, labels, projects, PRs; no milestone create) | GA | https://github.com/github/github-mcp-server | Work management |
| E14 | GitHub Copilot CLI (plugins, skills, agents, hooks, project MCP) | GA (25 Feb 2026) | https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference | All |
| E15 | Copilot hooks reference (events, fail-closed/open, decision output) | GA (VS Code Preview) | https://docs.github.com/en/copilot/reference/hooks-reference | Guardrails |
| E16 | Custom agents configuration (tools, MCP namespacing, handoffs VS Code only) | GA | https://docs.github.com/en/copilot/reference/custom-agents-configuration | Agents |
| E17 | VS Code harnesses: prompt files and handoffs only in Local harness | GA | https://code.visualstudio.com/docs/agents/run/agent-harnesses | Design |
| E18 | Superpowers v7.0.1, Copilot CLI install via `obra/superpowers-marketplace` | OSS (MIT) | https://github.com/obra/superpowers | Methodology |
| E19 | Spec Kit 1.2.4 (comparison only) | OSS (MIT) | https://github.com/github/spec-kit | ADR-0001 |
| E20 | Tabular Editor 2 CLI BPA, exit code 1 on error severity, no TE3 licence for CI | OSS (MIT) | https://docs.tabulareditor.com/te2/Command-line-Options.html | Gate L1 |
| E21 | Microsoft BPA rules | OSS | https://github.com/microsoft/Analysis-Services/tree/master/BestPracticeRules | Gate L1 |
| E22 | DAX Query View testing pattern | Community | https://github.com/kerski/fabric-dataops-patterns | Gate L2 |
| E23 | Az.Fabric 1.0.0 capacity cmdlets | GA | https://www.powershellgallery.com/packages/Az.Fabric | Capacity IaC |
| E24 | Az.Accounts ≥ 5 returns SecureString tokens | GA | https://learn.microsoft.com/en-us/powershell/azure/migrate-az-14.0.0 | Auth |
| E25 | Copilot cloud agent environments (cloud sandbox Linux, Actions, custom) | GA / Preview | https://docs.github.com/en/enterprise-cloud@latest/copilot/concepts/security-governance-and-network-settings/about-cloud-sandboxes | ADR-0004 |

## Open verifications (Sprint 0 spikes)

| # | Question | Owner | Result |
|---|---|---|---|
| V1 | Does `.github/copilot/settings.json` auto-enable the plugins in Copilot CLI and VS Code? | Agent-assets maintainer | Plugins listed by CLI; auto-enablement and both-harness behavior still unverified |
| V2 | Do hooks dispatch in both hosts, including the intended failure behavior? | Agent-assets maintainer | Offline rule/script tests ran; live dispatch not proven. Review `exit 0` / `|| true` wrappers and timeout behavior |
| V3 | Reconcile Modeling MCP version, server alias and exact dependency selection | Tooling maintainer | Public npm metadata reports 1.0.0; runtime probe blocked by human-only EULA. Two local aliases exposed; no exact version pin added |
| V4 | Tabular Editor 2 loads TMDL using `database.tmdl` | Automation maintainer | Not tested: TE2 is missing; BPA skipped and blocks PR gate |
| V5 | Does optional Copilot code review consume Actions minutes here? | Repository maintainer | Not tested; no review requested. Local reviewer remains the intended default |
| V6 | Repair baseline findings helper and prove local report/DAX pipeline | Automation/model/report maintainers | 160/180 Pester tests pass; commit/PR gates fail; no scaffolded report or loaded Desktop model |

## Readiness reverification (2026-10-30)

The following documentation was searched/fetched through Microsoft Learn MCP. These are capability findings, not claims of a successful deployment.

| Finding | Source | Verification and consequence |
|---|---|---|
| PBIP source is plain-text model/report definitions; external edits and path/sensitivity limitations apply | https://learn.microsoft.com/en-us/power-bi/developer/projects/projects-overview | Fetched 2026-10-30. Use a short path, save/reload carefully, keep service-only settings outside Git |
| Local Authoring MCP is generally available; hosted is preview and cannot reach local files | https://learn.microsoft.com/en-us/power-bi/developer/mcp/power-bi-authoring-mcp | Fetched 2026-10-30. Prefer one local registration for Desktop; plugin can bundle it. Runtime discovery was EULA-blocked; no acceptance attempted |
| `powerbi-report-cli` covers planning/design/authoring/management; structural validation does not replace rendered verification | https://learn.microsoft.com/en-us/power-bi/developer/agentic/power-bi-report-skill-overview | Fetched 2026-10-30. Keep repository approval/deployment constraints even when upstream skills offer publish/delete operations |
| Report definition API supports PBIR and service `byConnection` binding; local files may use `byPath` | https://learn.microsoft.com/en-us/rest/api/fabric/articles/item-management/definitions/report-definition | Fetched 2026-10-30; Fabric MCP also returned report-definition documentation. Keep `byPath` in Git and rewrite only for deploy |
| Dashboards are service-only tile canvases, distinct from Desktop reports | https://learn.microsoft.com/en-us/power-bi/create-reports/service-dashboards | Fetched 2026-10-30. Dashboard-style PBIR pages are supported; service dashboard/tile deployment is not implemented by this repository |

Live package metadata on 2026-10-30: report CLI **0.5.0**, Desktop bridge **1.0.0**, Modeling MCP **1.0.0**, Fabric MCP **1.6.0**. All four `npm view <package> version bin --json` requests exited 0; none installed a package. CLI plugin inventory showed Superpowers **5.1.0** and `powerbi-authoring` **0.3.20**. These observations supersede treating the analysis's version numbers as the installed baseline.

Read-only tooling/plugin `-WhatIf` plans exited 0. Their success messages do **not** mean missing tools were installed or existing plugins reconciled. The current prerequisites and quality-gate failures remain open in [intake #1](https://github.com/urruegg/power-bi-superpower/issues/1).
