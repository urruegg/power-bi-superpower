#Requires -Version 7.4
<#
.SYNOPSIS
    Installs the pinned tooling from tools/versions.json (PowerShell modules, npm CLIs and local binaries).
.DESCRIPTION
    - PowerShell modules (psModules) for the current user: Install-PSResource when available, otherwise
      Install-Module -Scope CurrentUser -Force -AllowClobber -MinimumVersion. Already satisfied modules are skipped.
    - npm global CLIs (npm.globalCli): npm install -g <package>@<version>; skipped when already installed (any version
      for 'latest', the exact version otherwise).
    - Binaries into tools/.bin/ (git-ignored):
        Tabular Editor 2 portable zip (Windows only)  -> tools/.bin/te2
        Microsoft BPA rules (when bpaRules.enabled)   -> tools/.bin/bpa/BPARules.json
        ADOMD.NET NuGet package                        -> tools/.bin/adomd/<id>.<version>/
        Fab Inspector zip (only when fabInspector.url) -> tools/.bin/fab-inspector
      Downloads that are already present (same version) are skipped unless -Force.
    - Writes tools/.bin/installed.json with what was installed and the SHA-256 of every downloaded archive.
    Supports -WhatIf. Exit codes: 0 success, 1 an installation failed, 2 configuration/prerequisite error.
.PARAMETER SkipModules
    Do not install PowerShell modules.
.PARAMETER SkipNpm
    Do not install npm CLIs.
.PARAMETER SkipBinaries
    Do not download binaries.
.PARAMETER Force
    Reinstall and re-download even when already present.
.EXAMPLE
    pwsh -NoProfile -File scripts/bootstrap/Install-PbiTooling.ps1
.EXAMPLE
    pwsh -NoProfile -File scripts/bootstrap/Install-PbiTooling.ps1 -SkipNpm -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $SkipModules,

    [switch] $SkipNpm,

    [switch] $SkipBinaries,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'PbiSuperpower' 'PbiSuperpower.psd1') -Force
Set-PbiLogMode

try {
    $repoRoot = Get-PbiRepoRoot -Path $PSScriptRoot
    $versions = Get-PbiToolVersions -RepoRoot $repoRoot
} catch {
    Write-PbiLog $_.Exception.Message -Level Error
    exit 2
}

$binRoot = Join-Path $repoRoot 'tools' '.bin'
$downloadRoot = Join-Path $binRoot 'downloads'
$manifestPath = Join-Path $binRoot 'installed.json'
$failures = [System.Collections.Generic.List[string]]::new()
$record = [ordered]@{
    updatedUtc = $null
    modules    = [ordered]@{}
    npm        = [ordered]@{}
    binaries   = [ordered]@{}
}
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try {
        $previous = Read-PbiJsonFile -Path $manifestPath -Description 'tools/.bin/installed.json'
        foreach ($section in @('modules', 'npm', 'binaries')) {
            $sectionValue = Get-PbiProperty $previous $section
            if ($null -ne $sectionValue) {
                foreach ($property in $sectionValue.PSObject.Properties) {
                    $record[$section][$property.Name] = $property.Value
                }
            }
        }
    } catch {
        Write-PbiWarning "Ignoring an unreadable tools/.bin/installed.json: $($_.Exception.Message)"
    }
}

function Save-ToolDownload {
    <#
    .SYNOPSIS
        Downloads a URL to a file (via a .partial file) and returns the SHA-256 of the file.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Url,

        [Parameter(Mandatory)]
        [string] $Destination
    )
    $ProgressPreference = 'SilentlyContinue'
    $directory = Split-Path -Path $Destination -Parent
    $null = New-Item -ItemType Directory -Path $directory -Force
    $partial = $Destination + '.partial'
    Invoke-WebRequest -Uri $Url -OutFile $partial -ErrorAction Stop -Verbose:$false
    Move-Item -LiteralPath $partial -Destination $Destination -Force
    return (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-ToolRecorded {
    <#
    .SYNOPSIS
        $true when installed.json records the binary with the same version and its target exists.
    #>
    param(
        [string] $Name,
        [string] $Version,
        [string] $TargetPath
    )
    $entry = $record.binaries[$Name]
    if ($null -eq $entry) {
        return $false
    }
    $recordedVersion = [string](Get-PbiProperty $entry 'version' '')
    return ($recordedVersion -eq $Version -and (Test-Path -LiteralPath $TargetPath))
}

function Add-ToolRecord {
    <#
    .SYNOPSIS
        Records an installed binary in installed.json.
    #>
    param(
        [string] $Name,
        [string] $Version,
        [string] $Url,
        [string] $TargetPath,
        [string] $Sha256
    )
    $record.binaries[$Name] = [ordered]@{
        version      = $Version
        url          = $Url
        path         = Get-PbiRelativePath -Path $TargetPath -RepoRoot $repoRoot
        sha256       = $Sha256
        installedUtc = [DateTime]::UtcNow.ToString('o')
    }
}

if (-not $SkipModules) {
    Write-PbiLog 'PowerShell modules (CurrentUser)' -Level Step
    $usePsResource = $null -ne (Get-Command -Name 'Install-PSResource' -ErrorAction SilentlyContinue)
    foreach ($module in @(Get-PbiProperty $versions 'psModules')) {
        $name = [string](Get-PbiProperty $module 'name' '')
        $minimum = [string](Get-PbiProperty $module 'minimumVersion' '0.0.1')
        $optional = [bool](Get-PbiProperty $module 'optional' $false)
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        $present = Get-Module -ListAvailable -Name $name | Where-Object { $_.Version -ge [version]$minimum } | Sort-Object -Property Version -Descending | Select-Object -First 1
        if ($null -ne $present -and -not $Force) {
            Write-PbiLog "$name $($present.Version) is already installed."
            $record.modules[$name] = [ordered]@{ version = $present.Version.ToString() }
            continue
        }
        if (-not $PSCmdlet.ShouldProcess("$name >= $minimum (CurrentUser)", 'Install PowerShell module')) {
            continue
        }
        try {
            if ($usePsResource) {
                Install-PSResource -Name $name -Version "[$minimum,)" -Scope CurrentUser -TrustRepository -Reinstall:$Force -Quiet -ErrorAction Stop
            } else {
                $moduleParameters = @{
                    Name           = $name
                    MinimumVersion = $minimum
                    Scope          = 'CurrentUser'
                    Force          = $true
                    AllowClobber   = $true
                    ErrorAction    = 'Stop'
                }
                if ($name -eq 'Pester') {
                    $moduleParameters.SkipPublisherCheck = $true
                }
                Install-Module @moduleParameters
            }
            $installedModule = Get-Module -ListAvailable -Name $name | Sort-Object -Property Version -Descending | Select-Object -First 1
            $installedVersion = 'unknown'
            if ($null -ne $installedModule) {
                $installedVersion = $installedModule.Version.ToString()
            }
            $record.modules[$name] = [ordered]@{ version = $installedVersion }
            Write-PbiLog "Installed $name $installedVersion." -Level Success
        } catch {
            $message = "Could not install PowerShell module $name ($($_.Exception.Message))."
            if ($optional) {
                Write-PbiWarning "$message It is optional."
            } else {
                $failures.Add($message)
            }
        }
    }
}

if (-not $SkipNpm) {
    Write-PbiLog 'npm global CLIs' -Level Step
    $npm = Get-Command -Name 'npm' -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    $globalCli = Get-PbiProperty (Get-PbiProperty $versions 'npm') 'globalCli'
    if ($null -eq $npm) {
        $failures.Add('npm was not found. Install Node.js 22 or later (winget install --id OpenJS.NodeJS.LTS) and re-run.')
    } elseif ($null -ne $globalCli) {
        $dependencies = $null
        try {
            $listing = Invoke-PbiNativeCommand -FilePath $npm.Source -ArgumentList @('ls', '-g', '--depth=0', '--json')
            $dependencies = Get-PbiProperty (ConvertFrom-Json -InputObject (@($listing.StdOut) -join "`n") -Depth 20) 'dependencies'
        } catch {
            Write-Verbose "Could not list global npm packages: $($_.Exception.Message)"
        }
        foreach ($package in $globalCli.PSObject.Properties) {
            $packageName = $package.Name
            $requested = [string]$package.Value
            if ([string]::IsNullOrWhiteSpace($requested)) {
                $requested = 'latest'
            }
            $installedVersion = [string](Get-PbiProperty (Get-PbiProperty $dependencies $packageName) 'version' '')
            if (-not [string]::IsNullOrEmpty($installedVersion) -and -not $Force -and ($requested -eq 'latest' -or $installedVersion -eq $requested)) {
                Write-PbiLog "$packageName $installedVersion is already installed."
                $record.npm[$packageName] = [ordered]@{ requested = $requested; version = $installedVersion }
                continue
            }
            if (-not $PSCmdlet.ShouldProcess("$packageName@$requested", 'npm install -g')) {
                continue
            }
            $run = Invoke-PbiNativeCommand -FilePath $npm.Source -ArgumentList @('install', '-g', "$packageName@$requested")
            if ($run.ExitCode -ne 0) {
                $failures.Add(("npm install -g {0}@{1} failed (exit {2}): {3}" -f $packageName, $requested, $run.ExitCode, ((@($run.StdErr) | Select-Object -Last 5) -join ' ')))
                continue
            }
            $record.npm[$packageName] = [ordered]@{ requested = $requested; version = $requested }
            Write-PbiLog "Installed $packageName@$requested." -Level Success
        }
    }
}

if (-not $SkipBinaries) {
    Write-PbiLog 'Binaries (tools/.bin)' -Level Step

    $te2Config = Get-PbiProperty $versions 'tabularEditor2'
    $te2Url = [string](Get-PbiProperty $te2Config 'url' '')
    $te2Version = [string](Get-PbiProperty $te2Config 'version' '')
    $te2Directory = Join-Path $binRoot 'te2'
    $te2Exe = Join-Path $te2Directory 'TabularEditor.exe'
    if (-not $IsWindows) {
        Write-PbiLog 'Skipping Tabular Editor 2 (Windows only).'
    } elseif ([string]::IsNullOrWhiteSpace($te2Url)) {
        Write-PbiWarning 'tools/versions.json has no tabularEditor2.url; Tabular Editor 2 was not installed.'
    } elseif ((Test-ToolRecorded -Name 'tabularEditor2' -Version $te2Version -TargetPath $te2Exe) -and -not $Force) {
        Write-PbiLog "Tabular Editor $te2Version is already installed."
    } elseif ($PSCmdlet.ShouldProcess('tools/.bin/te2', "Download Tabular Editor $te2Version")) {
        try {
            $archive = Join-Path $downloadRoot "TabularEditor.Portable.$te2Version.zip"
            $sha = Save-ToolDownload -Url $te2Url -Destination $archive
            if (Test-Path -LiteralPath $te2Directory) {
                Remove-Item -LiteralPath $te2Directory -Recurse -Force
            }
            Expand-Archive -LiteralPath $archive -DestinationPath $te2Directory -Force
            if (-not (Test-Path -LiteralPath $te2Exe -PathType Leaf)) {
                $nested = Get-ChildItem -LiteralPath $te2Directory -Recurse -File -Filter 'TabularEditor.exe' | Select-Object -First 1
                if ($null -eq $nested) {
                    throw 'TabularEditor.exe was not found in the downloaded archive.'
                }
                Get-ChildItem -LiteralPath $nested.DirectoryName -Force | Move-Item -Destination $te2Directory -Force
            }
            Add-ToolRecord -Name 'tabularEditor2' -Version $te2Version -Url $te2Url -TargetPath $te2Exe -Sha256 $sha
            Write-PbiLog "Installed Tabular Editor $te2Version." -Level Success
        } catch {
            $failures.Add("Tabular Editor 2: $($_.Exception.Message)")
        }
    }

    $bpaConfig = Get-PbiProperty $versions 'bpaRules'
    $bpaUrl = [string](Get-PbiProperty $bpaConfig 'url' '')
    $bpaEnabled = [bool](Get-PbiProperty $bpaConfig 'enabled' $false)
    $bpaFile = Join-Path $binRoot 'bpa' 'BPARules.json'
    if (-not $bpaEnabled -or [string]::IsNullOrWhiteSpace($bpaUrl)) {
        Write-PbiLog 'Microsoft BPA rules are disabled in tools/versions.json.'
    } elseif ((Test-Path -LiteralPath $bpaFile -PathType Leaf) -and -not $Force) {
        Write-PbiLog 'Microsoft BPA rules are already downloaded (use -Force to refresh).'
    } elseif ($PSCmdlet.ShouldProcess('tools/.bin/bpa/BPARules.json', 'Download Microsoft BPA rules')) {
        try {
            $sha = Save-ToolDownload -Url $bpaUrl -Destination $bpaFile
            $null = Read-PbiJsonFile -Path $bpaFile -Description 'Downloaded BPA rules'
            Add-ToolRecord -Name 'bpaRules' -Version 'url' -Url $bpaUrl -TargetPath $bpaFile -Sha256 $sha
            Write-PbiLog 'Downloaded the Microsoft BPA rules.' -Level Success
        } catch {
            $failures.Add("BPA rules: $($_.Exception.Message)")
        }
    }

    $adomdConfig = Get-PbiProperty $versions 'adomd'
    $adomdPackage = [string](Get-PbiProperty $adomdConfig 'package' '')
    $adomdVersion = [string](Get-PbiProperty $adomdConfig 'version' '')
    if ([string]::IsNullOrWhiteSpace($adomdPackage) -or [string]::IsNullOrWhiteSpace($adomdVersion)) {
        Write-PbiWarning 'tools/versions.json has no adomd.package/version; ADOMD.NET was not installed.'
    } else {
        $adomdDirectory = Join-Path $binRoot 'adomd' "$adomdPackage.$adomdVersion"
        if ((Test-Path -LiteralPath $adomdDirectory -PathType Container) -and -not $Force) {
            Write-PbiLog "ADOMD.NET $adomdVersion is already installed."
        } elseif ($PSCmdlet.ShouldProcess("tools/.bin/adomd/$adomdPackage.$adomdVersion", 'Download ADOMD.NET (NuGet)')) {
            try {
                $adomdUrl = "https://www.nuget.org/api/v2/package/$adomdPackage/$adomdVersion"
                $archive = Join-Path $downloadRoot "$adomdPackage.$adomdVersion.zip"
                $sha = Save-ToolDownload -Url $adomdUrl -Destination $archive
                if (Test-Path -LiteralPath $adomdDirectory) {
                    Remove-Item -LiteralPath $adomdDirectory -Recurse -Force
                }
                Expand-Archive -LiteralPath $archive -DestinationPath $adomdDirectory -Force
                Add-ToolRecord -Name 'adomd' -Version $adomdVersion -Url $adomdUrl -TargetPath $adomdDirectory -Sha256 $sha
                Write-PbiLog "Installed ADOMD.NET $adomdVersion." -Level Success
            } catch {
                $failures.Add("ADOMD.NET: $($_.Exception.Message)")
            }
        }
    }

    $inspectorConfig = Get-PbiProperty $versions 'fabInspector'
    $inspectorUrl = [string](Get-PbiProperty $inspectorConfig 'url' '')
    $inspectorVersion = [string](Get-PbiProperty $inspectorConfig 'version' '')
    $inspectorDirectory = Join-Path $binRoot 'fab-inspector'
    if ([string]::IsNullOrWhiteSpace($inspectorUrl)) {
        Write-PbiLog 'Fab Inspector is not configured (fabInspector.url is empty); skipping (optional).'
    } elseif ((Test-ToolRecorded -Name 'fabInspector' -Version $inspectorVersion -TargetPath $inspectorDirectory) -and -not $Force) {
        Write-PbiLog "Fab Inspector $inspectorVersion is already installed."
    } elseif ($PSCmdlet.ShouldProcess('tools/.bin/fab-inspector', "Download Fab Inspector $inspectorVersion")) {
        try {
            $archive = Join-Path $downloadRoot "fab-inspector.$inspectorVersion.zip"
            $sha = Save-ToolDownload -Url $inspectorUrl -Destination $archive
            if (Test-Path -LiteralPath $inspectorDirectory) {
                Remove-Item -LiteralPath $inspectorDirectory -Recurse -Force
            }
            Expand-Archive -LiteralPath $archive -DestinationPath $inspectorDirectory -Force
            Add-ToolRecord -Name 'fabInspector' -Version $inspectorVersion -Url $inspectorUrl -TargetPath $inspectorDirectory -Sha256 $sha
            Write-PbiLog "Installed Fab Inspector $inspectorVersion." -Level Success
        } catch {
            $failures.Add("Fab Inspector: $($_.Exception.Message)")
        }
    }
}

if (-not $WhatIfPreference) {
    $record.updatedUtc = [DateTime]::UtcNow.ToString('o')
    Write-PbiTextFile -Path $manifestPath -Content (ConvertTo-Json -InputObject $record -Depth 10)
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-PbiLog $failure -Level Error
    }
    Write-PbiLog 'Some tools could not be installed. Fix the errors above and re-run (already installed tools are skipped).' -Level Error
    exit 1
}
Write-PbiLog 'Tooling is installed. Run scripts/bootstrap/Test-Prerequisites.ps1 to verify.' -Level Success
exit 0
