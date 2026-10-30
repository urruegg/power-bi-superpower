---
applyTo: "src/**/*.Report/**"
description: "PBIR report authoring rules"
---
# PBIR rules

- Follow Microsoft's `powerbi-report-cli` skill (plugin `powerbi-authoring`) for file mechanics; this file adds repository conventions.
- Never hand-write a report shell (`.pbip`, `.platform`, `definition.pbir`, `version.json`, `report.json`, `pages.json`). Scaffold with `scripts/build/New-PbipReport.ps1`.
- Preserve every existing `$schema` URL. When adding a file, copy the `$schema` from a sibling of the same type; never invent or bump versions.
- `definition.pbir` keeps `byPath` to `../<Project>.SemanticModel`. Deployment rewrites it to `byConnection`; never commit `byConnection`, `semanticmodelid=` or `powerbi://` strings.
- Object names (page and visual folder names) are word characters or hyphens. Add every new page to `pages.json` `pageOrder`.
- Use `cardVisual` (role `Data`) for KPIs, not legacy `card` / `multiRowCard`. Avoid Q&A, Bing map and filled map visuals.
- Every visual has a title and alt text; tab order follows reading order; no overlapping visuals; at most 20 visuals per page.
- Use the theme for colours and fonts; per-visual formatting only when the spec asks for it.
- After each batch of edits run `powerbi-report-author validate "<Report folder>"`, then reload in Desktop (`powerbi-report-author preview "<Report folder>" --host desktop --reload`) when Desktop is open.
