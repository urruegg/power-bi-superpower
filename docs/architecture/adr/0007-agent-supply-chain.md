# ADR-0007 — Agent supply chain (plugins, skills, MCP versions)

**Status:** Accepted · **Date:** 2026-10-30

## Context
Agent behaviour depends on external plugins (Superpowers, Microsoft `powerbi-authoring`), npm CLIs and MCP servers that change weekly.

## Decision
- Pin in `tools/versions.json`: Superpowers tag, plugin list (required and optional), CLIs, PowerShell modules, Tabular Editor, BPA rules, ADOMD.
- Install with `scripts/bootstrap/Install-AgentPlugins.ps1` and `Install-PbiTooling.ps1`; record installed versions and hashes in `tools/.bin/installed.json`.
- Optional vendoring of Superpowers into `.github/skills/` with a SHA-256 manifest (`-VendorSuperpowers`, verified by the `SuperpowersManifest` check).
- GPL-licensed community plugins are not vendored into this repository.
- Monthly review; upgrades through PRs with evidence.

## Consequences
- Some Microsoft packages are only published as `@latest`; the evidence records the exact version used.

## Alternatives
Unpinned `@latest` everywhere (fast, unpredictable); full vendoring of every skill (heavy, licence review needed).
