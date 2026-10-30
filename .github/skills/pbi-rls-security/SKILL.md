---
name: pbi-rls-security
description: Use when a Power BI model or report involves restricted data - row-level or object-level security roles, personal data, sensitivity labels, workspace access. Designs RLS roles in TMDL, writes RLS tests with role and user directives, and keeps role membership, credentials and labels as human-only service actions.
---

# Security for semantic models and reports

## Decide in the spec
- Who may see which rows? Express it as rules ("a regional manager sees their region"), then as roles.
- Static roles (fixed filter per role) vs dynamic roles (`USERPRINCIPALNAME()` against a security table). Prefer dynamic roles with a security dimension when more than three groups exist.
- Object-level security only for genuinely confidential columns or tables.
- Sensitivity label and whether personal data is present (minimise; aggregate where possible).

## Build (TMDL)
- One file per role: `definition/roles/<Role>.tmdl`, referenced from `model.tmdl` with `ref role <Role>`.
  ```
  role 'Regional Manager'
  	modelPermission: read

  	tablePermission Region = [Manager Email] = USERPRINCIPALNAME()
  ```
- Filter on dimensions, not facts; keep the security table small and hidden.
- Never add role **members** (users or groups) in TMDL, scripts or the REST API. Membership is assigned in the service by the data owner.

## Test (before and after)
- Add `<Area>.LOCAL.Tests.dax` files that start with `// @role: <Role>` or `// @effectiveUserName: <synthetic.user@contoso.com>` and assert what that role sees (row counts, totals, a forbidden value returning blank).
- On a workspace, `@effectiveUserName` maps to the executeQueries impersonation; it is not supported for service principals on models with RLS — run those tests interactively.
- Include a negative test: a user outside every role sees nothing.

## Service-side (human-only, document in the release issue)
- Role membership, sensitivity label, workspace access beyond `config/environments/*.json`, data source credentials, gateway bindings.

## Personal data rules
- No real personal data in Git (sample data, tests, screenshots, docs). Use synthetic users like `user.a@contoso.com`.
- Screenshots from DEV/TEST with real data stay in `.evidence/` (git-ignored) and are not attached to public issues.
