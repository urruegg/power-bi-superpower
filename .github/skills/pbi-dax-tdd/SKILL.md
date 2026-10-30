---
name: pbi-dax-tdd
description: Use whenever a DAX measure, calculated column, calculation item or RLS rule is created or changed. Applies the Superpowers test-driven-development cycle to DAX - write a failing DAX query view test with independently sourced expected values, implement until it passes, refactor - and runs the tests against Power BI Desktop or a DEV/TEST workspace with the repository scripts.
argument-hint: "<measure or test area>"
---

# Test-driven DAX

Superpowers `test-driven-development` applies unchanged: **no production DAX without a failing test first.** This skill defines what a DAX test is here and how to run it.

## The test format (John Kerski's DAX Query View pattern)
- Location: `src/<Project>/<Project>.SemanticModel/DAXQueries/`.
- Name: `<Area>.<SCOPE>.Tests.dax` — SCOPE `ALL` (everywhere), `LOCAL` (Desktop only, may use `INFO.*`), `DEV`, `TEST`, `PROD` (environment-specific values).
- Result columns: `TestName`, `ExpectedValue`, `ActualValue`, `Passed`. Start from `templates/Measure.ALL.Tests.dax`.
- Desktop shows these files as DAX query view tabs, so humans can run them too.

## The cycle
1. **RED.** Add rows for the new behaviour. Expected values come from an **independent oracle**: the spec's acceptance table, a source-system report, a reconciliation sheet, or a hand calculation from the sample data written next to the test as `// Source: …`. Never copy the value the measure currently returns. Run the tests and **watch them fail for the right reason** (missing measure, wrong value).
2. **GREEN.** Implement the smallest DAX that passes (via Modeling MCP or TMDL, see `pbi-semantic-model`). Run again — all rows pass.
3. **REFACTOR.** Variables, `DIVIDE`, remove repetition, format string, description, display folder. Run again.
4. **Commit** test and measure together; paste the test summary into the sub-issue.

## Running tests
```powershell
# Power BI Desktop with the project open (fast inner loop)
pwsh scripts/quality/Invoke-PbiDaxTests.ps1 -ProjectPath src/<Project> -Target Local
# Deployed model in a workspace (after Deploy-PbiProject.ps1 -Environment DEV)
pwsh scripts/quality/Invoke-PbiDaxTests.ps1 -ProjectPath src/<Project> -Target DEV
```
With Desktop open you can also run a single query through `powerbi-modeling-mcp` (`dax_query_operations`) while iterating; the script run is the evidence.

## What to test for each measure
- Overall value (no filters).
- At least one slice per important dimension (`CALCULATE([Measure], 'Product'[Category] = "Bikes")`).
- Totals equal the sum of parts where the business expects additivity (or explicitly not, for ratios).
- Blank and zero handling (a period with no data).
- Time intelligence boundaries (first month of year, leap day, prior year with no data).
- RLS: the same measure under a role or user (directives `// @role:` and `// @effectiveUserName:` on the first lines).

## Anti-patterns
- Tests that compare a measure with itself or with an identical formula.
- Expected values updated to make a failing test pass without a source.
- `ALL` tests that use `INFO.*` functions (they fail on the service API — use a `LOCAL` file).
- Mixed data types between `ExpectedValue` and `ActualValue` (round decimals: `ROUND(x, 2)`).
