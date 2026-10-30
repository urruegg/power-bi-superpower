#Requires -Version 7.4
<#
.SYNOPSIS
    Starts a sprint: GitHub milestone, sprint document, docs/sprints/current.json and the tracking issue.
.DESCRIPTION
    Idempotent (existing items are kept):
      - milestone 'Sprint NN' (two digits) with the goal as description and due_on = end date 17:00 local time (UTC),
        created with gh api repos/<repo>/milestones --method POST (the GitHub MCP server cannot create milestones);
      - docs/sprints/sprint-NN/sprint.md from docs/sprints/_template/sprint.md (tokens __NUMBER__, __GOAL__, __START__,
        __END__, __MILESTONE__);
      - docs/sprints/current.json { number, goal, milestone, startDate, endDate } (read by the session-start hook);
      - the tracking issue 'Sprint NN: <goal>' with label type:sprint on the milestone. Its body is the section of the
        sprint document between <!-- issue-body:start --> and <!-- issue-body:end --> when present, else the whole
        document. The issue URL is printed.
    The sprint ends after -LengthDays business days (default 10, Monday-Friday) or on -EndDate.
    Supports -WhatIf. Exit codes: 0 success, 1 a GitHub call failed, 2 usage/prerequisite error.
.PARAMETER Number
    Sprint number (1-99).
.PARAMETER Goal
    Sprint goal (one sentence).
.PARAMETER StartDate
    First day (default: next Monday).
.PARAMETER LengthDays
    Length in business days (default 10).
.PARAMETER EndDate
    Last day (instead of -LengthDays).
.PARAMETER Repo
    owner/name (default: the repository of the current folder, from gh repo view).
.EXAMPLE
    pwsh -NoProfile -File scripts/sprint/New-PbiSprint.ps1 -Number 1 -Goal 'Sales overview report in TEST'
.EXAMPLE
    pwsh -NoProfile -File scripts/sprint/New-PbiSprint.ps1 -Number 2 -Goal 'RLS for regions' -StartDate 2026-11-16 -EndDate 2026-11-27 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Length')]
param(
    [Parameter(Mandatory)]
    [int] $Number,

    [Parameter(Mandatory)]
    [string] $Goal,

    [datetime] $StartDate,

    [Parameter(ParameterSetName = 'Length')]
    [int] $LengthDays = 10,

    [Parameter(Mandatory, ParameterSetName = 'EndDate')]
    [datetime] $EndDate,

    [string] $Repo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'PbiSuperpower' 'PbiSuperpower.psd1') -Force
Set-PbiLogMode

$culture = [System.Globalization.CultureInfo]::InvariantCulture
try {
    if ($Number -lt 1 -or $Number -gt 99) {
        throw "-Number must be between 1 and 99 (got $Number)."
    }
    if ([string]::IsNullOrWhiteSpace($Goal)) {
        throw '-Goal must not be empty.'
    }
    $Goal = ($Goal -replace '\s+', ' ').Trim()
    $repoRoot = Get-PbiRepoRoot -Path $PSScriptRoot
    $templatePath = Join-Path $repoRoot 'docs' 'sprints' '_template' 'sprint.md'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw 'docs/sprints/_template/sprint.md was not found.'
    }
    if ([string]::IsNullOrWhiteSpace($Repo)) {
        $repoInfo = Invoke-PbiGh -Arguments @('repo', 'view', '--json', 'nameWithOwner') -Json -WorkingDirectory $repoRoot
        $Repo = [string](Get-PbiProperty $repoInfo 'nameWithOwner' '')
    }
    if ($Repo -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$') {
        throw "Could not determine the GitHub repository (owner/name). Pass -Repo or run scripts/bootstrap/Initialize-GitHubRepo.ps1."
    }
    $today = (Get-Date).Date
    if ($PSBoundParameters.ContainsKey('StartDate')) {
        $start = $StartDate.Date
    } else {
        $offset = (8 - [int]$today.DayOfWeek) % 7
        if ($offset -eq 0) {
            $offset = 7
        }
        $start = $today.AddDays($offset)
    }
    if ($PSCmdlet.ParameterSetName -eq 'EndDate') {
        $end = $EndDate.Date
        if ($end -lt $start) {
            throw '-EndDate is before the start date.'
        }
    } else {
        if ($LengthDays -lt 1 -or $LengthDays -gt 60) {
            throw '-LengthDays must be between 1 and 60 business days.'
        }
        $end = $start
        $counted = 0
        $cursor = $start
        while ($counted -lt $LengthDays) {
            if ($cursor.DayOfWeek -ne [System.DayOfWeek]::Saturday -and $cursor.DayOfWeek -ne [System.DayOfWeek]::Sunday) {
                $counted++
                $end = $cursor
            }
            $cursor = $cursor.AddDays(1)
        }
    }
} catch {
    Write-PbiLog $_.Exception.Message -Level Error
    exit 2
}

$sprintNumber = $Number.ToString('00', $culture)
$milestoneTitle = "Sprint $sprintNumber"
$startText = $start.ToString('yyyy-MM-dd', $culture)
$endText = $end.ToString('yyyy-MM-dd', $culture)
$dueOn = [datetime]::new($end.Year, $end.Month, $end.Day, 17, 0, 0, [System.DateTimeKind]::Local).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $culture)
$failures = [System.Collections.Generic.List[string]]::new()
Write-PbiLog "$milestoneTitle ($startText to $endText): $Goal" -Level Step

$milestoneExists = $false
try {
    $milestones = @(Invoke-PbiGh -Arguments @('api', "repos/$Repo/milestones?state=all&per_page=100") -Json)
    $milestoneExists = @($milestones | Where-Object { [string](Get-PbiProperty $_ 'title' '') -eq $milestoneTitle }).Count -gt 0
    if ($milestoneExists) {
        Write-PbiLog "Milestone '$milestoneTitle' already exists."
    } elseif ($PSCmdlet.ShouldProcess($Repo, "Create milestone '$milestoneTitle' (due $endText)")) {
        $null = Invoke-PbiGh -Arguments @('api', "repos/$Repo/milestones", '--method', 'POST', '-f', "title=$milestoneTitle", '-f', "description=$Goal", '-f', "due_on=$dueOn")
        $milestoneExists = $true
        Write-PbiLog "Created milestone '$milestoneTitle'." -Level Success
    }
} catch {
    $failures.Add("Milestone: $($_.Exception.Message)")
}

$sprintDirectory = Join-Path $repoRoot 'docs' 'sprints' "sprint-$sprintNumber"
$sprintFile = Join-Path $sprintDirectory 'sprint.md'
$tokens = [ordered]@{
    '__NUMBER__'    = $sprintNumber
    '__GOAL__'      = $Goal
    '__START__'     = $startText
    '__END__'       = $endText
    '__MILESTONE__' = $milestoneTitle
}
$document = Read-PbiTextFile -Path $templatePath
foreach ($token in $tokens.Keys) {
    $document = $document.Replace([string]$token, [string]$tokens[$token])
}
if (Test-Path -LiteralPath $sprintFile -PathType Leaf) {
    Write-PbiLog "docs/sprints/sprint-$sprintNumber/sprint.md already exists (kept)."
    $document = Read-PbiTextFile -Path $sprintFile
} elseif ($PSCmdlet.ShouldProcess("docs/sprints/sprint-$sprintNumber/sprint.md", 'Create sprint document')) {
    Write-PbiTextFile -Path $sprintFile -Content $document
    Write-PbiLog "Created docs/sprints/sprint-$sprintNumber/sprint.md." -Level Success
}

$current = [ordered]@{
    number    = $Number
    goal      = $Goal
    milestone = $milestoneTitle
    startDate = $startText
    endDate   = $endText
}
if ($PSCmdlet.ShouldProcess('docs/sprints/current.json', "Point to $milestoneTitle")) {
    Write-PbiTextFile -Path (Join-Path $repoRoot 'docs' 'sprints' 'current.json') -Content ((ConvertTo-Json -InputObject $current) + "`n")
    Write-PbiLog 'Updated docs/sprints/current.json.' -Level Success
}

if ($milestoneExists) {
    try {
        $existingIssues = @(Invoke-PbiGh -Arguments @('issue', 'list', '--repo', $Repo, '--milestone', $milestoneTitle, '--label', 'type:sprint', '--state', 'all', '--json', 'number,title,url') -Json)
        if ($existingIssues.Count -gt 0) {
            Write-PbiLog ("Tracking issue already exists: {0}" -f [string](Get-PbiProperty $existingIssues[0] 'url' ''))
        } elseif ($PSCmdlet.ShouldProcess($Repo, "Create tracking issue '${milestoneTitle}: $Goal'")) {
            $body = $document
            $section = [regex]::Match($document, '(?s)<!--\s*issue-body:start\s*-->(?<body>.*?)<!--\s*issue-body:end\s*-->')
            if ($section.Success) {
                $body = $section.Groups['body'].Value.Trim()
            }
            $body = $body.TrimEnd() + "`n`n---`nSprint document: docs/sprints/sprint-$sprintNumber/sprint.md`n"
            $bodyFile = Join-Path $repoRoot '.evidence' 'tmp' "sprint-$sprintNumber-issue-body.md"
            Write-PbiTextFile -Path $bodyFile -Content $body
            try {
                $created = Invoke-PbiGh -Arguments @('issue', 'create', '--repo', $Repo, '--title', "${milestoneTitle}: $Goal", '--label', 'type:sprint', '--milestone', $milestoneTitle, '--body-file', $bodyFile)
                $url = @($created -split "`n" | Where-Object { $_ -match '^https?://' }) | Select-Object -Last 1
                Write-PbiLog "Created the tracking issue: $url" -Level Success
            } finally {
                Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        $failures.Add("Tracking issue: $($_.Exception.Message) (does the label type:sprint exist? Run scripts/bootstrap/Initialize-GitHubRepo.ps1.)")
    }
} else {
    Write-PbiLog 'The tracking issue is created once the milestone exists (re-run without -WhatIf).'
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-PbiLog $failure -Level Error
    }
    exit 1
}
Write-PbiLog "$milestoneTitle is ready. Commit docs/sprints/ and pull ready issues into the milestone." -Level Success
exit 0
