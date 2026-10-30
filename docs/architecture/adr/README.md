# Architecture decision records

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-methodology-superpowers.md) | Superpowers is the engineering methodology; Spec Kit is not installed | Accepted |
| [0002](0002-source-format-pbip.md) | PBIP with TMDL and PBIR; `byPath` in Git; reports are scaffolded | Accepted |
| [0003](0003-deployment-powershell-rest.md) | PowerShell 7 + Fabric/Power BI REST, no GitHub Actions | Accepted |
| [0004](0004-agent-surfaces-and-mcp.md) | VS Code + Copilot CLI on Windows; MCP allow-list | Accepted |
| [0005](0005-environments-and-identity.md) | DEV / TEST / PROD workspaces; human identity; PROD human-only | Accepted |
| [0006](0006-testing-strategy.md) | DAX TDD and gate levels L0–L3 | Accepted |
| [0007](0007-agent-supply-chain.md) | Plugins pinned in `tools/versions.json`; vendoring optional | Accepted |
| [0008](0008-work-management-github.md) | GitHub issues, labels as phases and gates, milestones as sprints | Accepted |

New ADRs: copy the structure (Context, Decision, Consequences, Alternatives), number sequentially, link from this table, and get CODEOWNERS approval.
