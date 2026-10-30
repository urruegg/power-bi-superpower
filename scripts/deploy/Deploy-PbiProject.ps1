#Requires -Version 7.4
<#
.SYNOPSIS
    Deploys PBIP projects (TMDL semantic models + PBIR reports) to the DEV, TEST or PROD workspace.
.DESCRIPTION
    1. Loads config/environments/<env>.json, reads the Git context and enforces the environment guards
       (PROD: human-only typed confirmation, clean tree, merged to main, passing TEST evidence for the same commit,
       -ReleaseIssue with gate:release-approved).
    2. Runs the quality gate in-process (profile from gates.json deployProfiles, e.g. deploy-dev) and aborts on failure.
    3. Signs in and ensures the workspace (Deploy-PbiWorkspace) unless -SkipInfrastructure (then the workspace must exist).
    4. Per project: publishes the semantic model (with the configured Power Query parameters), refreshes it when
       refreshAfterDeploy is true (unless -SkipRefresh), then publishes each report bound to the model id.
    5. Runs the DAX tests against the deployed model (Target = environment) when postDeploy.runDaxTests is true
       (unless -SkipTests). '// @role:' test files are reported as skipped on service targets.
    6. Always writes evidence (.evidence/<timestamp>-deployment-<ENV>-<commit>.json, git-ignored, with item ids) and
       prints a masked markdown summary for the pull request or release issue (also saved as .md).
    Supports -WhatIf (plan only). PROD uses this same script; its guards make it human-only.
    Exit codes: 0 success, 1 a guard, the gate or a deployment step failed, 2 configuration/usage error.
.PARAMETER Environment
    DEV, TEST or PROD.
.PARAMETER Project
    Deploy only these projects (paths as in the configuration, e.g. src/SalesStarter, or folder names).
.PARAMETER ReleaseIssue
    Release issue number (required for PROD).
.PARAMETER TenantId
    Tenant to sign in to (default: PBI_TENANT_ID when set).
.PARAMETER SkipInfrastructure
    Do not create/update the workspace; it must already exist.
.PARAMETER SkipRefresh
    Do not refresh the semantic models after deployment.
.PARAMETER SkipTests
    Do not run the post-deployment DAX tests (such evidence does not satisfy PROD's requireTestEvidence guard).
.PARAMETER Json
    Print the result object as JSON on stdout.
.EXAMPLE
    pwsh -NoProfile -File scripts/deploy/Deploy-PbiProject.ps1 -Environment DEV -WhatIf
.EXAMPLE
    pwsh -NoProfile -File scripts/deploy/Deploy-PbiProject.ps1 -Environment TEST
.EXAMPLE
    pwsh -NoProfile -File scripts/deploy/Deploy-PbiProject.ps1 -Environment PROD -ReleaseIssue 42
#>
[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param(
    [Parameter(Mandatory)]
    [ArgumentCompletions('DEV', 'TEST', 'PROD')]
    [string] $Environment,

    [string[]] $Project,

    [int] $ReleaseIssue,

    [string] $TenantId,

    [switch] $SkipInfrastructure,

    [switch] $SkipRefresh,

    [switch] $SkipTests,

    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'PbiSuperpower' 'PbiSuperpower.psd1') -Force
Set-PbiLogMode -Quiet:$Json

$environmentName = $Environment.ToUpperInvariant()
$isWhatIf = [bool]$WhatIfPreference
$state = [ordered]@{
    environment = $environmentName
    whatIf      = $isWhatIf
    workspace   = $null
    gate        = $null
    items       = [System.Collections.Generic.List[object]]::new()
    refreshes   = [System.Collections.Generic.List[object]]::new()
    tests       = [ordered]@{ run = $false; skipped = $false; reason = $null; passed = 0; failed = 0; skippedFiles = 0; results = @() }
    skipTests   = [bool]$SkipTests
    outcome     = 'Failed'
    error       = $null
}
$steps = [System.Collections.Generic.List[object]]::new()
$repoRoot = $null
$git = $null

function Add-DeploymentStep {
    <#
    .SYNOPSIS
        Records one deployment step for the summary.
    #>
    param(
        [string] $Name,
        [string] $Status,
        [string] $Summary
    )
    $steps.Add([pscustomobject]@{ Level = $environmentName; Check = $Name; Status = $Status; Summary = $Summary })
}

function Complete-Deployment {
    <#
    .SYNOPSIS
        Writes evidence and the masked summary, prints the result and exits.
    #>
    param(
        [int] $ExitCode,

        [switch] $NoEvidence
    )
    if ($ExitCode -eq 0) {
        $state.outcome = 'Passed'
    }
    $markdown = ConvertTo-PbiEvidenceMarkdown -Result $steps.ToArray() -Title "Deployment to $environmentName" -Outcome $state.outcome
    $evidencePath = $null
    if (-not $NoEvidence -and $null -ne $repoRoot) {
        try {
            $data = [ordered]@{
                environment = $state.environment
                whatIf      = $state.whatIf
                workspace   = $state.workspace
                gate        = $state.gate
                items       = $state.items.ToArray()
                refreshes   = $state.refreshes.ToArray()
                tests       = $state.tests
                skipTests   = $state.skipTests
                outcome     = $state.outcome
                error       = $state.error
                steps       = $steps.ToArray()
                warnings    = @(Get-PbiLogWarning)
            }
            $evidenceParameters = @{ Kind = 'deployment'; Environment = $environmentName; Data = $data; RepoRoot = $repoRoot }
            if ($null -ne $git) {
                $evidenceParameters.GitContext = $git
            }
            $evidencePath = New-PbiEvidence @evidenceParameters
            Write-PbiTextFile -Path ([System.IO.Path]::ChangeExtension($evidencePath, '.md')) -Content $markdown
        } catch {
            Write-PbiWarning "Evidence could not be written: $($_.Exception.Message)"
        }
    }
    if ($Json) {
        $relativeEvidence = $null
        if ($null -ne $evidencePath) {
            $relativeEvidence = Get-PbiRelativePath -Path $evidencePath -RepoRoot $repoRoot
        }
        [ordered]@{
            outcome      = $state.outcome
            exitCode     = $ExitCode
            environment  = $environmentName
            whatIf       = $isWhatIf
            workspace    = $state.workspace
            gate         = $state.gate
            items        = @($state.items | ForEach-Object { [ordered]@{ project = $_.project; type = $_.type; displayName = $_.displayName; action = $_.action } })
            refreshes    = $state.refreshes.ToArray()
            tests        = [ordered]@{ run = $state.tests.run; skipped = $state.tests.skipped; reason = $state.tests.reason; passed = $state.tests.passed; failed = $state.tests.failed; skippedFiles = $state.tests.skippedFiles }
            error        = $state.error
            evidencePath = $relativeEvidence
            summary      = $markdown
            warnings     = @(Get-PbiLogWarning)
        } | ConvertTo-Json -Depth 10
    } else {
        Write-Host ''
        Write-Host $markdown.TrimEnd()
        Write-Host ''
        if ($null -ne $evidencePath) {
            Write-PbiLog ('Evidence: {0} (paste the .md summary into the pull request or release issue)' -f (Get-PbiRelativePath -Path $evidencePath -RepoRoot $repoRoot))
        }
        if ($ExitCode -eq 0) {
            $doneText = "Deployment to $environmentName completed."
            if ($isWhatIf) {
                $doneText = "Plan for $environmentName completed (-WhatIf: nothing was changed)."
            }
            Write-PbiLog $doneText -Level Success
        } else {
            Write-PbiLog ("Deployment to {0} failed: {1}" -f $environmentName, $state.error) -Level Error
        }
    }
    exit $ExitCode
}

if (@('DEV', 'TEST', 'PROD') -notcontains $environmentName) {
    $state.error = "Invalid -Environment '$Environment'. Use DEV, TEST or PROD."
    Write-PbiLog $state.error -Level Error
    Complete-Deployment -ExitCode 2 -NoEvidence
}
if ([string]::IsNullOrWhiteSpace($TenantId) -and -not [string]::IsNullOrWhiteSpace($env:PBI_TENANT_ID)) {
    $TenantId = $env:PBI_TENANT_ID
}

# 1. Configuration, projects and guards.
try {
    $repoRoot = Get-PbiRepoRoot -Path $PSScriptRoot
    $config = Get-PbiEnvironmentConfig -Environment $environmentName -RepoRoot $repoRoot
    $gateConfig = Get-PbiGateConfig -RepoRoot $repoRoot
    $workspaceName = [string](Get-PbiProperty (Get-PbiProperty $config 'workspace') 'displayName' '')
    $state.workspace = $workspaceName
    $filters = @(Split-PbiListArgument $Project | ForEach-Object { $_.Replace('\', '/').TrimEnd('/') })
    $projects = @(Get-PbiProperty $config 'projects' | Where-Object {
            $configuredPath = ([string](Get-PbiProperty $_ 'path' '')).Replace('\', '/').TrimEnd('/')
            $leaf = ($configuredPath -split '/')[-1]
            $filters.Count -eq 0 -or $filters -contains $configuredPath -or $filters -contains $leaf
        })
    if ($projects.Count -eq 0) {
        if ($filters.Count -gt 0) {
            throw "No project in config/environments/$($environmentName.ToLowerInvariant()).json matches -Project $($filters -join ', ')."
        }
        throw "config/environments/$($environmentName.ToLowerInvariant()).json has no projects to deploy."
    }
    foreach ($projectConfig in $projects) {
        $projectFolder = Join-Path $repoRoot ([string](Get-PbiProperty $projectConfig 'path' ''))
        $modelFolder = Join-Path $projectFolder ([string](Get-PbiProperty (Get-PbiProperty $projectConfig 'semanticModel') 'folder' ''))
        if (-not (Test-Path -LiteralPath $modelFolder -PathType Container)) {
            throw "Semantic model folder not found: $(Get-PbiRelativePath -Path $modelFolder -RepoRoot $repoRoot)."
        }
        foreach ($reportConfig in @(Get-PbiProperty $projectConfig 'reports')) {
            $reportFolder = Join-Path $projectFolder ([string](Get-PbiProperty $reportConfig 'folder' ''))
            if (-not (Test-Path -LiteralPath $reportFolder -PathType Container)) {
                throw ("Report folder not found: {0}. Scaffold it with scripts/build/New-PbipReport.ps1 -ProjectPath {1} or remove it from the environment configuration." -f (Get-PbiRelativePath -Path $reportFolder -RepoRoot $repoRoot), [string](Get-PbiProperty $projectConfig 'path' ''))
            }
        }
    }
    $git = Get-PbiGitContext -RepoRoot $repoRoot
} catch {
    $state.error = $_.Exception.Message
    Write-PbiLog $state.error -Level Error
    Complete-Deployment -ExitCode 2 -NoEvidence
}

try {
    Write-PbiLog "Checking the $environmentName deployment guards..." -Level Step
    Assert-PbiDeploymentGuard -Config $config -GitContext $git -ReleaseIssue $ReleaseIssue -RepoRoot $repoRoot
    Add-DeploymentStep -Name 'Guards' -Status 'Passed' -Summary ("Branch {0}, commit {1}." -f $git.Branch, $git.ShortCommit)
} catch {
    $state.error = $_.Exception.Message
    Add-DeploymentStep -Name 'Guards' -Status 'Failed' -Summary $state.error
    Complete-Deployment -ExitCode 1
}

# 2. Quality gate (in-process).
try {
    $gateProfile = [string](Get-PbiProperty (Get-PbiProperty $gateConfig 'deployProfiles') $environmentName ('deploy-' + $environmentName.ToLowerInvariant()))
    Write-PbiLog "Quality gate (profile $gateProfile)..." -Level Step
    $projectPaths = @($projects | ForEach-Object { [string](Get-PbiProperty $_ 'path' '') })
    $gate = Test-PbiQualityGate -Profile $gateProfile -ProjectPath $projectPaths -Target 'Local' -TenantId $TenantId -RepoRoot $repoRoot
    $blockingChecks = @($gate.Checks | Where-Object { $_.Blocking } | ForEach-Object { $_.Check })
    $state.gate = [ordered]@{ profile = $gateProfile; outcome = $gate.Outcome; blockingChecks = $blockingChecks; counts = $gate.Counts }
    if ($gate.Outcome -ne 'Passed') {
        $state.error = "The quality gate ($gateProfile) failed: $($blockingChecks -join ', '). Run scripts/quality/Invoke-PbiQualityGate.ps1 -Profile $gateProfile for details."
        Add-DeploymentStep -Name "Quality gate ($gateProfile)" -Status 'Failed' -Summary ($blockingChecks -join ', ')
        Complete-Deployment -ExitCode 1
    }
    Add-DeploymentStep -Name "Quality gate ($gateProfile)" -Status 'Passed' -Summary ("{0} check(s) passed or not applicable." -f @($gate.Checks).Count)
} catch {
    $state.error = "The quality gate could not run: $($_.Exception.Message)"
    Add-DeploymentStep -Name 'Quality gate' -Status 'Failed' -Summary $state.error
    Complete-Deployment -ExitCode 1
}

# 3-5. Sign in, workspace, items, refresh, tests.
try {
    Write-PbiLog 'Signing in...' -Level Step
    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        $null = Connect-PbiFabric
    } else {
        $null = Connect-PbiFabric -TenantId $TenantId
    }

    $workspaceId = $null
    if ($SkipInfrastructure) {
        $workspace = Get-PbiWorkspace -DisplayName $workspaceName
        if ($null -eq $workspace) {
            throw "Workspace '$workspaceName' does not exist. Run scripts/infra/Deploy-PbiInfrastructure.ps1 -Environment $environmentName first (or omit -SkipInfrastructure)."
        }
        $workspaceId = [string](Get-PbiProperty $workspace 'id' '')
        Add-DeploymentStep -Name 'Workspace' -Status 'Passed' -Summary "Using existing workspace '$workspaceName' (-SkipInfrastructure)."
    } else {
        Write-PbiLog "Workspace '$workspaceName'" -Level Step
        $workspaceResult = Deploy-PbiWorkspace -Config $config -WhatIf:$isWhatIf
        $workspaceId = $workspaceResult.WorkspaceId
        $changeCount = @($workspaceResult.Changes).Count
        $workspaceSummary = 'Up to date.'
        if ($changeCount -gt 0) {
            $workspaceSummary = ('{0} change(s): {1}' -f $changeCount, (@($workspaceResult.Changes) -join '; '))
        }
        Add-DeploymentStep -Name 'Workspace' -Status 'Passed' -Summary $workspaceSummary
    }

    $deployedModels = [System.Collections.Generic.List[object]]::new()
    foreach ($projectConfig in $projects) {
        $projectPath = [string](Get-PbiProperty $projectConfig 'path' '')
        $projectFolder = Join-Path $repoRoot $projectPath
        $modelConfig = Get-PbiProperty $projectConfig 'semanticModel'
        $modelName = [string](Get-PbiProperty $modelConfig 'displayName' '')
        $modelFolder = Join-Path $projectFolder ([string](Get-PbiProperty $modelConfig 'folder' ''))
        if ([string]::IsNullOrEmpty($workspaceId)) {
            $state.items.Add([ordered]@{ project = $projectPath; type = 'SemanticModel'; displayName = $modelName; action = 'WouldCreate'; id = $null })
            Add-DeploymentStep -Name "Semantic model $modelName" -Status 'Passed' -Summary 'WouldCreate (the workspace does not exist yet).'
            foreach ($reportConfig in @(Get-PbiProperty $projectConfig 'reports')) {
                $reportName = [string](Get-PbiProperty $reportConfig 'displayName' '')
                $state.items.Add([ordered]@{ project = $projectPath; type = 'Report'; displayName = $reportName; action = 'WouldCreate'; id = $null })
                Add-DeploymentStep -Name "Report $reportName" -Status 'Passed' -Summary 'WouldCreate (the workspace does not exist yet).'
            }
            continue
        }

        Write-PbiLog "Semantic model '$modelName'" -Level Step
        $modelParameters = @{
            WorkspaceId = $workspaceId
            ItemPath    = $modelFolder
            DisplayName = $modelName
            Parameter   = (Get-PbiProperty $modelConfig 'parameters')
            Description = [string](Get-PbiProperty $modelConfig 'description' '')
            WhatIf      = $isWhatIf
        }
        $model = Publish-PbiSemanticModel @modelParameters
        $state.items.Add([ordered]@{ project = $projectPath; type = 'SemanticModel'; displayName = $modelName; action = $model.Action; id = $model.Id })
        Add-DeploymentStep -Name "Semantic model $modelName" -Status 'Passed' -Summary $model.Action

        $refreshWanted = [bool](Get-PbiProperty $modelConfig 'refreshAfterDeploy' $false)
        if ($refreshWanted -and -not $SkipRefresh) {
            if ([string]::IsNullOrEmpty($model.Id)) {
                $state.refreshes.Add([ordered]@{ displayName = $modelName; status = 'WhatIf'; durationSec = 0 })
                Add-DeploymentStep -Name "Refresh $modelName" -Status 'Passed' -Summary 'Would refresh after creation (-WhatIf).'
            } else {
                $refresh = Invoke-PbiDatasetRefresh -WorkspaceId $workspaceId -DatasetId $model.Id -DisplayName $modelName -WhatIf:$isWhatIf
                $state.refreshes.Add([ordered]@{ displayName = $modelName; status = $refresh.Status; durationSec = $refresh.DurationSec })
                Add-DeploymentStep -Name "Refresh $modelName" -Status 'Passed' -Summary ('{0} ({1} s)' -f $refresh.Status, $refresh.DurationSec)
            }
        } elseif ($refreshWanted) {
            Add-DeploymentStep -Name "Refresh $modelName" -Status 'Skipped' -Summary 'Skipped (-SkipRefresh).'
        }

        foreach ($reportConfig in @(Get-PbiProperty $projectConfig 'reports')) {
            $reportName = [string](Get-PbiProperty $reportConfig 'displayName' '')
            Write-PbiLog "Report '$reportName'" -Level Step
            $reportParameters = @{
                WorkspaceId     = $workspaceId
                ItemPath        = (Join-Path $projectFolder ([string](Get-PbiProperty $reportConfig 'folder' '')))
                DisplayName     = $reportName
                SemanticModelId = [string]$model.Id
                Description     = [string](Get-PbiProperty $reportConfig 'description' '')
                WhatIf          = $isWhatIf
            }
            $report = Publish-PbiReport @reportParameters
            $state.items.Add([ordered]@{ project = $projectPath; type = 'Report'; displayName = $reportName; action = $report.Action; id = $report.Id })
            Add-DeploymentStep -Name "Report $reportName" -Status 'Passed' -Summary $report.Action
        }
        $deployedModels.Add([pscustomobject]@{ ProjectPath = $projectPath; ModelFolder = $modelFolder; DisplayName = $modelName; Id = [string]$model.Id })
    }

    $runTests = [bool](Get-PbiProperty (Get-PbiProperty $config 'postDeploy') 'runDaxTests' $false)
    if ($SkipTests) {
        $state.tests.skipped = $true
        $state.tests.reason = '-SkipTests'
        Add-DeploymentStep -Name 'DAX tests' -Status 'Skipped' -Summary 'Skipped (-SkipTests); this evidence does not satisfy requireTestEvidence.'
    } elseif (-not $runTests) {
        $state.tests.skipped = $true
        $state.tests.reason = 'postDeploy.runDaxTests is false'
        Add-DeploymentStep -Name 'DAX tests' -Status 'NotApplicable' -Summary 'postDeploy.runDaxTests is false.'
    } elseif ($isWhatIf) {
        $state.tests.skipped = $true
        $state.tests.reason = 'WhatIf'
        Add-DeploymentStep -Name 'DAX tests' -Status 'Skipped' -Summary 'Not run with -WhatIf.'
    } else {
        $maxDuration = [int](Get-PbiProperty (Get-PbiProperty $gateConfig 'thresholds') 'daxTestMaxDurationMs' 5000)
        $allResults = [System.Collections.Generic.List[object]]::new()
        foreach ($deployed in $deployedModels) {
            Write-PbiLog "DAX tests of '$($deployed.DisplayName)' on $environmentName" -Level Step
            foreach ($testResult in @(Invoke-PbiDaxTestSuite -SemanticModelPath $deployed.ModelFolder -Target $environmentName -WorkspaceId $workspaceId -DatasetId $deployed.Id -MaxDurationMs $maxDuration -RepoRoot $repoRoot)) {
                $allResults.Add(($testResult | Add-Member -NotePropertyName 'Project' -NotePropertyValue $deployed.ProjectPath -PassThru -Force))
            }
        }
        $failedTests = @($allResults | Where-Object { -not $_.Passed -and -not $_.Skipped })
        $skippedTests = @($allResults | Where-Object { $_.Skipped })
        $passedTests = @($allResults | Where-Object { $_.Passed })
        $state.tests.run = $true
        $state.tests.passed = $passedTests.Count
        $state.tests.failed = $failedTests.Count
        $state.tests.skippedFiles = $skippedTests.Count
        $state.tests.results = $allResults.ToArray()
        $testSummary = '{0} passed, {1} failed, {2} skipped (role tests run only locally).' -f $passedTests.Count, $failedTests.Count, $skippedTests.Count
        if ($failedTests.Count -gt 0) {
            $names = @($failedTests | Select-Object -First 5 | ForEach-Object { $_.TestName }) -join '; '
            $state.error = "DAX tests failed on ${environmentName}: $names"
            Add-DeploymentStep -Name 'DAX tests' -Status 'Failed' -Summary $testSummary
            Complete-Deployment -ExitCode 1
        }
        $testStatus = 'Passed'
        if ($allResults.Count -eq 0) {
            $testStatus = 'Warning'
            $testSummary = 'No DAX test files for this environment.'
        }
        Add-DeploymentStep -Name 'DAX tests' -Status $testStatus -Summary $testSummary
    }
} catch {
    $state.error = Protect-PbiText -Text $_.Exception.Message
    Add-DeploymentStep -Name 'Deployment' -Status 'Failed' -Summary $state.error
    Complete-Deployment -ExitCode 1
}

Complete-Deployment -ExitCode 0
