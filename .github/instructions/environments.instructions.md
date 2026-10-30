---
applyTo: "config/**/*.json"
description: "Environment, quality and GitHub configuration"
---
# Configuration rules

- No identifiers or personal data: use `${env:NAME}` placeholders and document new variables in `.env.example` and `config/environments/README.md`.
- `prod.json` guards stay strict (`humanOnly`, `requireCleanWorkingTree`, `requireMergedToMain`, `requireTestEvidence`, `requireReleaseApproval` all `true`). Loosening them needs a written decision record (ADR).
- Item display names are identical across DEV, TEST and PROD; the workspace name carries the environment.
- Gate thresholds in `config/quality/gates.json` only get stricter without an ADR.
