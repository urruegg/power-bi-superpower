# ADR-0006 — Testing strategy: DAX TDD and gate levels

**Status:** Accepted · **Date:** 2026-10-30

## Context
Superpowers requires test-driven development and verification before completion. Power BI has no unit-test framework, but DAX queries can assert values; static analysis exists (BPA, PBIR validation).

## Decision
- **DAX tests** in `DAXQueries/<Area>.<SCOPE>.Tests.dax` returning `TestName`, `ExpectedValue`, `ActualValue`, `Passed` (Kerski pattern); expected values from independent sources; run locally against Desktop (ADOMD) or against a workspace (`executeQueries`); directives for RLS.
- **Gate levels:** L0 structure and hygiene, L1 static analysis (Tabular Editor 2 BPA, report conventions), L2 behaviour (DAX tests), L3 attended visual review. Profiles `commit`, `pr`, `deploy-*`, `release` in `config/quality/gates.json`.
- Skipped required checks fail the gate unless explicitly allowed with a reason.

## Consequences
- Tests need a running Desktop or a deployed model; agents get DEV deployments for service-side tests.
- Visual quality remains a human judgement (screenshots).

## Alternatives
Semantic Link Labs BPA in Fabric notebooks (needs Fabric capacity and notebooks; optional later); Fab Inspector rules (optional).
