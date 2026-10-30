---
name: pbi-report-pbir
description: Use when creating or changing Power BI report pages and visuals (PBIR). Scaffolds new reports from report-blueprint.json with the official powerbi-report-author CLI, then refines pages, visuals, filters, theme and accessibility with Microsoft's powerbi-report-cli skill, validating after every batch and verifying in Power BI Desktop with screenshots.
argument-hint: "<project> <page or visual change>"
---

# Report build (PBIR)

Microsoft's `powerbi-report-cli` skill (plugin `powerbi-authoring`) is the source of truth for PBIR mechanics — visual roles, formatting objects, encodings, validation, preview. Load it. This skill adds our workflow and conventions.

## 1. New report → scaffold, never hand-write
```powershell
pwsh scripts/build/New-PbipReport.ps1 -ProjectPath src/<Project>           # uses src/<Project>/report-blueprint.json
```
The script runs `powerbi-report-author scaffold` (valid `.pbip`, `.platform`, `definition.pbir` with `byPath`, `version.json`, `report.json` with a real base theme, `pages.json`, first page), writes one `visual.json` per blueprint visual (cards, column/bar/line charts, tables, slicers, with titles and alt text) and validates. If a scaffolded file triggers "This version of Power BI does not support the version…", re-run with `-Force -Offline` (older, accepted schema versions).

## 2. Change an existing report
1. Read the page and visual JSON you will touch; keep their `$schema` versions.
2. For a new visual, discover roles first: `powerbi-report-author catalog describe <visualType>`; formatting: `powerbi-report-author formatting describe-object <visualType> <object>`.
3. Edit; then `powerbi-report-author validate "src/<Project>/<Project>.Report"` — fix every error before going on.
4. If Desktop is open: `powerbi-report-author preview "src/<Project>/<Project>.Report" --host desktop --status`; reload only when `hasUnsavedChanges` is false: `… --host desktop --reload`.
5. Screenshot for review into an absolute path outside the PBIP folder: `… --host desktop --screenshot "<repo>\.evidence\screenshots\<page>.png" --page "<page id>"`. Look at the image; compare with the blueprint and spec.

## 3. Conventions
- Layout on a 12-column grid with 24 px margins and 16 px gutters (the blueprint grid); KPIs top, trend middle, detail bottom; filters in slicers or the filter pane, not both.
- `cardVisual` (role `Data`) for KPIs; one multi-value card instead of several single cards in a row.
- Every visual: title, alt text, logical tab order; no overlap; ≤ 20 visuals per page.
- Colours and fonts from the theme; conditional formatting only where the spec asks.
- Measures, not implicit aggregations, in visuals (exceptions need a reason).
- Bindings: `definition.pbir` keeps `byPath`; deployment rewrites it.

## 4. Definition of done for a report change
- `powerbi-report-author validate` passes; `-Profile commit` gate passes (includes report conventions).
- Desktop renders the page without errors; screenshot reviewed against the spec and attached to the PR (L3 gate is attended).
- Field renames in the model are reflected in all visuals (search the report folder for the old name).
