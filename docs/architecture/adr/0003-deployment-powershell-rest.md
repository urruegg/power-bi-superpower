# ADR-0003 — Deployment with PowerShell 7 and Fabric/Power BI REST (no GitHub Actions)

**Status:** Accepted · **Date:** 2026-10-30

## Context
GitHub Actions are out of scope. Options for deploying PBIP items: native PowerShell + REST (FabricPS-PBIP pattern), community modules (MicrosoftFabricMgmt, FabricTools), Python engines (fabric-cicd 1.4.0, Fabric CLI `fab deploy` 1.8.0), Fabric Git integration, deployment pipelines.

## Decision
A repository module (`scripts/modules/PbiSuperpower`) implements the few calls needed — workspace ensure, role assignments, item definition create/update, long-running operations, throttling, report rebinding, parameter rewrite, refresh, executeQueries — with Az.Accounts for tokens. Entry scripts: `Deploy-PbiInfrastructure.ps1`, `Deploy-PbiProject.ps1`, optional `Deploy-FabricCapacity.ps1` (Az.Fabric). Every run writes evidence; remote writes support `-WhatIf`.

## Consequences
- One language (PowerShell) for agents and humans; no Python runtime; precise per-item control and readable plans.
- We own LRO, 429 and paging logic (covered by Pester tests).
- No orphan clean-up: items removed from Git are deleted manually (human-only by design).

## Alternatives
fabric-cicd / `fab deploy` (idempotent, orphan clean-up, parameter.yml) — revisit if the item mix grows beyond semantic models and reports. Deployment pipelines for TEST→PROD promotion inside one tenant — possible later; the definition API keeps Git as the single source.
