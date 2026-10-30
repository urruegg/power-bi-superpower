# ADR-0005 — Environments and identity

**Status:** Accepted · **Date:** 2026-10-30

## Context
Without Actions there is no OIDC-federated pipeline identity. PROD changes must stay accountable to a person.

## Decision
- Three workspaces: `Power BI Superpower [DEV]`, `[TEST]`, and PROD without suffix; item names identical across them.
- DEV: any branch, developer or agent. TEST: `main` only, clean tree, merged. PROD: human only, `main`, TEST evidence for the same commit, `gate:release-approved`, typed confirmation.
- Default identity is the signed-in human (Az.Accounts). A certificate-based service principal per environment is optional for TEST. Secrets are never passed as parameters or stored in Git.
- IDs (groups, capacities) come from environment variables or git-ignored overlays.

## Consequences
- PROD deployment requires a human at a Windows workstation with PowerShell 7 — intended.
- Tenant settings for workspace creation and `executeQueries` are prerequisites (see `pbi-deploy/references/first-time-setup.md`).

## Alternatives
Service principal everywhere (needs secret/certificate management on workstations); Fabric deployment pipelines with in-product approvals for PROD.
