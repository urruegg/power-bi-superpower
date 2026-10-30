# GitHub configuration as code

Applied by `scripts/bootstrap/Initialize-GitHubRepo.ps1` with the GitHub CLI (no GitHub Actions involved).

| File | Applied as |
|---|---|
| `labels.json` | Repository labels (`gh label create --force`) — types, phases, human-only gates, areas, priority, size |
| `ruleset-main.json` | Repository ruleset on the default branch: pull request required, no force-push, no deletion, linear history, conversations resolved |
| `project.json` | GitHub Project (v2) with Phase / Priority / Size fields, linked to the repository (`-CreateProject`) |

**Approvals.** The ruleset ships with `required_approving_review_count: 0` because a solo maker cannot approve their own pull request and agents act with the maker's identity. The human gate is the merge itself (agents are blocked from merging by the `preToolUse` hook). For a team, raise the count to 1 and set `require_code_owner_review: true`.

**Plan limits.** Rulesets on private repositories need GitHub Pro (personal accounts) or GitHub Team/Enterprise (organisations). The script warns and continues if the API refuses.
