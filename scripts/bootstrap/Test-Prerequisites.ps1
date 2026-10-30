#Requires -Version 7.4
<#
.SYNOPSIS
    Checks the tools a developer (or an agent) needs to work in the power-bi-superpower repository.
.DESCRIPTION
    Prints a table of checks { Name, Required, Status (Ok | Missing | Outdated | Warning), Found, Expected, Fix }:
      - PowerShell >= 7.4; Windows (required for Power BI Desktop; a warning elsewhere)
      - git >= 2.45; on Windows Git for Windows bash.exe (the Superpowers SessionStart hook needs bash),
        git core.longpaths = true (warning) and the LongPathsEnabled registry value (warning)
      - GitHub CLI gh >= 2.90 and 'gh auth status'; Node.js >= 22 and npm; GitHub Copilot CLI (copilot --version)
      - Power BI Desktop (Microsoft Store or MSI) on Windows; VS Code 'code' on PATH (optional)
      - PowerShell modules Az.Accounts >= 5.0.0, Pester >= 5.5.0, Az.Fabric >= 1.0.0 (optional), SqlServer (optional)
      - npm CLIs powerbi-report-author and powerbi-desktop, Tabular Editor 2 and ADOMD.NET in tools/.bin (optional
        until scripts/bootstrap/Install-PbiTooling.ps1 has run)
    Version parsing tolerates prefixes such as 'v22.11.0', 'git version 2.47.1.windows.1' or 'gh version 2.90.0 (...)'.
    Exit codes: 0 = all required checks pass, 2 = at least one required check fails.
.PARAMETER Json
    Print one JSON object { outcome, checks[] } instead of the table.
.PARAMETER BeforeTooling
    Do not fail on checks that Install-PbiTooling.ps1 fixes (PowerShell modules). Used by Initialize-PbiSuperpower.ps1
    before it installs the tooling.
.EXAMPLE
    pwsh -NoProfile -File scripts/bootstrap/Test-Prerequisites.ps1
.EXAMPLE
    pwsh -NoProfile -File scripts/bootstrap/Test-Prerequisites.ps1 -Json | ConvertFrom-Json
#>
[CmdletBinding()]
param(
    [switch] $Json,

    [switch] $BeforeTooling
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'PbiSuperpower' 'PbiSuperpower.psd1') -Force
Set-PbiLogMode -Quiet:$Json

$checks = [System.Collections.Generic.List[object]]::new()

function Add-PrerequisiteResult {
    <#
    .SYNOPSIS
        Records one prerequisite check result.
    #>
    param(
        [string] $Name,
        [bool] $Required,
        [ValidateSet('Ok', 'Missing', 'Outdated', 'Warning')]
        [string] $Status,
        [string] $Found = '',
        [string] $Expected = '',
        [string] $Fix = '',
        [bool] $Installable = $false
    )
    $checks.Add([pscustomobject]@{
            Name        = $Name
            Required    = $Required
            Status      = $Status
            Found       = $Found
            Expected    = $Expected
            Fix         = $Fix
            Installable = $Installable
        })
}

function Get-ToolInfo {
    <#
    .SYNOPSIS
        Runs '<tool> <arguments>' and returns { Path, Text, Version, ExitCode }, or $null when the tool is not on PATH.
    #>
    param(
        [string] $Name,
        [string[]] $Arguments = @('--version')
    )
    $command = Get-Command -Name $Name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        return $null
    }
    try {
        $run = Invoke-PbiNativeCommand -FilePath $command.Source -ArgumentList $Arguments
        $text = ((@($run.StdOut) + @($run.StdErr)) -join ' ').Trim()
        return [pscustomobject]@{ Path = $command.Source; Text = $text; Version = (ConvertTo-PbiVersion -Text $text); ExitCode = $run.ExitCode }
    } catch {
        return [pscustomobject]@{ Path = $command.Source; Text = $_.Exception.Message; Version = $null; ExitCode = -1 }
    }
}

function Add-VersionCheck {
    <#
    .SYNOPSIS
        Checks that a command-line tool exists and meets a minimum version.
    #>
    param(
        [string] $Name,
        [string] $Command,
        [bool] $Required,
        [string] $Minimum,
        [string] $Fix,
        [string[]] $Arguments = @('--version')
    )
    $tool = Get-ToolInfo -Name $Command -Arguments $Arguments
    $expected = 'present'
    if (-not [string]::IsNullOrEmpty($Minimum)) {
        $expected = ">= $Minimum"
    }
    if ($null -eq $tool) {
        Add-PrerequisiteResult -Name $Name -Required $Required -Status 'Missing' -Found 'not found' -Expected $expected -Fix $Fix
        return $null
    }
    if ([string]::IsNullOrEmpty($Minimum)) {
        $found = 'present'
        if ($null -ne $tool.Version) {
            $found = $tool.Version.ToString()
        }
        Add-PrerequisiteResult -Name $Name -Required $Required -Status 'Ok' -Found $found -Expected $expected
        return $tool
    }
    if ($null -eq $tool.Version) {
        Add-PrerequisiteResult -Name $Name -Required $Required -Status 'Warning' -Found 'unknown version' -Expected $expected -Fix $Fix
        return $tool
    }
    $status = 'Ok'
    if ($tool.Version -lt (ConvertTo-PbiVersion -Text $Minimum)) {
        $status = 'Outdated'
    }
    Add-PrerequisiteResult -Name $Name -Required $Required -Status $status -Found $tool.Version.ToString() -Expected $expected -Fix $Fix
    return $tool
}

function Add-ModuleCheck {
    <#
    .SYNOPSIS
        Checks that a PowerShell module is available in a minimum version.
    #>
    param(
        [string] $Name,
        [string] $Minimum,
        [bool] $Required,
        [bool] $Installable = $true
    )
    $module = Get-Module -ListAvailable -Name $Name | Sort-Object -Property Version -Descending | Select-Object -First 1
    $fix = 'Run scripts/bootstrap/Install-PbiTooling.ps1'
    $expected = 'present'
    if (-not [string]::IsNullOrEmpty($Minimum)) {
        $expected = ">= $Minimum"
    }
    if ($null -eq $module) {
        Add-PrerequisiteResult -Name "PS module $Name" -Required $Required -Status 'Missing' -Found 'not installed' -Expected $expected -Fix $fix -Installable $Installable
        return
    }
    $status = 'Ok'
    if (-not [string]::IsNullOrEmpty($Minimum) -and $module.Version -lt [version]$Minimum) {
        $status = 'Outdated'
    }
    Add-PrerequisiteResult -Name "PS module $Name" -Required $Required -Status $status -Found $module.Version.ToString() -Expected $expected -Fix $fix -Installable $Installable
}

try {
    $repoRoot = Get-PbiRepoRoot -Path $PSScriptRoot

    $psVersion = ConvertTo-PbiVersion -Text $PSVersionTable.PSVersion.ToString()
    $psStatus = 'Ok'
    if ($psVersion -lt [version]'7.4.0') {
        $psStatus = 'Outdated'
    }
    Add-PrerequisiteResult -Name 'PowerShell' -Required $true -Status $psStatus -Found $psVersion.ToString() -Expected '>= 7.4' -Fix 'winget install --id Microsoft.PowerShell'

    if ($IsWindows) {
        Add-PrerequisiteResult -Name 'Windows' -Required $false -Status 'Ok' -Found 'Windows' -Expected 'Windows'
    } else {
        Add-PrerequisiteResult -Name 'Windows' -Required $false -Status 'Warning' -Found ([System.Runtime.InteropServices.RuntimeInformation]::OSDescription) -Expected 'Windows' -Fix 'Power BI Desktop, Tabular Editor 2 and local DAX tests need Windows; other steps work cross-platform.'
    }

    $git = Add-VersionCheck -Name 'git' -Command 'git' -Required $true -Minimum '2.45.0' -Fix 'winget install --id Git.Git'
    if ($IsWindows) {
        $bashPath = $null
        if ($null -ne $git) {
            $gitRoot = Split-Path -Path (Split-Path -Path $git.Path -Parent) -Parent
            $bashCandidates = [System.Collections.Generic.List[string]]::new()
            if (-not [string]::IsNullOrEmpty($gitRoot)) {
                $bashCandidates.Add((Join-Path $gitRoot 'bin' 'bash.exe'))
                $bashCandidates.Add((Join-Path $gitRoot 'usr' 'bin' 'bash.exe'))
                $gitParent = Split-Path -Path $gitRoot -Parent
                if (-not [string]::IsNullOrEmpty($gitParent)) {
                    $bashCandidates.Add((Join-Path $gitParent 'bin' 'bash.exe'))
                }
            }
            foreach ($candidate in $bashCandidates) {
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $bashPath = $candidate
                    break
                }
            }
        }
        if ($null -ne $bashPath) {
            Add-PrerequisiteResult -Name 'Git Bash (bash.exe)' -Required $true -Status 'Ok' -Found 'Git for Windows bash.exe' -Expected 'present'
        } else {
            Add-PrerequisiteResult -Name 'Git Bash (bash.exe)' -Required $true -Status 'Missing' -Found 'not found next to git' -Expected 'present' -Fix 'Install Git for Windows (winget install --id Git.Git); the Superpowers SessionStart hook needs bash.'
        }
        if ($null -ne $git) {
            $longPaths = Invoke-PbiNativeCommand -FilePath $git.Path -ArgumentList @('config', '--get', 'core.longpaths')
            $longPathsValue = (@($longPaths.StdOut) -join '').Trim()
            if ($longPathsValue -eq 'true') {
                Add-PrerequisiteResult -Name 'git core.longpaths' -Required $false -Status 'Ok' -Found 'true' -Expected 'true'
            } else {
                Add-PrerequisiteResult -Name 'git core.longpaths' -Required $false -Status 'Warning' -Found $longPathsValue -Expected 'true' -Fix 'git config --global core.longpaths true'
            }
        }
        $longPathsEnabled = $null
        try {
            $longPathsEnabled = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -ErrorAction Stop).LongPathsEnabled
        } catch {
            $longPathsEnabled = $null
        }
        if ($longPathsEnabled -eq 1) {
            Add-PrerequisiteResult -Name 'Windows LongPathsEnabled' -Required $false -Status 'Ok' -Found '1' -Expected '1'
        } else {
            Add-PrerequisiteResult -Name 'Windows LongPathsEnabled' -Required $false -Status 'Warning' -Found ([string]$longPathsEnabled) -Expected '1' -Fix 'As administrator: Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem LongPathsEnabled 1'
        }
    }

    $gh = Add-VersionCheck -Name 'GitHub CLI (gh)' -Command 'gh' -Required $true -Minimum '2.90.0' -Fix 'winget install --id GitHub.cli'
    if ($null -ne $gh) {
        $auth = Invoke-PbiNativeCommand -FilePath $gh.Path -ArgumentList @('auth', 'status') -Environment @{ GH_PROMPT_DISABLED = '1' }
        if ($auth.ExitCode -eq 0) {
            Add-PrerequisiteResult -Name 'gh auth status' -Required $true -Status 'Ok' -Found 'authenticated' -Expected 'authenticated'
        } else {
            Add-PrerequisiteResult -Name 'gh auth status' -Required $true -Status 'Missing' -Found 'not authenticated' -Expected 'authenticated' -Fix 'gh auth login (add project scope with: gh auth refresh -s project)'
        }
    }
    $null = Add-VersionCheck -Name 'Node.js' -Command 'node' -Required $true -Minimum '22.0.0' -Fix 'winget install --id OpenJS.NodeJS.LTS'
    $null = Add-VersionCheck -Name 'npm' -Command 'npm' -Required $true -Minimum '' -Fix 'npm ships with Node.js 22+'
    $null = Add-VersionCheck -Name 'GitHub Copilot CLI' -Command 'copilot' -Required $true -Minimum '' -Fix 'npm install -g @github/copilot'

    if ($IsWindows) {
        $desktopFound = $null
        try {
            $package = Get-AppxPackage -Name 'Microsoft.MicrosoftPowerBIDesktop' -ErrorAction Stop | Select-Object -First 1
            if ($null -ne $package) {
                $desktopFound = "Microsoft Store $($package.Version)"
            }
        } catch {
            $fallback = Get-ToolInfo -Name 'powershell.exe' -Arguments @('-NoProfile', '-NonInteractive', '-Command', '(Get-AppxPackage -Name Microsoft.MicrosoftPowerBIDesktop | Select-Object -First 1).Version')
            if ($null -ne $fallback -and $null -ne $fallback.Version) {
                $desktopFound = "Microsoft Store $($fallback.Version)"
            }
        }
        $msiPath = Join-Path $env:ProgramFiles 'Microsoft Power BI Desktop' 'bin' 'PBIDesktop.exe'
        if ($null -eq $desktopFound -and (Test-Path -LiteralPath $msiPath -PathType Leaf)) {
            $desktopFound = 'MSI ' + (Get-Item -LiteralPath $msiPath).VersionInfo.ProductVersion
        }
        if ($null -ne $desktopFound) {
            Add-PrerequisiteResult -Name 'Power BI Desktop' -Required $true -Status 'Ok' -Found $desktopFound -Expected 'present'
        } else {
            Add-PrerequisiteResult -Name 'Power BI Desktop' -Required $true -Status 'Missing' -Found 'not found' -Expected 'present' -Fix 'winget install --id Microsoft.PowerBI (or the Microsoft Store app)'
        }
    } else {
        Add-PrerequisiteResult -Name 'Power BI Desktop' -Required $false -Status 'Warning' -Found 'not available on this OS' -Expected 'Windows' -Fix 'Use a Windows machine for Power BI Desktop work.'
    }
    $code = Get-ToolInfo -Name 'code'
    if ($null -ne $code) {
        Add-PrerequisiteResult -Name 'VS Code (code)' -Required $false -Status 'Ok' -Found 'present' -Expected 'present'
    } else {
        Add-PrerequisiteResult -Name 'VS Code (code)' -Required $false -Status 'Warning' -Found 'not on PATH' -Expected 'present' -Fix 'winget install --id Microsoft.VisualStudioCode'
    }

    Add-ModuleCheck -Name 'Az.Accounts' -Minimum '5.0.0' -Required $true
    Add-ModuleCheck -Name 'Pester' -Minimum '5.5.0' -Required $true
    Add-ModuleCheck -Name 'Az.Fabric' -Minimum '1.0.0' -Required $false
    Add-ModuleCheck -Name 'SqlServer' -Minimum '' -Required $false -Installable $false

    foreach ($cli in @('powerbi-report-author', 'powerbi-desktop')) {
        $command = Get-Command -Name $cli -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            Add-PrerequisiteResult -Name "npm CLI $cli" -Required $false -Status 'Ok' -Found 'present' -Expected 'present' -Installable $true
        } else {
            Add-PrerequisiteResult -Name "npm CLI $cli" -Required $false -Status 'Warning' -Found 'not on PATH' -Expected 'present' -Fix 'Run scripts/bootstrap/Install-PbiTooling.ps1' -Installable $true
        }
    }
    $te2 = Join-Path $repoRoot 'tools' '.bin' 'te2' 'TabularEditor.exe'
    if (Test-Path -LiteralPath $te2 -PathType Leaf) {
        Add-PrerequisiteResult -Name 'Tabular Editor 2' -Required $false -Status 'Ok' -Found 'tools/.bin/te2' -Expected 'present' -Installable $true
    } else {
        Add-PrerequisiteResult -Name 'Tabular Editor 2' -Required $false -Status 'Warning' -Found 'not installed' -Expected 'tools/.bin/te2/TabularEditor.exe' -Fix 'Run scripts/bootstrap/Install-PbiTooling.ps1 (Windows)' -Installable $true
    }
    $adomdRoot = Join-Path $repoRoot 'tools' '.bin' 'adomd'
    $adomd = @()
    if (Test-Path -LiteralPath $adomdRoot -PathType Container) {
        $adomd = @(Get-ChildItem -LiteralPath $adomdRoot -Recurse -File -Filter 'Microsoft.AnalysisServices.AdomdClient.dll')
    }
    if ($adomd.Count -gt 0) {
        Add-PrerequisiteResult -Name 'ADOMD.NET client' -Required $false -Status 'Ok' -Found 'tools/.bin/adomd' -Expected 'present' -Installable $true
    } else {
        Add-PrerequisiteResult -Name 'ADOMD.NET client' -Required $false -Status 'Warning' -Found 'not installed' -Expected 'tools/.bin/adomd' -Fix 'Run scripts/bootstrap/Install-PbiTooling.ps1' -Installable $true
    }
} catch {
    $message = $_.Exception.Message
    if ($Json) {
        [Console]::Error.WriteLine("[pbi] ERROR: $message")
        [ordered]@{ outcome = 'Error'; error = $message; checks = $checks.ToArray() } | ConvertTo-Json -Depth 5
    } else {
        Write-PbiLog $message -Level Error
    }
    exit 2
}

$blocking = @($checks | Where-Object { $_.Required -and @('Missing', 'Outdated') -contains $_.Status -and -not ($BeforeTooling -and $_.Installable) })
$outcome = 'Passed'
if ($blocking.Count -gt 0) {
    $outcome = 'Failed'
}
if ($Json) {
    [ordered]@{ outcome = $outcome; beforeTooling = [bool]$BeforeTooling; checks = $checks.ToArray() } | ConvertTo-Json -Depth 5
} else {
    $table = $checks | Format-Table -Property Name, Required, Status, Found, Expected -AutoSize | Out-String -Width 220
    Write-Host $table.TrimEnd()
    $toFix = @($checks | Where-Object { $_.Status -ne 'Ok' -and -not [string]::IsNullOrEmpty($_.Fix) })
    if ($toFix.Count -gt 0) {
        Write-Host ''
        Write-PbiLog 'How to fix:'
        foreach ($item in $toFix) {
            Write-Host ("  - {0}: {1}" -f $item.Name, $item.Fix)
        }
    }
    Write-Host ''
    if ($blocking.Count -gt 0) {
        Write-PbiLog ("{0} required prerequisite(s) missing or outdated: {1}" -f $blocking.Count, (($blocking | ForEach-Object { $_.Name }) -join ', ')) -Level Error
    } else {
        Write-PbiLog 'All required prerequisites are met.' -Level Success
    }
}
if ($blocking.Count -gt 0) {
    exit 2
}
exit 0
