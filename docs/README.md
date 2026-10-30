# Documentation

New here? Read the [repository overview](../README.md), check the [readiness assessment](analysis/development-readiness.md), then follow [workstation setup](getting-started/setup.md) and the [first-sprint walkthrough](getting-started/first-sprint.md). The capability analysis describes the intended toolchain; the readiness assessment records what actually ran.

| Start here | |
|---|---|
| [Readiness intake](analysis/development-readiness.md) | Verified baseline, tooling/MCP/skill inventory, blockers and proposed readiness backlog |
| [Setup](getting-started/setup.md) | Existing-checkout vs new-repository setup, trusted downloads, tools and MCP |
| [First sprints](getting-started/first-sprint.md) | Walking skeleton, approval gates, commands and first real report |
| [Operating model](architecture/operating-model.md) | Principles, flow, roles, gates, artifacts and guardrails |
| [Capability analysis](analysis/capability-analysis.md) | Dated input analysis of plugins, agents, hooks and MCP tools; not proof of local readiness |
| [ADRs](architecture/adr/README.md) | Architecture decisions |
| [Deployment](runbooks/deploy.md), [troubleshooting](runbooks/troubleshooting.md) | Operations |
| [Evidence register](evidence-register.md) | Capability sources, current re-verifications and open spikes |
| [Sprints](sprints/README.md) | Proposed vs active sprint context |
| [Specs](superpowers/specs/README.md), [plans](superpowers/plans/README.md) | Human-reviewed designs and implementation plans |

## Which artifact is meant?

A semantic model is TMDL; an interactive report (including a dashboard-style overview page) is PBIR. A **Power BI service dashboard** is a separate tile-based service artifact, not a PBIP report. This repository does not automate dashboard/tile deployment, app distribution, gateways or RLS membership. Include those as explicit human-owned acceptance/release steps when needed.
