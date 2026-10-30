# ADR-0008 — Work management on GitHub

**Status:** Accepted · **Date:** 2026-10-30

## Context
Agents use the GitHub MCP server for issues, sub-issues, labels, projects and pull requests. It cannot create milestones. Approval must be visible and attributable.

## Decision
- Issue forms for idea, feature, task, bug, sprint, release.
- `phase:*` labels track the flow; `gate:*` labels are human approvals (agents are blocked from applying them); `agent:ready` marks Definition of Ready.
- Sprints are milestones (`Sprint NN`) created by `scripts/sprint/New-PbiSprint.ps1` with a sprint document and tracking issue; an optional GitHub Project with Phase/Priority/Size fields.
- Labels, ruleset and project are configuration as code in `config/github/` applied by `Initialize-GitHubRepo.ps1`.

## Consequences
- Label events give an audit trail of approvals (who applied `gate:*`, when).
- Projects v2 field updates by agents need option IDs; the board is a convenience, labels are the source of truth.

## Alternatives
Azure Boards (better for enterprise portfolios; Azure DevOps MCP server GA) — possible for customers already on Azure DevOps.
