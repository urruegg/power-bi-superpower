# Templates

Used by `scripts/build/New-PbipProject.ps1 -Name <Name>` to start a new PBIP project under `src/<Name>/`.

| Path | Becomes |
|---|---|
| `semantic-model/` | `src/<Name>/<Name>.SemanticModel/` — compatibility level 1702, marked `Date` table, hidden `About` table, `Environment` parameter, integrity and environment smoke tests |
| `report-blueprint.json` | `src/<Name>/report-blueprint.json` — extend it in the Spec phase, then scaffold the report with `scripts/build/New-PbipReport.ps1` |

Tokens replaced by the script: `__MODEL_NAME__`, `__LOGICAL_ID__` (new GUID per project; required to be unique by Fabric Git integration).
