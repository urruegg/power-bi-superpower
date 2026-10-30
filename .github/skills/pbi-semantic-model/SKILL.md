---
name: pbi-semantic-model
description: Use when building or changing a Power BI semantic model in this repository (tables, columns, relationships, measures, Power Query partitions, parameters, date table, calculation groups). Chooses between the Power BI Modeling MCP server against Power BI Desktop and direct TMDL edits, applies the repository's modeling conventions, and keeps the TMDL on disk, the open Desktop model and the DAX tests in sync.
---

# Semantic model build

Microsoft's `semantic-model-authoring` skill (plugin `powerbi-authoring`) holds the authoring mechanics — tool priority, TMDL guidelines, modeling and DAX guidelines. Load it. This skill adds how we work in this repository.

## 1. Choose the path (never mix them on the same model at the same time)

| Situation | Path | How |
|---|---|---|
| Power BI Desktop has `src/<Project>/<Project>.pbip` open | **Tier 1: Modeling MCP** | Tell `powerbi-modeling-mcp`: "Connect to '<Project>' in Power BI Desktop". Use transactions for multi-step changes. When done, ask the human to **save in Desktop** (Ctrl+S) — that writes the TMDL files. Then `git diff` to review. |
| Desktop closed, small change | **Tier 2: TMDL edit** | Edit `definition/**/*.tmdl` following `.github/instructions/tmdl.instructions.md`. Then open (or reload with `powerbi-report-author preview "<Report folder>" --host desktop --reload-with-model`) to prove it loads, and refresh the changed tables. |
| No Desktop available (cloud agent, Linux) | **Tier 2 + DEV** | Edit TMDL, run `-Profile commit`, deploy to DEV (`Deploy-PbiProject.ps1 -Environment DEV`) and run tests against DEV. |

The first time the Modeling MCP server starts it asks for its licence (EULA) to be accepted. That is a human decision — ask the user; never accept it yourself.

## 2. Conventions
- **Star schema.** Facts hold keys and numbers; dimensions hold attributes. Single-direction relationships from dimension to fact; many-to-many and bidirectional only with a written reason in the spec.
- **Names.** Business names with spaces (`Sales Amount`, `Customer Name`); tables singular nouns (`Sales`, `Customer`, `Date`); measures describe the result (`Total Sales`, `Sales YoY %`).
- **Columns.** Correct data types; hide keys and technical columns; `summarizeBy: none` on IDs and attributes; `sortByColumn` for month and weekday names; no calculated columns when Power Query or the source can do it.
- **Date table.** One marked date table (`dataCategory: Time`, key `Date` column) with Year, Month Number, Month, Year Month; auto date/time stays off.
- **Measures.** Explicit measures for everything users see; `formatString` and `///` description on every measure; display folders by subject; base measures first, derived measures reuse them.
- **Parameters.** Every environment-specific value (server, database, lakehouse, environment name) is an M parameter in `expressions.tmdl`; deployment sets it per environment from `config/environments/*.json`.
- **Storage mode.** Import by default; Direct Lake when data is in OneLake; DirectQuery only when the spec says so.
- **Performance.** Integer keys, low-cardinality columns, no high-precision datetimes in facts, no unused columns.

## 3. Definition of done for a model change
- DAX tests written first and passing locally (`pbi-dax-tdd`).
- `pwsh scripts/quality/Invoke-PbiQualityGate.ps1 -Profile commit` passes (structure, TMDL conventions, hygiene).
- Best Practice Analyzer has no errors (`pwsh scripts/quality/Invoke-PbiModelBpa.ps1 -SemanticModelPath src/<Project>/<Project>.SemanticModel`).
- Desktop opens the project and the changed tables refresh.
- TMDL diff reviewed: only intended objects changed; no stray `lineageTag` churn beyond the new objects.

## 4. Pitfalls
- Desktop does not pick up TMDL edits made while it is open unless you reload; edits made in Desktop overwrite files on save. Coordinate with the human.
- Renaming a table or measure breaks report visuals that reference it — search the `*.Report` folder for the old name and update `visual.json` files in the same task.
- Never change RLS role **membership** — only role definitions (see `pbi-rls-security`).
