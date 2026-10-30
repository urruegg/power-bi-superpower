# ADR-0002 — PBIP with TMDL and PBIR as the only source format

**Status:** Accepted · **Date:** 2026-10-30

## Context
PBIP and developer mode are generally available (Sep 2026); PBIR is the default report format in Desktop and the service; TMDL is GA. Agents edit text files and the Power BI Modeling MCP server well; PBIX is opaque.

## Decision
- Semantic models as TMDL (`definition/`), reports as PBIR (`definition/`), in `src/<Project>/`.
- Reports in Git bind to the co-located model with `byPath`; deployment rewrites to `byConnection` (`semanticmodelid=<id>`).
- New reports are scaffolded with `powerbi-report-author scaffold` (via `scripts/build/New-PbipReport.ps1`), never hand-written; existing `$schema` versions are preserved.
- `.pbi/localSettings.json` and `.pbi/cache.abf` are git-ignored; `DAXQueries/` holds tests and is committed.

## Consequences
- Every model change is reviewable as a text diff; DAX tests live next to the model.
- Desktop remains the visual verification tool; schema versions can lag behind new Desktop releases (re-scaffold with `-Offline` if needed).
- Sensitivity labels, RLS membership and credentials stay service-side human actions.

## Alternatives
PBIX in Git (no diffs); Fabric Git integration as the source of truth (needs a GitHub connection per workspace and couples Git structure to workspaces).
