# Sprints

| File | Purpose |
|---|---|
| `current.json` | Pointer to the active sprint (`number`, `goal`, `milestone`, `startDate`, `endDate`). Written by `scripts/sprint/New-PbiSprint.ps1`; read by the session-start hook and the `pbi-sprint-flow` skill. Absent until the first sprint starts. |
| `sprint-NN/sprint.md` | Goal, capacity, committed scope, risks, demo plan, review and retro of sprint NN. |
| `_template/sprint.md` | Template used by the script. |

Start by asking `pbi-sprint-lead` to load `pbi-sprint-flow` and `pbi-sprint-start`, review the intake/backlog and propose a goal and scope. The product owner agrees the goal, dates and capacity **before** sprint creation.

The walking skeleton is called "Sprint 0" conceptually, but the current scripts support numbers **1-99**, and status treats zero as missing. Resolve that mismatch or explicitly agree numbered Sprint 01 for readiness; do not create `current.json` manually. See [readiness intake #1](../analysis/development-readiness.md).

After agreement, preview the selected number and goal (example only):

```powershell
pwsh -NoProfile -File .\scripts\sprint\New-PbiSprint.ps1 -Number 1 -Goal "Prove the SalesStarter toolchain before real reports" -WhatIf
```

`-WhatIf` is not a started sprint. After creation, `Get-PbiSprintStatus.ps1` must read the active pointer and milestone successfully. Sprint agreement does not replace specification, implementation-plan or release approval labels.
