#Requires -Version 7.4
<#
.SYNOPSIS
    Shows the status of a sprint: issues of the milestone grouped by phase:* label and state.
.DESCRIPTION
    Reads docs/sprints/current.json when -Number is not given, then runs
    gh issue list --milestone "Sprint NN" --state all --json number,title,state,labels,assignees --limit 200
    and prints the issues per phase (intake, spec, plan, build, test, review, deploy, done), the approval gates
    (gate:* labels) and the issues that have no phase label.
    Exit codes: 0 success, 2 usage/prerequisite error (no current sprint, gh not available or not authenticated).
.PARAMETER Number
    Sprint number (default: docs/sprints/current.json).
.PARAMETER Repo
    owner/name (default: the repository of the current folder).
.PARAMETER Json
    Print the result object as JSON on stdout.
.EXAMPLE
    pwsh -NoProfile -File scripts/sprint/Get-PbiSprintStatus.ps1
.EXAMPLE
    pwsh -NoProfile -File scripts/sprint/Get-PbiSprintStatus.ps1 -Number 3 -Json
#>
[CmdletBinding()]
param(
    [int] $Number,

    [string] $Repo,

    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'PbiSuperpower' 'PbiSuperpower.psd1') -Force
Set-PbiLogMode -Quiet:$Json

$phases = @('intake', 'spec', 'plan', 'build', 'test', 'review', 'deploy', 'done')
$sprint = $null
try {
    $repoRoot = Get-PbiRepoRoot -Path $PSScriptRoot
    $currentPath = Join-Path $repoRoot 'docs' 'sprints' 'current.json'
    if (Test-Path -LiteralPath $currentPath -PathType Leaf) {
        $sprint = Read-PbiJsonFile -Path $currentPath -Description 'docs/sprints/current.json'
    }
    if ($Number -le 0) {
        $Number = [int](Get-PbiProperty $sprint 'number' 0)
        if ($Number -le 0) {
            throw 'No current sprint (docs/sprints/current.json is missing). Start one with /pbi-sprint-start or scripts/sprint/New-PbiSprint.ps1, or pass -Number.'
        }
    }
    $milestoneTitle = 'Sprint ' + $Number.ToString('00', [System.Globalization.CultureInfo]::InvariantCulture)
    $listArguments = @('issue', 'list', '--milestone', $milestoneTitle, '--state', 'all', '--json', 'number,title,state,labels,assignees', '--limit', '200')
    if (-not [string]::IsNullOrWhiteSpace($Repo)) {
        $listArguments += @('--repo', $Repo)
    }
    $issues = @(Invoke-PbiGh -Arguments $listArguments -Json -WorkingDirectory $repoRoot)
} catch {
    Write-PbiLog $_.Exception.Message -Level Error
    if ($Json) {
        [ordered]@{ outcome = 'Error'; exitCode = 2; error = $_.Exception.Message } | ConvertTo-Json
    }
    exit 2
}

$rows = foreach ($issue in $issues) {
    $labelNames = @(Get-PbiProperty $issue 'labels' | ForEach-Object { [string](Get-PbiProperty $_ 'name' '') })
    $phaseLabel = @($labelNames | Where-Object { $_ -like 'phase:*' }) | Select-Object -First 1
    $phase = $null
    if ($null -ne $phaseLabel) {
        $phase = $phaseLabel.Substring(6).ToLowerInvariant()
    }
    [pscustomobject]@{
        Number    = [int](Get-PbiProperty $issue 'number' 0)
        State     = ([string](Get-PbiProperty $issue 'state' '')).ToUpperInvariant()
        Phase     = $phase
        Title     = [string](Get-PbiProperty $issue 'title' '')
        Gates     = (@($labelNames | Where-Object { $_ -like 'gate:*' }) -join ', ')
        Assignees = (@(Get-PbiProperty $issue 'assignees' | ForEach-Object { [string](Get-PbiProperty $_ 'login' '') }) -join ', ')
        Labels    = $labelNames
    }
}
$rows = @($rows | Sort-Object -Property Number)
$phaseSummary = foreach ($phaseName in @($phases) + @('(none)')) {
    $inPhase = @($rows | Where-Object {
            ($phaseName -eq '(none)' -and $null -eq $_.Phase) -or ($null -ne $_.Phase -and $_.Phase -eq $phaseName)
        })
    [pscustomobject]@{
        Phase  = $phaseName
        Open   = @($inPhase | Where-Object { $_.State -eq 'OPEN' }).Count
        Closed = @($inPhase | Where-Object { $_.State -ne 'OPEN' }).Count
    }
}
$otherPhases = @($rows | Where-Object { $null -ne $_.Phase -and $phases -notcontains $_.Phase })
$missingPhase = @($rows | Where-Object { $null -eq $_.Phase })

if ($Json) {
    [ordered]@{
        outcome      = 'Passed'
        exitCode     = 0
        sprint       = [ordered]@{
            number    = $Number
            milestone = $milestoneTitle
            goal      = Get-PbiProperty $sprint 'goal'
            startDate = Get-PbiProperty $sprint 'startDate'
            endDate   = Get-PbiProperty $sprint 'endDate'
        }
        phases       = @($phaseSummary)
        issues       = $rows
        missingPhase = @($missingPhase | ForEach-Object { $_.Number })
        unknownPhase = @($otherPhases | ForEach-Object { $_.Number })
    } | ConvertTo-Json -Depth 6
    exit 0
}

$header = $milestoneTitle
if ($null -ne $sprint -and [int](Get-PbiProperty $sprint 'number' 0) -eq $Number) {
    $header = '{0} - {1} ({2} to {3})' -f $milestoneTitle, (Get-PbiProperty $sprint 'goal' ''), (Get-PbiProperty $sprint 'startDate' '?'), (Get-PbiProperty $sprint 'endDate' '?')
}
Write-PbiLog $header -Level Step
Write-Host ((@($phaseSummary | Where-Object { $_.Open -gt 0 -or $_.Closed -gt 0 -or $phases -contains $_.Phase }) | Format-Table -Property Phase, Open, Closed -AutoSize | Out-String).TrimEnd())
if ($rows.Count -gt 0) {
    Write-Host ''
    Write-Host (($rows | Format-Table -Property Number, State, Phase, Title, Gates, Assignees -AutoSize -Wrap | Out-String -Width 220).TrimEnd())
} else {
    Write-Host ''
    Write-PbiLog "No issues in milestone '$milestoneTitle' yet. Pull ready issues into the sprint."
}
if ($missingPhase.Count -gt 0) {
    Write-Host ''
    Write-PbiWarning ("Issues without a phase:* label: {0}. Add one (phase:intake ... phase:done)." -f (($missingPhase | ForEach-Object { '#' + $_.Number }) -join ', '))
}
if ($otherPhases.Count -gt 0) {
    Write-PbiWarning ("Issues with an unknown phase label: {0}." -f (($otherPhases | ForEach-Object { '#' + $_.Number + ' (' + $_.Phase + ')' }) -join ', '))
}
exit 0
