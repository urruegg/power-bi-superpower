## Summary
<!-- What changed and why, in two or three sentences. -->

**Issue:** #  ·  **Spec:** `docs/superpowers/specs/…`  ·  **Plan:** `docs/superpowers/plans/…`

## Change type
- [ ] Semantic model (TMDL / DAX / Power Query)
- [ ] Report (PBIR)
- [ ] Security / RLS
- [ ] Environment or quality configuration
- [ ] Scripts / infrastructure
- [ ] Agent assets (skills, agents, instructions, hooks)
- [ ] Documentation only

## Validation evidence
<!-- Paste the masked summary from .evidence/*-quality-gate-*.md for the LATEST commit. No pasted output = not done. -->
```text
pwsh scripts/quality/Invoke-PbiQualityGate.ps1 -Profile pr -Target Local
<paste summary>
```

<!-- Paste the DEV deployment summary (.evidence/*-deployment-DEV-*.md) when the model or report changed. -->
```text
pwsh scripts/deploy/Deploy-PbiProject.ps1 -Environment DEV
<paste summary>
```

## Tests
- [ ] New/changed measures have DAX tests in `DAXQueries/*.Tests.dax`, written before the implementation
- [ ] Expected values have a named independent source
- [ ] Skipped checks are listed below with the reason

## Screenshots (attended visual review)
<!-- Attach page screenshots for report changes. No personal data. -->

## Security and privacy
- [ ] No IDs, secrets, tenant names or personal data in the diff
- [ ] RLS impact: none / described below
- [ ] Human service actions needed after deployment (membership, credentials, labels) listed below

## Deployment notes
<!-- New projects in config/environments/*.json, parameter values, refresh changes. -->
