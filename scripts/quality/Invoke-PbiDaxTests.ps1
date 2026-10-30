#Requires -Version 7.4
<#
.SYNOPSIS
    Runs the DAX tests of one project against Power BI Desktop (Local) or a deployed model (DEV/TEST/PROD).
.DESCRIPTION
    Test files: <Model>.SemanticModel/DAXQueries/<Name>.<SCOPE>.Tests.dax (SCOPE = ALL, LOCAL, DEV, TEST, PROD). Each file
    is one DAX query returning TestName, ExpectedValue, ActualValue and Passed (John Kerski's DAX Query View testing
    pattern). Optional first-line directives: '// @role: <Role>' (Local only) and '// @effectiveUserName: <upn>'.
    Local: finds the Power BI Desktop instance whose window title contains the project (.pbip) name.
    DEV/TEST/PROD: reads config/environments/<env>.json, signs in (Connect-PbiFabric) and resolves the workspace and
    semantic model by display name.
    Prints PASS/FAIL/SKIP/SLOW per test, writes evidence (.evidence/<timestamp>-dax-tests-<ENV>-<commit>.json).
    Exit codes: 0 no test failed (skipped role tests are reported as SKIP), 1 a test failed, 2 configuration/usage error.
.PARAMETER ProjectPath
    Project folder (for example src/SalesStarter). Optional when the repository contains exactly one project.
.PARAMETER Target
    Local (default), DEV, TEST or PROD.
.PARAMETER TenantId
    Tenant for service targets (default: PBI_TENANT_ID when set).
.PARAMETER Json
    Print the result object as JSON on stdout.
.EXAMPLE
    pwsh -NoProfile -File scripts/quality/Invoke-PbiDaxTests.ps1 -ProjectPath src/SalesStarter -Target Local
.EXAMPLE
    pwsh -NoProfile -File scripts/quality/Invoke-PbiDaxTests.ps1 -ProjectPath src/SalesStarter -Target DEV -Json
#>
[CmdletBinding()]
param(
    [string] $ProjectPath,

    [ArgumentCompletions('Local', 'DEV', 'TEST', 'PROD')]
    [string] $Target = 'Local',

    [string] $TenantId,

    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'PbiSuperpower' 'PbiSuperpower.psd1') -Force
Set-PbiLogMode -Quiet:$Json

function Write-DaxUsageError {
    <#
    .SYNOPSIS
        Reports a configuration/usage error and exits with 2.
    #>
    param(
        [string] $Message
    )
    Write-PbiLog $Message -Level Error
    if ($Json) {
        [ordered]@{ outcome = 'Error'; exitCode = 2; error = $Message } | ConvertTo-Json -Depth 5
    }
    exit 2
}

$matchedTarget = @(@('Local', 'DEV', 'TEST', 'PROD') | Where-Object { $_ -eq $Target })
if ($matchedTarget.Count -eq 0) {
    Write-DaxUsageError "Invalid -Target '$Target'. Use Local, DEV, TEST or PROD."
}
$Target = $matchedTarget[0]
if ([string]::IsNullOrWhiteSpace($TenantId) -and -not [string]::IsNullOrWhiteSpace($env:PBI_TENANT_ID)) {
    $TenantId = $env:PBI_TENANT_ID
}

try {
    $repoRoot = Get-PbiRepoRoot -Path $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        $allProjects = @(Get-PbiProject -RepoRoot $repoRoot)
        if ($allProjects.Count -eq 0) {
            throw 'No PBIP project found under src/. Create one with scripts/build/New-PbipProject.ps1.'
        }
        if ($allProjects.Count -gt 1) {
            throw ('Several projects found ({0}). Pass -ProjectPath, for example -ProjectPath {1}.' -f (($allProjects | ForEach-Object { $_.RelativePath }) -join ', '), $allProjects[0].RelativePath)
        }
        $project = $allProjects[0]
        $ProjectPath = $project.RelativePath
    } else {
        $project = Get-PbiProject -RepoRoot $repoRoot -Path $ProjectPath | Select-Object -First 1
    }
    if ($null -eq $project -or [string]::IsNullOrEmpty($project.SemanticModelPath)) {
        throw "No *.SemanticModel folder found in $ProjectPath."
    }
    $gate = Get-PbiGateConfig -RepoRoot $repoRoot
    $maxDuration = [int](Get-PbiProperty (Get-PbiProperty $gate 'thresholds') 'daxTestMaxDurationMs' 5000)
    $files = @(Get-PbiDaxTestFile -SemanticModelPath $project.SemanticModelPath -Target $Target)
    $suiteParameters = @{
        SemanticModelPath = $project.SemanticModelPath
        Target            = $Target
        MaxDurationMs     = $maxDuration
        RepoRoot          = $repoRoot
    }
    if ($files.Count -gt 0) {
        if ($Target -eq 'Local') {
            $projectName = $project.Name
            if (-not [string]::IsNullOrEmpty($project.PbipPath)) {
                $projectName = [System.IO.Path]::GetFileNameWithoutExtension($project.PbipPath)
            }
            $instance = Get-PbiDesktopInstance -ProjectName $projectName
            $suiteParameters.Port = $instance.Port
            Write-PbiLog "Using Power BI Desktop '$($instance.WindowTitle)'."
        } else {
            $config = Get-PbiEnvironmentConfig -Environment $Target -RepoRoot $repoRoot
            $entry = @(Get-PbiProperty $config 'projects' | Where-Object {
                    [string]::Equals(([string](Get-PbiProperty $_ 'path' '')).Replace('\', '/').TrimEnd('/'), $project.RelativePath, [System.StringComparison]::OrdinalIgnoreCase)
                }) | Select-Object -First 1
            if ($null -eq $entry) {
                throw "$($project.RelativePath) is not configured in config/environments/$($Target.ToLowerInvariant()).json."
            }
            $modelName = [string](Get-PbiProperty (Get-PbiProperty $entry 'semanticModel') 'displayName' '')
            $workspaceName = [string](Get-PbiProperty (Get-PbiProperty $config 'workspace') 'displayName' '')
            if ([string]::IsNullOrWhiteSpace($TenantId)) {
                $null = Connect-PbiFabric
            } else {
                $null = Connect-PbiFabric -TenantId $TenantId
            }
            $workspace = Get-PbiWorkspace -DisplayName $workspaceName
            if ($null -eq $workspace) {
                throw "Workspace '$workspaceName' does not exist. Deploy first: scripts/deploy/Deploy-PbiProject.ps1 -Environment $Target"
            }
            $workspaceId = [string](Get-PbiProperty $workspace 'id' '')
            $item = Get-PbiItem -WorkspaceId $workspaceId -Type 'SemanticModel' -DisplayName $modelName
            if ($null -eq $item) {
                throw "Semantic model '$modelName' is not deployed to $Target."
            }
            $suiteParameters.WorkspaceId = $workspaceId
            $suiteParameters.DatasetId = [string](Get-PbiProperty $item 'id' '')
        }
    }
} catch {
    Write-DaxUsageError $_.Exception.Message
}

$results = @()
if ($files.Count -gt 0) {
    Write-PbiLog ("Running {0} DAX test file(s) of {1} against {2}..." -f $files.Count, $project.RelativePath, $Target) -Level Step
    try {
        $results = @(Invoke-PbiDaxTestSuite @suiteParameters)
    } catch {
        Write-DaxUsageError $_.Exception.Message
    }
} else {
    Write-PbiWarning "No DAX test files for $Target in $($project.RelativePath)/$(Split-Path -Path $project.SemanticModelPath -Leaf)/DAXQueries (*.ALL.Tests.dax or *.$($Target.ToUpperInvariant()).Tests.dax)."
}

$failed = @($results | Where-Object { -not $_.Passed -and -not $_.Skipped })
$skipped = @($results | Where-Object { $_.Skipped })
$passed = @($results | Where-Object { $_.Passed })
$outcome = 'Passed'
if ($failed.Count -gt 0) {
    $outcome = 'Failed'
}
if ($skipped.Count -gt 0) {
    Write-PbiWarning "$($skipped.Count) test file(s) were skipped on $Target (role directives are only supported with -Target Local)."
}

$evidencePath = $null
try {
    $environmentName = $Target.ToUpperInvariant()
    $evidenceData = [ordered]@{
        project  = $project.RelativePath
        target   = $Target
        outcome  = $outcome
        passed   = $passed.Count
        failed   = $failed.Count
        skipped  = $skipped.Count
        results  = $results
        warnings = @(Get-PbiLogWarning)
    }
    $evidencePath = New-PbiEvidence -Kind 'dax-tests' -Environment $environmentName -Data $evidenceData -RepoRoot $repoRoot
} catch {
    Write-PbiWarning "Evidence could not be written: $($_.Exception.Message)"
}

if ($Json) {
    $relativeEvidence = $null
    if ($null -ne $evidencePath) {
        $relativeEvidence = Get-PbiRelativePath -Path $evidencePath -RepoRoot $repoRoot
    }
    [ordered]@{
        outcome      = $outcome
        exitCode     = $(if ($outcome -eq 'Passed') { 0 } else { 1 })
        project      = $project.RelativePath
        target       = $Target
        passed       = $passed.Count
        failed       = $failed.Count
        skipped      = $skipped.Count
        results      = $results
        evidencePath = $relativeEvidence
        warnings     = @(Get-PbiLogWarning)
    } | ConvertTo-Json -Depth 10
} else {
    if ($results.Count -gt 0) {
        $rows = foreach ($testResult in $results) {
            $label = 'FAIL'
            if ($testResult.Skipped) {
                $label = 'SKIP'
            } elseif ($testResult.Passed -and $testResult.SlowQuery) {
                $label = 'SLOW'
            } elseif ($testResult.Passed) {
                $label = 'PASS'
            }
            $detail = ''
            if ($null -ne $testResult.Error) {
                $detail = $testResult.Error
            } elseif (-not $testResult.Passed) {
                $detail = 'expected {0}, actual {1}' -f [string]$testResult.ExpectedValue, [string]$testResult.ActualValue
            }
            [pscustomobject]@{
                Result   = $label
                File     = $testResult.File
                Test     = $testResult.TestName
                Expected = [string]$testResult.ExpectedValue
                Actual   = [string]$testResult.ActualValue
                Ms       = $testResult.DurationMs
                Detail   = $detail
            }
        }
        Write-Host (($rows | Format-Table -AutoSize -Wrap | Out-String -Width 220).TrimEnd())
    }
    Write-Host ''
    if ($null -ne $evidencePath) {
        Write-PbiLog ('Evidence: {0}' -f (Get-PbiRelativePath -Path $evidencePath -RepoRoot $repoRoot))
    }
    if ($outcome -eq 'Passed') {
        Write-PbiLog ('{0} test(s) passed, {1} skipped.' -f $passed.Count, $skipped.Count) -Level Success
    } else {
        Write-PbiLog ('{0} passed, {1} failed, {2} skipped. Fix the failing measures (or run role-based tests with -Target Local) and re-run.' -f $passed.Count, $failed.Count, $skipped.Count) -Level Error
    }
}
if ($outcome -eq 'Passed') {
    exit 0
}
exit 1
