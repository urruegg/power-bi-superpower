# SalesStarter — walking skeleton

A deliberately small PBIP project that proves the whole tool chain in **Sprint 0** before real work starts: TMDL authoring, DAX tests, report scaffolding, quality gates, DEV/TEST deployment and post-deployment tests. Replace or retire it once your first real project is live.

**Current state:** model and blueprint only; the report and PBIP entry file are not scaffolded. The [readiness intake](../../docs/analysis/development-readiness.md) records failing baseline checks and missing tools. The expected values below are test oracles, not a claim that the tests have run successfully in Desktop.

## Contents

| Path | Purpose |
|---|---|
| `SalesStarter.SemanticModel/definition/` | TMDL: `Sales` fact, `Product` and `Date` dimensions, hidden `About` table; 7 measures; `Environment` parameter |
| `SalesStarter.SemanticModel/DAXQueries/` | Tests: `Measures.ALL`, `ModelIntegrity.ALL`, `Environment.<LOCAL|DEV|TEST|PROD>` |
| `report-blueprint.json` | One-page wireframe (KPI card, column chart, bar chart, table, slicer) used by `scripts/build/New-PbipReport.ps1` |
| `SalesStarter.Report/` | Created by the scaffold step (not in the initial commit) |
| `SalesStarter.pbip` | Created by the scaffold step; open this in Power BI Desktop |

## Data

All data is synthetic and embedded in the Power Query partitions (`#table`), so the model refreshes in Desktop and in the service without credentials or gateways. 84 order lines, January 2025 to September 2026, six products in three categories.

## Expected values (oracle for the tests)

Calculated independently from the rows in `tables/Sales.tmdl`:

| Fact | Value |
|---|---|
| Order lines | 84 |
| Total quantity | 252 |
| Total sales | 91,445.00 |
| Total sales, category Bikes | 83,200.00 |
| Total quantity, category Clothing | 84 |
| Average unit price | 362.88 |
| Total sales 2025 | 52,145.00 |
| Sales YTD at 2026-06 | 29,040.00 |
| Total sales 2025-03 / 2026-03 | 1,890.00 / 6,525.00 |
| Sales YoY % at 2026-03 | 2.4524 |
| Date table rows (2025-01-01 to 2026-12-31) | 730 |

## Run it after readiness tasks and plan approval

```powershell
pwsh -NoProfile -File .\scripts\build\New-PbipReport.ps1 -ProjectPath .\src\SalesStarter
powerbi-report-author validate .\src\SalesStarter\SalesStarter.Report
# Human: open SalesStarter.pbip in Desktop, allow the model to load, refresh and save.
pwsh -NoProfile -File .\scripts\quality\Invoke-PbiDaxTests.ps1 -ProjectPath .\src\SalesStarter -Target Local
pwsh -NoProfile -File .\scripts\quality\Invoke-PbiQualityGate.ps1 -Profile pr -Target Local
# After local proof and service setup, review the DEV plan before applying:
pwsh -NoProfile -File .\scripts\deploy\Deploy-PbiProject.ps1 -Environment DEV -WhatIf
```

Expected artifacts are `SalesStarter.Report` and `SalesStarter.pbip` beside the model, with the report bound by local path. Collect rendered screenshots for human review, then follow the [DEV/TEST deployment runbook](../../docs/runbooks/deploy.md). A NotApplicable report check, skipped DAX test or `-WhatIf` plan is not a completed walking skeleton.
