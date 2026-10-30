#Requires -Version 7.4
<#
.SYNOPSIS
    Runs the Power BI quality gate (levels L0-L3) for a profile and records evidence.
.DESCRIPTION
    Profiles and levels come from config/quality/gates.json:
      L0 Structure and hygiene  RepoHygiene, PbipStructure, TmdlConventions, PbirValidate, AgentAssets, McpParity,
                                SuperpowersManifest
      L1 Static analysis        ModelBpa (Tabular Editor 2 BPA, Windows), ReportConventions, ReportInspector (optional)
      L2 Behaviour              DaxTests (-Target Local = Power BI Desktop with the project open; DEV/TEST/PROD =
                                deployed model, signs in with Az.Accounts)
      L3 Visual review          Screenshots (attended: a human reviews the PNGs, then re-runs with -AttendedConfirmed)
    -Level overrides the profile's levels; -Check runs exactly the named checks.
    Status per check: Passed, Failed, Warning (passes), Skipped, NotApplicable (passes). A Skipped check fails the
    gate when gates.json skippedCountsAsFailure is true, unless it is in optionalChecks or -AllowSkip.
    Output: a table on the console; evidence .evidence/<timestamp>-quality-gate-<commit>.json (unless -NoEvidence)
    with a masked markdown summary next to it (.md) for the pull request; -Json prints the result object instead.
    Exit codes: 0 Passed, 1 Failed, 2 configuration/usage error.
.PARAMETER Profile
    commit (default), pr, deploy-dev, deploy-test or release.
.PARAMETER Level
    Levels to run instead of the profile (for example L0,L1).
.PARAMETER Check
    Run only these checks (for example RepoHygiene,AgentAssets).
.PARAMETER ProjectPath
    Limit project checks to these folders (for example src/SalesStarter).
.PARAMETER Target
    Local (default), DEV, TEST or PROD (used by DaxTests and Screenshots).
.PARAMETER AllowSkip
    Checks that may be skipped without failing the gate (recorded in the evidence).
.PARAMETER AttendedConfirmed
    Confirms that a human reviewed the screenshots of the L3 check.
.PARAMETER TenantId
    Tenant for service DAX tests (default: PBI_TENANT_ID when set).
.PARAMETER NoEvidence
    Do not write evidence files (used by the Git hooks).
.PARAMETER Json
    Print the result object as JSON on stdout (progress goes to the information stream, warnings to stderr).
.EXAMPLE
    pwsh -NoProfile -File scripts/quality/Invoke-PbiQualityGate.ps1 -Profile commit
.EXAMPLE
    pwsh -NoProfile -File scripts/quality/Invoke-PbiQualityGate.ps1 -Profile pr -Target Local
.EXAMPLE
    pwsh -NoProfile -File scripts/quality/Invoke-PbiQualityGate.ps1 -Check ModelBpa,DaxTests -Target DEV -Json
#>
[CmdletBinding()]
param(
    [ArgumentCompletions('commit', 'pr', 'deploy-dev', 'deploy-test', 'release')]
    [string] $Profile = 'commit',

    [string[]] $Level,

    [string[]] $Check,

    [string[]] $ProjectPath,

    [ArgumentCompletions('Local', 'DEV', 'TEST', 'PROD')]
    [string] $Target = 'Local',

    [string[]] $AllowSkip,

    [switch] $AttendedConfirmed,

    [string] $TenantId,

    [switch] $NoEvidence,

    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'PbiSuperpower' 'PbiSuperpower.psd1') -Force
Set-PbiLogMode -Quiet:$Json

function Write-GateUsageError {
    <#
    .SYNOPSIS
        Reports a configuration/usage error (stderr + JSON in -Json mode) and exits with 2.
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

$targetNames = @('Local', 'DEV', 'TEST', 'PROD')
$matchedTarget = @($targetNames | Where-Object { $_ -eq $Target })
if ($matchedTarget.Count -eq 0) {
    Write-GateUsageError "Invalid -Target '$Target'. Use Local, DEV, TEST or PROD."
}
$Target = $matchedTarget[0]
if ([string]::IsNullOrWhiteSpace($TenantId) -and -not [string]::IsNullOrWhiteSpace($env:PBI_TENANT_ID)) {
    $TenantId = $env:PBI_TENANT_ID
}

try {
    $repoRoot = Get-PbiRepoRoot -Path $PSScriptRoot
    $gateParameters = @{
        Profile           = $Profile
        Level             = @(Split-PbiListArgument $Level)
        Check             = @(Split-PbiListArgument $Check)
        ProjectPath       = @(Split-PbiListArgument $ProjectPath)
        Target            = $Target
        AllowSkip         = @(Split-PbiListArgument $AllowSkip)
        AttendedConfirmed = [bool]$AttendedConfirmed
        TenantId          = $TenantId
        RepoRoot          = $repoRoot
    }
    $modeText = "profile $Profile"
    if (@($gateParameters.Check).Count -gt 0) {
        $modeText = 'checks ' + (@($gateParameters.Check) -join ', ')
    }
    Write-PbiLog "Quality gate: $modeText, target $Target" -Level Step
    $result = Test-PbiQualityGate @gateParameters
} catch {
    Write-GateUsageError $_.Exception.Message
}

$evidencePath = $null
$markdownPath = $null
$markdown = ConvertTo-PbiEvidenceMarkdown -Result $result.Checks -Title "Quality gate ($modeText, target $Target)" -Outcome $result.Outcome
if (-not $NoEvidence) {
    try {
        $evidenceData = [ordered]@{
            profile   = $result.Profile
            levels    = $result.Levels
            target    = $result.Target
            outcome   = $result.Outcome
            counts    = $result.Counts
            allowSkip = $result.AllowSkip
            projects  = $result.Projects
            checks    = $result.Checks
            warnings  = @(Get-PbiLogWarning)
        }
        $evidencePath = New-PbiEvidence -Kind 'quality-gate' -Data $evidenceData -RepoRoot $repoRoot
        $markdownPath = [System.IO.Path]::ChangeExtension($evidencePath, '.md')
        Write-PbiTextFile -Path $markdownPath -Content $markdown
    } catch {
        Write-PbiWarning "Evidence could not be written: $($_.Exception.Message)"
    }
}

if ($Json) {
    $output = [ordered]@{
        outcome      = $result.Outcome
        exitCode     = $(if ($result.Outcome -eq 'Passed') { 0 } else { 1 })
        profile      = $result.Profile
        levels       = $result.Levels
        target       = $result.Target
        counts       = $result.Counts
        checks       = $result.Checks
        evidencePath = $(if ($evidencePath) { Get-PbiRelativePath -Path $evidencePath -RepoRoot $repoRoot } else { $null })
        markdownPath = $(if ($markdownPath) { Get-PbiRelativePath -Path $markdownPath -RepoRoot $repoRoot } else { $null })
        warnings     = @(Get-PbiLogWarning)
    }
    $output | ConvertTo-Json -Depth 20
} else {
    $table = $result.Checks | Format-Table -Property Level, Check, Status, @{ Label = 'Blocking'; Expression = { if ($_.Blocking) { 'yes' } else { '' } } }, Summary -AutoSize -Wrap | Out-String -Width 220
    Write-Host $table.TrimEnd()
    foreach ($checkResult in $result.Checks) {
        $relevant = @($checkResult.Findings | Where-Object { $_.Severity -ne 'Info' })
        if ($relevant.Count -eq 0) {
            continue
        }
        Write-Host ''
        Write-Host ("{0} ({1}):" -f $checkResult.Check, $checkResult.Status)
        foreach ($finding in @($relevant | Select-Object -First 25)) {
            Write-Host ("  [{0}] {1}: {2}" -f $finding.Severity, $finding.Path, $finding.Message)
        }
        if ($relevant.Count -gt 25) {
            Write-Host ("  ... {0} more (see the evidence file)" -f ($relevant.Count - 25))
        }
    }
    Write-Host ''
    if ($null -ne $evidencePath) {
        Write-PbiLog ("Evidence: {0} (markdown summary for the pull request: {1})" -f (Get-PbiRelativePath -Path $evidencePath -RepoRoot $repoRoot), (Get-PbiRelativePath -Path $markdownPath -RepoRoot $repoRoot))
    }
    if ($result.Outcome -eq 'Passed') {
        Write-PbiLog ("Quality gate PASSED ({0} passed, {1} warning, {2} skipped, {3} not applicable)." -f $result.Counts['Passed'], $result.Counts['Warning'], $result.Counts['Skipped'], $result.Counts['NotApplicable']) -Level Success
    } else {
        $blocking = @($result.Checks | Where-Object { $_.Blocking } | ForEach-Object { $_.Check })
        Write-PbiLog ("Quality gate FAILED: {0}. Fix the findings above (or justify a skip with -AllowSkip) and re-run." -f ($blocking -join ', ')) -Level Error
    }
}
if ($result.Outcome -eq 'Passed') {
    exit 0
}
exit 1
