---
applyTo: "src/**/*.SemanticModel/**/*.tmdl"
description: "TMDL authoring rules for semantic models in this repository"
---
# TMDL rules

- Prefer the `powerbi-modeling-mcp` server against Power BI Desktop for changes (Microsoft `semantic-model-authoring` skill, Tier 1). Edit TMDL by hand only when Desktop is closed, then reload the project in Desktop to prove it still opens.
- Indent with **tabs**. Object declarations: `table`, `column`, `measure`, `partition`, `relationship`, `role`, `expression`. Quote names with spaces or special characters: `'Order Date'`.
- `database.tmdl` starts with `database <name>` and keeps `compatibilityLevel` at 1702 or higher.
- `model.tmdl` lists every table with `ref table <Name>`; adding a table file means adding its `ref` line.
- In a table: measures first, then columns, hierarchies, partitions. Every measure has `formatString` and a `///` description directly above it. Multi-line DAX goes between triple backticks.
- Hide keys and technical columns (`isHidden`), set `summarizeBy: none` on IDs and attributes, set `sortByColumn` for month names.
- Data source values (server, database, environment) are M parameters in `expressions.tmdl` (`meta [IsParameterQuery=true, …]`) so deployment can set them per environment. Never hard-code environment-specific values in partitions.
- Do not add `lineageTag` to new objects; Desktop assigns them. Never copy lineage tags between objects.
- Do not author `PBI_*` annotations, do not edit `.pbi/` files, do not add RLS role members.
- After a change, run `pwsh scripts/quality/Invoke-PbiQualityGate.ps1 -Profile commit` and the model's DAX tests.
