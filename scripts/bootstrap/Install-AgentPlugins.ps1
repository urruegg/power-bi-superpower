#Requires -Version 7.4
<#
.SYNOPSIS
    Installs the GitHub Copilot CLI plugins from tools/versions.json and optionally vendors Superpowers into .github/skills.
.DESCRIPTION
    Plugins: for each entry of tools/versions.json 'plugins' ({ name, marketplace, marketplaceRepo, optional }):
      - adds the marketplace when 'copilot plugin marketplace list' does not show it
        (copilot plugin marketplace add <marketplaceRepo>);
      - installs the plugin unless 'copilot plugin list' already shows it (copilot plugin install <name>@<marketplace>).
      Optional plugins are installed only with -IncludeOptional. The copilot CLI is required unless -VendorSuperpowers
      is used (then plugin installation is skipped with a warning when copilot is missing).
    -VendorSuperpowers: git clone --depth 1 --branch <ref> <superpowers repo> into tools/.bin/tmp, copies its skills/*
      folders into .github/skills/ (pbi-* folders are never touched), copies LICENSE to
      .github/skills/SUPERPOWERS-LICENSE.txt and writes .github/skills/superpowers.manifest.json
      { source, ref, commit, hashAlgorithm, files: [{ path, sha256 }] }. The 'superpowers' plugin is then not installed
      (the vendored copy is used instead).
    -Verify: re-hashes the vendored files against the manifest; exit 1 on drift.
    Exit codes: 0 success, 1 failure or drift, 2 missing prerequisite or configuration.
.PARAMETER IncludeOptional
    Also install plugins marked optional.
.PARAMETER VendorSuperpowers
    Vendor the Superpowers skills into .github/skills (pinned by tag, hashed in a manifest).
.PARAMETER SuperpowersRef
    Tag or branch to vendor (default: tools/versions.json superpowers.ref).
.PARAMETER Verify
    Only verify the vendored Superpowers files against the manifest.
.EXAMPLE
    pwsh -NoProfile -File scripts/bootstrap/Install-AgentPlugins.ps1
.EXAMPLE
    pwsh -NoProfile -File scripts/bootstrap/Install-AgentPlugins.ps1 -VendorSuperpowers -SuperpowersRef v7.0.1
.EXAMPLE
    pwsh -NoProfile -File scripts/bootstrap/Install-AgentPlugins.ps1 -Verify
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $IncludeOptional,

    [switch] $VendorSuperpowers,

    [string] $SuperpowersRef,

    [switch] $Verify
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
$skillsDirectory = Join-Path $repoRoot '.github' 'skills'
$manifestPath = Join-Path $skillsDirectory 'superpowers.manifest.json'

if ($Verify) {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Write-PbiLog 'Superpowers is not vendored (.github/skills/superpowers.manifest.json does not exist); nothing to verify.'
        exit 0
    }
    try {
        $drift = @(Test-PbiSuperpowersManifest -RepoRoot $repoRoot)
    } catch {
        Write-PbiLog $_.Exception.Message -Level Error
        exit 2
    }
    if ($drift.Count -gt 0) {
        foreach ($finding in $drift) {
            Write-PbiLog ('{0}: {1}' -f $finding.Path, $finding.Message) -Level Error
        }
        Write-PbiLog "$($drift.Count) vendored Superpowers file(s) drifted from the manifest." -Level Error
        exit 1
    }
    Write-PbiLog 'Vendored Superpowers files match the manifest.' -Level Success
    exit 0
}

$failures = [System.Collections.Generic.List[string]]::new()

function Invoke-SuperpowersVendoring {
    <#
    .SYNOPSIS
        Clones Superpowers at a ref, copies its skills into .github/skills and writes the manifest.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Ref,

        [Parameter(Mandatory)]
        [string] $SourceUrl
    )
    $tempRoot = Join-Path $repoRoot 'tools' '.bin' 'tmp'
    $cloneDirectory = Join-Path $tempRoot ('superpowers-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $tempRoot -Force
    try {
        Write-PbiLog "Cloning $SourceUrl at $Ref..."
        $clone = Invoke-PbiNativeCommand -FilePath 'git' -ArgumentList @('-c', 'core.autocrlf=false', 'clone', '--quiet', '--depth', '1', '--branch', $Ref, $SourceUrl, $cloneDirectory) -Environment @{ GIT_TERMINAL_PROMPT = '0' }
        if ($clone.ExitCode -ne 0) {
            throw ("git clone failed (exit {0}): {1}" -f $clone.ExitCode, (@($clone.StdErr) -join ' '))
        }
        $revision = Invoke-PbiNativeCommand -FilePath 'git' -ArgumentList @('-C', $cloneDirectory, 'rev-parse', 'HEAD')
        $commit = (@($revision.StdOut) -join '').Trim()
        $sourceSkills = Join-Path $cloneDirectory 'skills'
        if (-not (Test-Path -LiteralPath $sourceSkills -PathType Container)) {
            throw "The Superpowers repository at $Ref has no skills folder."
        }
        $null = New-Item -ItemType Directory -Path $skillsDirectory -Force
        $previousSkills = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $previous = Read-PbiJsonFile -Path $manifestPath -Description 'Superpowers manifest'
            foreach ($entry in @(Get-PbiProperty $previous 'files')) {
                $match = [regex]::Match([string](Get-PbiProperty $entry 'path' ''), '^\.github/skills/(?<skill>[^/]+)/')
                if ($match.Success) {
                    $null = $previousSkills.Add($match.Groups['skill'].Value)
                }
            }
        }
        foreach ($skillName in $previousSkills) {
            $oldFolder = Join-Path $skillsDirectory $skillName
            if (-not $skillName.StartsWith('pbi-') -and (Test-Path -LiteralPath $oldFolder -PathType Container)) {
                Remove-Item -LiteralPath $oldFolder -Recurse -Force
            }
        }
        $vendored = [System.Collections.Generic.List[string]]::new()
        foreach ($skillFolder in @(Get-ChildItem -LiteralPath $sourceSkills -Directory | Sort-Object -Property Name)) {
            if ($skillFolder.Name.StartsWith('pbi-')) {
                Write-PbiWarning "Skipping upstream skill '$($skillFolder.Name)': pbi-* folders belong to this repository."
                continue
            }
            $target = Join-Path $skillsDirectory $skillFolder.Name
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Recurse -Force
            }
            Copy-Item -LiteralPath $skillFolder.FullName -Destination $target -Recurse -Force
            $vendored.Add($skillFolder.Name)
        }
        $licenseTarget = Join-Path $skillsDirectory 'SUPERPOWERS-LICENSE.txt'
        $license = Join-Path $cloneDirectory 'LICENSE'
        if (Test-Path -LiteralPath $license -PathType Leaf) {
            Copy-Item -LiteralPath $license -Destination $licenseTarget -Force
        } else {
            Write-PbiWarning 'The Superpowers repository has no LICENSE file; check the licence before committing the vendored skills.'
        }
        $files = [System.Collections.Generic.List[object]]::new()
        foreach ($skillName in $vendored) {
            foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $skillsDirectory $skillName) -Recurse -File -Force | Sort-Object -Property FullName)) {
                $files.Add([ordered]@{
                        path   = Get-PbiRelativePath -Path $file.FullName -RepoRoot $repoRoot
                        sha256 = Get-PbiContentHash -Path $file.FullName
                    })
            }
        }
        if (Test-Path -LiteralPath $licenseTarget -PathType Leaf) {
            $files.Add([ordered]@{
                    path   = Get-PbiRelativePath -Path $licenseTarget -RepoRoot $repoRoot
                    sha256 = Get-PbiContentHash -Path $licenseTarget
                })
        }
        $manifest = [ordered]@{
            source        = $SourceUrl
            ref           = $Ref
            commit        = $commit
            hashAlgorithm = 'sha256 (text files with CRLF normalised to LF)'
            vendoredUtc   = [DateTime]::UtcNow.ToString('o')
            files         = $files.ToArray()
        }
        Write-PbiTextFile -Path $manifestPath -Content (ConvertTo-Json -InputObject $manifest -Depth 5)
        Write-PbiLog ("Vendored {0} Superpowers skill(s) at {1} ({2} files). Review and commit .github/skills." -f $vendored.Count, $Ref, $files.Count) -Level Success
    } finally {
        if (Test-Path -LiteralPath $cloneDirectory) {
            Remove-Item -LiteralPath $cloneDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($VendorSuperpowers) {
    $superpowersConfig = Get-PbiProperty $versions 'superpowers'
    $reference = $SuperpowersRef
    if ([string]::IsNullOrWhiteSpace($reference)) {
        $reference = [string](Get-PbiProperty $superpowersConfig 'ref' '')
    }
    $sourceUrl = [string](Get-PbiProperty $superpowersConfig 'repo' 'https://github.com/obra/superpowers')
    if ([string]::IsNullOrWhiteSpace($reference)) {
        Write-PbiLog 'No Superpowers ref: pass -SuperpowersRef <tag> or set superpowers.ref in tools/versions.json.' -Level Error
        exit 2
    }
    if ($null -eq (Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-PbiLog 'git is required to vendor Superpowers (winget install --id Git.Git).' -Level Error
        exit 2
    }
    if ($PSCmdlet.ShouldProcess('.github/skills', "Vendor Superpowers $reference")) {
        try {
            Invoke-SuperpowersVendoring -Ref $reference -SourceUrl $sourceUrl
        } catch {
            $failures.Add("Vendoring Superpowers failed: $($_.Exception.Message)")
        }
    }
}

$plugins = @(Get-PbiProperty $versions 'plugins' | Where-Object {
        $isOptional = [bool](Get-PbiProperty $_ 'optional' $false)
        $pluginName = [string](Get-PbiProperty $_ 'name' '')
        (-not $isOptional -or $IncludeOptional) -and -not ($VendorSuperpowers -and $pluginName -eq 'superpowers')
    })
if ($plugins.Count -gt 0) {
    $copilot = Get-Command -Name 'copilot' -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $copilot) {
        if ($VendorSuperpowers) {
            Write-PbiWarning 'GitHub Copilot CLI (copilot) not found; plugin installation was skipped. Install it with: npm install -g @github/copilot'
        } else {
            Write-PbiLog 'GitHub Copilot CLI (copilot) is required: npm install -g @github/copilot (or use -VendorSuperpowers to vendor Superpowers only).' -Level Error
            exit 2
        }
    } else {
        $marketplaceList = Invoke-PbiNativeCommand -FilePath $copilot.Source -ArgumentList @('plugin', 'marketplace', 'list')
        $marketplaceText = (@($marketplaceList.StdOut) + @($marketplaceList.StdErr)) -join "`n"
        $pluginList = Invoke-PbiNativeCommand -FilePath $copilot.Source -ArgumentList @('plugin', 'list')
        $pluginText = (@($pluginList.StdOut) + @($pluginList.StdErr)) -join "`n"
        foreach ($plugin in $plugins) {
            $pluginName = [string](Get-PbiProperty $plugin 'name' '')
            $marketplace = [string](Get-PbiProperty $plugin 'marketplace' '')
            $marketplaceRepo = [string](Get-PbiProperty $plugin 'marketplaceRepo' '')
            $optional = [bool](Get-PbiProperty $plugin 'optional' $false)
            $knownMarketplace = [regex]::IsMatch($marketplaceText, '(?im)(^|[^\w-])' + [regex]::Escape($marketplace) + '([^\w-]|$)') -or
                (-not [string]::IsNullOrEmpty($marketplaceRepo) -and $marketplaceText.IndexOf($marketplaceRepo, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
            if (-not $knownMarketplace) {
                if ($PSCmdlet.ShouldProcess($marketplaceRepo, 'copilot plugin marketplace add')) {
                    $added = Invoke-PbiNativeCommand -FilePath $copilot.Source -ArgumentList @('plugin', 'marketplace', 'add', $marketplaceRepo)
                    if ($added.ExitCode -ne 0) {
                        $message = "Adding marketplace $marketplaceRepo failed (exit $($added.ExitCode)): $((@($added.StdErr) + @($added.StdOut)) -join ' ')"
                        if ($optional) {
                            Write-PbiWarning $message
                        } else {
                            $failures.Add($message)
                        }
                        continue
                    }
                    Write-PbiLog "Added plugin marketplace $marketplaceRepo." -Level Success
                }
            }
            if ([regex]::IsMatch($pluginText, '(?im)(^|[^\w-])' + [regex]::Escape($pluginName) + '([^\w-]|$)')) {
                Write-PbiLog "Plugin $pluginName is already installed."
                continue
            }
            if ($PSCmdlet.ShouldProcess("$pluginName@$marketplace", 'copilot plugin install')) {
                $install = Invoke-PbiNativeCommand -FilePath $copilot.Source -ArgumentList @('plugin', 'install', "$pluginName@$marketplace")
                if ($install.ExitCode -ne 0) {
                    $message = "Installing plugin $pluginName@$marketplace failed (exit $($install.ExitCode)): $((@($install.StdErr) + @($install.StdOut)) -join ' ')"
                    if ($optional) {
                        Write-PbiWarning $message
                    } else {
                        $failures.Add($message)
                    }
                    continue
                }
                Write-PbiLog "Installed plugin $pluginName@$marketplace." -Level Success
            }
        }
    }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-PbiLog $failure -Level Error
    }
    exit 1
}
Write-PbiLog 'Agent plugins are ready. Start a new Copilot session so that the plugins and skills are loaded.' -Level Success
exit 0
