# Evidence record format (`.evidence/*.json`)

```json
{
  "schema": "pbi-superpower/evidence/1.0",
  "kind": "quality-gate | dax-tests | deployment | infrastructure",
  "createdUtc": "2026-11-03T09:15:00Z",
  "environment": "DEV",
  "repository": { "commit": "<sha>", "branch": "feat/12-sales-overview", "dirty": false },
  "host": { "os": "Windows", "pwsh": "7.4.6" },
  "data": { "profile": "pr", "outcome": "Passed", "results": [ { "level": "L0", "check": "PbipStructure", "status": "Passed", "summary": "…" } ] }
}
```

- Evidence files are git-ignored; they may contain workspace and item IDs.
- The `.md` twin is safe to paste: GUIDs become `<id>`, e-mail addresses are masked.
- Deployments to PROD require a `deployment` record for TEST with the same short commit SHA and outcome `Passed`.
