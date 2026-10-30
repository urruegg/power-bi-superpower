# ADR-0004 — Agent surfaces and MCP allow-list

**Status:** Accepted · **Date:** 2026-10-30

## Context
Power BI Desktop, the Modeling MCP server's Desktop connection and Tabular Editor 2 are Windows-only. VS Code's Copilot harness and Copilot CLI share skills, custom agents, hooks and plugins; prompt files and handoffs only run in VS Code's Local harness. The Copilot cloud agent runs on Linux.

## Decision
- Primary surfaces: **VS Code agent mode and Copilot CLI on Windows**. The cloud agent is not used for Power BI build work.
- Build on skills, custom agents, hooks, instructions and plugins; no prompt files.
- MCP allow-list (both `.vscode/mcp.json` and `.github/mcp.json`): `powerbi-modeling-mcp` (local), `fabric-mcp` (local, read-mostly), `microsoft-learn`, `github` (built into the CLI; explicit in VS Code with toolsets), `playwright` (optional visual checks). Not enabled: hosted Power BI MCP servers (preview; do not combine with the local server), Azure MCP.
- No blanket tool approval (`--allow-all-tools`, `--yolo` are blocked by the hook).

## Consequences
- Two MCP files must stay in sync (checked by the `McpParity` gate).
- Licence acceptance for the Modeling MCP server is a human step on first use.

## Alternatives
Hosted Power BI authoring MCP for workspace models (preview, needs tenant setting); cloud agent with a Windows larger runner (requires Actions).
