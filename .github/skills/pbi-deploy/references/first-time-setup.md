# First-time deployment setup

## Tenant settings (Fabric admin portal — human, once)
| Setting | Needed for |
|---|---|
| Users can create Fabric items / workspaces (or a security group including the deployers) | Creating DEV/TEST/PROD workspaces |
| *Dataset Execute Queries REST API* (Integration settings) | Post-deployment DAX tests (`executeQueries`) |
| *Service principals can call Fabric public APIs* and *Service principals can create workspaces, connections, and deployment pipelines* (scoped to a group) | Only if a service principal deploys (optional, see below) |
| XMLA endpoint Read Write on the capacity | Only for the Power BI Modeling MCP against workspace models |
| *Users can use the Power BI Model Context Protocol server endpoint* | Only for the hosted (remote) Power BI MCP servers |

## Capacity
Workspaces should sit on a Fabric (F SKU) or Premium capacity for DEV/TEST/PROD parity. Set `PBI_CAPACITY_NAME`. Optional Azure IaC: `scripts/infra/Deploy-FabricCapacity.ps1` (Az.Fabric) and `Set-FabricCapacityState.ps1` to pause DEV capacity outside working hours.

## Identity
- **Default: the signed-in human** (Az.Accounts interactive sign-in) for DEV, TEST and PROD — matches "PROD is human-only".
- **Optional: a service principal with a certificate** per environment for TEST (`Connect-PbiFabric -ServicePrincipalId … -CertificateThumbprint … -TenantId …`). One principal never spans DEV and PROD. Secrets in parameters are not supported by design.

## Environment variables
Copy `.env.example` to `.env.local` and fill in capacity name and Entra group object IDs. These never go into Git.

## Verify
```powershell
pwsh scripts/infra/Deploy-PbiInfrastructure.ps1 -Environment DEV -WhatIf
pwsh scripts/deploy/Deploy-PbiProject.ps1 -Environment DEV -WhatIf
```
