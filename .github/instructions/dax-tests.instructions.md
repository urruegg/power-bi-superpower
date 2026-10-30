---
applyTo: "src/**/DAXQueries/*.dax"
description: "DAX query view test files (John Kerski pattern)"
---
# DAX test files

- File name: `<Area>.<SCOPE>.Tests.dax` where SCOPE is `ALL`, `LOCAL`, `DEV`, `TEST` or `PROD`. Scripts run `ALL` plus the scope of the target.
- One query per file. The result has exactly the columns `TestName`, `ExpectedValue`, `ActualValue`, `Passed`.
- Build rows with `ROW(...)` combined with `UNION(...)`; finish with `EVALUATE ADDCOLUMNS(_Tests, "Passed", [ExpectedValue] = [ActualValue])` or an explicit tolerance for decimals (`ABS([ExpectedValue] - [ActualValue]) < 0.005`).
- Expected values come from an independent source (spec, source system, reconciliation sheet). Write the comment `// Source: …` above each block of expectations.
- Keep `ExpectedValue` and `ActualValue` the same data type in every row (round currency to 2 decimals).
- `ALL` tests must not use `INFO.*` functions or DMVs (they fail on the service `executeQueries` API); put metadata tests in `LOCAL` files.
- Optional directives on the first lines: `// @role: <RoleName>` (local only) and `// @effectiveUserName: <upn>` to test row-level security. Use synthetic user names.
- A test that cannot fail is not a test: check at least one non-trivial filter context per measure.
