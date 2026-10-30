#Requires -Version 7.4
<#
.SYNOPSIS
    Runs the Best Practice Analyzer (Tabular Editor 2 CLI) on a TMDL semantic model.
.DESCRIPTION
    Windows only. Uses tools/.bin/te2/TabularEditor.exe (scripts/bootstrap/Install-PbiTooling.ps1).
    Rules: config/quality/bpa-rules.json (repository rules) plus tools/.bin/bpa/BPARules.json (Microsoft rules, when
    downloaded and tools/versions.json bpaRules.enabled), merged into tools/.bin/bpa/effective-rules.json (deduplicated
    by ID, repository rules win) because TE2 accepts one rules file. -RulesPath replaces both.
    The model argument is <model>/definition/database.tmdl (tools/versions.json tabularEditor2.modelArgument =
    databaseFile) or <model>/definition (definitionFolder). The TRX output is parsed into findings (severity from the
    rule: 1 Info, 2 Warning, >= 3 Error) and compared with config/quality/gates.json thresholds bpaMaxErrors and
    bpaMaxWarnings. TRX and logs are kept in .evidence/bpa/.
    Exit codes: 0 within thresholds, 1 thresholds exceeded, 2 prerequisite/usage error (not Windows, TE2 missing,
    rules missing, model not found).
.PARAMETER SemanticModelPath
    The *.SemanticModel folder.
.PARAMETER RulesPath
    Rule files to use instead of the defaults.
.PARAMETER Json
    Print the result object as JSON on stdout.
.EXAMPLE
    pwsh -NoProfile -File scripts/quality/Invoke-PbiModelBpa.ps1 -SemanticModelPath src/SalesStarter/SalesStarter.SemanticModel
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SemanticModelPath,

    [string[]] $RulesPath,

    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'PbiSuperpower' 'PbiSuperpower.psd1') -Force
Set-PbiLogMode -Quiet:$Json

function Write-BpaUsageError {
    <#
    .SYNOPSIS
        Reports a prerequisite/usage error and exits with 2.
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

try {
    $repoRoot = Get-PbiRepoRoot -Path $PSScriptRoot
    $modelPath = $SemanticModelPath
    if (-not [System.IO.Path]::IsPathRooted($modelPath) -and -not (Test-Path -LiteralPath $modelPath)) {
        $modelPath = Join-Path $repoRoot $SemanticModelPath
    }
    if (-not (Test-Path -LiteralPath $modelPath -PathType Container)) {
        throw "Semantic model folder not found: $SemanticModelPath"
    }
    $gate = Get-PbiGateConfig -RepoRoot $repoRoot
    $thresholds = Get-PbiProperty $gate 'thresholds'
    $maxErrors = [int](Get-PbiProperty $thresholds 'bpaMaxErrors' 0)
    $maxWarnings = [int](Get-PbiProperty $thresholds 'bpaMaxWarnings' 25)
    $bpaParameters = @{ SemanticModelPath = $modelPath; RepoRoot = $repoRoot }
    $rules = @(Split-PbiListArgument $RulesPath)
    if ($rules.Count -gt 0) {
        $bpaParameters.RulesPath = $rules
    }
    $result = Test-PbiModelBpa @bpaParameters
    if ($result.Status -eq 'Skipped') {
        throw $result.SkipReason
    }
} catch {
    Write-BpaUsageError $_.Exception.Message
}

$exceeded = ($result.ErrorCount -gt $maxErrors) -or ($result.WarningCount -gt $maxWarnings)
$outcome = 'Passed'
if ($exceeded) {
    $outcome = 'Failed'
}
if ($Json) {
    [ordered]@{
        outcome      = $outcome
        exitCode     = $(if ($exceeded) { 1 } else { 0 })
        model        = Get-PbiRelativePath -Path $modelPath -RepoRoot $repoRoot
        errors       = $result.ErrorCount
        warnings     = $result.WarningCount
        info         = $result.InfoCount
        maxErrors    = $maxErrors
        maxWarnings  = $maxWarnings
        rules        = $result.RuleCount
        rulesPath    = $result.RulesPath
        trxPath      = $result.TrxPath
        logPath      = $result.LogPath
        te2ExitCode  = $result.ExitCode
        findings     = $result.Findings
        logWarnings  = @(Get-PbiLogWarning)
    } | ConvertTo-Json -Depth 10
} else {
    $findings = @($result.Findings)
    if ($findings.Count -gt 0) {
        $ordered = @($findings | Sort-Object -Property @{ Expression = { @('Error', 'Warning', 'Info').IndexOf([string]$_.Severity) } }, Message)
        Write-Host (($ordered | Format-Table -Property Severity, Message -AutoSize -Wrap | Out-String -Width 220).TrimEnd())
    }
    Write-Host ''
    Write-PbiLog ("Rules: {0} ({1}); TRX: {2}" -f $result.RuleCount, $result.RulesPath, $result.TrxPath)
    $summary = '{0} error(s) (max {1}), {2} warning(s) (max {3}), {4} info.' -f $result.ErrorCount, $maxErrors, $result.WarningCount, $maxWarnings, $result.InfoCount
    if ($exceeded) {
        Write-PbiLog "Best Practice Analyzer FAILED: $summary Fix the violations or, for a justified exception, adjust config/quality/bpa-rules.json in a reviewed pull request." -Level Error
    } else {
        Write-PbiLog "Best Practice Analyzer passed: $summary" -Level Success
    }
}
if ($exceeded) {
    exit 1
}
exit 0
