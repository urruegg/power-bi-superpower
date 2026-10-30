#Requires -Version 7.4
<#
.SYNOPSIS
    One-command developer setup for the power-bi-superpower repository.
.DESCRIPTION
    1. Test-Prerequisites.ps1 -BeforeTooling (stops on exit code 2).
    2. Install-PbiTooling.ps1 (unless -SkipInstall).
    3. Install-AgentPlugins.ps1 (unless -SkipPlugins; failures are reported as warnings).
    4. git config core.hooksPath .githooks (inside a Git repository).
    5. Scaffolds the report of every project that has report-blueprint.json but no *.Report folder
       (scripts/build/New-PbipReport.ps1; unless -SkipReport).
    6. Runs the commit quality gate (scripts/quality/Invoke-PbiQualityGate.ps1 -Profile commit).
    7. Prints the next steps.
    Exit codes: 0 ready, 1 the quality gate or a setup step failed, 2 prerequisites missing.
.PARAMETER SkipInstall
    Skip Install-PbiTooling.ps1.
.PARAMETER SkipPlugins
    Skip Install-AgentPlugins.ps1.
.PARAMETER SkipReport
    Do not scaffold missing reports.
.EXAMPLE
    pwsh -NoProfile -File scripts/bootstrap/Initialize-PbiSuperpower.ps1
.EXAMPLE
    pwsh -NoProfile -File scripts/bootstrap/Initialize-PbiSuperpower.ps1 -SkipPlugins -SkipReport
#>
[CmdletBinding()]
param(
    [switch] $SkipInstall,

    [switch] $SkipPlugins,

    [switch] $SkipReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'PbiSuperpower' 'PbiSuperpower.psd1') -Force
Set-PbiLogMode

$repoRoot = Get-PbiRepoRoot -Path $PSScriptRoot
$scriptsRoot = Join-Path $repoRoot 'scripts'
$problems = [System.Collections.Generic.List[string]]::new()

function Invoke-SetupScript {
    <#
    .SYNOPSIS
        Runs a repository script in-process and returns its exit code.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $RelativePath,

        [hashtable] $Parameters = @{}
    )
    $scriptPath = Join-Path $scriptsRoot $RelativePath
    $global:LASTEXITCODE = 0
    $null = & $scriptPath @Parameters
    $code = $global:LASTEXITCODE
    if ($null -eq $code) {
        $code = 0
    }
    Import-Module (Join-Path $scriptsRoot 'modules' 'PbiSuperpower' 'PbiSuperpower.psd1') -Force
    Set-PbiLogMode
    return [int]$code
}

Write-PbiLog '1/6 Prerequisites' -Level Step
$prerequisites = Invoke-SetupScript -RelativePath 'bootstrap/Test-Prerequisites.ps1' -Parameters @{ BeforeTooling = $true }
if ($prerequisites -eq 2) {
    Write-PbiLog 'Required prerequisites are missing. Install them (see the table above) and re-run this script.' -Level Error
    exit 2
}

if (-not $SkipInstall) {
    Write-PbiLog '2/6 Tooling (tools/versions.json)' -Level Step
    $tooling = Invoke-SetupScript -RelativePath 'bootstrap/Install-PbiTooling.ps1'
    if ($tooling -ne 0) {
        $problems.Add("Install-PbiTooling.ps1 exited with $tooling.")
    }
} else {
    Write-PbiLog '2/6 Tooling skipped (-SkipInstall).'
}

if (-not $SkipPlugins) {
    Write-PbiLog '3/6 Copilot plugins' -Level Step
    $pluginsExit = Invoke-SetupScript -RelativePath 'bootstrap/Install-AgentPlugins.ps1'
    if ($pluginsExit -ne 0) {
        Write-PbiWarning "Install-AgentPlugins.ps1 exited with $pluginsExit; agents will work without the plugins but with fewer skills. Re-run it later."
    }
} else {
    Write-PbiLog '3/6 Copilot plugins skipped (-SkipPlugins).'
}

Write-PbiLog '4/6 Git hooks' -Level Step
if (Test-Path -LiteralPath (Join-Path $repoRoot '.git')) {
    $hooks = Invoke-PbiNativeCommand -FilePath 'git' -ArgumentList @('-C', $repoRoot, 'config', 'core.hooksPath', '.githooks')
    if ($hooks.ExitCode -eq 0) {
        Write-PbiLog 'core.hooksPath = .githooks (pre-commit and pre-push run the commit quality gate).' -Level Success
    } else {
        $problems.Add('Could not set git core.hooksPath.')
    }
} else {
    Write-PbiWarning 'Not a Git repository yet; run scripts/bootstrap/Initialize-GitHubRepo.ps1 to create it and enable the hooks.'
}

if (-not $SkipReport) {
    Write-PbiLog '5/6 Report scaffolding' -Level Step
    $scaffolded = 0
    foreach ($project in @(Get-PbiProject -RepoRoot $repoRoot)) {
        if ($null -eq $project.BlueprintPath -or @($project.ReportPaths).Count -gt 0) {
            continue
        }
        $reportExit = Invoke-SetupScript -RelativePath 'build/New-PbipReport.ps1' -Parameters @{ ProjectPath = $project.Path }
        if ($reportExit -eq 0) {
            $scaffolded++
        } else {
            Write-PbiWarning "The report of $($project.RelativePath) was not scaffolded (exit $reportExit). Run scripts/build/New-PbipReport.ps1 -ProjectPath $($project.RelativePath) after fixing the cause."
        }
    }
    Write-PbiLog "$scaffolded report(s) scaffolded."
} else {
    Write-PbiLog '5/6 Report scaffolding skipped (-SkipReport).'
}

Write-PbiLog '6/6 Commit quality gate' -Level Step
$gateExit = Invoke-SetupScript -RelativePath 'quality/Invoke-PbiQualityGate.ps1' -Parameters @{ Profile = 'commit' }
if ($gateExit -ne 0) {
    $problems.Add("The commit quality gate failed (exit $gateExit); see the findings above.")
}

Write-Host ''
Write-PbiLog 'Next steps' -Level Step
Write-Host '  1. Copy .env.example to .env.local and fill in the capacity name and group ids (never commit it).'
Write-Host '  2. Open the folder in VS Code (code .) and start GitHub Copilot in agent mode, or run copilot in this folder.'
Write-Host '  3. Run /pbi-sprint-start (or scripts/sprint/New-PbiSprint.ps1) to start Sprint 1.'
Write-Host '  4. Open src/<Project>/<Project>.pbip in Power BI Desktop for local DAX tests and screenshots.'
Write-Host '  5. Deploy to DEV with scripts/deploy/Deploy-PbiProject.ps1 -Environment DEV -WhatIf, then without -WhatIf.'
if ($problems.Count -gt 0) {
    foreach ($problem in $problems) {
        Write-PbiLog $problem -Level Error
    }
    exit 1
}
Write-PbiLog 'Setup complete.' -Level Success
exit 0
