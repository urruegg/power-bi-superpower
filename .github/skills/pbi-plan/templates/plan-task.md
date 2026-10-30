### Task T<k>: <title>  (sub-issue #<m>)

**Files:**
- `src/<Project>/<Project>.SemanticModel/DAXQueries/<Area>.ALL.Tests.dax` (test)
- `src/<Project>/<Project>.SemanticModel/definition/tables/<Table>.tmdl` (implementation)

**Interfaces:** measure `'<Measure name>'` in table `<Table>`, display folder `<Folder>`, format `<format string>`.

- [ ] **RED** — add test rows for `<Measure name>` (expected values from spec §9: <values and source>). Run:
      `pwsh scripts/quality/Invoke-PbiDaxTests.ps1 -ProjectPath src/<Project> -Target Local`
      Expect: the new rows FAIL (measure missing or wrong).
- [ ] **GREEN** — create the measure (Modeling MCP on Desktop, then save; or TMDL edit and reload). Re-run the tests. Expect: all PASS.
- [ ] **REFACTOR** — variables, `DIVIDE`, format string, `///` description, display folder. Re-run tests and `pwsh scripts/quality/Invoke-PbiQualityGate.ps1 -Profile commit`.
- [ ] **COMMIT** — `feat(model): add <Measure name> (#<m>)`; tick this task in the plan; comment the pasted test summary on sub-issue #<m>.
