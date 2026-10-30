# Third-party components

This repository references (and, on request, installs) the following components. None of their code is included in the repository unless stated.

| Component | Licence | How it is used |
|---|---|---|
| obra/superpowers | MIT | Installed as a Copilot CLI plugin; optionally vendored into `.github/skills/` with its licence file by `Install-AgentPlugins.ps1 -VendorSuperpowers` |
| microsoft/skills-for-fabric (`powerbi-authoring` plugin) | MIT | Installed as a Copilot CLI plugin |
| microsoft/powerbi-modeling-mcp (Power BI Authoring MCP server) | MIT repository; use governed by the Power BI Authoring MCP Server licence terms | Started via `npx`; licence accepted by the user |
| @microsoft/powerbi-report-authoring-cli, @microsoft/powerbi-desktop-bridge-cli | MIT | Installed via npm |
| @microsoft/fabric-mcp, @playwright/mcp | MIT / Apache-2.0 | Started via `npx` |
| github/awesome-copilot (`power-bi-development`, optional) | MIT | Optional plugin |
| Tabular Editor 2 | MIT | Downloaded to `tools/.bin/` for BPA |
| microsoft/Analysis-Services BPA rules | MIT | Downloaded to `tools/.bin/` |
| Microsoft.AnalysisServices.AdomdClient | Microsoft software licence | Downloaded to `tools/.bin/` for local DAX tests |
| Pattern: DAX Query View testing (John Kerski) | MIT (pattern adopted, no code copied) | Test file convention |
