#Requires -Version 7.4
<#
.SYNOPSIS
    Resumes (Active) or pauses (Paused) a Microsoft Fabric capacity to control cost.
.DESCRIPTION
    Uses Az.Fabric: Resume-AzFabricCapacity or Suspend-AzFabricCapacity. Does nothing when the capacity is already in
    the requested state. Pausing a capacity makes every workspace on it unavailable (including PROD when the
    capacity is shared), so this is a human-only operation (blocked for agents by the guardrail hook).
    Supports -WhatIf. The subscription id is never printed.
    Exit codes: 0 success, 1 the Azure operation failed or the capacity was not found, 2 usage/prerequisite error.
.PARAMETER SubscriptionId
    Azure subscription that holds the capacity.
.PARAMETER ResourceGroupName
    Resource group of the capacity.
.PARAMETER Name
    Capacity name.
.PARAMETER State
    Active (resume) or Paused (suspend).
.PARAMETER TenantId
    Tenant to sign in to (default: PBI_TENANT_ID when set).
.EXAMPLE
    pwsh -NoProfile -File scripts/infra/Set-FabricCapacityState.ps1 -SubscriptionId $sub -ResourceGroupName rg-pbi -Name pbisuperpowerf2 -State Paused
#>
[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param(
    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [string] $Name,

    [Parameter(Mandatory)]
    [ArgumentCompletions('Active', 'Paused')]
    [string] $State,

    [string] $TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'PbiSuperpower' 'PbiSuperpower.psd1') -Force
Set-PbiLogMode

try {
    $matchedState = @(@('Active', 'Paused') | Where-Object { $_ -eq $State })
    if ($matchedState.Count -eq 0) {
        throw "Invalid -State '$State'. Use Active or Paused."
    }
    $State = $matchedState[0]
    if ($null -eq (Get-Module -ListAvailable -Name 'Az.Fabric')) {
        throw 'The Az.Fabric module is required. Run scripts/bootstrap/Install-PbiTooling.ps1 or Install-Module Az.Fabric -Scope CurrentUser.'
    }
    if ([string]::IsNullOrWhiteSpace($TenantId) -and -not [string]::IsNullOrWhiteSpace($env:PBI_TENANT_ID)) {
        $TenantId = $env:PBI_TENANT_ID
    }
    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        $null = Connect-PbiFabric
    } else {
        $null = Connect-PbiFabric -TenantId $TenantId
    }
    Import-Module -Name 'Az.Fabric' -ErrorAction Stop -Verbose:$false
} catch {
    Write-PbiLog $_.Exception.Message -Level Error
    exit 2
}

$capacityParameters = @{
    SubscriptionId    = $SubscriptionId
    ResourceGroupName = $ResourceGroupName
    CapacityName      = $Name
}
try {
    $capacity = $null
    try {
        $capacity = Get-AzFabricCapacity @capacityParameters -ErrorAction Stop
    } catch {
        if ($_.Exception.Message -notmatch '(?i)not\s*found|ResourceNotFound|ResourceGroupNotFound|404') {
            throw
        }
    }
    if ($null -eq $capacity) {
        Write-PbiLog "Capacity '$Name' was not found in resource group '$ResourceGroupName'." -Level Error
        exit 1
    }
    $current = [string](Get-PbiProperty $capacity 'State' '')
    $isPaused = @('Paused', 'Pausing', 'Suspended', 'Suspending') -contains $current
    if (($State -eq 'Paused' -and $isPaused) -or ($State -eq 'Active' -and -not $isPaused -and $current -ne '')) {
        Write-PbiLog "Capacity '$Name' is already $current; nothing to do." -Level Success
        exit 0
    }
    if ($State -eq 'Active') {
        if ($PSCmdlet.ShouldProcess("capacity '$Name'", 'Resume')) {
            $null = Resume-AzFabricCapacity @capacityParameters -ErrorAction Stop
            Write-PbiLog "Capacity '$Name' resumed." -Level Success
        }
    } else {
        if ($PSCmdlet.ShouldProcess("capacity '$Name'", 'Pause (every workspace on it becomes unavailable)')) {
            $null = Suspend-AzFabricCapacity @capacityParameters -ErrorAction Stop
            Write-PbiLog "Capacity '$Name' paused." -Level Success
        }
    }
} catch {
    Write-PbiLog ("Changing the capacity state failed: {0}" -f (Protect-PbiText -Text $_.Exception.Message)) -Level Error
    exit 1
}
exit 0
