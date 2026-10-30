#Requires -Version 7.4
<#
.SYNOPSIS
    Creates a Microsoft Fabric capacity (Azure resource) or updates its SKU - infrastructure as code with Az.Fabric.
.DESCRIPTION
    Requires the Az.Fabric module (scripts/bootstrap/Install-PbiTooling.ps1 installs it) and Az.Accounts.
    - Get-AzFabricCapacity; when the capacity does not exist: New-AzFabricCapacity -ResourceGroupName -CapacityName
      -Location -SkuName -SkuTier Fabric -AdministrationMember -Tag.
    - When it exists with another SKU: Update-AzFabricCapacity -SkuName.
    - Different administration members are reported (not changed).
    Capacity changes affect every environment (DEV, TEST and PROD share capacities) and are human-only: the agent
    guardrail hook blocks this script for agents. Supports -WhatIf. The subscription id is never printed.
    Exit codes: 0 success, 1 an Azure operation failed, 2 usage/prerequisite error.
.PARAMETER SubscriptionId
    Azure subscription that holds the capacity.
.PARAMETER ResourceGroupName
    Resource group of the capacity.
.PARAMETER Name
    Capacity name: lower-case letters and digits, 3-63 characters, starting with a letter.
.PARAMETER Location
    Azure region, for example westeurope.
.PARAMETER Sku
    F2 (default), F4, F8, F16, F32, F64, F128, F256, F512, F1024 or F2048.
.PARAMETER AdministrationMember
    Capacity administrators (user principal names or service principal object ids).
.PARAMETER Tag
    Azure tags, for example @{ project = 'power-bi-superpower' }.
.PARAMETER TenantId
    Tenant to sign in to (default: PBI_TENANT_ID when set).
.EXAMPLE
    pwsh -NoProfile -File scripts/infra/Deploy-FabricCapacity.ps1 -SubscriptionId $sub -ResourceGroupName rg-pbi -Name pbisuperpowerf2 -Location westeurope -AdministrationMember admin@contoso.com -WhatIf
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
    [string] $Location,

    [ArgumentCompletions('F2', 'F4', 'F8', 'F16', 'F32', 'F64', 'F128', 'F256', 'F512', 'F1024', 'F2048')]
    [string] $Sku = 'F2',

    [Parameter(Mandatory)]
    [string[]] $AdministrationMember,

    [hashtable] $Tag = @{},

    [string] $TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'PbiSuperpower' 'PbiSuperpower.psd1') -Force
Set-PbiLogMode

$members = @(Split-PbiListArgument $AdministrationMember)
$Sku = $Sku.ToUpperInvariant()
try {
    if ($Name -cnotmatch '^[a-z][a-z0-9]{2,62}$') {
        throw "Invalid capacity name '$Name': use 3-63 lower-case letters and digits, starting with a letter."
    }
    if ($Sku -notmatch '^F(2|4|8|16|32|64|128|256|512|1024|2048)$') {
        throw "Invalid -Sku '$Sku': use F2, F4, F8, F16, F32, F64, F128, F256, F512, F1024 or F2048."
    }
    if ($members.Count -eq 0) {
        throw '-AdministrationMember needs at least one capacity administrator.'
    }
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
    Write-PbiLog "Fabric capacity '$Name' ($ResourceGroupName)" -Level Step
    $capacity = $null
    try {
        $capacity = Get-AzFabricCapacity @capacityParameters -ErrorAction Stop
    } catch {
        if ($_.Exception.Message -notmatch '(?i)not\s*found|ResourceNotFound|ResourceGroupNotFound|404') {
            throw
        }
        $capacity = $null
    }
    if ($null -eq $capacity) {
        Write-PbiLog "Plan: create capacity '$Name' ($Sku) in $Location with $($members.Count) administrator(s)."
        if ($PSCmdlet.ShouldProcess("capacity '$Name'", "Create ($Sku, $Location)")) {
            $null = New-AzFabricCapacity @capacityParameters -Location $Location -SkuName $Sku -SkuTier 'Fabric' -AdministrationMember $members -Tag $Tag -ErrorAction Stop
            Write-PbiLog "Created capacity '$Name' ($Sku)." -Level Success
        }
    } else {
        $currentSku = [string](Get-PbiProperty $capacity 'SkuName' (Get-PbiProperty (Get-PbiProperty $capacity 'Sku') 'Name' ''))
        if ($currentSku -ne $Sku) {
            Write-PbiLog "Plan: change the SKU of '$Name' from $currentSku to $Sku."
            if ($PSCmdlet.ShouldProcess("capacity '$Name'", "Change SKU $currentSku -> $Sku")) {
                $null = Update-AzFabricCapacity @capacityParameters -SkuName $Sku -SkuTier 'Fabric' -ErrorAction Stop
                Write-PbiLog "Capacity '$Name' is now $Sku." -Level Success
            }
        } else {
            Write-PbiLog "Capacity '$Name' already exists with SKU $Sku."
        }
        $currentMembers = @(Get-PbiProperty $capacity 'AdministrationMember' (Get-PbiProperty (Get-PbiProperty $capacity 'Administration') 'Member'))
        $missingMembers = @($members | Where-Object { $currentMembers -notcontains $_ })
        if ($missingMembers.Count -gt 0) {
            Write-PbiWarning "$($missingMembers.Count) requested administrator(s) are not capacity administrators yet. Add them in the Azure portal (this script does not change administrators of an existing capacity)."
        }
    }
} catch {
    Write-PbiLog ("Capacity deployment failed: {0}" -f (Protect-PbiText -Text $_.Exception.Message)) -Level Error
    exit 1
}
exit 0
