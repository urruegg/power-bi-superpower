---
applyTo: "**/*.ps1,**/*.psm1,**/*.psd1"
description: "PowerShell standards for scripts in this repository"
---
# PowerShell rules

- PowerShell 7.4+ (`#Requires -Version 7.4`), except `scripts/hooks/*`, which must also run on Windows PowerShell 5.1 and must never throw.
- `[CmdletBinding()]`, `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, approved verbs, comment-based help with an example.
- Remote writes support `-WhatIf` (`SupportsShouldProcess`) and print a plan first.
- Shared logic belongs in `scripts/modules/PbiSuperpower/PbiSuperpower.psm1` (export it in the `.psd1`) with Pester tests in `tests/powershell/`.
- Never print tokens, secrets or IDs; evidence goes to `.evidence/` and summaries pass through `Protect-PbiText`.
- Exit codes: 0 success, 1 check failure, 2 usage or configuration error. Use `exit` only in entry scripts.
- Run `Invoke-Pester -Path tests/powershell` after changing the module.
