<#
.SYNOPSIS
    sessionStart hook for GitHub Copilot: adds repository context to every new agent session.
.DESCRIPTION
    Prints ONE compact JSON object {"additionalContext": "<text>"} (at most 1,500 characters) with the working rules,
    the current sprint (from docs/sprints/current.json) and a warning when the Superpowers skills are not installed
    (neither .github/skills/brainstorming/SKILL.md nor ~/.copilot/installed-plugins/*/superpowers exists).
    Never throws: on any error it prints {}. Compatible with Windows PowerShell 5.1 and PowerShell 7; the output is
    ASCII-only JSON (non-ASCII characters are escaped).
.EXAMPLE
    pwsh -NoProfile -File scripts/hooks/Invoke-SessionStart.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-PbiHookJson {
    <#
    .SYNOPSIS
        Compact JSON with every non-ASCII character escaped as \uXXXX (safe for any console code page).
    .PARAMETER InputObject
        Object to serialise.
    #>
    [CmdletBinding()]
    param(
        $InputObject
    )
    $json = ConvertTo-Json -InputObject $InputObject -Compress -Depth 5
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $json.ToCharArray()) {
        if ([int]$character -gt 127) {
            $null = $builder.Append('\u').Append(([int]$character).ToString('x4'))
        } else {
            $null = $builder.Append($character)
        }
    }
    return $builder.ToString()
}

function Get-PbiHookText {
    <#
    .SYNOPSIS
        Returns a property of an object as single-line text ('' when missing).
    .PARAMETER InputObject
        Object.
    .PARAMETER Name
        Property name.
    .PARAMETER MaxLength
        Maximum length of the returned text.
    #>
    [CmdletBinding()]
    param(
        $InputObject,
        [string] $Name,
        [int] $MaxLength = 200
    )
    if ($null -eq $InputObject) {
        return ''
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ''
    }
    $value = $property.Value
    if ($value -is [datetime]) {
        $text = $value.ToString('yyyy-MM-dd')
    } else {
        $text = ([string]$value -replace '\s+', ' ').Trim()
    }
    if ($text.Length -gt $MaxLength) {
        $text = $text.Substring(0, $MaxLength - 3) + '...'
    }
    return $text
}

function Test-PbiSuperpowersPresent {
    <#
    .SYNOPSIS
        $true when the Superpowers skills are vendored in the repository or installed as a Copilot CLI plugin.
    .PARAMETER RepoRoot
        Repository root.
    #>
    [CmdletBinding()]
    param(
        [string] $RepoRoot
    )
    if (Test-Path -LiteralPath (Join-Path $RepoRoot '.github/skills/brainstorming/SKILL.md') -PathType Leaf) {
        return $true
    }
    $homeDirectory = $HOME
    if ([string]::IsNullOrEmpty($homeDirectory)) {
        $homeDirectory = [Environment]::GetFolderPath('UserProfile')
    }
    if ([string]::IsNullOrEmpty($homeDirectory)) {
        return $false
    }
    $pluginRoot = Join-Path $homeDirectory '.copilot/installed-plugins'
    if (Test-Path -LiteralPath $pluginRoot -PathType Container) {
        foreach ($marketplace in @(Get-ChildItem -LiteralPath $pluginRoot -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (Join-Path $marketplace.FullName 'superpowers')) {
                return $true
            }
        }
    }
    return $false
}

try {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $sprintText = 'none - run /pbi-sprint-start'
    $currentPath = Join-Path $repoRoot 'docs/sprints/current.json'
    if (Test-Path -LiteralPath $currentPath -PathType Leaf) {
        $sprint = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($currentPath))
        $parts = New-Object System.Collections.Generic.List[string]
        $number = Get-PbiHookText -InputObject $sprint -Name 'number'
        $milestone = Get-PbiHookText -InputObject $sprint -Name 'milestone'
        $goal = Get-PbiHookText -InputObject $sprint -Name 'goal' -MaxLength 300
        $endDate = Get-PbiHookText -InputObject $sprint -Name 'endDate'
        if ($number) {
            $parts.Add('Sprint ' + $number)
        }
        if ($milestone) {
            $parts.Add('milestone ' + $milestone)
        }
        if ($goal) {
            $parts.Add('goal: ' + $goal)
        }
        if ($endDate) {
            $parts.Add('ends ' + $endDate)
        }
        if ($parts.Count -gt 0) {
            $sprintText = $parts -join ', '
        }
    }
    $text = 'Power BI Superpower repo. Start with the pbi-sprint-flow skill and Superpowers using-superpowers. Phase gates are human-owned labels (gate:*). PROD deploys are human-only. Current sprint: ' + $sprintText + '. Open work: run scripts/sprint/Get-PbiSprintStatus.ps1.'
    if (-not (Test-PbiSuperpowersPresent -RepoRoot $repoRoot)) {
        $text += ' Superpowers is not installed: run scripts/bootstrap/Install-AgentPlugins.ps1.'
    }
    if ($text.Length -gt 1500) {
        $text = $text.Substring(0, 1497) + '...'
    }
    $output = New-Object System.Collections.Specialized.OrderedDictionary
    $output['additionalContext'] = $text
    [Console]::Out.WriteLine((ConvertTo-PbiHookJson -InputObject $output))
} catch {
    try {
        [Console]::Out.WriteLine('{}')
    } catch {
        $null = $_
    }
}
exit 0
