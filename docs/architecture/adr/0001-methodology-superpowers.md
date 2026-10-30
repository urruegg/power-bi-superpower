# ADR-0001 — Superpowers as the engineering methodology

**Status:** Accepted · **Date:** 2026-10-30

## Context
Agents need a disciplined path from idea to merged code. Two GitHub-native options exist: obra/superpowers (v7.0.1, 15 skills, plugin for Copilot CLI) and GitHub Spec Kit (v1.2.4, `/speckit-*` skills). They overlap in spec → plan → tasks. Running both creates competing artefacts and instructions.

## Decision
Use **Superpowers** for the whole flow (brainstorming, worktrees, writing-plans, subagent-driven development with TDD, verification, code review, finishing a branch, writing skills). Add Power BI specifics through repository skills (`pbi-*`). Do not install Spec Kit; adopt its useful ideas (constitution → `AGENTS.md` and operating-model principles; checklists → spec acceptance-test table).

## Consequences
- Artefacts in Superpowers default locations (`docs/superpowers/specs`, `docs/superpowers/plans`), named with the issue number.
- Sessions must start with `using-superpowers`; the plugin's SessionStart hook does it in Copilot CLI, `AGENTS.md` and the repository session hook remind otherwise.
- Superpowers does not accept community skills; our extensions live in this repository.

## Alternatives
Spec Kit only (strong governance artefacts, weaker execution discipline); both with a community bridge (not verified on Copilot).
