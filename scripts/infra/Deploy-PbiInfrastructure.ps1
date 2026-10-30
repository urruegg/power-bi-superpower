#Requires -Version 7.4
<#
.SYNOPSIS
    Provisions the workspace of an environment (capacity assignment, description, role assignments) - infrastructure as code.
.DESCRIPTION
    1. Loads config/environments/<env>.json (+ <env>.local.json, .env.local placeholders).
    2. Enforces ALL guards of the environment (Assert-PbiDeploymentGuard): branch, clean tree, merged to main, TEST
       evidence, release approval and the human-only typed confirmation for PROD.
    3. Signs in (Connect-PbiFabric) and runs Deploy-PbiWorkspace: creates the workspace if missing, assigns the
       capacity, updates the description and adds/updates role assignments (never removes any).
    4. Writes evidence (kind infrastructure) and prints a summary with identifiers masked.
    Supports -WhatIf (plan only; reads the service but changes nothing).
    Exit codes: 0 success, 1 a guard or a deployment step failed, 2 configuration/usage error.
.PARAMETER Environment
    DEV, TEST or PROD.
.PARAMETER TenantId
    Tenant to sign in to (default: PBI_TENANT_ID when set).
.PARAMETER ReleaseIssue
    Release issue number (required by PROD's requireReleaseApproval guard).
.PARAMETER Json
    Print the result object as JSON on stdout.
.EXAMPLE
    pwsh -NoProfile -File scripts/infra/Deploy-PbiInfrastructure.ps1 -Environment DEV -WhatIf
.EXAMPLE
    pwsh -NoProfile -File scripts/infra/Deploy-PbiInfrastructure.ps1 -Environment TEST
#>
[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param(
    [Parameter(Mandatory)]
    [ArgumentCompletions('DEV', 'TEST', 'PROD')]
    [string] $Environment,

    [string] $TenantId,

    [int] $ReleaseIssue,

    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'PbiSuperpower' 'PbiSuperpower.psd1') -Force
Set-PbiLogMode -Quiet:$Json

function Write-InfraResult {
    <#
    .SYNOPSIS
        Prints the JSON result (in -Json mode) and exits with the given code.
    #>
    param(
        [System.Collections.IDictionary] $Result,
        [int] $ExitCode
    )
    if ($Json) {
        $Result['exitCode'] = $ExitCode
        $Result['warnings'] = @(Get-PbiLogWarning)
        $Result | ConvertTo-Json -Depth 10
    }
    exit $ExitCode
}

$result = [ordered]@{
    outcome     = 'Error'
    environment = $null
    whatIf      = [bool]$WhatIfPreference
    workspace   = $null
    created     = $false
    changes     = @()
    error       = $null
}
$environmentName = $Environment.ToUpperInvariant()
if (@('DEV', 'TEST', 'PROD') -notcontains $environmentName) {
    $result.error = "Invalid -Environment '$Environment'. Use DEV, TEST or PROD."
    Write-PbiLog $result.error -Level Error
    Write-InfraResult -Result $result -ExitCode 2
}
$result.environment = $environmentName
if ([string]::IsNullOrWhiteSpace($TenantId) -and -not [string]::IsNullOrWhiteSpace($env:PBI_TENANT_ID)) {
    $TenantId = $env:PBI_TENANT_ID
}

try {
    $repoRoot = Get-PbiRepoRoot -Path $PSScriptRoot
    $config = Get-PbiEnvironmentConfig -Environment $environmentName -RepoRoot $repoRoot
    $workspaceName = [string](Get-PbiProperty (Get-PbiProperty $config 'workspace') 'displayName' '')
    $result.workspace = $workspaceName
    $git = Get-PbiGitContext -RepoRoot $repoRoot
} catch {
    $result.error = $_.Exception.Message
    Write-PbiLog $result.error -Level Error
    Write-InfraResult -Result $result -ExitCode 2
}

try {
    Write-PbiLog "Checking the $environmentName deployment guards..." -Level Step
    Assert-PbiDeploymentGuard -Config $config -GitContext $git -ReleaseIssue $ReleaseIssue -RepoRoot $repoRoot
} catch {
    $result.outcome = 'Failed'
    $result.error = $_.Exception.Message
    Write-PbiLog $result.error -Level Error
    Write-InfraResult -Result $result -ExitCode 1
}

$exitCode = 0
try {
    Write-PbiLog 'Signing in...' -Level Step
    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        $null = Connect-PbiFabric
    } else {
        $null = Connect-PbiFabric -TenantId $TenantId
    }
    Write-PbiLog "Workspace '$workspaceName' ($environmentName)" -Level Step
    $deployment = Deploy-PbiWorkspace -Config $config -WhatIf:$WhatIfPreference
    $result.created = [bool]$deployment.Created
    $result.changes = @($deployment.Changes)
    $result.outcome = 'Passed'
} catch {
    $result.outcome = 'Failed'
    $result.error = Protect-PbiText -Text $_.Exception.Message
    $exitCode = 1
}

try {
    $evidenceData = [ordered]@{
        environment = $environmentName
        workspace   = $workspaceName
        whatIf      = [bool]$WhatIfPreference
        created     = $result.created
        changes     = $result.changes
        outcome     = $result.outcome
        error       = $result.error
        warnings    = @(Get-PbiLogWarning)
    }
    $evidencePath = New-PbiEvidence -Kind 'infrastructure' -Environment $environmentName -Data $evidenceData -RepoRoot $repoRoot -GitContext $git
    $result['evidencePath'] = Get-PbiRelativePath -Path $evidencePath -RepoRoot $repoRoot
} catch {
    Write-PbiWarning "Evidence could not be written: $($_.Exception.Message)"
}

if (-not $Json) {
    Write-Host ''
    $planWord = 'Changes'
    if ($WhatIfPreference) {
        $planWord = 'Planned changes (-WhatIf, nothing was changed)'
    }
    Write-PbiLog ("{0} for workspace '{1}':" -f $planWord, $workspaceName) -Level Step
    if (@($result.changes).Count -eq 0) {
        Write-Host '  - none (the workspace already matches the configuration)'
    }
    foreach ($change in @($result.changes)) {
        Write-Host ('  - ' + (Protect-PbiText -Text $change))
    }
    if ($result.Contains('evidencePath')) {
        Write-PbiLog "Evidence: $($result['evidencePath'])"
    }
    if ($result.outcome -eq 'Passed') {
        Write-PbiLog "Infrastructure for $environmentName is up to date." -Level Success
    } else {
        Write-PbiLog "Infrastructure deployment failed: $($result.error)" -Level Error
    }
}
Write-InfraResult -Result $result -ExitCode $exitCode
