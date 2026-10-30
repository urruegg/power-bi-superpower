---
applyTo: ".github/agents/**,.github/skills/**,.github/instructions/**,.github/hooks/**,AGENTS.md"
description: "Rules for changing agents, skills, instructions and hooks"
---
# Agent asset rules

- Skills: folder name equals the `name` front-matter field (lowercase, hyphens, max 64 characters); `description` says what the skill does and when to use it (max 1,024 characters). Keep SKILL.md short; move long material to `references/` or `templates/` inside the skill.
- Custom agents: `description` is required; give each agent the narrowest tool list that does the job; reviewers are read-only.
- Do not edit vendored Superpowers skills (if `.github/skills/superpowers.manifest.json` exists); upgrade them with `scripts/bootstrap/Install-AgentPlugins.ps1 -VendorSuperpowers`.
- Hooks must stay fast (under one second) and compatible with Windows PowerShell 5.1; add a Pester case in `tests/powershell/Guardrails.Tests.ps1` for every new rule.
- Use the Superpowers `writing-skills` skill when turning a lesson learned into a new skill; open the change as `area:agent-assets`.
