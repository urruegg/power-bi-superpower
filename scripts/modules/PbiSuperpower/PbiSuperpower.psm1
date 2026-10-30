#Requires -Version 7.4
<#
    PbiSuperpower - shared PowerShell automation for the power-bi-superpower repository
    (Power BI as code: PBIP = TMDL semantic models + PBIR reports, driven by GitHub Copilot agents).

    Regions:
      Module state and logging   Set-PbiLogMode, Write-PbiLog, Write-PbiWarning, Get-PbiLogWarning
      Shared helpers             native commands, text/JSON files, paths, hashing, versions
      Repo + config helpers      Get-PbiRepoRoot, Get-PbiProperty, Expand-PbiPlaceholder, Get-PbiEnvironmentConfig, ...
      Git context and guards     Get-PbiGitContext, Assert-PbiDeploymentGuard
      Auth + REST core           Connect-PbiFabric, Get-PbiAccessToken, Invoke-PbiFabricApi, Invoke-PbiFabricApiPaged
      Workspace + capacity       Get-PbiCapacity, Get-PbiWorkspace, Deploy-PbiWorkspace
      Definitions and items      Get-PbipDefinitionPart, Set-PbipSemanticModelParameter, Set-PbipReportBinding, ...
      Power BI operations        Invoke-PbiDatasetRefresh, Invoke-PbiDaxQuery
      Local Power BI Desktop     Get-PbiDesktopInstance, Import-PbiAdomdClient, Invoke-PbiLocalDaxQuery
      DAX tests                  Get-PbiDaxTestFile, Get-PbiDaxTestDirective, Invoke-PbiDaxTestSuite
      Static checks              Test-PbiRepoHygiene, Test-PbipProjectStructure, Test-PbiTmdlConvention, ...
      Quality gate engine        Test-PbiModelBpa, Test-PbiSuperpowersManifest, Test-PbiQualityGate
      Evidence                   New-PbiEvidence, ConvertTo-PbiEvidenceMarkdown, Protect-PbiText
      GitHub CLI wrapper         Invoke-PbiGh

    Conventions
      - Functions never call 'exit'; entry scripts own the exit codes (0 ok, 1 gate/check failure, 2 usage/config).
      - Tokens are never printed or persisted. Messages that may contain identifiers are passed through Protect-PbiText.
      - Collections are returned unrolled (normal pipeline semantics): wrap calls in @() when you need an array.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Module state and logging

$script:PbiTokenCache = @{}
$script:PbiEmptyVariables = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:PbiLogState = @{
    Quiet    = $false
    Warnings = [System.Collections.Generic.List[string]]::new()
}
$script:PbiGuidPattern = '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'
$script:PbiZeroGuid = '00000000-0000-0000-0000-000000000000'
$script:PbiEmailPattern = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
$script:PbiPlaceholderPattern = '\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}'
$script:PbiSecretPatterns = @(
    '(?i)(client_secret|password|pwd)\s*[:=]\s*[''"][^''"$]{6,}'
    '-----BEGIN (RSA |EC )?PRIVATE KEY-----'
    '(?i)AccountKey[=]'
)
$script:PbiDefaultPartExclude = @(
    '^\.pbi/'
    '(^|/)\.pbi/'
    '^DAXQueries/'
    '^TMDLScripts/'
    '^\.platform$'
    '(^|/)localSettings\.json$'
    '\.abf$'
    '(^|/)item\..*\.json$'
)
$script:PbiApiBaseUrl = @{
    Fabric  = 'https://api.fabric.microsoft.com/v1/'
    PowerBI = 'https://api.powerbi.com/v1.0/myorg/'
}
$script:PbiResourceUrl = @{
    Fabric  = 'https://api.fabric.microsoft.com'
    PowerBI = 'https://analysis.windows.net/powerbi/api'
}
$script:PbiWalkExclude = @('.git', 'tools/.bin', 'node_modules', '.evidence')
$script:PbiGateCheckRegistry = [ordered]@{
    RepoHygiene         = 'L0'
    PbipStructure       = 'L0'
    TmdlConventions     = 'L0'
    PbirValidate        = 'L0'
    AgentAssets         = 'L0'
    McpParity           = 'L0'
    SuperpowersManifest = 'L0'
    ModelBpa            = 'L1'
    ReportConventions   = 'L1'
    ReportInspector     = 'L1'
    DaxTests            = 'L2'
    Screenshots         = 'L3'
}

function Set-PbiLogMode {
    <#
    .SYNOPSIS
        Switches the module's progress output between console mode and quiet (JSON) mode.
    .DESCRIPTION
        In quiet mode progress lines go to Write-Information (hidden by default) and warnings go to stderr, so an
        entry point can print exactly one JSON object on stdout. Warnings are always collected (Get-PbiLogWarning).
        Calling this function also clears the collected warnings.
    .PARAMETER Quiet
        Enable quiet mode. Entry points pass -Quiet:$Json.
    .EXAMPLE
        Set-PbiLogMode -Quiet:$Json
    #>
    [CmdletBinding()]
    param(
        [switch] $Quiet
    )
    $script:PbiLogState.Quiet = [bool]$Quiet
    $script:PbiLogState.Warnings.Clear()
}

function Write-PbiLog {
    <#
    .SYNOPSIS
        Writes a human progress line prefixed with '[pbi]'.
    .DESCRIPTION
        Uses Write-Host in console mode and Write-Information in quiet mode (see Set-PbiLogMode). Level 'Error' is
        written to stderr in quiet mode so that stdout stays valid JSON.
    .PARAMETER Message
        Text to write. Never pass tokens or secrets.
    .PARAMETER Level
        Info (default), Step (cyan), Success (green) or Error (red).
    .EXAMPLE
        Write-PbiLog 'Deploying workspace...' -Level Step
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string] $Message,

        [ValidateSet('Info', 'Step', 'Success', 'Error')]
        [string] $Level = 'Info'
    )
    $line = "[pbi] $Message"
    if ($Level -eq 'Error') {
        $line = "[pbi] ERROR: $Message"
    }
    if ($script:PbiLogState.Quiet) {
        if ($Level -eq 'Error') {
            [Console]::Error.WriteLine($line)
        } else {
            Write-Information -MessageData $line
        }
        return
    }
    $color = $null
    if ($Level -eq 'Step') { $color = 'Cyan' }
    if ($Level -eq 'Success') { $color = 'Green' }
    if ($Level -eq 'Error') { $color = 'Red' }
    if ($null -ne $color) {
        Write-Host $line -ForegroundColor $color
    } else {
        Write-Host $line
    }
}

function Write-PbiWarning {
    <#
    .SYNOPSIS
        Writes and records a warning.
    .DESCRIPTION
        Console mode: Write-Warning. Quiet (JSON) mode: the warning is written to stderr. In both modes the text is
        collected so that entry points can include it in their JSON result (Get-PbiLogWarning).
    .PARAMETER Message
        Warning text. Never pass tokens or secrets.
    .EXAMPLE
        Write-PbiWarning 'Workspace has unmanaged role assignments.'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Message
    )
    $script:PbiLogState.Warnings.Add($Message)
    if ($script:PbiLogState.Quiet) {
        [Console]::Error.WriteLine("WARNING: $Message")
    } else {
        Write-Warning -Message $Message
    }
}

function Get-PbiLogWarning {
    <#
    .SYNOPSIS
        Returns the warnings recorded by Write-PbiWarning since the last Set-PbiLogMode call.
    .EXAMPLE
        $result.warnings = @(Get-PbiLogWarning)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:PbiLogState.Warnings.ToArray()
}

#endregion Module state and logging

#region Shared helpers

function Split-PbiListArgument {
    <#
    .SYNOPSIS
        Normalises list arguments that may arrive as one comma-separated string.
    .DESCRIPTION
        'pwsh -File script.ps1 -Check A,B' passes "A,B" as ONE string. This splits every element on commas, trims
        whitespace and drops empty entries.
    .PARAMETER Value
        The raw argument values.
    .EXAMPLE
        $Check = @(Split-PbiListArgument $Check)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Value
    )
    if ($null -eq $Value) {
        return
    }
    foreach ($item in $Value) {
        if ([string]::IsNullOrEmpty($item)) {
            continue
        }
        foreach ($part in ($item -split ',')) {
            $trimmed = $part.Trim()
            if ($trimmed.Length -gt 0) {
                $trimmed
            }
        }
    }
}

function Invoke-PbiNativeCommand {
    <#
    .SYNOPSIS
        Runs an external program with an argument array and captures exit code, stdout and stderr.
    .DESCRIPTION
        Arguments are passed as an array (never concatenated into one string). Output on stderr never throws; inspect
        ExitCode. Output is decoded as UTF-8 for the duration of the call. Throws only when the program is not found.
    .PARAMETER FilePath
        Program name (resolved on PATH) or full path. npm '.ps1' shims are supported.
    .PARAMETER ArgumentList
        Arguments, one element per argument.
    .PARAMETER WorkingDirectory
        Directory to run in (default: current location).
    .PARAMETER Environment
        Extra environment variables for the duration of the call (restored afterwards).
    .EXAMPLE
        $result = Invoke-PbiNativeCommand -FilePath 'git' -ArgumentList @('status', '--porcelain')
        if ($result.ExitCode -ne 0) { throw ($result.StdErr -join ' ') }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [AllowEmptyCollection()]
        [string[]] $ArgumentList = @(),

        [string] $WorkingDirectory,

        [hashtable] $Environment
    )
    $command = Get-Command -Name $FilePath -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        throw "Command '$FilePath' was not found on PATH. Run scripts/bootstrap/Test-Prerequisites.ps1 to see what is missing."
    }
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $stdout = [System.Collections.Generic.List[string]]::new()
    $stderr = [System.Collections.Generic.List[string]]::new()
    $savedEnvironment = @{}
    $savedEncoding = $null
    $pushed = $false
    $exitCode = $null
    try {
        try {
            $savedEncoding = [Console]::OutputEncoding
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        } catch {
            $savedEncoding = $null
        }
        if ($null -ne $Environment) {
            foreach ($key in @($Environment.Keys)) {
                $savedEnvironment[[string]$key] = [Environment]::GetEnvironmentVariable([string]$key)
                [Environment]::SetEnvironmentVariable([string]$key, [string]$Environment[$key])
            }
        }
        if (-not [string]::IsNullOrEmpty($WorkingDirectory)) {
            Push-Location -LiteralPath $WorkingDirectory
            $pushed = $true
        }
        $global:LASTEXITCODE = 0
        $output = & $command.Source @ArgumentList 2>&1
        $exitCode = $global:LASTEXITCODE
        foreach ($record in @($output)) {
            if ($record -is [System.Management.Automation.ErrorRecord]) {
                $stderr.Add($record.ToString())
            } elseif ($null -ne $record) {
                $stdout.Add([string]$record)
            }
        }
    } finally {
        if ($pushed) {
            Pop-Location
        }
        foreach ($key in @($savedEnvironment.Keys)) {
            [Environment]::SetEnvironmentVariable([string]$key, $savedEnvironment[$key])
        }
        if ($null -ne $savedEncoding) {
            try {
                [Console]::OutputEncoding = $savedEncoding
            } catch {
                Write-Verbose 'Could not restore the console output encoding.'
            }
        }
    }
    if ($null -eq $exitCode) {
        $exitCode = 0
    }
    [pscustomobject]@{
        ExitCode = [int]$exitCode
        StdOut   = $stdout.ToArray()
        StdErr   = $stderr.ToArray()
    }
}

function Resolve-PbiFullPath {
    # Private: absolute file-system path for .NET APIs (which do not know PowerShell's current location).
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-PbiTextFile {
    <#
    .SYNOPSIS
        Reads a text file as a string (BOM detected and removed).
    .PARAMETER Path
        File path (relative paths are resolved against the current PowerShell location).
    .EXAMPLE
        $query = Read-PbiTextFile -Path 'src/Sales/Sales.SemanticModel/DAXQueries/Measures.ALL.Tests.dax'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )
    $fullPath = Resolve-PbiFullPath -Path $Path
    $text = [System.IO.File]::ReadAllText($fullPath)
    return $text.TrimStart([char]0xFEFF)
}

function Write-PbiTextFile {
    <#
    .SYNOPSIS
        Writes text as UTF-8 without BOM, creating the parent folder when needed.
    .PARAMETER Path
        Target file path.
    .PARAMETER Content
        Text to write.
    .EXAMPLE
        Write-PbiTextFile -Path '.evidence/summary.md' -Content $markdown
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Content
    )
    $fullPath = Resolve-PbiFullPath -Path $Path
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [string]::IsNullOrEmpty($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    [System.IO.File]::WriteAllText($fullPath, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Read-PbiJsonFile {
    <#
    .SYNOPSIS
        Reads and parses a JSON file with a clear error message when it is missing or invalid.
    .DESCRIPTION
        Top-level JSON arrays are returned unrolled (wrap the call in @() when you expect an array).
    .PARAMETER Path
        File path.
    .PARAMETER Description
        Human description used in error messages.
    .EXAMPLE
        $gates = Read-PbiJsonFile -Path 'config/quality/gates.json' -Description 'Quality gate configuration'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [string] $Description = 'JSON file'
    )
    $fullPath = Resolve-PbiFullPath -Path $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Description not found: $fullPath"
    }
    $text = Read-PbiTextFile -Path $fullPath
    try {
        $parsed = ConvertFrom-Json -InputObject $text -Depth 100
    } catch {
        throw "$Description is not valid JSON ($fullPath): $($_.Exception.Message)"
    }
    if ($null -eq $parsed) {
        return
    }
    return $parsed
}

function Read-PbiJsonSafe {
    # Private: parse a JSON file without throwing. Returns @{ Exists; Ok; Value; Error }.
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [switch] $AllowComments
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{ Exists = $false; Ok = $false; Value = $null; Error = 'file not found' }
    }
    try {
        $text = Read-PbiTextFile -Path $Path
        if ($AllowComments) {
            $text = Remove-PbiJsonComment -Text $text
        }
        if ([string]::IsNullOrWhiteSpace($text)) {
            return @{ Exists = $true; Ok = $false; Value = $null; Error = 'file is empty' }
        }
        $value = ConvertFrom-Json -InputObject $text -Depth 100 -NoEnumerate
        return @{ Exists = $true; Ok = $true; Value = $value; Error = $null }
    } catch {
        return @{ Exists = $true; Ok = $false; Value = $null; Error = $_.Exception.Message }
    }
}

function Remove-PbiJsonComment {
    # Private: strips // and /* */ comments (outside strings) and trailing commas from JSONC text.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )
    $builder = [System.Text.StringBuilder]::new($Text.Length)
    $inString = $false
    $index = 0
    while ($index -lt $Text.Length) {
        $character = $Text[$index]
        $next = [char]0
        if ($index + 1 -lt $Text.Length) {
            $next = $Text[$index + 1]
        }
        if ($inString) {
            $null = $builder.Append($character)
            if ($character -eq '\' -and $index + 1 -lt $Text.Length) {
                $null = $builder.Append($next)
                $index += 2
                continue
            }
            if ($character -eq '"') {
                $inString = $false
            }
            $index++
            continue
        }
        if ($character -eq '"') {
            $inString = $true
            $null = $builder.Append($character)
            $index++
            continue
        }
        if ($character -eq '/' -and $next -eq '/') {
            while ($index -lt $Text.Length -and $Text[$index] -ne "`n") {
                $index++
            }
            continue
        }
        if ($character -eq '/' -and $next -eq '*') {
            $end = $Text.IndexOf('*/', $index + 2)
            if ($end -lt 0) {
                break
            }
            $index = $end + 2
            continue
        }
        $null = $builder.Append($character)
        $index++
    }
    return [regex]::Replace($builder.ToString(), ',(\s*[}\]])', '$1')
}

function Get-PbiRelativePath {
    <#
    .SYNOPSIS
        Returns a repository-relative path with forward slashes.
    .PARAMETER Path
        Absolute or relative path.
    .PARAMETER RepoRoot
        Repository root.
    .EXAMPLE
        Get-PbiRelativePath -Path $project.Path -RepoRoot $root   # src/SalesStarter
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $RepoRoot
    )
    $fullPath = Resolve-PbiFullPath -Path $Path
    $fullRoot = Resolve-PbiFullPath -Path $RepoRoot
    return [System.IO.Path]::GetRelativePath($fullRoot, $fullPath).Replace('\', '/')
}

function ConvertTo-PbiVersion {
    <#
    .SYNOPSIS
        Extracts a [version] from tool output such as 'v22.11.0', 'git version 2.47.1.windows.1' or 'gh version 2.90.0 (2026-01-01)'.
    .PARAMETER Text
        Text that contains a version number.
    .EXAMPLE
        ConvertTo-PbiVersion -Text 'git version 2.47.1.windows.1'   # 2.47.1
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    $match = [regex]::Match($Text, '(\d+)(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $match.Success) {
        return $null
    }
    $major = [int]$match.Groups[1].Value
    $minor = 0
    $build = 0
    if ($match.Groups[2].Success) {
        $minor = [int]$match.Groups[2].Value
    }
    if ($match.Groups[3].Success) {
        $build = [int]$match.Groups[3].Value
    }
    return [version]::new($major, $minor, $build)
}

function Get-PbiContentHash {
    <#
    .SYNOPSIS
        SHA-256 (lowercase hex) of a file; text files are hashed with CRLF normalised to LF.
    .DESCRIPTION
        Normalising line endings keeps hashes stable when Git converts line endings on checkout (core.autocrlf).
        A file is treated as text when it contains no NUL byte.
    .PARAMETER Path
        File to hash.
    .EXAMPLE
        Get-PbiContentHash -Path '.github/skills/brainstorming/SKILL.md'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-PbiFullPath -Path $Path))
    if ([Array]::IndexOf($bytes, [byte]0) -lt 0) {
        $latin1 = [System.Text.Encoding]::Latin1
        $bytes = $latin1.GetBytes($latin1.GetString($bytes).Replace("`r`n", "`n"))
    }
    $hash = [System.Security.Cryptography.SHA256]::HashData([byte[]]$bytes)
    return [System.Convert]::ToHexString($hash).ToLowerInvariant()
}

function Test-PbiObjectLike {
    # Private: $true for dictionaries and PSCustomObjects.
    param(
        [AllowNull()]
        [object] $Value
    )
    return (($Value -is [System.Collections.IDictionary]) -or ($Value -is [System.Management.Automation.PSCustomObject]))
}

function Get-PbiPropertyEntry {
    # Private: enumerates { Name; Value } pairs of a dictionary or PSCustomObject without unrolling array values.
    param(
        [AllowNull()]
        [object] $InputObject
    )
    if ($null -eq $InputObject) {
        return
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in @($InputObject.Keys)) {
            [pscustomobject]@{ Name = [string]$key; Value = $InputObject[$key] }
        }
        return
    }
    foreach ($property in $InputObject.PSObject.Properties) {
        [pscustomobject]@{ Name = $property.Name; Value = $property.Value }
    }
}

function Test-PbiNumeric {
    # Private: $true for numeric values (integers, floating point, decimal, BigInteger).
    param(
        [AllowNull()]
        [object] $Value
    )
    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [System.Numerics.BigInteger]) {
        return $true
    }
    $code = [int][System.Type]::GetTypeCode($Value.GetType())
    return ($code -ge 5 -and $code -le 15)
}

function Test-PbiTruthy {
    # Private: $true only for boolean true, the strings 'true'/'1' (any case) or the number 1.
    param(
        [AllowNull()]
        [object] $Value
    )
    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [bool]) {
        return $Value
    }
    if ($Value -is [string]) {
        $text = $Value.Trim()
        return ($text -eq 'true' -or $text -eq '1')
    }
    if (Test-PbiNumeric -Value $Value) {
        return ([double]$Value -eq 1)
    }
    return $false
}

function Assert-PbiWindows {
    # Private: throws a clear error on non-Windows hosts.
    param(
        [Parameter(Mandatory)]
        [string] $Feature
    )
    if (-not $IsWindows) {
        throw "$Feature requires Windows (Power BI Desktop and Tabular Editor 2 are Windows-only). Run this step on a Windows machine."
    }
}

#endregion Shared helpers

#region Repo + config helpers

function Get-PbiRepoRoot {
    <#
    .SYNOPSIS
        Finds the repository root (the folder that contains .git or AGENTS.md).
    .DESCRIPTION
        Walks up from -Path (default: the current location) until a folder that contains '.git' (folder or file) or
        'AGENTS.md' is found. Throws when none is found.
    .PARAMETER Path
        Start folder or file. Entry scripts pass $PSScriptRoot so they work from any current directory.
    .EXAMPLE
        $root = Get-PbiRepoRoot -Path $PSScriptRoot
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [string] $Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = (Get-Location -PSProvider FileSystem).ProviderPath
    }
    $current = Resolve-PbiFullPath -Path $Path
    if (Test-Path -LiteralPath $current -PathType Leaf) {
        $current = Split-Path -Path $current -Parent
    }
    $start = $current
    while (-not [string]::IsNullOrEmpty($current)) {
        $hasGit = Test-Path -LiteralPath (Join-Path $current '.git')
        $hasAgents = Test-Path -LiteralPath (Join-Path $current 'AGENTS.md') -PathType Leaf
        if ($hasGit -or $hasAgents) {
            return $current
        }
        $parent = Split-Path -Path $current -Parent
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) {
            break
        }
        $current = $parent
    }
    throw "Could not find the repository root above '$start' (looked for a .git folder or AGENTS.md). Run the command inside the power-bi-superpower repository or pass -RepoRoot."
}

function Get-PbiProperty {
    <#
    .SYNOPSIS
        Reads a property from a PSCustomObject or dictionary without failing under Set-StrictMode.
    .DESCRIPTION
        Returns the property value, or -Default when the object is $null, the property does not exist or its value is
        $null. Nothing is returned when the result is $null, so @(Get-PbiProperty $o 'list') is always a clean array.
        Collections are returned unrolled (pipeline semantics): wrap the call in @() when you expect an array.
    .PARAMETER InputObject
        Object to read from (PSCustomObject, hashtable/ordered dictionary or any .NET object).
    .PARAMETER Name
        Property or key name (case-insensitive).
    .PARAMETER Default
        Value returned when the property is missing or $null.
    .EXAMPLE
        $displayName = Get-PbiProperty $config.workspace 'displayName'
    .EXAMPLE
        $assignments = @(Get-PbiProperty -InputObject $workspace -Name 'roleAssignments')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string] $Name,

        [Parameter(Position = 2)]
        [AllowNull()]
        [object] $Default = $null
    )
    $value = $null
    if ($null -ne $InputObject) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            foreach ($key in @($InputObject.Keys)) {
                if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $value = $InputObject[$key]
                    break
                }
            }
        } else {
            $property = $InputObject.PSObject.Properties[$Name]
            if ($null -ne $property) {
                $value = $property.Value
            }
        }
    }
    if ($null -eq $value) {
        if ($null -eq $Default) {
            return
        }
        return $Default
    }
    return $value
}

function Expand-PbiPlaceholder {
    <#
    .SYNOPSIS
        Replaces ${env:NAME} placeholders in a configuration object with environment variable values.
    .DESCRIPTION
        Recursively walks strings, arrays, dictionaries and PSCustomObjects and returns a NEW object (the input is not
        modified). Unresolved placeholders are collected; when any remain outside an object marked "optional": true,
        ONE error listing all missing variables is thrown.
        An object marked "optional": true that contains a placeholder which is unset or resolves to an empty string is
        dropped from its parent array (or omitted from its parent object) with a warning.
        A variable declared with an empty value in .env.local (NAME=) resolves to an empty string.
    .PARAMETER Value
        The value to expand. Arrays are returned as one array object.
    .EXAMPLE
        $config = Expand-PbiPlaceholder -Value (Get-Content config/environments/dev.json -Raw | ConvertFrom-Json)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [object] $Value
    )
    $state = @{
        Missing = [System.Collections.Generic.List[string]]::new()
        Empty   = [System.Collections.Generic.List[string]]::new()
    }
    $result = Expand-PbiPlaceholderNode -Node $Value -State $state -Location '$'
    if ($state.Missing.Count -gt 0) {
        $names = @($state.Missing | Sort-Object -Unique)
        throw ('Missing environment variable(s): {0}. Set them in your shell or in .env.local at the repository root (copy .env.example), or mark the containing entry with "optional": true.' -f ($names -join ', '))
    }
    if ($result.Dropped) {
        return
    }
    if ($result.Value -is [array]) {
        return , $result.Value
    }
    return $result.Value
}

function Expand-PbiPlaceholderNode {
    # Private: recursive worker for Expand-PbiPlaceholder. Returns @{ Value; Dropped }.
    param(
        [AllowNull()]
        [object] $Node,

        [Parameter(Mandatory)]
        [hashtable] $State,

        [Parameter(Mandatory)]
        [string] $Location
    )
    if ($null -eq $Node) {
        return @{ Value = $null; Dropped = $false }
    }
    if ($Node -is [string]) {
        $found = [regex]::Matches($Node, $script:PbiPlaceholderPattern)
        if ($found.Count -eq 0) {
            return @{ Value = $Node; Dropped = $false }
        }
        $builder = [System.Text.StringBuilder]::new()
        $position = 0
        foreach ($match in $found) {
            $null = $builder.Append($Node.Substring($position, $match.Index - $position))
            $variableName = $match.Groups[1].Value
            $variableValue = [Environment]::GetEnvironmentVariable($variableName)
            if ($null -eq $variableValue -and $script:PbiEmptyVariables.Contains($variableName)) {
                $variableValue = ''
            }
            if ($null -eq $variableValue) {
                $State.Missing.Add($variableName)
                $null = $builder.Append($match.Value)
            } else {
                if ($variableValue.Length -eq 0) {
                    $State.Empty.Add($variableName)
                }
                $null = $builder.Append($variableValue)
            }
            $position = $match.Index + $match.Length
        }
        $null = $builder.Append($Node.Substring($position))
        return @{ Value = $builder.ToString(); Dropped = $false }
    }
    $isDictionary = $Node -is [System.Collections.IDictionary]
    if ($isDictionary -or ($Node -is [System.Management.Automation.PSCustomObject])) {
        $local = @{
            Missing = [System.Collections.Generic.List[string]]::new()
            Empty   = [System.Collections.Generic.List[string]]::new()
        }
        if ($Node -is [System.Collections.Specialized.OrderedDictionary] -or -not $isDictionary) {
            $copy = [ordered]@{}
        } else {
            $copy = @{}
        }
        foreach ($entry in @(Get-PbiPropertyEntry -InputObject $Node)) {
            $child = Expand-PbiPlaceholderNode -Node $entry.Value -State $local -Location ($Location + '.' + $entry.Name)
            if (-not $child.Dropped) {
                $copy[$entry.Name] = $child.Value
            }
        }
        $isOptional = Test-PbiTruthy -Value (Get-PbiProperty -InputObject $Node -Name 'optional')
        if ($isOptional -and ($local.Missing.Count -gt 0 -or $local.Empty.Count -gt 0)) {
            $names = @(@($local.Missing) + @($local.Empty) | Sort-Object -Unique) -join ', '
            Write-PbiWarning "Optional entry $Location was skipped because environment variable(s) $names are not set."
            return @{ Value = $null; Dropped = $true }
        }
        foreach ($name in $local.Missing) {
            $State.Missing.Add($name)
        }
        foreach ($name in $local.Empty) {
            $State.Empty.Add($name)
        }
        if ($isDictionary) {
            return @{ Value = $copy; Dropped = $false }
        }
        return @{ Value = [pscustomobject]$copy; Dropped = $false }
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        $items = [System.Collections.Generic.List[object]]::new()
        $index = 0
        foreach ($element in $Node) {
            $child = Expand-PbiPlaceholderNode -Node $element -State $State -Location ('{0}[{1}]' -f $Location, $index)
            if (-not $child.Dropped) {
                $items.Add($child.Value)
            }
            $index++
        }
        return @{ Value = $items.ToArray(); Dropped = $false }
    }
    return @{ Value = $Node; Dropped = $false }
}

function Import-PbiDotEnv {
    # Private: loads KEY=VALUE lines from .env.local into the process environment (values are never logged).
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    $loaded = 0
    $lineNumber = 0
    foreach ($rawLine in [System.IO.File]::ReadAllLines((Resolve-PbiFullPath -Path $Path))) {
        $lineNumber++
        $line = $rawLine.Trim().TrimStart([char]0xFEFF)
        if ($line.Length -eq 0 -or $line.StartsWith('#')) {
            continue
        }
        if ($line.StartsWith('export ')) {
            $line = $line.Substring(7).TrimStart()
        }
        $separator = $line.IndexOf('=')
        if ($separator -lt 1) {
            Write-PbiWarning "Ignoring line $lineNumber of .env.local: expected KEY=VALUE."
            continue
        }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            Write-PbiWarning "Ignoring line $lineNumber of .env.local: '$key' is not a valid variable name."
            continue
        }
        if ($value.Length -ge 2) {
            $first = $value[0]
            $last = $value[$value.Length - 1]
            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        if ($value.Length -eq 0) {
            $null = $script:PbiEmptyVariables.Add($key)
            [Environment]::SetEnvironmentVariable($key, $null)
        } else {
            $null = $script:PbiEmptyVariables.Remove($key)
            [Environment]::SetEnvironmentVariable($key, $value)
        }
        $loaded++
    }
    Write-Verbose "Loaded $loaded variable(s) from .env.local (values are not shown)."
}

function Merge-PbiObject {
    # Private: deep merge; values from -Override win, nested objects are merged, arrays are replaced.
    param(
        [AllowNull()]
        [object] $Base,

        [AllowNull()]
        [object] $Override
    )
    if (-not ((Test-PbiObjectLike -Value $Base) -and (Test-PbiObjectLike -Value $Override))) {
        return , $Override
    }
    $merged = [ordered]@{}
    foreach ($entry in @(Get-PbiPropertyEntry -InputObject $Base)) {
        $merged[$entry.Name] = $entry.Value
    }
    foreach ($entry in @(Get-PbiPropertyEntry -InputObject $Override)) {
        if ($merged.Contains($entry.Name)) {
            $merged[$entry.Name] = Merge-PbiObject -Base $merged[$entry.Name] -Override $entry.Value
        } else {
            $merged[$entry.Name] = $entry.Value
        }
    }
    return [pscustomobject]$merged
}

function Test-PbiEnvironmentConfigShape {
    # Private: returns a list of problems with an expanded environment configuration.
    param(
        [Parameter(Mandatory)]
        [object] $Config,

        [Parameter(Mandatory)]
        [string] $EnvironmentName
    )
    $problems = [System.Collections.Generic.List[string]]::new()
    $name = [string](Get-PbiProperty $Config 'name' '')
    if ([string]::IsNullOrWhiteSpace($name)) {
        $problems.Add("'name' is required (expected '$EnvironmentName').")
    } elseif ($name -ne $EnvironmentName) {
        $problems.Add("'name' is '$name' but this file configures '$EnvironmentName'.")
    }
    $workspace = Get-PbiProperty $Config 'workspace'
    if ($null -eq $workspace) {
        $problems.Add("'workspace' is required.")
    } else {
        if ([string]::IsNullOrWhiteSpace([string](Get-PbiProperty $workspace 'displayName' ''))) {
            $problems.Add("'workspace.displayName' is required.")
        }
        $assignments = @(Get-PbiProperty $workspace 'roleAssignments')
        for ($index = 0; $index -lt $assignments.Count; $index++) {
            $assignment = $assignments[$index]
            if ([string]::IsNullOrWhiteSpace([string](Get-PbiProperty $assignment 'principalId' ''))) {
                $problems.Add("'workspace.roleAssignments[$index].principalId' is empty. Set the environment variable it references in .env.local, or mark the entry ""optional"": true.")
            }
            if ([string]::IsNullOrWhiteSpace([string](Get-PbiProperty $assignment 'role' ''))) {
                $problems.Add("'workspace.roleAssignments[$index].role' is required (Admin, Member, Contributor or Viewer).")
            }
        }
    }
    $projects = @(Get-PbiProperty $Config 'projects')
    for ($index = 0; $index -lt $projects.Count; $index++) {
        $project = $projects[$index]
        if ([string]::IsNullOrWhiteSpace([string](Get-PbiProperty $project 'path' ''))) {
            $problems.Add("'projects[$index].path' is required.")
        }
        $semanticModel = Get-PbiProperty $project 'semanticModel'
        if ($null -eq $semanticModel) {
            $problems.Add("'projects[$index].semanticModel' is required.")
        } else {
            if ([string]::IsNullOrWhiteSpace([string](Get-PbiProperty $semanticModel 'folder' ''))) {
                $problems.Add("'projects[$index].semanticModel.folder' is required.")
            }
            if ([string]::IsNullOrWhiteSpace([string](Get-PbiProperty $semanticModel 'displayName' ''))) {
                $problems.Add("'projects[$index].semanticModel.displayName' is required.")
            }
        }
        $reports = @(Get-PbiProperty $project 'reports')
        for ($reportIndex = 0; $reportIndex -lt $reports.Count; $reportIndex++) {
            $report = $reports[$reportIndex]
            if ([string]::IsNullOrWhiteSpace([string](Get-PbiProperty $report 'folder' ''))) {
                $problems.Add("'projects[$index].reports[$reportIndex].folder' is required.")
            }
            if ([string]::IsNullOrWhiteSpace([string](Get-PbiProperty $report 'displayName' ''))) {
                $problems.Add("'projects[$index].reports[$reportIndex].displayName' is required.")
            }
        }
    }
    return $problems.ToArray()
}

function Get-PbiEnvironmentConfig {
    <#
    .SYNOPSIS
        Loads, merges, expands and validates config/environments/<env>.json.
    .DESCRIPTION
        1. Loads .env.local (KEY=VALUE lines, # comments) from the repository root into the PROCESS environment
           (values are never logged; a value in .env.local overrides the same variable in the shell).
        2. Reads config/environments/<env>.json and deep-merges config/environments/<env>.local.json when present
           (local wins; arrays are replaced).
        3. Expands ${env:NAME} placeholders (Expand-PbiPlaceholder).
        4. Validates name, workspace.displayName, role assignments, projects[].path and projects[].semanticModel.
    .PARAMETER Environment
        DEV, TEST or PROD.
    .PARAMETER RepoRoot
        Repository root (default: discovered from the current location).
    .EXAMPLE
        $config = Get-PbiEnvironmentConfig -Environment DEV -RepoRoot $root
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DEV', 'TEST', 'PROD')]
        [string] $Environment,

        [string] $RepoRoot
    )
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-PbiRepoRoot
    }
    $environmentName = $Environment.ToUpperInvariant()
    $baseName = $environmentName.ToLowerInvariant()
    $configDirectory = Join-Path $RepoRoot 'config' 'environments'
    $basePath = Join-Path $configDirectory "$baseName.json"
    $localPath = Join-Path $configDirectory "$baseName.local.json"
    if (-not (Test-Path -LiteralPath $basePath -PathType Leaf)) {
        throw "Environment configuration not found: config/environments/$baseName.json. Create it (see config/environments/README.md) before running scripts for $environmentName."
    }
    Import-PbiDotEnv -Path (Join-Path $RepoRoot '.env.local')
    $config = Read-PbiJsonFile -Path $basePath -Description "Environment configuration config/environments/$baseName.json"
    if (Test-Path -LiteralPath $localPath -PathType Leaf) {
        Write-Verbose "Merging local overrides from config/environments/$baseName.local.json."
        $override = Read-PbiJsonFile -Path $localPath -Description "Local overrides config/environments/$baseName.local.json"
        $config = Merge-PbiObject -Base $config -Override $override
    }
    $expanded = Expand-PbiPlaceholder -Value $config
    $problems = @(Test-PbiEnvironmentConfigShape -Config $expanded -EnvironmentName $environmentName)
    if ($problems.Count -gt 0) {
        $list = ($problems | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
        throw ("Invalid environment configuration config/environments/{0}.json:{1}{2}" -f $baseName, [Environment]::NewLine, $list)
    }
    return $expanded
}

function Get-PbiGateConfig {
    <#
    .SYNOPSIS
        Reads config/quality/gates.json.
    .PARAMETER RepoRoot
        Repository root (default: discovered from the current location).
    .EXAMPLE
        $gates = Get-PbiGateConfig -RepoRoot $root
    #>
    [CmdletBinding()]
    param(
        [string] $RepoRoot
    )
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-PbiRepoRoot
    }
    return Read-PbiJsonFile -Path (Join-Path $RepoRoot 'config' 'quality' 'gates.json') -Description 'Quality gate configuration config/quality/gates.json'
}

function Get-PbiToolVersions {
    <#
    .SYNOPSIS
        Reads tools/versions.json (pinned tool, module, plugin and binary versions).
    .PARAMETER RepoRoot
        Repository root (default: discovered from the current location).
    .EXAMPLE
        $versions = Get-PbiToolVersions -RepoRoot $root
    #>
    [CmdletBinding()]
    param(
        [string] $RepoRoot
    )
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-PbiRepoRoot
    }
    return Read-PbiJsonFile -Path (Join-Path $RepoRoot 'tools' 'versions.json') -Description 'Tool versions tools/versions.json'
}

function Get-PbiProject {
    <#
    .SYNOPSIS
        Lists the PBIP projects under src/ (folders that contain *.SemanticModel and/or *.Report folders).
    .DESCRIPTION
        Returns one object per project: Name, Path, RelativePath, SemanticModelPath (preferring <Name>.SemanticModel),
        ReportPaths (array), PbipPath ($null when absent) and BlueprintPath (report-blueprint.json or $null).
    .PARAMETER RepoRoot
        Repository root (default: discovered from the current location).
    .PARAMETER Path
        Restrict to these project folders (absolute or repository-relative). A folder without *.SemanticModel or
        *.Report is an error.
    .EXAMPLE
        Get-PbiProject -RepoRoot $root | Select-Object Name, RelativePath
    .EXAMPLE
        $project = Get-PbiProject -RepoRoot $root -Path 'src/SalesStarter'
    #>
    [CmdletBinding()]
    param(
        [string] $RepoRoot,

        [Parameter(Position = 0)]
        [string[]] $Path
    )
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-PbiRepoRoot
    }
    $requested = @(Split-PbiListArgument $Path)
    $folders = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
    if ($requested.Count -gt 0) {
        foreach ($item in $requested) {
            $candidate = $item
            if (-not [System.IO.Path]::IsPathRooted($candidate)) {
                $fromRoot = Join-Path $RepoRoot $candidate
                if (Test-Path -LiteralPath $fromRoot -PathType Container) {
                    $candidate = $fromRoot
                }
            }
            $fullPath = Resolve-PbiFullPath -Path $candidate
            if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
                throw "Project folder not found: '$item'. Pass a folder under src/ (for example src/SalesStarter)."
            }
            $folders.Add([System.IO.DirectoryInfo]::new($fullPath))
        }
    } else {
        $sourceRoot = Join-Path $RepoRoot 'src'
        if (Test-Path -LiteralPath $sourceRoot -PathType Container) {
            foreach ($directory in @(Get-ChildItem -LiteralPath $sourceRoot -Directory | Sort-Object -Property Name)) {
                $folders.Add($directory)
            }
        }
    }
    foreach ($folder in $folders) {
        $semanticModels = @(Get-ChildItem -LiteralPath $folder.FullName -Directory -Filter '*.SemanticModel' | Sort-Object -Property Name)
        $reports = @(Get-ChildItem -LiteralPath $folder.FullName -Directory -Filter '*.Report' | Sort-Object -Property Name)
        if ($semanticModels.Count -eq 0 -and $reports.Count -eq 0) {
            if ($requested.Count -gt 0) {
                throw "'$($folder.FullName)' contains no *.SemanticModel or *.Report folder. Create a project with scripts/build/New-PbipProject.ps1."
            }
            continue
        }
        $semanticModel = $null
        $preferred = @($semanticModels | Where-Object { $_.Name -eq ($folder.Name + '.SemanticModel') })
        if ($preferred.Count -gt 0) {
            $semanticModel = $preferred[0]
        } elseif ($semanticModels.Count -gt 0) {
            $semanticModel = $semanticModels[0]
        }
        if ($semanticModels.Count -gt 1) {
            Write-PbiWarning "Project '$($folder.Name)' contains $($semanticModels.Count) semantic models; using '$($semanticModel.Name)'."
        }
        $pbipFiles = @(Get-ChildItem -LiteralPath $folder.FullName -File -Filter '*.pbip' | Sort-Object -Property Name)
        $blueprint = Join-Path $folder.FullName 'report-blueprint.json'
        $semanticModelPath = $null
        if ($null -ne $semanticModel) {
            $semanticModelPath = $semanticModel.FullName
        }
        $pbipPath = $null
        if ($pbipFiles.Count -gt 0) {
            $pbipPath = $pbipFiles[0].FullName
        }
        $blueprintPath = $null
        if (Test-Path -LiteralPath $blueprint -PathType Leaf) {
            $blueprintPath = $blueprint
        }
        [pscustomobject]@{
            Name              = $folder.Name
            Path              = $folder.FullName
            RelativePath      = Get-PbiRelativePath -Path $folder.FullName -RepoRoot $RepoRoot
            SemanticModelPath = $semanticModelPath
            ReportPaths       = @($reports | ForEach-Object { $_.FullName })
            PbipPath          = $pbipPath
            BlueprintPath     = $blueprintPath
        }
    }
}

#endregion Repo + config helpers

#region Git context and guards

function Invoke-PbiGit {
    # Private: runs git -C <RepoRoot> <Arguments>; returns the Invoke-PbiNativeCommand result.
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,

        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [hashtable] $Environment
    )
    $allArguments = @('-C', $RepoRoot) + $Arguments
    return Invoke-PbiNativeCommand -FilePath 'git' -ArgumentList $allArguments -Environment $Environment
}

function Get-PbiGitContext {
    <#
    .SYNOPSIS
        Returns branch, commit and cleanliness information for the repository.
    .DESCRIPTION
        Returns { Branch, Commit, ShortCommit (7 characters), IsDirty (uncommitted or untracked changes), IsOnMain,
        IsMergedToOriginMain (HEAD is an ancestor of origin/main after a best-effort 'git fetch origin main'),
        RemoteUrl (credentials stripped) }. Never throws when git, commits or the remote are missing: the fields are
        $null/$false instead.
    .PARAMETER RepoRoot
        Repository root (default: discovered from the current location).
    .PARAMETER SkipFetch
        Do not run 'git fetch origin main' (used when only commit/branch are needed, for example for evidence).
    .EXAMPLE
        $git = Get-PbiGitContext -RepoRoot $root
        if ($git.IsDirty) { 'Commit first' }
    #>
    [CmdletBinding()]
    param(
        [string] $RepoRoot,

        [switch] $SkipFetch
    )
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-PbiRepoRoot
    }
    $context = [ordered]@{
        Branch               = $null
        Commit               = $null
        ShortCommit          = $null
        IsDirty              = $false
        IsOnMain             = $false
        IsMergedToOriginMain = $false
        RemoteUrl            = $null
    }
    if ($null -eq (Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-PbiWarning 'git was not found on PATH; repository information is unavailable.'
        return [pscustomobject]$context
    }
    $inside = Invoke-PbiGit -RepoRoot $RepoRoot -Arguments @('rev-parse', '--is-inside-work-tree')
    if ($inside.ExitCode -ne 0) {
        Write-Verbose 'Not inside a git working tree.'
        return [pscustomobject]$context
    }
    $branch = Invoke-PbiGit -RepoRoot $RepoRoot -Arguments @('symbolic-ref', '--short', '-q', 'HEAD')
    if ($branch.ExitCode -eq 0 -and $branch.StdOut.Count -gt 0) {
        $context.Branch = $branch.StdOut[0].Trim()
    } else {
        $context.Branch = 'HEAD'
    }
    $commit = Invoke-PbiGit -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '-q', 'HEAD')
    if ($commit.ExitCode -eq 0 -and $commit.StdOut.Count -gt 0) {
        $context.Commit = $commit.StdOut[0].Trim()
        $context.ShortCommit = $context.Commit.Substring(0, [Math]::Min(7, $context.Commit.Length))
    }
    $status = Invoke-PbiGit -RepoRoot $RepoRoot -Arguments @('status', '--porcelain')
    $changedLines = @($status.StdOut | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $context.IsDirty = ($status.ExitCode -ne 0) -or ($changedLines.Count -gt 0)
    $context.IsOnMain = ($context.Branch -ceq 'main')
    $remote = Invoke-PbiGit -RepoRoot $RepoRoot -Arguments @('remote', 'get-url', 'origin')
    if ($remote.ExitCode -eq 0 -and $remote.StdOut.Count -gt 0) {
        $context.RemoteUrl = [regex]::Replace($remote.StdOut[0].Trim(), '(?<=://)[^/@\s]+@', '')
        if (-not $SkipFetch) {
            $fetch = Invoke-PbiGit -RepoRoot $RepoRoot -Arguments @('fetch', 'origin', 'main', '--quiet') -Environment @{ GIT_TERMINAL_PROMPT = '0' }
            if ($fetch.ExitCode -ne 0) {
                Write-Verbose 'git fetch origin main failed (offline?); using the local origin/main ref.'
            }
        }
        if ($null -ne $context.Commit) {
            $ancestor = Invoke-PbiGit -RepoRoot $RepoRoot -Arguments @('merge-base', '--is-ancestor', 'HEAD', 'origin/main')
            $context.IsMergedToOriginMain = ($ancestor.ExitCode -eq 0)
        }
    }
    return [pscustomobject]$context
}

function Get-PbiNonInteractiveReason {
    # Private: returns why the current session must be treated as an agent/non-interactive session, or $null.
    if ($env:PBI_AGENT_SESSION -eq '1') {
        return 'PBI_AGENT_SESSION=1 marks an agent session'
    }
    if (-not [string]::IsNullOrEmpty($env:COPILOT_AGENT_PROMPT)) {
        return 'COPILOT_AGENT_PROMPT is set (Copilot agent session)'
    }
    if (-not [Environment]::UserInteractive) {
        return 'the process is not user-interactive'
    }
    if ([Console]::IsInputRedirected) {
        return 'standard input is redirected'
    }
    foreach ($argument in [Environment]::GetCommandLineArgs()) {
        if ($argument -match '^-noni\w*$') {
            return 'PowerShell was started with -NonInteractive'
        }
    }
    return $null
}

function Get-PbiTestEvidenceProblem {
    # Private: $null when passing TEST deployment evidence exists for the current commit, otherwise the problem text.
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,

        [Parameter(Mandatory)]
        [object] $GitContext
    )
    $shortCommit = [string](Get-PbiProperty $GitContext 'ShortCommit' '')
    $commit = [string](Get-PbiProperty $GitContext 'Commit' '')
    if ([string]::IsNullOrEmpty($shortCommit)) {
        return 'the repository has no commit to match evidence against.'
    }
    $evidenceDirectory = Join-Path $RepoRoot '.evidence'
    $candidates = @()
    if (Test-Path -LiteralPath $evidenceDirectory -PathType Container) {
        $candidates = @(Get-ChildItem -LiteralPath $evidenceDirectory -File -Filter "*-deployment-TEST-$shortCommit.json" | Sort-Object -Property Name -Descending)
    }
    foreach ($file in $candidates) {
        $parsed = Read-PbiJsonSafe -Path $file.FullName
        if (-not $parsed.Ok) {
            continue
        }
        $evidence = $parsed.Value
        $data = Get-PbiProperty $evidence 'data'
        $evidenceCommit = [string](Get-PbiProperty (Get-PbiProperty $evidence 'repository') 'commit' '')
        if (-not [string]::IsNullOrEmpty($commit) -and -not [string]::IsNullOrEmpty($evidenceCommit) -and $evidenceCommit -ne $commit) {
            continue
        }
        if (Test-PbiTruthy -Value (Get-PbiProperty $data 'whatIf')) {
            continue
        }
        if (Test-PbiTruthy -Value (Get-PbiProperty $data 'skipTests')) {
            continue
        }
        if ([string](Get-PbiProperty $data 'outcome' '') -ne 'Passed') {
            continue
        }
        return $null
    }
    return "no passing TEST deployment evidence for commit $shortCommit (.evidence/*-deployment-TEST-$shortCommit.json with outcome Passed, not -WhatIf, tests not skipped). Deploy and test this exact commit in TEST first."
}

function Assert-PbiDeploymentGuard {
    <#
    .SYNOPSIS
        Enforces the deployment guards of an environment configuration (config.guards).
    .DESCRIPTION
        Evaluates every guard and throws ONE error that lists all failures:
          allowedBranches          the branch must match one of the wildcard patterns (for example '*', 'main', 'release/*')
          requireCleanWorkingTree  no uncommitted or untracked changes
          requireMergedToMain      HEAD must be contained in origin/main
          requireTestEvidence      .evidence/*-deployment-TEST-<ShortCommit>.json with outcome Passed must exist
          requireReleaseApproval   -ReleaseIssue must be an OPEN issue with the label gate:release-approved
          humanOnly                refuses agent/non-interactive sessions (PBI_AGENT_SESSION=1, COPILOT_AGENT_PROMPT,
                                   redirected input, -NonInteractive) and then asks the person to type the workspace
                                   name exactly.
    .PARAMETER Config
        Environment configuration from Get-PbiEnvironmentConfig.
    .PARAMETER GitContext
        Result of Get-PbiGitContext.
    .PARAMETER ReleaseIssue
        Release issue number (required when requireReleaseApproval is true).
    .PARAMETER RepoRoot
        Repository root (default: discovered from the current location).
    .EXAMPLE
        Assert-PbiDeploymentGuard -Config $config -GitContext $git -ReleaseIssue 42 -RepoRoot $root
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Config,

        [Parameter(Mandatory)]
        [object] $GitContext,

        [int] $ReleaseIssue,

        [string] $RepoRoot
    )
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-PbiRepoRoot
    }
    $environmentName = [string](Get-PbiProperty $Config 'name' 'this environment')
    $guards = Get-PbiProperty $Config 'guards'
    $failures = [System.Collections.Generic.List[string]]::new()

    $allowedBranches = @(Get-PbiProperty $guards 'allowedBranches')
    if ($allowedBranches.Count -gt 0) {
        $branch = [string](Get-PbiProperty $GitContext 'Branch' '')
        $allowed = $false
        foreach ($pattern in $allowedBranches) {
            if ($branch -clike [string]$pattern) {
                $allowed = $true
                break
            }
        }
        if (-not $allowed) {
            $failures.Add("allowedBranches: branch '$branch' may not deploy to $environmentName (allowed: $($allowedBranches -join ', ')). Switch to an allowed branch.")
        }
    }
    if (Test-PbiTruthy -Value (Get-PbiProperty $guards 'requireCleanWorkingTree')) {
        if (Test-PbiTruthy -Value (Get-PbiProperty $GitContext 'IsDirty')) {
            $failures.Add('requireCleanWorkingTree: the working tree has uncommitted or untracked changes. Commit or stash them, then re-run.')
        }
    }
    if (Test-PbiTruthy -Value (Get-PbiProperty $guards 'requireMergedToMain')) {
        if (-not (Test-PbiTruthy -Value (Get-PbiProperty $GitContext 'IsMergedToOriginMain'))) {
            $failures.Add('requireMergedToMain: HEAD is not contained in origin/main. Merge the pull request, check out main and pull, then re-run.')
        }
    }
    if (Test-PbiTruthy -Value (Get-PbiProperty $guards 'requireTestEvidence')) {
        $evidenceProblem = Get-PbiTestEvidenceProblem -RepoRoot $RepoRoot -GitContext $GitContext
        if (-not [string]::IsNullOrEmpty($evidenceProblem)) {
            $failures.Add("requireTestEvidence: $evidenceProblem")
        }
    }
    if (Test-PbiTruthy -Value (Get-PbiProperty $guards 'requireReleaseApproval')) {
        if ($ReleaseIssue -le 0) {
            $failures.Add('requireReleaseApproval: pass -ReleaseIssue <number> (the OPEN release issue that carries the gate:release-approved label).')
        } else {
            try {
                $issue = Invoke-PbiGh -Arguments @('issue', 'view', [string]$ReleaseIssue, '--json', 'labels,state') -Json -WorkingDirectory $RepoRoot
                $state = [string](Get-PbiProperty $issue 'state' '')
                $labels = @(Get-PbiProperty $issue 'labels' | ForEach-Object { [string](Get-PbiProperty $_ 'name' '') })
                if ($labels -notcontains 'gate:release-approved') {
                    $failures.Add("requireReleaseApproval: issue #$ReleaseIssue does not carry the label 'gate:release-approved'. Ask the release approver to apply it.")
                }
                if ($state -ne 'OPEN') {
                    $failures.Add("requireReleaseApproval: issue #$ReleaseIssue is '$state'; the release issue must be OPEN.")
                }
            } catch {
                $failures.Add("requireReleaseApproval: could not read issue #$ReleaseIssue with gh ($($_.Exception.Message)). Run 'gh auth login' and check the issue number.")
            }
        }
    }
    $humanOnly = Test-PbiTruthy -Value (Get-PbiProperty $guards 'humanOnly')
    if ($humanOnly) {
        $reason = Get-PbiNonInteractiveReason
        if (-not [string]::IsNullOrEmpty($reason)) {
            $failures.Add("humanOnly: $environmentName deployments are human-only ($reason). A person must run this command in an interactive terminal.")
        }
    }
    if ($failures.Count -gt 0) {
        $list = ($failures | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
        throw ("Deployment guards failed for {0} ({1} problem(s)):{2}{3}" -f $environmentName, $failures.Count, [Environment]::NewLine, $list)
    }
    if ($humanOnly) {
        $displayName = [string](Get-PbiProperty (Get-PbiProperty $Config 'workspace') 'displayName' '')
        $typed = Read-Host "Type the workspace name '$displayName' to confirm"
        if ($typed -cne $displayName) {
            throw "Confirmation failed: the typed name did not match '$displayName' exactly. Nothing was deployed."
        }
    }
}

#endregion Git context and guards

#region Auth + REST core

function Connect-PbiFabric {
    <#
    .SYNOPSIS
        Signs in to Microsoft Entra ID with Az.Accounts (5.0.0 or later) for Fabric and Power BI REST calls.
    .DESCRIPTION
        Reuses the current Az context when it exists (and matches -TenantId / -ServicePrincipalId). Otherwise runs
        Connect-AzAccount interactively, with device code, or as a service principal with a certificate
        (-ServicePrincipal -ApplicationId -CertificateThumbprint -Tenant). Client secrets are not supported on purpose.
        Returns the Az context; do not print it (it contains identifiers).
    .PARAMETER TenantId
        Tenant to sign in to (required for service principals).
    .PARAMETER ServicePrincipalId
        Application (client) id of a service principal that authenticates with a certificate.
    .PARAMETER CertificateThumbprint
        Thumbprint of the service principal certificate in the current user's certificate store.
    .PARAMETER UseDeviceAuthentication
        Use the device code flow (for terminals without a browser).
    .EXAMPLE
        $null = Connect-PbiFabric -TenantId $env:PBI_TENANT_ID
    .EXAMPLE
        $null = Connect-PbiFabric -TenantId $tenant -ServicePrincipalId $appId -CertificateThumbprint $thumbprint
    #>
    [CmdletBinding(DefaultParameterSetName = 'Interactive')]
    param(
        [Parameter(ParameterSetName = 'Interactive')]
        [Parameter(ParameterSetName = 'DeviceCode')]
        [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
        [string] $TenantId,

        [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
        [string] $ServicePrincipalId,

        [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
        [string] $CertificateThumbprint,

        [Parameter(ParameterSetName = 'DeviceCode')]
        [switch] $UseDeviceAuthentication
    )
    $available = @(Get-Module -ListAvailable -Name 'Az.Accounts' | Where-Object { $_.Version -ge [version]'5.0.0' })
    if ($available.Count -eq 0) {
        throw 'Az.Accounts 5.0.0 or later is required. Run scripts/bootstrap/Install-PbiTooling.ps1 (or Install-Module Az.Accounts -MinimumVersion 5.0.0 -Scope CurrentUser) and try again.'
    }
    Import-Module -Name 'Az.Accounts' -MinimumVersion '5.0.0' -ErrorAction Stop -Verbose:$false
    $context = Get-AzContext -ErrorAction SilentlyContinue
    $needsLogin = ($null -eq $context) -or ($null -eq (Get-PbiProperty $context 'Account'))
    if (-not $needsLogin -and -not [string]::IsNullOrWhiteSpace($TenantId)) {
        $currentTenant = [string](Get-PbiProperty (Get-PbiProperty $context 'Tenant') 'Id' '')
        if ($currentTenant -ne $TenantId) {
            $needsLogin = $true
        }
    }
    if (-not $needsLogin -and $PSCmdlet.ParameterSetName -eq 'ServicePrincipal') {
        $currentAccount = [string](Get-PbiProperty (Get-PbiProperty $context 'Account') 'Id' '')
        if ($currentAccount -ne $ServicePrincipalId) {
            $needsLogin = $true
        }
    }
    if (-not $needsLogin) {
        Write-Verbose 'Reusing the existing Az context.'
        return $context
    }
    $connectParameters = @{ ErrorAction = 'Stop' }
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $connectParameters.Tenant = $TenantId
    }
    if ($PSCmdlet.ParameterSetName -eq 'ServicePrincipal') {
        $connectParameters.ServicePrincipal = $true
        $connectParameters.ApplicationId = $ServicePrincipalId
        $connectParameters.CertificateThumbprint = $CertificateThumbprint
    } elseif ($UseDeviceAuthentication) {
        $connectParameters.UseDeviceAuthentication = $true
    }
    Write-PbiLog 'Signing in to Microsoft Entra ID (Az.Accounts)...'
    $null = Connect-AzAccount @connectParameters
    $script:PbiTokenCache.Clear()
    return (Get-AzContext)
}

function Get-PbiAccessToken {
    <#
    .SYNOPSIS
        Returns an access token for the Fabric or Power BI REST API (cached until 5 minutes before expiry).
    .DESCRIPTION
        Uses Get-AzAccessToken -ResourceUrl. Az.Accounts 5 returns the token as a SecureString; it is converted to
        plain text in memory only. Never print or persist the returned value.
    .PARAMETER Resource
        Fabric (https://api.fabric.microsoft.com) or PowerBI (https://analysis.windows.net/powerbi/api).
    .EXAMPLE
        $headers = @{ Authorization = 'Bearer ' + (Get-PbiAccessToken -Resource Fabric) }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('Fabric', 'PowerBI')]
        [string] $Resource = 'Fabric'
    )
    $cached = $script:PbiTokenCache[$Resource]
    if ($null -ne $cached -and $cached.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        return $cached.Token
    }
    if ($null -eq (Get-Command -Name 'Get-AzAccessToken' -ErrorAction SilentlyContinue)) {
        throw 'Az.Accounts is not loaded. Run Connect-PbiFabric first (the deploy scripts do this for you).'
    }
    try {
        $tokenResult = Get-AzAccessToken -ResourceUrl $script:PbiResourceUrl[$Resource] -ErrorAction Stop -WarningAction SilentlyContinue
    } catch {
        throw "Could not get an access token for $Resource. Sign in with Connect-PbiFabric (or Connect-AzAccount) and try again. Details: $($_.Exception.Message)"
    }
    $token = $tokenResult.Token
    if ($token -is [System.Security.SecureString]) {
        $plainToken = ConvertFrom-SecureString -SecureString $token -AsPlainText
    } else {
        $plainToken = [string]$token
    }
    $expiresOn = [DateTimeOffset]::UtcNow.AddMinutes(30)
    $rawExpiry = Get-PbiProperty $tokenResult 'ExpiresOn'
    if ($null -ne $rawExpiry) {
        try {
            $expiresOn = [DateTimeOffset]$rawExpiry
        } catch {
            Write-Verbose 'Could not read the token expiry; caching the token for 30 minutes.'
        }
    }
    $script:PbiTokenCache[$Resource] = @{ Token = $plainToken; ExpiresOn = $expiresOn }
    return $plainToken
}

function Resolve-PbiApiUri {
    # Private: absolute URI for a relative API path.
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Resource
    )
    if ($Path -match '^https?://') {
        return $Path
    }
    return $script:PbiApiBaseUrl[$Resource] + $Path.TrimStart('/')
}

function Get-PbiApiDisplayPath {
    # Private: API path for messages (base URL and query string removed, identifiers masked).
    param(
        [Parameter(Mandatory)]
        [string] $Uri
    )
    $display = $Uri
    foreach ($base in @($script:PbiApiBaseUrl.Values)) {
        if ($display.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
            $display = $display.Substring($base.Length)
            break
        }
    }
    $queryIndex = $display.IndexOf('?')
    if ($queryIndex -ge 0) {
        $display = $display.Substring(0, $queryIndex)
    }
    return Protect-PbiText -Text $display
}

function Get-PbiHeaderValue {
    # Private: first value of a response header (case-insensitive), or $null.
    param(
        [AllowNull()]
        [object] $Headers,

        [Parameter(Mandatory)]
        [string] $Name
    )
    if ($null -eq $Headers) {
        return $null
    }
    foreach ($key in @($Headers.Keys)) {
        if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            $value = $Headers[$key]
            if ($null -eq $value) {
                return $null
            }
            if ($value -is [string]) {
                return $value
            }
            $values = @($value)
            if ($values.Count -eq 0) {
                return $null
            }
            return [string]$values[0]
        }
    }
    return $null
}

function Get-PbiRetryAfterSecond {
    # Private: Retry-After header in seconds (capped at 300), or the default.
    param(
        [AllowNull()]
        [object] $Headers,

        [int] $Default = 5
    )
    $value = Get-PbiHeaderValue -Headers $Headers -Name 'Retry-After'
    $seconds = 0
    if (-not [string]::IsNullOrWhiteSpace($value) -and [int]::TryParse($value.Trim(), [ref]$seconds) -and $seconds -ge 0) {
        return [Math]::Min($seconds, 300)
    }
    return $Default
}

function Get-PbiResponseText {
    # Private: response body as text ('' when empty).
    param(
        [AllowNull()]
        [object] $Response
    )
    if ($null -eq $Response) {
        return ''
    }
    $property = $Response.PSObject.Properties['Content']
    if ($null -eq $property -or $null -eq $property.Value) {
        return ''
    }
    $content = $property.Value
    if ($content -is [byte[]]) {
        return [System.Text.Encoding]::UTF8.GetString($content)
    }
    return [string]$content
}

function ConvertFrom-PbiResponseContent {
    # Private: parsed JSON body, the raw text when it is not JSON, or $null when empty.
    param(
        [AllowNull()]
        [object] $Response
    )
    $text = Get-PbiResponseText -Response $Response
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    try {
        return (ConvertFrom-Json -InputObject $text -Depth 100)
    } catch {
        return $text
    }
}

function Get-PbiErrorText {
    # Private: 'code - message - details' from a Fabric or Power BI error object.
    param(
        [AllowNull()]
        [object] $ErrorObject
    )
    if ($null -eq $ErrorObject) {
        return 'Unknown - no error details were returned'
    }
    if ($ErrorObject -is [string]) {
        return $ErrorObject
    }
    $code = [string](Get-PbiProperty $ErrorObject 'errorCode' (Get-PbiProperty $ErrorObject 'code' 'Unknown'))
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add($code)
    $message = [string](Get-PbiProperty $ErrorObject 'message' '')
    if (-not [string]::IsNullOrWhiteSpace($message)) {
        $parts.Add($message)
    }
    $pbiError = Get-PbiProperty $ErrorObject 'pbi.error'
    foreach ($detail in @(Get-PbiProperty $pbiError 'details')) {
        $detailValue = [string](Get-PbiProperty (Get-PbiProperty $detail 'detail') 'value' '')
        $detailCode = [string](Get-PbiProperty $detail 'code' '')
        if (-not [string]::IsNullOrWhiteSpace($detailValue) -and $detailCode -ne 'AnalysisServicesErrorCode') {
            $parts.Add($detailValue)
        }
    }
    foreach ($detail in @(Get-PbiProperty $ErrorObject 'moreDetails')) {
        $detailMessage = [string](Get-PbiProperty $detail 'message' '')
        if (-not [string]::IsNullOrWhiteSpace($detailMessage)) {
            $parts.Add($detailMessage)
        }
    }
    return ($parts -join ' - ')
}

function Format-PbiApiError {
    # Private: error message with method, masked path, status code and the service error code/message (never the token).
    param(
        [Parameter(Mandatory)]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $SafePath,

        [Parameter(Mandatory)]
        [int] $StatusCode,

        [AllowEmptyString()]
        [string] $Content
    )
    $detail = 'Unknown - no error details were returned'
    if (-not [string]::IsNullOrWhiteSpace($Content)) {
        try {
            $parsed = ConvertFrom-Json -InputObject $Content -Depth 100
            $nested = Get-PbiProperty $parsed 'error'
            if ($null -ne $nested -and $null -eq (Get-PbiProperty $parsed 'errorCode')) {
                $detail = Get-PbiErrorText -ErrorObject $nested
            } else {
                $detail = Get-PbiErrorText -ErrorObject $parsed
            }
        } catch {
            $detail = $Content.Substring(0, [Math]::Min(300, $Content.Length))
        }
    }
    $hint = ''
    if ($StatusCode -eq 401) {
        $hint = ' Sign in again (Connect-PbiFabric).'
    } elseif ($StatusCode -eq 403) {
        $hint = ' Check that your identity has the required workspace role and that the tenant setting allows the API.'
    } elseif ($StatusCode -eq 404) {
        $hint = ' Check that the workspace or item exists and that you have access to it.'
    }
    return Protect-PbiText -Text ('{0} {1} failed with HTTP {2}: {3}.{4}' -f $Method.ToUpperInvariant(), $SafePath, $StatusCode, $detail.TrimEnd('.'), $hint)
}

function Invoke-PbiHttpRequest {
    # Private: one authenticated HTTP request (Invoke-WebRequest -SkipHttpErrorCheck). Mocked in the Pester tests.
    param(
        [Parameter(Mandatory)]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Uri,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $BodyJson,

        [Parameter(Mandatory)]
        [string] $Resource
    )
    $ProgressPreference = 'SilentlyContinue'
    $token = Get-PbiAccessToken -Resource $Resource
    $request = @{
        Method             = $Method
        Uri                = $Uri
        Headers            = @{ Authorization = "Bearer $token" }
        SkipHttpErrorCheck = $true
        TimeoutSec         = 600
        ErrorAction        = 'Stop'
        Verbose            = $false
    }
    if (-not [string]::IsNullOrEmpty($BodyJson)) {
        $request.Body = [System.Text.Encoding]::UTF8.GetBytes($BodyJson)
        $request.ContentType = 'application/json; charset=utf-8'
    }
    return Invoke-WebRequest @request
}

function Wait-PbiFabricOperation {
    # Private: polls a Fabric long-running operation until Succeeded/Failed/Cancelled or the deadline.
    param(
        [AllowEmptyString()]
        [string] $OperationId,

        [AllowEmptyString()]
        [string] $Location,

        [int] $InitialDelaySec = 5,

        [Parameter(Mandatory)]
        [datetime] $Deadline,

        [int] $TimeoutSec,

        [Parameter(Mandatory)]
        [string] $Resource,

        [Parameter(Mandatory)]
        [string] $SafePath
    )
    if (-not [string]::IsNullOrEmpty($OperationId)) {
        $pollResource = 'Fabric'
        $pollUri = Resolve-PbiApiUri -Path ('operations/' + $OperationId) -Resource 'Fabric'
    } else {
        $pollResource = $Resource
        $pollUri = Resolve-PbiApiUri -Path $Location -Resource $Resource
    }
    $resultUri = ($pollUri -split '\?')[0].TrimEnd('/') + '/result'
    $delay = [Math]::Max(1, $InitialDelaySec)
    Write-Verbose "Long-running operation accepted for $SafePath; polling."
    while ($true) {
        if ([DateTime]::UtcNow -gt $Deadline) {
            throw "Timed out after $TimeoutSec s waiting for the long-running operation of $SafePath. It may still complete in the service; check the workspace before retrying."
        }
        Start-Sleep -Seconds $delay
        $poll = Invoke-PbiHttpRequest -Method 'Get' -Uri $pollUri -BodyJson $null -Resource $pollResource
        $pollStatus = [int]$poll.StatusCode
        if ($pollStatus -eq 429 -or $pollStatus -eq 503) {
            $delay = Get-PbiRetryAfterSecond -Headers $poll.Headers -Default 30
            continue
        }
        if ($pollStatus -ge 400) {
            throw (Format-PbiApiError -Method 'Get' -SafePath (Get-PbiApiDisplayPath -Uri $pollUri) -StatusCode $pollStatus -Content (Get-PbiResponseText -Response $poll))
        }
        $operation = ConvertFrom-PbiResponseContent -Response $poll
        $state = [string](Get-PbiProperty $operation 'status' '')
        if ($state -eq 'Succeeded') {
            $resultResponse = $null
            try {
                $resultResponse = Invoke-PbiHttpRequest -Method 'Get' -Uri $resultUri -BodyJson $null -Resource $pollResource
            } catch {
                Write-Verbose "Could not read the operation result: $($_.Exception.Message)"
            }
            if ($null -ne $resultResponse -and [int]$resultResponse.StatusCode -eq 200) {
                $result = ConvertFrom-PbiResponseContent -Response $resultResponse
                if ($null -ne $result) {
                    return $result
                }
            }
            return $operation
        }
        if ($state -eq 'Failed' -or $state -eq 'Cancelled') {
            $errorText = Get-PbiErrorText -ErrorObject (Get-PbiProperty $operation 'error')
            throw (Protect-PbiText -Text ('Long-running operation of {0} {1}: {2}' -f $SafePath, $state.ToLowerInvariant(), $errorText))
        }
        $delay = Get-PbiRetryAfterSecond -Headers $poll.Headers -Default 5
    }
}

function Invoke-PbiFabricApi {
    <#
    .SYNOPSIS
        Calls the Fabric (default) or Power BI REST API with retries and long-running-operation support.
    .DESCRIPTION
        - Base URLs: Fabric https://api.fabric.microsoft.com/v1/, PowerBI https://api.powerbi.com/v1.0/myorg/.
          -Path may be relative ('workspaces/{id}/items') or absolute (https://...).
        - The body is serialised with ConvertTo-Json -Depth 100 -Compress and sent as UTF-8 application/json.
        - HTTP 429/503: waits Retry-After seconds (default 30, plus up to 2 s jitter) and retries up to -MaxRetries.
        - HTTP 202 with Location and/or x-ms-operation-id (Fabric LRO), unless -NoLongRunning: polls the operation
          (honouring Retry-After, default 5 s) until Succeeded/Failed/Cancelled or -TimeoutSec; on Succeeded returns
          the JSON of GET operations/{id}/result when it answers 200, else the final operation object.
        - 200/201: returns the parsed JSON ($null for an empty body).
        - Other 4xx/5xx: throws with method, masked path, status code and the service errorCode/message.
    .PARAMETER Method
        Get, Post, Patch, Put or Delete.
    .PARAMETER Path
        Relative API path or absolute URL.
    .PARAMETER Body
        Object (serialised to JSON) or a JSON string.
    .PARAMETER Resource
        Fabric (default) or PowerBI.
    .PARAMETER NoLongRunning
        Return the 202 response instead of polling.
    .PARAMETER MaxRetries
        Retries for 429/503 (default 5).
    .PARAMETER TimeoutSec
        Overall timeout including long-running operations (default 1800).
    .PARAMETER PassThruResponse
        Return @{ StatusCode; Headers; Body } instead of the parsed body (used to read the Location header).
    .EXAMPLE
        $items = Invoke-PbiFabricApi -Method Get -Path "workspaces/$workspaceId/items"
    .EXAMPLE
        $response = Invoke-PbiFabricApi -Method Post -Path $path -Body $body -Resource PowerBI -NoLongRunning -PassThruResponse
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Post', 'Patch', 'Put', 'Delete')]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Path,

        [AllowNull()]
        [object] $Body,

        [ValidateSet('Fabric', 'PowerBI')]
        [string] $Resource = 'Fabric',

        [switch] $NoLongRunning,

        [ValidateRange(0, 50)]
        [int] $MaxRetries = 5,

        [ValidateRange(1, 86400)]
        [int] $TimeoutSec = 1800,

        [switch] $PassThruResponse
    )
    $uri = Resolve-PbiApiUri -Path $Path -Resource $Resource
    $safePath = Get-PbiApiDisplayPath -Uri $uri
    $verb = $Method.ToUpperInvariant()
    $bodyJson = $null
    if ($null -ne $Body) {
        if ($Body -is [string]) {
            $bodyJson = $Body
        } else {
            $bodyJson = ConvertTo-Json -InputObject $Body -Depth 100 -Compress
        }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $attempt = 0
    $response = $null
    while ($true) {
        $attempt++
        try {
            $response = Invoke-PbiHttpRequest -Method $Method -Uri $uri -BodyJson $bodyJson -Resource $Resource
        } catch [System.Net.Http.HttpRequestException] {
            if ($Method -eq 'Get' -and $attempt -le $MaxRetries) {
                $networkDelay = 5 * $attempt
                Write-PbiLog "$verb $safePath failed with a network error; retrying in $networkDelay s (attempt $attempt of $MaxRetries)."
                Start-Sleep -Seconds $networkDelay
                continue
            }
            throw (Protect-PbiText -Text "$verb $safePath failed: $($_.Exception.Message)")
        }
        $status = [int]$response.StatusCode
        if (($status -eq 429 -or $status -eq 503) -and $attempt -le $MaxRetries) {
            $waitSeconds = Get-PbiRetryAfterSecond -Headers $response.Headers -Default 30
            $jitterMilliseconds = Get-Random -Minimum 0 -Maximum 2000
            Write-PbiLog ('{0} {1} returned HTTP {2}; waiting {3} s before retry {4} of {5}.' -f $verb, $safePath, $status, ($waitSeconds + 2), $attempt, $MaxRetries)
            Start-Sleep -Milliseconds ([int]($waitSeconds * 1000 + $jitterMilliseconds))
            continue
        }
        break
    }
    $status = [int]$response.StatusCode
    if ($status -ge 400) {
        throw (Format-PbiApiError -Method $Method -SafePath $safePath -StatusCode $status -Content (Get-PbiResponseText -Response $response))
    }
    if ($status -eq 202 -and -not $NoLongRunning) {
        $operationId = Get-PbiHeaderValue -Headers $response.Headers -Name 'x-ms-operation-id'
        $location = Get-PbiHeaderValue -Headers $response.Headers -Name 'Location'
        if (-not [string]::IsNullOrEmpty($operationId) -or -not [string]::IsNullOrEmpty($location)) {
            $waitParameters = @{
                OperationId     = [string]$operationId
                Location        = [string]$location
                InitialDelaySec = (Get-PbiRetryAfterSecond -Headers $response.Headers -Default 5)
                Deadline        = $deadline
                TimeoutSec      = $TimeoutSec
                Resource        = $Resource
                SafePath        = "$verb $safePath"
            }
            return (Wait-PbiFabricOperation @waitParameters)
        }
    }
    $parsed = ConvertFrom-PbiResponseContent -Response $response
    if ($PassThruResponse) {
        return @{ StatusCode = $status; Headers = $response.Headers; Body = $parsed }
    }
    return $parsed
}

function Invoke-PbiFabricApiPaged {
    <#
    .SYNOPSIS
        GETs every page of a list API and returns all '.value' items.
    .DESCRIPTION
        Follows 'continuationUri' (absolute), 'continuationToken' (appended as continuationToken=<urlencoded>) and
        '@odata.nextLink'. Returns the items unrolled; wrap the call in @().
    .PARAMETER Path
        Relative API path or absolute URL.
    .PARAMETER Resource
        Fabric (default) or PowerBI.
    .PARAMETER MaxPages
        Safety limit (default 500).
    .EXAMPLE
        $workspaces = @(Invoke-PbiFabricApiPaged -Path 'workspaces')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [ValidateSet('Fabric', 'PowerBI')]
        [string] $Resource = 'Fabric',

        [ValidateRange(1, 10000)]
        [int] $MaxPages = 500
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Path
    $page = 0
    while (-not [string]::IsNullOrEmpty($next)) {
        $page++
        if ($page -gt $MaxPages) {
            throw ('Paging stopped after {0} pages for {1}.' -f $MaxPages, (Get-PbiApiDisplayPath -Uri (Resolve-PbiApiUri -Path $Path -Resource $Resource)))
        }
        $response = Invoke-PbiFabricApi -Method 'Get' -Path $next -Resource $Resource -NoLongRunning
        foreach ($item in @(Get-PbiProperty $response 'value')) {
            $items.Add($item)
        }
        $continuationUri = [string](Get-PbiProperty $response 'continuationUri' '')
        $continuationToken = [string](Get-PbiProperty $response 'continuationToken' '')
        $nextLink = [string](Get-PbiProperty $response '@odata.nextLink' '')
        if (-not [string]::IsNullOrEmpty($continuationUri)) {
            $next = $continuationUri
        } elseif (-not [string]::IsNullOrEmpty($continuationToken)) {
            $separator = '?'
            if ($Path.Contains('?')) {
                $separator = '&'
            }
            $next = $Path + $separator + 'continuationToken=' + [System.Uri]::EscapeDataString($continuationToken)
        } elseif (-not [string]::IsNullOrEmpty($nextLink)) {
            $next = $nextLink
        } else {
            $next = $null
        }
    }
    return $items.ToArray()
}

#endregion Auth + REST core

#region Workspace + capacity

function Get-PbiCapacity {
    <#
    .SYNOPSIS
        Finds a Fabric/Power BI capacity by display name (exact, case-insensitive).
    .DESCRIPTION
        Lists GET capacities (paged). Throws when the name is not found or is ambiguous. Returns { id, displayName,
        sku, state, region }.
    .PARAMETER DisplayName
        Capacity display name.
    .EXAMPLE
        $capacity = Get-PbiCapacity -DisplayName 'pbi-superpower-f2'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $DisplayName
    )
    $capacities = @(Invoke-PbiFabricApiPaged -Path 'capacities')
    $found = @($capacities | Where-Object { [string]::Equals([string](Get-PbiProperty $_ 'displayName' ''), $DisplayName, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($found.Count -eq 0) {
        $available = @($capacities | ForEach-Object { [string](Get-PbiProperty $_ 'displayName' '') } | Sort-Object -Unique)
        $hint = 'none visible to this identity'
        if ($available.Count -gt 0) {
            $hint = $available -join ', '
        }
        throw "Capacity '$DisplayName' was not found (available: $hint). Check workspace.capacityName / PBI_CAPACITY_NAME and that you are an admin or contributor of the capacity."
    }
    if ($found.Count -gt 1) {
        throw "Capacity name '$DisplayName' matches $($found.Count) capacities. Rename them so that the name is unique."
    }
    $capacity = $found[0]
    [pscustomobject]@{
        id          = [string](Get-PbiProperty $capacity 'id' '')
        displayName = [string](Get-PbiProperty $capacity 'displayName' '')
        sku         = [string](Get-PbiProperty $capacity 'sku' '')
        state       = [string](Get-PbiProperty $capacity 'state' '')
        region      = [string](Get-PbiProperty $capacity 'region' '')
    }
}

function Get-PbiWorkspace {
    <#
    .SYNOPSIS
        Finds a workspace by display name (exact, case-insensitive); returns $null when it does not exist.
    .PARAMETER DisplayName
        Workspace display name.
    .EXAMPLE
        $workspace = Get-PbiWorkspace -DisplayName 'Power BI Superpower [DEV]'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $DisplayName
    )
    $workspaces = @(Invoke-PbiFabricApiPaged -Path 'workspaces')
    $found = @($workspaces | Where-Object { [string]::Equals([string](Get-PbiProperty $_ 'displayName' ''), $DisplayName, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($found.Count -eq 0) {
        return $null
    }
    if ($found.Count -gt 1) {
        throw "Found $($found.Count) workspaces named '$DisplayName'. Workspace names must be unique; clean up the duplicates manually."
    }
    return $found[0]
}

function Get-PbiPrincipalId {
    # Private: principal id of a workspace role assignment returned by the Fabric API.
    param(
        [AllowNull()]
        [object] $Assignment
    )
    $principalId = [string](Get-PbiProperty (Get-PbiProperty $Assignment 'principal') 'id' '')
    if ([string]::IsNullOrEmpty($principalId)) {
        $principalId = [string](Get-PbiProperty $Assignment 'id' '')
    }
    return $principalId
}

function Deploy-PbiWorkspace {
    <#
    .SYNOPSIS
        Ensures that the environment's workspace exists with the configured capacity, description and role assignments.
    .DESCRIPTION
        Idempotent and safe to re-run:
          - creates the workspace (POST workspaces) when it does not exist, on the configured capacity;
          - assigns the capacity (POST workspaces/{id}/assignToCapacity) when workspace.capacityName is set and differs;
          - updates the description when it differs;
          - adds missing role assignments and updates roles that differ. Assignments that are not in the
            configuration are NEVER removed; they are reported as a warning.
        Honours -WhatIf (prints the plan, makes no remote change). Returns { WorkspaceId, DisplayName, Created,
        Changes[] }. Do not print WorkspaceId.
    .PARAMETER Config
        Environment configuration from Get-PbiEnvironmentConfig.
    .EXAMPLE
        $result = Deploy-PbiWorkspace -Config $config -WhatIf
        $result.Changes
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [object] $Config
    )
    $workspaceConfig = Get-PbiProperty $Config 'workspace'
    $displayName = [string](Get-PbiProperty $workspaceConfig 'displayName' '')
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        throw 'workspace.displayName is required in the environment configuration.'
    }
    $description = [string](Get-PbiProperty $workspaceConfig 'description' '')
    $capacityName = [string](Get-PbiProperty $workspaceConfig 'capacityName' '')
    $changes = [System.Collections.Generic.List[string]]::new()
    $capacity = $null
    if (-not [string]::IsNullOrWhiteSpace($capacityName)) {
        $capacity = Get-PbiCapacity -DisplayName $capacityName
    }
    $workspace = Get-PbiWorkspace -DisplayName $displayName
    $created = $false
    $workspaceId = $null
    if ($null -eq $workspace) {
        $plan = "Create workspace '$displayName'"
        if ($null -ne $capacity) {
            $plan += " on capacity '$capacityName'"
        }
        $changes.Add($plan)
        if ($PSCmdlet.ShouldProcess("workspace '$displayName'", 'Create')) {
            $body = [ordered]@{ displayName = $displayName }
            if (-not [string]::IsNullOrWhiteSpace($description)) {
                $body.description = $description
            }
            if ($null -ne $capacity) {
                $body.capacityId = $capacity.id
            }
            $newWorkspace = Invoke-PbiFabricApi -Method 'Post' -Path 'workspaces' -Body $body
            $workspaceId = [string](Get-PbiProperty $newWorkspace 'id' '')
            if ([string]::IsNullOrEmpty($workspaceId)) {
                $workspaceId = [string](Get-PbiProperty (Get-PbiWorkspace -DisplayName $displayName) 'id' '')
            }
            if ([string]::IsNullOrEmpty($workspaceId)) {
                throw "Workspace '$displayName' was created but its id could not be resolved. Re-run the command."
            }
            $created = $true
            Write-PbiLog "Created workspace '$displayName'." -Level Success
        }
    } else {
        $workspaceId = [string](Get-PbiProperty $workspace 'id' '')
        if ($null -ne $capacity -and [string](Get-PbiProperty $workspace 'capacityId' '') -ne $capacity.id) {
            $changes.Add("Assign workspace '$displayName' to capacity '$capacityName'")
            if ($PSCmdlet.ShouldProcess("workspace '$displayName'", "Assign to capacity '$capacityName'")) {
                $null = Invoke-PbiFabricApi -Method 'Post' -Path "workspaces/$workspaceId/assignToCapacity" -Body @{ capacityId = $capacity.id }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($description) -and [string](Get-PbiProperty $workspace 'description' '') -ne $description) {
            $changes.Add("Update the description of workspace '$displayName'")
            if ($PSCmdlet.ShouldProcess("workspace '$displayName'", 'Update description')) {
                $null = Invoke-PbiFabricApi -Method 'Patch' -Path "workspaces/$workspaceId" -Body @{ description = $description }
            }
        }
    }

    $desired = @(Get-PbiProperty $workspaceConfig 'roleAssignments')
    $current = @()
    if (-not [string]::IsNullOrEmpty($workspaceId)) {
        $current = @(Invoke-PbiFabricApiPaged -Path "workspaces/$workspaceId/roleAssignments")
    }
    $managedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    for ($index = 0; $index -lt $desired.Count; $index++) {
        $assignment = $desired[$index]
        $principalId = [string](Get-PbiProperty $assignment 'principalId' '')
        $principalType = [string](Get-PbiProperty $assignment 'principalType' 'Group')
        $role = [string](Get-PbiProperty $assignment 'role' '')
        $label = "roleAssignments[$index]"
        if ([string]::IsNullOrWhiteSpace($principalId) -or [string]::IsNullOrWhiteSpace($role)) {
            throw "workspace.$label needs principalId and role."
        }
        $null = $managedIds.Add($principalId)
        $existing = $null
        foreach ($candidate in $current) {
            if ([string]::Equals((Get-PbiPrincipalId -Assignment $candidate), $principalId, [System.StringComparison]::OrdinalIgnoreCase)) {
                $existing = $candidate
                break
            }
        }
        if ($null -eq $existing) {
            $changes.Add("Add $principalType as $role ($label)")
            if (-not [string]::IsNullOrEmpty($workspaceId) -and $PSCmdlet.ShouldProcess("workspace '$displayName'", "Add $principalType as $role ($label)")) {
                $body = [ordered]@{
                    principal = [ordered]@{ id = $principalId; type = $principalType }
                    role      = $role
                }
                $null = Invoke-PbiFabricApi -Method 'Post' -Path "workspaces/$workspaceId/roleAssignments" -Body $body
            }
        } else {
            $currentRole = [string](Get-PbiProperty $existing 'role' '')
            if ($currentRole -ne $role) {
                $changes.Add("Change $principalType role from $currentRole to $role ($label)")
                if ($PSCmdlet.ShouldProcess("workspace '$displayName'", "Change $principalType role to $role ($label)")) {
                    $null = Invoke-PbiFabricApi -Method 'Patch' -Path "workspaces/$workspaceId/roleAssignments/$principalId" -Body @{ role = $role }
                }
            }
        }
    }
    $extras = @($current | Where-Object { -not $managedIds.Contains((Get-PbiPrincipalId -Assignment $_)) })
    if ($extras.Count -gt 0) {
        $descriptions = @($extras | ForEach-Object {
                '{0} as {1}' -f [string](Get-PbiProperty (Get-PbiProperty $_ 'principal') 'type' 'Unknown'), [string](Get-PbiProperty $_ 'role' 'Unknown')
            })
        Write-PbiWarning ("Workspace '{0}' has {1} unmanaged role assignment(s) that were left in place: {2}. The identity that created the workspace is expected here; add the others to the environment configuration or remove them manually." -f $displayName, $extras.Count, ($descriptions -join ', '))
    }
    [pscustomobject]@{
        WorkspaceId = $workspaceId
        DisplayName = $displayName
        Created     = $created
        Changes     = $changes.ToArray()
    }
}

#endregion Workspace + capacity

#region Definitions and items

function Get-PbipDefinitionPart {
    <#
    .SYNOPSIS
        Builds the Fabric item definition parts (InlineBase64) for a PBIP item folder.
    .DESCRIPTION
        Lists every file under the item folder recursively. Paths are relative with forward slashes. Files whose
        relative path matches an exclusion regex are skipped. Default exclusions: ^\.pbi/  (^|/)\.pbi/  ^DAXQueries/
        ^TMDLScripts/  ^\.platform$  (^|/)localSettings\.json$  \.abf$  (^|/)item\..*\.json$
        Returns @{ path; payload (base64 of the raw bytes); payloadType = 'InlineBase64' } ordered by path (ordinal).
    .PARAMETER ItemPath
        The *.SemanticModel or *.Report folder.
    .PARAMETER Exclude
        Regular expressions that REPLACE the default exclusions.
    .EXAMPLE
        $parts = @(Get-PbipDefinitionPart -ItemPath 'src/SalesStarter/SalesStarter.SemanticModel')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ItemPath,

        [AllowEmptyCollection()]
        [string[]] $Exclude
    )
    $root = Resolve-PbiFullPath -Path $ItemPath
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Item folder not found: $ItemPath"
    }
    $patterns = $script:PbiDefaultPartExclude
    if ($PSBoundParameters.ContainsKey('Exclude')) {
        $patterns = @($Exclude)
    }
    $parts = [System.Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force)) {
        $relative = [System.IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
        $excluded = $false
        foreach ($pattern in $patterns) {
            if ($relative -match $pattern) {
                $excluded = $true
                break
            }
        }
        if ($excluded) {
            continue
        }
        $parts.Add(@{
                path        = $relative
                payload     = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file.FullName))
                payloadType = 'InlineBase64'
            })
    }
    $parts.Sort([System.Comparison[object]] {
            param($left, $right)
            return [string]::CompareOrdinal([string]$left['path'], [string]$right['path'])
        })
    return $parts.ToArray()
}

function Find-PbiDefinitionPart {
    # Private: the part with the given path, or $null.
    param(
        [AllowEmptyCollection()]
        [object[]] $Part,

        [Parameter(Mandatory)]
        [string] $Path
    )
    foreach ($item in $Part) {
        if ([string](Get-PbiProperty $item 'path' '') -eq $Path) {
            return $item
        }
    }
    return $null
}

function ConvertTo-PbiMLiteral {
    # Private: Power Query (M) literal for a parameter value.
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Name
    )
    if ($null -eq $Value) {
        throw "Semantic model parameter '$Name' has no value. Use a string, number or boolean."
    }
    if ($Value -is [bool]) {
        if ($Value) {
            return 'true'
        }
        return 'false'
    }
    if (Test-PbiNumeric -Value $Value) {
        return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [string]) {
        return '"' + $Value.Replace('"', '""') + '"'
    }
    throw "Semantic model parameter '$Name' has an unsupported value type ($($Value.GetType().Name)). Use a string, number or boolean."
}

function Set-PbipSemanticModelParameter {
    <#
    .SYNOPSIS
        Sets Power Query parameter values in definition/expressions.tmdl of a set of definition parts (pure function).
    .DESCRIPTION
        For each name/value, replaces the value of a line such as
          expression Environment = "Local" meta [IsParameterQuery=true, Type="Text", IsParameterQueryRequired=true]
        (the name may be quoted: expression 'My Param' = ...). Strings are written as M text literals ("" escapes),
        numbers (invariant culture) and booleans (true/false) raw. Throws when a parameter does not exist. Returns
        the parts with a new payload for definition/expressions.tmdl; the input is not modified and nothing is read
        from or written to disk.
    .PARAMETER Part
        Definition parts from Get-PbipDefinitionPart.
    .PARAMETER Parameter
        Hashtable or PSCustomObject of parameter name -> value.
    .EXAMPLE
        $parts = @(Set-PbipSemanticModelParameter -Part $parts -Parameter @{ Environment = 'DEV' })
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Part,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Parameter
    )
    $entries = @(Get-PbiPropertyEntry -InputObject $Parameter)
    if ($entries.Count -eq 0) {
        return $Part
    }
    $target = Find-PbiDefinitionPart -Part $Part -Path 'definition/expressions.tmdl'
    if ($null -eq $target) {
        $names = ($entries | ForEach-Object { $_.Name }) -join ', '
        throw "The semantic model has no definition/expressions.tmdl, so parameter(s) $names cannot be set. Create them in Power BI Desktop (Transform data > Manage parameters) and save the project."
    }
    $bytes = [System.Convert]::FromBase64String([string](Get-PbiProperty $target 'payload' ''))
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $entries) {
        $literal = ConvertTo-PbiMLiteral -Value $entry.Value -Name $entry.Name
        $quotedName = [regex]::Escape($entry.Name.Replace("'", "''"))
        $plainName = [regex]::Escape($entry.Name)
        $pattern = '(?im)^(?<prefix>[ \t]*expression[ \t]+(?:''' + $quotedName + '''|' + $plainName + ')[ \t]*=[ \t]*)(?<value>"(?:[^"]|"")*"|[^\s]+)(?<suffix>[ \t]+meta[ \t]*\[)'
        $match = [regex]::Match($text, $pattern)
        if (-not $match.Success) {
            $missing.Add($entry.Name)
            continue
        }
        $valueGroup = $match.Groups['value']
        $text = $text.Substring(0, $valueGroup.Index) + $literal + $text.Substring($valueGroup.Index + $valueGroup.Length)
    }
    if ($missing.Count -gt 0) {
        throw ('Semantic model parameter(s) not found in definition/expressions.tmdl: {0}. Create them in Power BI Desktop (Transform data > Manage parameters) or remove them from the environment configuration.' -f ($missing -join ', '))
    }
    $output = [System.Collections.Generic.List[byte]]::new()
    if ($hasBom) {
        $output.AddRange([byte[]](0xEF, 0xBB, 0xBF))
    }
    $output.AddRange([System.Text.UTF8Encoding]::new($false).GetBytes($text))
    $payload = [System.Convert]::ToBase64String($output.ToArray())
    foreach ($item in $Part) {
        if ([object]::ReferenceEquals($item, $target)) {
            @{ path = 'definition/expressions.tmdl'; payload = $payload; payloadType = 'InlineBase64' }
        } else {
            $item
        }
    }
}

function Set-PbipReportBinding {
    <#
    .SYNOPSIS
        Rewrites definition.pbir so that the report binds to a deployed semantic model by id (pure function).
    .DESCRIPTION
        Keeps $schema and version (and any other top-level property) and replaces datasetReference:
          - definitionProperties/1.0.0 schema: byConnection { connectionString: null, pbiServiceModelId: null,
            pbiModelVirtualServerName: 'sobe_wowvirtualserver', pbiModelDatabaseName: <id>, name: 'EntityDataSource',
            connectionType: 'pbiServiceXmlaStyleLive' }
          - 2.0.0 or a missing schema (the 2.0.0 schema URL is then added): byConnection { connectionString:
            'semanticmodelid=<id>' }
        byPath is always removed. Returns the parts with the new definition.pbir payload; the input is not modified.
    .PARAMETER Part
        Definition parts from Get-PbipDefinitionPart.
    .PARAMETER SemanticModelId
        Id of the deployed semantic model.
    .EXAMPLE
        $parts = @(Set-PbipReportBinding -Part $parts -SemanticModelId $model.Id)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Part,

        [Parameter(Mandatory)]
        [string] $SemanticModelId
    )
    $target = Find-PbiDefinitionPart -Part $Part -Path 'definition.pbir'
    if ($null -eq $target) {
        throw 'The report definition has no definition.pbir. Save the report as PBIP (PBIR format) in Power BI Desktop.'
    }
    $text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String([string](Get-PbiProperty $target 'payload' ''))).TrimStart([char]0xFEFF)
    try {
        $pbir = ConvertFrom-Json -InputObject $text -Depth 100
    } catch {
        throw "definition.pbir is not valid JSON: $($_.Exception.Message)"
    }
    $schema = [string](Get-PbiProperty $pbir '$schema' '')
    $version = Get-PbiProperty $pbir 'version'
    $output = [ordered]@{}
    if ($schema -match '/definitionProperties/1\.0\.0/') {
        if ($null -eq $version) {
            $version = '1.0'
        }
        $output['$schema'] = $schema
        $output['version'] = $version
        $output['datasetReference'] = [ordered]@{
            byConnection = [ordered]@{
                connectionString          = $null
                pbiServiceModelId         = $null
                pbiModelVirtualServerName = 'sobe_wowvirtualserver'
                pbiModelDatabaseName      = $SemanticModelId
                name                      = 'EntityDataSource'
                connectionType            = 'pbiServiceXmlaStyleLive'
            }
        }
    } else {
        if ([string]::IsNullOrWhiteSpace($schema)) {
            $schema = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/2.0.0/schema.json'
        }
        if ($null -eq $version) {
            $version = '4.0'
        }
        $output['$schema'] = $schema
        $output['version'] = $version
        $output['datasetReference'] = [ordered]@{
            byConnection = [ordered]@{
                connectionString = "semanticmodelid=$SemanticModelId"
            }
        }
    }
    foreach ($entry in @(Get-PbiPropertyEntry -InputObject $pbir)) {
        if (@('$schema', 'version', 'datasetReference') -contains $entry.Name) {
            continue
        }
        $output[$entry.Name] = $entry.Value
    }
    $json = ConvertTo-Json -InputObject $output -Depth 50
    $payload = [System.Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($json))
    foreach ($item in $Part) {
        if ([object]::ReferenceEquals($item, $target)) {
            @{ path = 'definition.pbir'; payload = $payload; payloadType = 'InlineBase64' }
        } else {
            $item
        }
    }
}

function Get-PbiItem {
    <#
    .SYNOPSIS
        Finds a semantic model or report in a workspace by display name; returns $null when it does not exist.
    .DESCRIPTION
        GET workspaces/{ws}/items?type=<Type> (paged), exact case-insensitive match. Throws when more than one item has
        the name (duplicate display names must be cleaned up manually).
    .PARAMETER WorkspaceId
        Workspace id.
    .PARAMETER Type
        SemanticModel or Report.
    .PARAMETER DisplayName
        Item display name.
    .EXAMPLE
        $model = Get-PbiItem -WorkspaceId $workspaceId -Type SemanticModel -DisplayName 'SalesStarter'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidateSet('SemanticModel', 'Report')]
        [string] $Type,

        [Parameter(Mandatory)]
        [string] $DisplayName
    )
    $items = @(Invoke-PbiFabricApiPaged -Path "workspaces/$WorkspaceId/items?type=$Type")
    $found = @($items | Where-Object {
            $itemType = [string](Get-PbiProperty $_ 'type' $Type)
            [string]::Equals([string](Get-PbiProperty $_ 'displayName' ''), $DisplayName, [System.StringComparison]::OrdinalIgnoreCase) -and $itemType -eq $Type
        })
    if ($found.Count -gt 1) {
        throw "Found $($found.Count) $Type items named '$DisplayName' in the workspace (duplicate display names - clean up the workspace manually)."
    }
    if ($found.Count -eq 0) {
        return $null
    }
    return $found[0]
}

function Publish-PbiSemanticModel {
    <#
    .SYNOPSIS
        Creates or updates a semantic model in a workspace from a PBIP *.SemanticModel folder (TMDL).
    .DESCRIPTION
        Builds the parts with Get-PbipDefinitionPart (and Set-PbipSemanticModelParameter when -Parameter is given),
        checks that definition.pbism, definition/model.tmdl and definition/database.tmdl are present, then:
          - creates the item (POST workspaces/{ws}/semanticModels with displayName, description and the TMDL definition), or
          - updates it (POST workspaces/{ws}/semanticModels/{id}/updateDefinition, without updateMetadata).
        Honours -WhatIf. Returns { Id, DisplayName, Action = Created | Updated | WouldCreate | WouldUpdate }.
    .PARAMETER WorkspaceId
        Target workspace id.
    .PARAMETER ItemPath
        The *.SemanticModel folder.
    .PARAMETER DisplayName
        Item display name in the workspace.
    .PARAMETER Parameter
        Power Query parameter values to set (hashtable or PSCustomObject).
    .PARAMETER Description
        Item description (used when the item is created).
    .EXAMPLE
        $model = Publish-PbiSemanticModel -WorkspaceId $workspaceId -ItemPath $modelPath -DisplayName 'SalesStarter' -Parameter @{ Environment = 'DEV' }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [string] $ItemPath,

        [Parameter(Mandatory)]
        [string] $DisplayName,

        [AllowNull()]
        [object] $Parameter,

        [string] $Description
    )
    $parts = @(Get-PbipDefinitionPart -ItemPath $ItemPath)
    if (@(Get-PbiPropertyEntry -InputObject $Parameter).Count -gt 0) {
        $parts = @(Set-PbipSemanticModelParameter -Part $parts -Parameter $Parameter)
    }
    $paths = @($parts | ForEach-Object { [string]$_['path'] })
    $absent = @(@('definition.pbism', 'definition/model.tmdl', 'definition/database.tmdl') | Where-Object { $paths -notcontains $_ })
    if ($absent.Count -gt 0) {
        throw ("The semantic model folder '{0}' is incomplete (missing: {1}). Save the project from Power BI Desktop as PBIP with the TMDL format enabled." -f (Split-Path -Path $ItemPath -Leaf), ($absent -join ', '))
    }
    $definition = [ordered]@{ format = 'TMDL'; parts = $parts }
    $existing = Get-PbiItem -WorkspaceId $WorkspaceId -Type 'SemanticModel' -DisplayName $DisplayName
    if ($null -eq $existing) {
        if (-not $PSCmdlet.ShouldProcess("semantic model '$DisplayName'", 'Create')) {
            return [pscustomobject]@{ Id = $null; DisplayName = $DisplayName; Action = 'WouldCreate' }
        }
        $body = [ordered]@{ displayName = $DisplayName }
        if (-not [string]::IsNullOrWhiteSpace($Description)) {
            $body.description = $Description
        }
        $body.definition = $definition
        $result = Invoke-PbiFabricApi -Method 'Post' -Path "workspaces/$WorkspaceId/semanticModels" -Body $body
        $id = [string](Get-PbiProperty $result 'id' '')
        if ([string]::IsNullOrEmpty($id)) {
            $id = [string](Get-PbiProperty (Get-PbiItem -WorkspaceId $WorkspaceId -Type 'SemanticModel' -DisplayName $DisplayName) 'id' '')
        }
        if ([string]::IsNullOrEmpty($id)) {
            throw "Semantic model '$DisplayName' was created but its id could not be resolved. Re-run the deployment (it will update the existing model)."
        }
        Write-PbiLog "Created semantic model '$DisplayName'." -Level Success
        return [pscustomobject]@{ Id = $id; DisplayName = $DisplayName; Action = 'Created' }
    }
    $id = [string](Get-PbiProperty $existing 'id' '')
    if (-not $PSCmdlet.ShouldProcess("semantic model '$DisplayName'", 'Update definition')) {
        return [pscustomobject]@{ Id = $id; DisplayName = $DisplayName; Action = 'WouldUpdate' }
    }
    $null = Invoke-PbiFabricApi -Method 'Post' -Path "workspaces/$WorkspaceId/semanticModels/$id/updateDefinition" -Body @{ definition = $definition }
    Write-PbiLog "Updated semantic model '$DisplayName'." -Level Success
    return [pscustomobject]@{ Id = $id; DisplayName = $DisplayName; Action = 'Updated' }
}

function Publish-PbiReport {
    <#
    .SYNOPSIS
        Creates or updates a report in a workspace from a PBIP *.Report folder (PBIR), bound to a semantic model id.
    .DESCRIPTION
        Builds the parts with Get-PbipDefinitionPart, rewrites definition.pbir with Set-PbipReportBinding, checks that
        definition.pbir and definition/report.json (PBIR; report.json for PBIR-Legacy) exist, then creates the item
        (POST workspaces/{ws}/reports) or updates it (POST workspaces/{ws}/reports/{id}/updateDefinition). The
        definition format is never sent for reports (the service detects PBIR). Honours -WhatIf.
        Returns { Id, DisplayName, Action }.
    .PARAMETER WorkspaceId
        Target workspace id.
    .PARAMETER ItemPath
        The *.Report folder.
    .PARAMETER DisplayName
        Item display name in the workspace.
    .PARAMETER SemanticModelId
        Id of the deployed semantic model. May be empty only with -WhatIf (model not created yet).
    .PARAMETER Description
        Item description (used when the item is created).
    .EXAMPLE
        Publish-PbiReport -WorkspaceId $workspaceId -ItemPath $reportPath -DisplayName 'SalesStarter' -SemanticModelId $model.Id
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [string] $ItemPath,

        [Parameter(Mandatory)]
        [string] $DisplayName,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $SemanticModelId,

        [string] $Description
    )
    $modelId = $SemanticModelId
    if ([string]::IsNullOrWhiteSpace($modelId)) {
        if (-not $WhatIfPreference) {
            throw "A semantic model id is required to publish report '$DisplayName'."
        }
        $modelId = $script:PbiZeroGuid
    }
    $parts = @(Get-PbipDefinitionPart -ItemPath $ItemPath)
    $paths = @($parts | ForEach-Object { [string]$_['path'] })
    if ($paths -notcontains 'definition.pbir') {
        throw "The report folder '$(Split-Path -Path $ItemPath -Leaf)' has no definition.pbir. Save the report as PBIP in Power BI Desktop."
    }
    if ($paths -notcontains 'definition/report.json' -and $paths -notcontains 'report.json') {
        throw "The report folder '$(Split-Path -Path $ItemPath -Leaf)' has no definition/report.json. Save the report in the PBIR format (Power BI Desktop > Options > Preview features > Store reports using enhanced metadata format (PBIR))."
    }
    $parts = @(Set-PbipReportBinding -Part $parts -SemanticModelId $modelId)
    $definition = [ordered]@{ parts = $parts }
    $existing = Get-PbiItem -WorkspaceId $WorkspaceId -Type 'Report' -DisplayName $DisplayName
    if ($null -eq $existing) {
        if (-not $PSCmdlet.ShouldProcess("report '$DisplayName'", 'Create')) {
            return [pscustomobject]@{ Id = $null; DisplayName = $DisplayName; Action = 'WouldCreate' }
        }
        $body = [ordered]@{ displayName = $DisplayName }
        if (-not [string]::IsNullOrWhiteSpace($Description)) {
            $body.description = $Description
        }
        $body.definition = $definition
        $result = Invoke-PbiFabricApi -Method 'Post' -Path "workspaces/$WorkspaceId/reports" -Body $body
        $id = [string](Get-PbiProperty $result 'id' '')
        if ([string]::IsNullOrEmpty($id)) {
            $id = [string](Get-PbiProperty (Get-PbiItem -WorkspaceId $WorkspaceId -Type 'Report' -DisplayName $DisplayName) 'id' '')
        }
        Write-PbiLog "Created report '$DisplayName'." -Level Success
        return [pscustomobject]@{ Id = $id; DisplayName = $DisplayName; Action = 'Created' }
    }
    $id = [string](Get-PbiProperty $existing 'id' '')
    if (-not $PSCmdlet.ShouldProcess("report '$DisplayName'", 'Update definition')) {
        return [pscustomobject]@{ Id = $id; DisplayName = $DisplayName; Action = 'WouldUpdate' }
    }
    $null = Invoke-PbiFabricApi -Method 'Post' -Path "workspaces/$WorkspaceId/reports/$id/updateDefinition" -Body @{ definition = $definition }
    Write-PbiLog "Updated report '$DisplayName'." -Level Success
    return [pscustomobject]@{ Id = $id; DisplayName = $DisplayName; Action = 'Updated' }
}

#endregion Definitions and items

#region Power BI operations

function ConvertTo-PbiDaxColumnName {
    # Private: '[TestName]' -> 'TestName', 'Table[Col]' -> 'Col', "'My Table'[A]]B]" -> 'A]B'.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Name
    )
    $match = [regex]::Match($Name, '\[(?<column>(?:[^\[\]]|\]\])*)\]\s*$')
    if ($match.Success) {
        return $match.Groups['column'].Value.Replace(']]', ']')
    }
    return $Name
}

function ConvertTo-PbiNormalizedRow {
    # Private: copies a result row with normalised column names (first column wins on a name collision).
    param(
        [AllowNull()]
        [object] $Row
    )
    $normalized = [ordered]@{}
    foreach ($entry in @(Get-PbiPropertyEntry -InputObject $Row)) {
        $key = ConvertTo-PbiDaxColumnName -Name $entry.Name
        if ($normalized.Contains($key)) {
            $key = $entry.Name
        }
        $normalized[$key] = $entry.Value
    }
    return [pscustomobject]$normalized
}

function Invoke-PbiDatasetRefresh {
    <#
    .SYNOPSIS
        Runs a full, transactional enhanced refresh of a semantic model and waits for it to finish.
    .DESCRIPTION
        POST groups/{ws}/datasets/{id}/refreshes (Power BI API) with {"type":"full","commitMode":"transactional","retryCount":1}.
        The refresh id is read from the Location header (last path segment) or from GET .../refreshes?$top=1. Polls
        GET .../refreshes/{refreshId} every -PollIntervalSec seconds until extendedStatus/status is Completed, Failed,
        Cancelled, Disabled or TimedOut; throws (with the service messages) for anything but Completed.
        Honours -WhatIf. Returns { Status, DurationSec }.
    .PARAMETER WorkspaceId
        Workspace (group) id.
    .PARAMETER DatasetId
        Semantic model (dataset) id.
    .PARAMETER TimeoutMinutes
        Maximum wait (default 30).
    .PARAMETER PollIntervalSec
        Polling interval (default 10).
    .PARAMETER DisplayName
        Name used in messages.
    .EXAMPLE
        Invoke-PbiDatasetRefresh -WorkspaceId $workspaceId -DatasetId $model.Id -DisplayName 'SalesStarter'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [string] $DatasetId,

        [ValidateRange(1, 1440)]
        [int] $TimeoutMinutes = 30,

        [ValidateRange(1, 600)]
        [int] $PollIntervalSec = 10,

        [string] $DisplayName = 'semantic model'
    )
    if (-not $PSCmdlet.ShouldProcess("semantic model '$DisplayName'", 'Refresh (full, transactional)')) {
        return [pscustomobject]@{ Status = 'WhatIf'; DurationSec = 0 }
    }
    $basePath = "groups/$WorkspaceId/datasets/$DatasetId/refreshes"
    $body = [ordered]@{ type = 'full'; commitMode = 'transactional'; retryCount = 1 }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-PbiLog "Refreshing '$DisplayName' (full, transactional)..."
    $response = Invoke-PbiFabricApi -Method 'Post' -Path $basePath -Body $body -Resource 'PowerBI' -NoLongRunning -PassThruResponse
    $refreshId = $null
    $location = Get-PbiHeaderValue -Headers $response['Headers'] -Name 'Location'
    if (-not [string]::IsNullOrWhiteSpace($location)) {
        $locationPath = ($location -split '\?')[0].TrimEnd('/')
        $refreshId = ($locationPath -split '/')[-1]
    }
    if ([string]::IsNullOrWhiteSpace($refreshId)) {
        $latest = Invoke-PbiFabricApi -Method 'Get' -Path ($basePath + '?$top=1') -Resource 'PowerBI' -NoLongRunning
        $first = @(Get-PbiProperty $latest 'value') | Select-Object -First 1
        $refreshId = [string](Get-PbiProperty $first 'requestId' '')
    }
    if ([string]::IsNullOrWhiteSpace($refreshId)) {
        throw "The refresh of '$DisplayName' was accepted but its id could not be determined. Check the refresh history in the service."
    }
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $terminal = @('Completed', 'Failed', 'Cancelled', 'Disabled', 'TimedOut', 'Succeeded')
    $state = 'Unknown'
    $details = $null
    while ($true) {
        Start-Sleep -Seconds $PollIntervalSec
        $details = Invoke-PbiFabricApi -Method 'Get' -Path "$basePath/$refreshId" -Resource 'PowerBI' -NoLongRunning
        $state = [string](Get-PbiProperty $details 'extendedStatus' (Get-PbiProperty $details 'status' 'Unknown'))
        if ($terminal -contains $state) {
            break
        }
        if ([DateTime]::UtcNow -gt $deadline) {
            throw "The refresh of '$DisplayName' did not finish within $TimeoutMinutes minute(s) (last status: $state). It may still be running in the service."
        }
        Write-Verbose "Refresh status: $state"
    }
    $stopwatch.Stop()
    $duration = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
    if ($state -eq 'Succeeded') {
        $state = 'Completed'
    }
    if ($state -ne 'Completed') {
        $messages = @(Get-PbiProperty $details 'messages' | ForEach-Object {
                '{0}: {1}' -f [string](Get-PbiProperty $_ 'code' 'Error'), [string](Get-PbiProperty $_ 'message' '')
            })
        $serviceError = [string](Get-PbiProperty $details 'serviceExceptionJson' '')
        if (-not [string]::IsNullOrWhiteSpace($serviceError)) {
            $messages += $serviceError
        }
        $detailText = 'No details were returned.'
        if ($messages.Count -gt 0) {
            $detailText = $messages -join ' | '
        }
        throw (Protect-PbiText -Text "Refresh of '$DisplayName' ended with status $state after $duration s. $detailText Check data source credentials and the refresh history in the service.")
    }
    Write-PbiLog "Refresh of '$DisplayName' completed in $duration s." -Level Success
    return [pscustomobject]@{ Status = $state; DurationSec = $duration }
}

function Invoke-PbiDaxQuery {
    <#
    .SYNOPSIS
        Runs a DAX query against a semantic model in the service (executeQueries API).
    .DESCRIPTION
        POST groups/{ws}/datasets/{id}/executeQueries with { queries: [{ query }], serializerSettings: { includeNulls: true } }
        (+ impersonatedUserName). Returns the rows of the first table as PSCustomObjects whose column names are
        normalised ('[TestName]' -> 'TestName', 'Table[Col]' -> 'Col'). Errors in the result are thrown.
    .PARAMETER WorkspaceId
        Workspace (group) id.
    .PARAMETER DatasetId
        Semantic model (dataset) id.
    .PARAMETER Query
        The DAX query (EVALUATE ...).
    .PARAMETER ImpersonatedUserName
        UPN to impersonate (row-level security tests).
    .EXAMPLE
        Invoke-PbiDaxQuery -WorkspaceId $ws -DatasetId $ds -Query 'EVALUATE ROW("Rows", COUNTROWS(Sales))'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [string] $DatasetId,

        [Parameter(Mandatory)]
        [string] $Query,

        [string] $ImpersonatedUserName
    )
    $body = [ordered]@{
        queries            = @([ordered]@{ query = $Query })
        serializerSettings = [ordered]@{ includeNulls = $true }
    }
    if (-not [string]::IsNullOrWhiteSpace($ImpersonatedUserName)) {
        $body.impersonatedUserName = $ImpersonatedUserName
    }
    $response = Invoke-PbiFabricApi -Method 'Post' -Path "groups/$WorkspaceId/datasets/$DatasetId/executeQueries" -Body $body -Resource 'PowerBI' -NoLongRunning
    $topError = Get-PbiProperty $response 'error'
    if ($null -ne $topError) {
        throw (Protect-PbiText -Text "DAX query failed: $(Get-PbiErrorText -ErrorObject $topError)")
    }
    $results = @(Get-PbiProperty $response 'results')
    if ($results.Count -eq 0) {
        return
    }
    $resultError = Get-PbiProperty $results[0] 'error'
    if ($null -ne $resultError) {
        throw (Protect-PbiText -Text "DAX query failed: $(Get-PbiErrorText -ErrorObject $resultError)")
    }
    $tables = @(Get-PbiProperty $results[0] 'tables')
    if ($tables.Count -eq 0) {
        return
    }
    $tableError = Get-PbiProperty $tables[0] 'error'
    if ($null -ne $tableError) {
        throw (Protect-PbiText -Text "DAX query failed: $(Get-PbiErrorText -ErrorObject $tableError)")
    }
    foreach ($row in @(Get-PbiProperty $tables[0] 'rows')) {
        ConvertTo-PbiNormalizedRow -Row $row
    }
}

#endregion Power BI operations

#region Local Power BI Desktop

function Get-PbiDesktopInstance {
    <#
    .SYNOPSIS
        Finds the local Analysis Services port of a running Power BI Desktop instance (Windows only).
    .DESCRIPTION
        Looks for msmdsrv.exe processes, reads '-s "<dataDir>"' from the command line and the port from
        <dataDir>\msmdsrv.port.txt, and finds the PBIDesktop.exe parent (up to 3 levels) for its window title.
        Returns exactly one { Port, ProcessId, WindowTitle, DataDirectory }; throws when none or several match.
    .PARAMETER ProjectName
        Keep only instances whose window title contains this text (normally the .pbip file name).
    .EXAMPLE
        $desktop = Get-PbiDesktopInstance -ProjectName 'SalesStarter'
    #>
    [CmdletBinding()]
    param(
        [string] $ProjectName
    )
    Assert-PbiWindows -Feature 'Finding a running Power BI Desktop instance'
    $engines = @(Get-CimInstance -ClassName 'Win32_Process' -Filter "Name='msmdsrv.exe'" -ErrorAction Stop)
    $instances = [System.Collections.Generic.List[object]]::new()
    foreach ($engine in $engines) {
        $commandLine = [string](Get-PbiProperty $engine 'CommandLine' '')
        $directoryMatch = [regex]::Match($commandLine, '-s\s+"(?<dir>[^"]+)"')
        if (-not $directoryMatch.Success) {
            Write-Verbose 'Skipping an msmdsrv.exe process without a -s data directory (or access was denied).'
            continue
        }
        $dataDirectory = $directoryMatch.Groups['dir'].Value
        $portFile = Join-Path $dataDirectory 'msmdsrv.port.txt'
        if (-not (Test-Path -LiteralPath $portFile -PathType Leaf)) {
            continue
        }
        $bytes = [System.IO.File]::ReadAllBytes($portFile)
        if ([Array]::IndexOf($bytes, [byte]0) -ge 0) {
            $portText = [System.Text.Encoding]::Unicode.GetString($bytes)
        } else {
            $portText = [System.Text.Encoding]::UTF8.GetString($bytes)
        }
        $digits = $portText -replace '[^0-9]', ''
        if ([string]::IsNullOrEmpty($digits)) {
            continue
        }
        $title = $null
        $parentId = [int](Get-PbiProperty $engine 'ParentProcessId' 0)
        for ($level = 0; $level -lt 3 -and $parentId -gt 0; $level++) {
            $parent = Get-CimInstance -ClassName 'Win32_Process' -Filter "ProcessId=$parentId" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $parent) {
                break
            }
            if ([string](Get-PbiProperty $parent 'Name' '') -ieq 'PBIDesktop.exe') {
                $process = Get-Process -Id $parentId -ErrorAction SilentlyContinue
                if ($null -ne $process) {
                    $title = [string]$process.MainWindowTitle
                }
                break
            }
            $parentId = [int](Get-PbiProperty $parent 'ParentProcessId' 0)
        }
        $instances.Add([pscustomobject]@{
                Port          = [int]$digits
                ProcessId     = [int](Get-PbiProperty $engine 'ProcessId' 0)
                WindowTitle   = $title
                DataDirectory = $dataDirectory
            })
    }
    $candidates = @($instances)
    if (-not [string]::IsNullOrWhiteSpace($ProjectName)) {
        $pattern = '*' + [System.Management.Automation.WildcardPattern]::Escape($ProjectName) + '*'
        $candidates = @($instances | Where-Object { [string]$_.WindowTitle -like $pattern })
    }
    if ($candidates.Count -eq 0) {
        if ($instances.Count -eq 0) {
            throw 'No running Power BI Desktop instance with a loaded model was found. Open the project (.pbip) in Power BI Desktop, wait until the model has loaded, then re-run.'
        }
        $open = @($instances | ForEach-Object { if ($_.WindowTitle) { $_.WindowTitle } else { '(untitled)' } }) -join '; '
        throw "Power BI Desktop is running, but no window title contains '$ProjectName' (open: $open). Open the project's .pbip file in Power BI Desktop."
    }
    if ($candidates.Count -gt 1) {
        $titles = @($candidates | ForEach-Object { if ($_.WindowTitle) { $_.WindowTitle } else { '(untitled)' } }) -join '; '
        throw "Several Power BI Desktop instances match ($titles). Close the others or pass -ProjectName."
    }
    return $candidates[0]
}

function Test-PbiAdomdLoaded {
    # Private: $true when the ADOMD.NET client type is available.
    return ($null -ne ('Microsoft.AnalysisServices.AdomdClient.AdomdConnection' -as [type]))
}

function Import-PbiAdomdClient {
    <#
    .SYNOPSIS
        Loads the ADOMD.NET client (Microsoft.AnalysisServices.AdomdClient) for local DAX queries.
    .DESCRIPTION
        Order: already loaded; tools/.bin/adomd/**/Microsoft.AnalysisServices.AdomdClient.dll (lib folders preferred
        net8.0 > net6.0 > netcoreapp3.0 > netstandard2.0, sibling Microsoft.AnalysisServices.*.dll loaded first);
        the SqlServer module. Throws with the install command when nothing works.
    .PARAMETER RepoRoot
        Repository root (default: discovered from the current location).
    .EXAMPLE
        Import-PbiAdomdClient -RepoRoot $root
    #>
    [CmdletBinding()]
    param(
        [string] $RepoRoot
    )
    if (Test-PbiAdomdLoaded) {
        return
    }
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        try {
            $RepoRoot = Get-PbiRepoRoot
        } catch {
            $RepoRoot = $null
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $adomdRoot = Join-Path $RepoRoot 'tools' '.bin' 'adomd'
        if (Test-Path -LiteralPath $adomdRoot -PathType Container) {
            $candidates = @(Get-ChildItem -LiteralPath $adomdRoot -Recurse -File -Filter 'Microsoft.AnalysisServices.AdomdClient.dll')
            $chosen = $null
            foreach ($framework in @('net8.0', 'net6.0', 'netcoreapp3.0', 'netstandard2.0')) {
                $chosen = $candidates | Where-Object { $_.Directory.Name -eq $framework } | Sort-Object -Property FullName -Descending | Select-Object -First 1
                if ($null -ne $chosen) {
                    break
                }
            }
            if ($null -eq $chosen -and $candidates.Count -gt 0) {
                $chosen = $candidates[0]
            }
            if ($null -ne $chosen) {
                foreach ($dependency in @(Get-ChildItem -LiteralPath $chosen.DirectoryName -File -Filter 'Microsoft.AnalysisServices.*.dll')) {
                    if ($dependency.FullName -eq $chosen.FullName) {
                        continue
                    }
                    try {
                        Add-Type -Path $dependency.FullName -ErrorAction Stop
                    } catch {
                        Write-Verbose "Skipped $($dependency.Name): $($_.Exception.Message)"
                    }
                }
                try {
                    Add-Type -Path $chosen.FullName -ErrorAction Stop
                } catch {
                    Write-PbiWarning "Could not load $($chosen.Name): $($_.Exception.Message)"
                }
            }
        }
    }
    if (Test-PbiAdomdLoaded) {
        return
    }
    Import-Module -Name 'SqlServer' -ErrorAction SilentlyContinue -Verbose:$false
    if (Test-PbiAdomdLoaded) {
        return
    }
    throw 'The ADOMD.NET client (Microsoft.AnalysisServices.AdomdClient) was not found. Run scripts/bootstrap/Install-PbiTooling.ps1 (downloads it into tools/.bin/adomd), then re-run.'
}

function Format-PbiConnectionStringValue {
    # Private: quotes a connection string value when it contains special characters.
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )
    if ($Value -match '[;="''\s]' -or $Value -ne $Value.Trim()) {
        return '"' + $Value.Replace('"', '""') + '"'
    }
    return $Value
}

function Invoke-PbiLocalDaxQuery {
    <#
    .SYNOPSIS
        Runs a DAX query against the local Power BI Desktop model (ADOMD.NET, Data Source=localhost:<port>).
    .DESCRIPTION
        Returns the rows as PSCustomObjects with normalised column names ('[TestName]' -> 'TestName'). The connection
        is always disposed. -Role and -EffectiveUserName append Roles= / EffectiveUserName= to the connection string to
        evaluate row-level security.
    .PARAMETER Port
        Port from Get-PbiDesktopInstance.
    .PARAMETER Query
        The DAX query.
    .PARAMETER Role
        Role name(s) to impersonate (comma-separated for several roles).
    .PARAMETER EffectiveUserName
        User principal name to impersonate.
    .PARAMETER RepoRoot
        Repository root used to locate tools/.bin/adomd.
    .EXAMPLE
        Invoke-PbiLocalDaxQuery -Port $desktop.Port -Query 'EVALUATE ROW("x", 1)' -Role 'Sales Europe'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int] $Port,

        [Parameter(Mandatory)]
        [string] $Query,

        [string] $Role,

        [string] $EffectiveUserName,

        [string] $RepoRoot
    )
    Import-PbiAdomdClient -RepoRoot $RepoRoot
    $connectionString = "Data Source=localhost:$Port"
    if (-not [string]::IsNullOrWhiteSpace($Role)) {
        $connectionString += ';Roles=' + (Format-PbiConnectionStringValue -Value $Role.Trim())
    }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveUserName)) {
        $connectionString += ';EffectiveUserName=' + (Format-PbiConnectionStringValue -Value $EffectiveUserName.Trim())
    }
    $connection = $null
    $command = $null
    $reader = $null
    try {
        $connection = New-Object -TypeName 'Microsoft.AnalysisServices.AdomdClient.AdomdConnection' -ArgumentList $connectionString
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $reader = $command.ExecuteReader()
        $names = [System.Collections.Generic.List[string]]::new()
        for ($index = 0; $index -lt $reader.FieldCount; $index++) {
            $rawName = [string]$reader.GetName($index)
            $name = ConvertTo-PbiDaxColumnName -Name $rawName
            if ($names.Contains($name)) {
                $name = $rawName
            }
            $names.Add($name)
        }
        $rows = [System.Collections.Generic.List[object]]::new()
        while ($reader.Read()) {
            $row = [ordered]@{}
            for ($index = 0; $index -lt $reader.FieldCount; $index++) {
                $value = $reader.GetValue($index)
                if ($value -is [System.DBNull]) {
                    $value = $null
                }
                $row[$names[$index]] = $value
            }
            $rows.Add([pscustomobject]$row)
        }
        return $rows.ToArray()
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        if ($null -ne $command) {
            $command.Dispose()
        }
        if ($null -ne $connection) {
            $connection.Dispose()
        }
    }
}

#endregion Local Power BI Desktop

#region DAX tests

function Get-PbiDaxTestFile {
    <#
    .SYNOPSIS
        Lists the DAX test files of a semantic model for a target.
    .DESCRIPTION
        Test files live in <Model>.SemanticModel/DAXQueries/ and are named <Name>.<SCOPE>.Tests.dax with SCOPE in ALL,
        LOCAL, DEV, TEST, PROD. Returns *.ALL.Tests.dax plus *.<scope>.Tests.dax (LOCAL for the Local target),
        sorted by name (ordinal).
    .PARAMETER SemanticModelPath
        The *.SemanticModel folder.
    .PARAMETER Target
        Local, DEV, TEST or PROD.
    .EXAMPLE
        Get-PbiDaxTestFile -SemanticModelPath $project.SemanticModelPath -Target Local
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SemanticModelPath,

        [Parameter(Mandatory)]
        [ValidateSet('Local', 'DEV', 'TEST', 'PROD')]
        [string] $Target
    )
    $directory = Join-Path $SemanticModelPath 'DAXQueries'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        return
    }
    $scope = $Target.ToUpperInvariant()
    if ($Target -eq 'Local') {
        $scope = 'LOCAL'
    }
    $pattern = '\.(ALL|' + $scope + ')\.Tests\.dax$'
    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -File)) {
        if ($file.Name -match $pattern) {
            $files.Add($file)
        }
    }
    $files.Sort([System.Comparison[System.IO.FileInfo]] {
            param($left, $right)
            return [string]::CompareOrdinal($left.Name, $right.Name)
        })
    return $files.ToArray()
}

function Get-PbiDaxTestDirective {
    <#
    .SYNOPSIS
        Reads the '// @role:' and '// @effectiveUserName:' directives at the top of a DAX test query.
    .DESCRIPTION
        Only the leading comment block is read (blank lines and '//' lines before the first DAX line). Directive names
        are case-insensitive; other '//' comments are ignored. Several roles may be given on several lines or
        comma-separated. Returns { Roles[], Role (comma-joined or $null), EffectiveUserName (or $null) }.
    .PARAMETER Query
        The DAX query text.
    .EXAMPLE
        $directive = Get-PbiDaxTestDirective -Query (Get-Content $file -Raw)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Query
    )
    $roles = [System.Collections.Generic.List[string]]::new()
    $effectiveUserName = $null
    foreach ($line in ($Query.TrimStart([char]0xFEFF) -split '\r?\n')) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0) {
            continue
        }
        if (-not $trimmed.StartsWith('//')) {
            break
        }
        $match = [regex]::Match($trimmed, '^//\s*@(?<name>role|effectiveUserName)\s*:\s*(?<value>.*?)\s*$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) {
            continue
        }
        $value = $match.Groups['value'].Value
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        if ($match.Groups['name'].Value -ieq 'role') {
            foreach ($roleName in ($value -split ',')) {
                if (-not [string]::IsNullOrWhiteSpace($roleName)) {
                    $roles.Add($roleName.Trim())
                }
            }
        } elseif ($null -eq $effectiveUserName) {
            $effectiveUserName = $value
        }
    }
    $role = $null
    if ($roles.Count -gt 0) {
        $role = $roles -join ','
    }
    [pscustomobject]@{
        Roles             = $roles.ToArray()
        Role              = $role
        EffectiveUserName = $effectiveUserName
    }
}

function New-PbiDaxTestResult {
    # Private: one DAX test result row.
    param(
        [string] $File,
        [string] $TestName,
        [AllowNull()] [object] $ExpectedValue = $null,
        [AllowNull()] [object] $ActualValue = $null,
        [bool] $Passed = $false,
        [int] $DurationMs = 0,
        [AllowNull()] [AllowEmptyString()] [string] $ErrorMessage = '',
        [switch] $SlowQuery,
        [switch] $Skipped
    )
    $status = 'Failed'
    if ($Skipped) {
        $status = 'Skipped'
    } elseif ($Passed -and $SlowQuery) {
        $status = 'Warning'
    } elseif ($Passed) {
        $status = 'Passed'
    }
    $errorText = $null
    if (-not [string]::IsNullOrEmpty($ErrorMessage)) {
        $errorText = $ErrorMessage
    }
    [pscustomobject]@{
        File          = $File
        TestName      = $TestName
        ExpectedValue = $ExpectedValue
        ActualValue   = $ActualValue
        Passed        = $Passed
        DurationMs    = $DurationMs
        Error         = $errorText
        SlowQuery     = [bool]$SlowQuery
        Skipped       = [bool]$Skipped
        Status        = $status
    }
}

function Invoke-PbiDaxTestSuite {
    <#
    .SYNOPSIS
        Runs the DAX test files of a semantic model against Power BI Desktop (Local) or a deployed model (DEV/TEST/PROD).
    .DESCRIPTION
        Each test file is ONE DAX query that returns the columns TestName, ExpectedValue, ActualValue and Passed.
        Returns one result per row: { File, TestName, ExpectedValue, ActualValue, Passed, DurationMs, Error, SlowQuery,
        Skipped, Status }. Passed is $true only for true / "True" / 1. A query error gives one failed result for the
        file. Files slower than -MaxDurationMs keep their Passed value and get SlowQuery = $true (Status Warning).
        Directives at the top of a file:
          // @role: <RoleName>                Local: Roles=<RoleName>; service targets: not supported, so the file
                                              gives one result with Skipped = $true (reported as Skipped, not Failed).
          // @effectiveUserName: <upn>        Local: EffectiveUserName=<upn>; service: impersonatedUserName.
    .PARAMETER SemanticModelPath
        The *.SemanticModel folder.
    .PARAMETER Target
        Local, DEV, TEST or PROD.
    .PARAMETER Port
        Local Analysis Services port (Target Local).
    .PARAMETER WorkspaceId
        Workspace id (service targets).
    .PARAMETER DatasetId
        Semantic model id (service targets).
    .PARAMETER MaxDurationMs
        Slow-query threshold (default 5000).
    .PARAMETER RepoRoot
        Repository root (used to locate ADOMD.NET).
    .EXAMPLE
        $results = @(Invoke-PbiDaxTestSuite -SemanticModelPath $model -Target Local -Port $desktop.Port)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SemanticModelPath,

        [Parameter(Mandatory)]
        [ValidateSet('Local', 'DEV', 'TEST', 'PROD')]
        [string] $Target,

        [int] $Port,

        [string] $WorkspaceId,

        [string] $DatasetId,

        [ValidateRange(0, 86400000)]
        [int] $MaxDurationMs = 5000,

        [string] $RepoRoot
    )
    if ($Target -eq 'Local') {
        if ($Port -le 0) {
            throw 'Target Local needs -Port (from Get-PbiDesktopInstance).'
        }
    } elseif ([string]::IsNullOrWhiteSpace($WorkspaceId) -or [string]::IsNullOrWhiteSpace($DatasetId)) {
        throw "Target $Target needs -WorkspaceId and -DatasetId."
    }
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-PbiDaxTestFile -SemanticModelPath $SemanticModelPath -Target $Target)) {
        $testName = $file.Name -replace '\.dax$', ''
        $query = Read-PbiTextFile -Path $file.FullName
        $directive = Get-PbiDaxTestDirective -Query $query
        if ($Target -ne 'Local' -and $null -ne $directive.Role) {
            $results.Add((New-PbiDaxTestResult -File $file.Name -TestName $testName -ErrorMessage 'role directive not supported on service target' -Skipped))
            Write-PbiWarning "$($file.Name) was skipped on $Target because '// @role:' cannot be evaluated through executeQueries. Use '// @effectiveUserName:' or run it against Power BI Desktop (Target Local)."
            continue
        }
        $rows = @()
        $queryError = $null
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            if ($Target -eq 'Local') {
                $localParameters = @{ Port = $Port; Query = $query }
                if ($null -ne $directive.Role) {
                    $localParameters.Role = $directive.Role
                }
                if ($null -ne $directive.EffectiveUserName) {
                    $localParameters.EffectiveUserName = $directive.EffectiveUserName
                }
                if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
                    $localParameters.RepoRoot = $RepoRoot
                }
                $rows = @(Invoke-PbiLocalDaxQuery @localParameters)
            } else {
                $serviceParameters = @{ WorkspaceId = $WorkspaceId; DatasetId = $DatasetId; Query = $query }
                if ($null -ne $directive.EffectiveUserName) {
                    $serviceParameters.ImpersonatedUserName = $directive.EffectiveUserName
                }
                $rows = @(Invoke-PbiDaxQuery @serviceParameters)
            }
        } catch {
            $queryError = Protect-PbiText -Text $_.Exception.Message
        }
        $stopwatch.Stop()
        $durationMs = [int]$stopwatch.ElapsedMilliseconds
        $slow = $durationMs -gt $MaxDurationMs
        if ($null -ne $queryError) {
            $results.Add((New-PbiDaxTestResult -File $file.Name -TestName $testName -DurationMs $durationMs -ErrorMessage $queryError -SlowQuery:$slow))
            continue
        }
        if ($rows.Count -eq 0) {
            $results.Add((New-PbiDaxTestResult -File $file.Name -TestName $testName -DurationMs $durationMs -ErrorMessage 'The test query returned no rows (expected the columns TestName, ExpectedValue, ActualValue and Passed).' -SlowQuery:$slow))
            continue
        }
        foreach ($row in $rows) {
            $resultParameters = @{
                File          = $file.Name
                TestName      = [string](Get-PbiProperty $row 'TestName' $testName)
                ExpectedValue = (Get-PbiProperty $row 'ExpectedValue')
                ActualValue   = (Get-PbiProperty $row 'ActualValue')
                Passed        = (Test-PbiTruthy -Value (Get-PbiProperty $row 'Passed'))
                DurationMs    = $durationMs
                SlowQuery     = $slow
            }
            $results.Add((New-PbiDaxTestResult @resultParameters))
        }
        if ($slow) {
            Write-PbiWarning "$($file.Name) took $durationMs ms (limit $MaxDurationMs ms)."
        }
    }
    return $results.ToArray()
}

#endregion DAX tests

#region Static checks

function New-PbiFinding {
    <#
    .SYNOPSIS
        Creates a check finding { Check; Severity; Path; Message }.
    .PARAMETER Check
        Check name (for example RepoHygiene).
    .PARAMETER Severity
        Error, Warning or Info.
    .PARAMETER Path
        Repository-relative path with forward slashes ('' when not file-specific).
    .PARAMETER Message
        What is wrong and what to do. Never include secrets or identifiers.
    .EXAMPLE
        New-PbiFinding -Check 'ModelBpa' -Severity Warning -Path 'src/Sales/Sales.SemanticModel' -Message 'Rule X violated.'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Check,

        [Parameter(Mandatory)]
        [ValidateSet('Error', 'Warning', 'Info')]
        [string] $Severity,

        [AllowEmptyString()]
        [string] $Path = '',

        [Parameter(Mandatory)]
        [string] $Message
    )
    [pscustomobject]@{
        Check    = $Check
        Severity = $Severity
        Path     = $Path
        Message  = $Message
    }
}

function Add-PbiFinding {
    # Private: appends a finding; absolute paths are converted to repository-relative paths.
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]] $List,

        [Parameter(Mandatory)]
        [string] $Check,

        [Parameter(Mandatory)]
        [string] $Severity,

        [AllowEmptyString()]
        [string] $Path = '',

        [Parameter(Mandatory)]
        [string] $Message,

        [string] $RepoRoot
    )
    $displayPath = $Path
    if (-not [string]::IsNullOrEmpty($Path) -and -not [string]::IsNullOrEmpty($RepoRoot) -and [System.IO.Path]::IsPathRooted($Path)) {
        $displayPath = Get-PbiRelativePath -Path $Path -RepoRoot $RepoRoot
    }
    $List.Add((New-PbiFinding -Check $Check -Severity $Severity -Path $displayPath -Message $Message))
}

function Resolve-PbiCheckRoot {
    # Private: repository root for a path, falling back to the given folder.
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [string] $RepoRoot
    )
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        return (Resolve-PbiFullPath -Path $RepoRoot)
    }
    try {
        return (Get-PbiRepoRoot -Path $Path)
    } catch {
        return (Resolve-PbiFullPath -Path $Path)
    }
}

function Get-PbiRepoFileList {
    # Private: repository-relative paths of tracked files (git ls-files), or of all files when Git is not available.
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )
    $gitAvailable = $null -ne (Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue)
    if ($gitAvailable -and (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) {
        $listing = Invoke-PbiGit -RepoRoot $RepoRoot -Arguments @('-c', 'core.quotepath=false', 'ls-files')
        if ($listing.ExitCode -eq 0) {
            foreach ($line in $listing.StdOut) {
                $trimmed = $line.Trim()
                if ($trimmed.Length -eq 0) {
                    continue
                }
                if ($trimmed.Length -ge 2 -and $trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) {
                    $trimmed = $trimmed.Substring(1, $trimmed.Length - 2)
                }
                $trimmed
            }
            return
        }
        Write-PbiWarning 'git ls-files failed; scanning all files instead.'
    }
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push('')
    while ($pending.Count -gt 0) {
        $relative = $pending.Pop()
        $folder = $RepoRoot
        if ($relative.Length -gt 0) {
            $folder = Join-Path $RepoRoot $relative
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue)) {
            $itemRelative = $item.Name
            if ($relative.Length -gt 0) {
                $itemRelative = $relative + '/' + $item.Name
            }
            if ($item.PSIsContainer) {
                if ($script:PbiWalkExclude -contains $itemRelative -or $item.Name -eq 'node_modules') {
                    continue
                }
                $pending.Push($itemRelative)
            } else {
                $itemRelative
            }
        }
    }
}

function Test-PbiRepoHygiene {
    <#
    .SYNOPSIS
        Scans tracked files for local-only files, secrets, identifiers and personal data.
    .DESCRIPTION
        Uses 'git ls-files' when the folder is a Git repository, otherwise all files except .git, tools/.bin,
        node_modules and .evidence.
        Errors:
          - tracked .pbi/localSettings.json, .pbi/cache.abf, .env files (except .env.example), *.pfx/.pem/.key/.publishsettings
          - GUIDs in config/, docs/, scripts/, .github/ and src/**/definition.pbir (except the all-zero GUID and lines
            that contain 'pbi-allow-guid')
          - 'semanticmodelid=' or 'powerbi://' in src/ (reports in Git must use byPath)
          - secrets: password/client_secret assignments, private keys, storage account keys
        Warnings: e-mail addresses in config/ or src/ (personal data).
        Content checks cover *.json, *.md, *.ps1, *.psm1, *.psd1, *.yml, *.yaml, *.tmdl, *.dax, *.pbir, *.pbism and
        *.txt files, skip tests/** fixtures, .platform files and 'lineageTag:' lines in src/**/*.tmdl.
    .PARAMETER RepoRoot
        Repository root.
    .EXAMPLE
        Test-PbiRepoHygiene -RepoRoot $root | Where-Object Severity -eq 'Error'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )
    $check = 'RepoHygiene'
    $root = Resolve-PbiFullPath -Path $RepoRoot
    $findings = [System.Collections.Generic.List[object]]::new()
    $textExtensions = @('.json', '.md', '.ps1', '.psm1', '.psd1', '.yml', '.yaml', '.tmdl', '.dax', '.pbir', '.pbism', '.txt')
    foreach ($relative in @(Get-PbiRepoFileList -RepoRoot $root)) {
        $fileName = [System.IO.Path]::GetFileName($relative)
        if ($relative -match '\.pbi/localSettings\.json$' -or $relative -match '\.pbi/cache\.abf$') {
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $relative -Message 'Local Power BI Desktop file is tracked. Remove it from Git (git rm --cached <file>); .gitignore must keep .pbi/localSettings.json and .pbi/cache.abf out.'
        } elseif ($relative -match '\.env(\..*)?$' -and $fileName -ne '.env.example') {
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $relative -Message 'Environment/secret file is tracked. Remove it from Git (git rm --cached <file>) and keep only .env.example in the repository.'
        } elseif ($relative -match '\.(pfx|pem|key|publishsettings)$') {
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $relative -Message 'Certificate/key file is tracked. Remove it from Git, rotate the credential and keep certificates in a certificate store or key vault.'
        }
        if ($relative.StartsWith('tests/') -or $fileName -eq '.platform') {
            continue
        }
        $extension = [System.IO.Path]::GetExtension($relative).ToLowerInvariant()
        if ($textExtensions -notcontains $extension) {
            continue
        }
        $fullPath = Join-Path $root $relative
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            continue
        }
        if ((Get-Item -LiteralPath $fullPath).Length -gt 5MB) {
            continue
        }
        $lines = [System.IO.File]::ReadAllLines($fullPath)
        $inSource = $relative.StartsWith('src/')
        $guidScope = ($relative -match '^(config|docs|scripts|\.github)/') -or ($inSource -and $fileName -eq 'definition.pbir')
        $emailScope = $relative -match '^(config|src)/'
        $skipLineageLines = $inSource -and $extension -eq '.tmdl'
        $emailLines = [System.Collections.Generic.List[int]]::new()
        for ($index = 0; $index -lt $lines.Length; $index++) {
            $line = $lines[$index]
            $lineNumber = $index + 1
            if ($skipLineageLines -and $line.Contains('lineageTag:')) {
                continue
            }
            if ($guidScope -and -not $line.Contains('pbi-allow-guid')) {
                foreach ($guidMatch in [regex]::Matches($line, $script:PbiGuidPattern)) {
                    if ($guidMatch.Value -ne $script:PbiZeroGuid) {
                        Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $relative -Message ('Line {0}: identifier in tracked file (GUID). Replace it with a ${{env:NAME}} placeholder or keep it in a git-ignored *.local.json; add pbi-allow-guid to the line only for non-sensitive ids.' -f $lineNumber)
                        break
                    }
                }
            }
            if ($inSource -and ($line -match '(?i)semanticmodelid=' -or $line -match '(?i)powerbi://')) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $relative -Message ('Line {0}: service connection in source. Reports in Git must reference their model with datasetReference.byPath; byConnection is written only at deploy time.' -f $lineNumber)
            }
            foreach ($secretPattern in $script:PbiSecretPatterns) {
                if ([regex]::IsMatch($line, $secretPattern)) {
                    Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $relative -Message ('Line {0}: possible secret (password, client secret, private key or account key). Remove it, rotate the credential and use environment variables or a key vault.' -f $lineNumber)
                    break
                }
            }
            if ($emailScope -and [regex]::IsMatch($line, $script:PbiEmailPattern)) {
                $emailLines.Add($lineNumber)
            }
        }
        if ($emailLines.Count -gt 0) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Warning' -Path $relative -Message ('Line(s) {0}: e-mail address (personal data). Use group ids via environment variables, or synthetic test users (contoso.com) in tests only.' -f ($emailLines -join ', '))
        }
    }
    return $findings.ToArray()
}

function ConvertTo-PbiIndentWidth {
    # Private: indentation width of a line (tab = 4, space = 1).
    param(
        [AllowEmptyString()]
        [string] $Line
    )
    $width = 0
    foreach ($character in $Line.ToCharArray()) {
        if ($character -eq "`t") {
            $width += 4
        } elseif ($character -eq ' ') {
            $width += 1
        } else {
            break
        }
    }
    return $width
}

function ConvertFrom-PbiTmdlName {
    # Private: TMDL object name without quotes ('A B' -> A B, 'It''s' -> It's).
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )
    $trimmed = $Name.Trim()
    if ($trimmed.Length -ge 2 -and $trimmed.StartsWith("'") -and $trimmed.EndsWith("'")) {
        return $trimmed.Substring(1, $trimmed.Length - 2).Replace("''", "'")
    }
    return $trimmed
}

function Test-PbipProjectStructure {
    <#
    .SYNOPSIS
        Validates the folder structure of a PBIP project (TMDL semantic models and PBIR reports).
    .DESCRIPTION
        For each *.SemanticModel: definition.pbism parses with version >= 4.0; definition/database.tmdl and
        definition/model.tmdl exist; at least one definition/tables/*.tmdl.
        For each *.Report: definition.pbir parses and datasetReference.byPath.path resolves to a folder; definition/
        version.json, report.json and pages/pages.json exist and parse; every page folder has page.json; every visual
        folder has visual.json; pages.json pageOrder entries exist; every JSON file under definition/ (and
        definition.pbir) has a Fabric $schema (warning otherwise).
        A .pbip file (when present) must parse and its artifacts[].report.path must exist.
        A semantic model without a report gives a warning (scaffold it with scripts/build/New-PbipReport.ps1).
    .PARAMETER ProjectPath
        The project folder (src/<Name>).
    .PARAMETER RepoRoot
        Repository root (used for relative paths in findings).
    .EXAMPLE
        Test-PbipProjectStructure -ProjectPath 'src/SalesStarter'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ProjectPath,

        [string] $RepoRoot
    )
    $check = 'PbipStructure'
    $project = Resolve-PbiFullPath -Path $ProjectPath
    $root = Resolve-PbiCheckRoot -Path $project -RepoRoot $RepoRoot
    $findings = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $project -PathType Container)) {
        Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $project -RepoRoot $root -Message 'Project folder not found.'
        return $findings.ToArray()
    }
    $models = @(Get-ChildItem -LiteralPath $project -Directory -Filter '*.SemanticModel')
    $reports = @(Get-ChildItem -LiteralPath $project -Directory -Filter '*.Report')
    if ($models.Count -eq 0 -and $reports.Count -eq 0) {
        Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $project -RepoRoot $root -Message 'No *.SemanticModel or *.Report folder found. Create projects with scripts/build/New-PbipProject.ps1.'
    }
    foreach ($model in $models) {
        $pbismPath = Join-Path $model.FullName 'definition.pbism'
        $pbism = Read-PbiJsonSafe -Path $pbismPath
        if (-not $pbism.Exists) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $model.FullName -RepoRoot $root -Message 'definition.pbism is missing.'
        } elseif (-not $pbism.Ok) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $pbismPath -RepoRoot $root -Message "definition.pbism is not valid JSON: $($pbism.Error)"
        } else {
            $versionText = [string](Get-PbiProperty $pbism.Value 'version' '')
            $version = ConvertTo-PbiVersion -Text $versionText
            if ($null -eq $version -or $version -lt [version]'4.0') {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $pbismPath -RepoRoot $root -Message "definition.pbism version must be 4.0 or later (TMDL format); found '$versionText'. Save the model with the TMDL format enabled."
            }
        }
        foreach ($required in @('definition/database.tmdl', 'definition/model.tmdl')) {
            if (-not (Test-Path -LiteralPath (Join-Path $model.FullName $required) -PathType Leaf)) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $model.FullName -RepoRoot $root -Message "$required is missing (the model must be saved in TMDL format)."
            }
        }
        $tablesDirectory = Join-Path $model.FullName 'definition' 'tables'
        $tableFiles = @()
        if (Test-Path -LiteralPath $tablesDirectory -PathType Container) {
            $tableFiles = @(Get-ChildItem -LiteralPath $tablesDirectory -File -Filter '*.tmdl')
        }
        if ($tableFiles.Count -eq 0) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $model.FullName -RepoRoot $root -Message 'definition/tables contains no *.tmdl table file.'
        }
    }
    foreach ($report in $reports) {
        $reported = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $pbirPath = Join-Path $report.FullName 'definition.pbir'
        $pbir = Read-PbiJsonSafe -Path $pbirPath
        if (-not $pbir.Exists) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $report.FullName -RepoRoot $root -Message 'definition.pbir is missing.'
        } elseif (-not $pbir.Ok) {
            $null = $reported.Add($pbirPath)
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $pbirPath -RepoRoot $root -Message "definition.pbir is not valid JSON: $($pbir.Error)"
        } else {
            $byPath = [string](Get-PbiProperty (Get-PbiProperty (Get-PbiProperty $pbir.Value 'datasetReference') 'byPath') 'path' '')
            if ([string]::IsNullOrWhiteSpace($byPath)) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $pbirPath -RepoRoot $root -Message 'definition.pbir must reference its semantic model with datasetReference.byPath.path (byConnection is written only at deploy time).'
            } elseif (-not (Test-Path -LiteralPath (Join-Path $report.FullName $byPath) -PathType Container)) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $pbirPath -RepoRoot $root -Message "datasetReference.byPath.path '$byPath' does not resolve to a folder next to the report."
            }
        }
        foreach ($required in @('definition/version.json', 'definition/report.json', 'definition/pages/pages.json')) {
            $requiredPath = Join-Path $report.FullName $required
            $parsed = Read-PbiJsonSafe -Path $requiredPath
            if (-not $parsed.Exists) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $report.FullName -RepoRoot $root -Message "$required is missing (the report must be saved in the PBIR format)."
            } elseif (-not $parsed.Ok) {
                $null = $reported.Add((Resolve-PbiFullPath -Path $requiredPath))
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $requiredPath -RepoRoot $root -Message "$required is not valid JSON: $($parsed.Error)"
            }
        }
        $pagesDirectory = Join-Path $report.FullName 'definition' 'pages'
        if (Test-Path -LiteralPath $pagesDirectory -PathType Container) {
            foreach ($pageFolder in @(Get-ChildItem -LiteralPath $pagesDirectory -Directory)) {
                if (-not (Test-Path -LiteralPath (Join-Path $pageFolder.FullName 'page.json') -PathType Leaf)) {
                    Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $pageFolder.FullName -RepoRoot $root -Message "Page folder '$($pageFolder.Name)' has no page.json."
                }
                $visualsDirectory = Join-Path $pageFolder.FullName 'visuals'
                if (Test-Path -LiteralPath $visualsDirectory -PathType Container) {
                    foreach ($visualFolder in @(Get-ChildItem -LiteralPath $visualsDirectory -Directory)) {
                        if (-not (Test-Path -LiteralPath (Join-Path $visualFolder.FullName 'visual.json') -PathType Leaf)) {
                            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $visualFolder.FullName -RepoRoot $root -Message "Visual folder '$($visualFolder.Name)' has no visual.json."
                        }
                    }
                }
            }
            $pagesJson = Read-PbiJsonSafe -Path (Join-Path $pagesDirectory 'pages.json')
            if ($pagesJson.Ok) {
                foreach ($pageName in @(Get-PbiProperty $pagesJson.Value 'pageOrder')) {
                    if (-not (Test-Path -LiteralPath (Join-Path $pagesDirectory ([string]$pageName)) -PathType Container)) {
                        Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path (Join-Path $pagesDirectory 'pages.json') -RepoRoot $root -Message "pages.json pageOrder entry '$pageName' has no page folder."
                    }
                }
            }
        }
        $jsonFiles = [System.Collections.Generic.List[string]]::new()
        if (Test-Path -LiteralPath $pbirPath -PathType Leaf) {
            $jsonFiles.Add((Resolve-PbiFullPath -Path $pbirPath))
        }
        $definitionDirectory = Join-Path $report.FullName 'definition'
        if (Test-Path -LiteralPath $definitionDirectory -PathType Container) {
            foreach ($jsonFile in @(Get-ChildItem -LiteralPath $definitionDirectory -Recurse -File -Filter '*.json')) {
                $jsonFiles.Add($jsonFile.FullName)
            }
        }
        foreach ($jsonPath in $jsonFiles) {
            if ($reported.Contains($jsonPath)) {
                continue
            }
            $parsed = Read-PbiJsonSafe -Path $jsonPath
            if (-not $parsed.Ok) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $jsonPath -RepoRoot $root -Message "Not valid JSON: $($parsed.Error)"
                continue
            }
            $schemaUrl = [string](Get-PbiProperty $parsed.Value '$schema' '')
            if (-not $schemaUrl.StartsWith('https://developer.microsoft.com/json-schemas/fabric/', [System.StringComparison]::OrdinalIgnoreCase)) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Warning' -Path $jsonPath -RepoRoot $root -Message 'Missing or non-Fabric $schema (expected https://developer.microsoft.com/json-schemas/fabric/...). Keep the $schema written by Power BI Desktop or the report CLI.'
            }
        }
    }
    foreach ($pbipFile in @(Get-ChildItem -LiteralPath $project -File -Filter '*.pbip')) {
        $pbip = Read-PbiJsonSafe -Path $pbipFile.FullName
        if (-not $pbip.Ok) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $pbipFile.FullName -RepoRoot $root -Message "The .pbip file is not valid JSON: $($pbip.Error)"
            continue
        }
        foreach ($artifact in @(Get-PbiProperty $pbip.Value 'artifacts')) {
            $artifactPath = [string](Get-PbiProperty (Get-PbiProperty $artifact 'report') 'path' '')
            if (-not [string]::IsNullOrWhiteSpace($artifactPath) -and -not (Test-Path -LiteralPath (Join-Path $project $artifactPath) -PathType Container)) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $pbipFile.FullName -RepoRoot $root -Message "artifacts[].report.path '$artifactPath' does not exist."
            }
        }
    }
    if ($models.Count -gt 0 -and $reports.Count -eq 0) {
        Add-PbiFinding -List $findings -Check $check -Severity 'Warning' -Path $project -RepoRoot $root -Message 'Report not scaffolded yet - run scripts/build/New-PbipReport.ps1.'
    }
    return $findings.ToArray()
}

function Test-PbiTmdlConvention {
    <#
    .SYNOPSIS
        Checks TMDL conventions of a semantic model (line-based, offline).
    .DESCRIPTION
        - every 'ref table X' in model.tmdl has tables/X.tmdl (Error) and every table file is referenced (Warning);
        - indentation uses tabs (lines starting with 4+ spaces outside ``` blocks: Warning);
        - every measure has formatString (or formatStringDefinition) in its block (Error);
        - every measure has a /// description line immediately above it (Warning);
        - database.tmdl starts with 'database' (Error) and has compatibilityLevel >= 1600 (Error);
        - no duplicate lineageTag values (Error).
    .PARAMETER SemanticModelPath
        The *.SemanticModel folder.
    .PARAMETER RepoRoot
        Repository root (used for relative paths in findings).
    .EXAMPLE
        Test-PbiTmdlConvention -SemanticModelPath 'src/SalesStarter/SalesStarter.SemanticModel'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SemanticModelPath,

        [string] $RepoRoot
    )
    $check = 'TmdlConventions'
    $modelRoot = Resolve-PbiFullPath -Path $SemanticModelPath
    $root = Resolve-PbiCheckRoot -Path $modelRoot -RepoRoot $RepoRoot
    $findings = [System.Collections.Generic.List[object]]::new()
    $definition = Join-Path $modelRoot 'definition'
    if (-not (Test-Path -LiteralPath $definition -PathType Container)) {
        Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $modelRoot -RepoRoot $root -Message 'definition folder not found (the model must be saved in TMDL format).'
        return $findings.ToArray()
    }

    $modelFile = Join-Path $definition 'model.tmdl'
    $referenced = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $modelFile -PathType Leaf) {
        foreach ($line in [System.IO.File]::ReadAllLines($modelFile)) {
            $refMatch = [regex]::Match($line, '^\s*ref\s+table\s+(?<name>''(?:[^'']|'''')*''|\S+)\s*$')
            if ($refMatch.Success) {
                $null = $referenced.Add((ConvertFrom-PbiTmdlName -Name $refMatch.Groups['name'].Value))
            }
        }
    }
    $tableNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $tablesDirectory = Join-Path $definition 'tables'
    if (Test-Path -LiteralPath $tablesDirectory -PathType Container) {
        foreach ($tableFile in @(Get-ChildItem -LiteralPath $tablesDirectory -File -Filter '*.tmdl')) {
            $null = $tableNames.Add($tableFile.BaseName)
        }
    }
    foreach ($name in $referenced) {
        if (-not $tableNames.Contains($name)) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $modelFile -RepoRoot $root -Message "model.tmdl references table '$name' but definition/tables/$name.tmdl does not exist."
        }
    }
    foreach ($name in $tableNames) {
        if (-not $referenced.Contains($name)) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Warning' -Path (Join-Path $tablesDirectory "$name.tmdl") -RepoRoot $root -Message "Table file is not referenced by a 'ref table' line in model.tmdl."
        }
    }

    $lineageTags = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $definition -Recurse -File -Filter '*.tmdl')) {
        $relative = Get-PbiRelativePath -Path $file.FullName -RepoRoot $root
        $lines = [System.IO.File]::ReadAllLines($file.FullName)
        $inBlock = $false
        $spaceIndented = 0
        $firstSpaceLine = 0
        $measure = $null
        for ($index = 0; $index -lt $lines.Length; $index++) {
            $line = $lines[$index]
            $lineNumber = $index + 1
            $trimmed = $line.Trim()
            if ($inBlock) {
                if ($trimmed -eq '```') {
                    $inBlock = $false
                }
                continue
            }
            if ($trimmed.Length -eq 0) {
                continue
            }
            if ($line -match '^ {4,}') {
                $spaceIndented++
                if ($firstSpaceLine -eq 0) {
                    $firstSpaceLine = $lineNumber
                }
            }
            $indent = ConvertTo-PbiIndentWidth -Line $line
            if ($null -ne $measure -and $indent -le $measure.Indent) {
                if (-not $measure.HasFormat) {
                    Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $relative -Message ("Line {0}: measure {1} has no formatString. Add 'formatString: <format>' to the measure." -f $measure.Line, $measure.Name)
                }
                $measure = $null
            }
            $measureMatch = [regex]::Match($line, '^\s*measure\s+(?<name>''(?:[^'']|'''')*''|[^\s=]+)')
            if ($measureMatch.Success) {
                $measure = @{
                    Name      = $measureMatch.Groups['name'].Value
                    Indent    = $indent
                    Line      = $lineNumber
                    HasFormat = $false
                }
                $hasDescription = ($index -gt 0) -and $lines[$index - 1].Trim().StartsWith('///')
                if (-not $hasDescription) {
                    Add-PbiFinding -List $findings -Check $check -Severity 'Warning' -Path $relative -Message ("Line {0}: measure {1} has no /// description line immediately above it." -f $lineNumber, $measure.Name)
                }
            } elseif ($null -ne $measure -and ($trimmed -match '^formatString\s*:' -or $trimmed -match '^formatStringDefinition\b')) {
                $measure.HasFormat = $true
            }
            $tagMatch = [regex]::Match($line, '^\s*lineageTag:\s*(?<tag>\S+)')
            if ($tagMatch.Success) {
                $tag = $tagMatch.Groups['tag'].Value
                if (-not $lineageTags.ContainsKey($tag)) {
                    $lineageTags[$tag] = [System.Collections.Generic.List[string]]::new()
                }
                $lineageTags[$tag].Add("${relative}:$lineNumber")
            }
            if ($trimmed.EndsWith('```')) {
                $inBlock = $true
            }
        }
        if ($null -ne $measure -and -not $measure.HasFormat) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $relative -Message ("Line {0}: measure {1} has no formatString. Add 'formatString: <format>' to the measure." -f $measure.Line, $measure.Name)
        }
        if ($spaceIndented -gt 0) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Warning' -Path $relative -Message ("{0} line(s) are indented with spaces (first at line {1}); TMDL uses tabs." -f $spaceIndented, $firstSpaceLine)
        }
    }

    $databaseFile = Join-Path $definition 'database.tmdl'
    if (Test-Path -LiteralPath $databaseFile -PathType Leaf) {
        $databaseLines = @([System.IO.File]::ReadAllLines($databaseFile))
        $firstLine = $databaseLines | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -First 1
        if ($null -eq $firstLine -or $firstLine.Trim() -notmatch '^database(\s|$)') {
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $databaseFile -RepoRoot $root -Message "database.tmdl must start with 'database <name>'."
        }
        $level = $null
        foreach ($line in $databaseLines) {
            $levelMatch = [regex]::Match($line, '^\s*compatibilityLevel:\s*(?<level>\d+)')
            if ($levelMatch.Success) {
                $level = [int]$levelMatch.Groups['level'].Value
                break
            }
        }
        if ($null -eq $level) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $databaseFile -RepoRoot $root -Message 'database.tmdl has no compatibilityLevel (1600 or later is required).'
        } elseif ($level -lt 1600) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $databaseFile -RepoRoot $root -Message "compatibilityLevel is $level; 1600 or later is required. Save the model with a current Power BI Desktop."
        }
    }

    foreach ($tag in @($lineageTags.Keys)) {
        $locations = $lineageTags[$tag]
        if ($locations.Count -gt 1) {
            $firstPath = ($locations[0] -split ':')[0]
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $firstPath -Message ("lineageTag <id> is used {0} times ({1}). Every object needs a unique lineageTag; remove the duplicates and let Power BI Desktop generate new ones." -f $locations.Count, ($locations -join ', '))
        }
    }
    return $findings.ToArray()
}

function Test-PbiReportConvention {
    <#
    .SYNOPSIS
        Checks report conventions of a PBIR report (offline).
    .DESCRIPTION
        Info: number of pages; visuals without a title. Warnings: more visuals on a page than
        thresholds.reportMaxVisualsPerPage; visuals without alt text (accessibility); visuals whose rectangles overlap
        by more than 10% of the smaller one; legacy 'card'/'multiRowCard' (use cardVisual); 'map', 'filledMap' and
        'qnaVisual' visuals.
    .PARAMETER ReportPath
        The *.Report folder.
    .PARAMETER Gate
        Gate configuration from Get-PbiGateConfig.
    .PARAMETER RepoRoot
        Repository root (used for relative paths in findings).
    .EXAMPLE
        Test-PbiReportConvention -ReportPath 'src/SalesStarter/SalesStarter.Report' -Gate (Get-PbiGateConfig)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ReportPath,

        [Parameter(Mandatory)]
        [object] $Gate,

        [string] $RepoRoot
    )
    $check = 'ReportConventions'
    $reportRoot = Resolve-PbiFullPath -Path $ReportPath
    $root = Resolve-PbiCheckRoot -Path $reportRoot -RepoRoot $RepoRoot
    $findings = [System.Collections.Generic.List[object]]::new()
    $maxVisuals = [int](Get-PbiProperty (Get-PbiProperty $Gate 'thresholds') 'reportMaxVisualsPerPage' 20)
    $pagesDirectory = Join-Path $reportRoot 'definition' 'pages'
    if (-not (Test-Path -LiteralPath $pagesDirectory -PathType Container)) {
        Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $reportRoot -RepoRoot $root -Message 'definition/pages not found (the report must be saved in the PBIR format).'
        return $findings.ToArray()
    }
    $pageFolders = @(Get-ChildItem -LiteralPath $pagesDirectory -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'page.json') -PathType Leaf })
    Add-PbiFinding -List $findings -Check $check -Severity 'Info' -Path $reportRoot -RepoRoot $root -Message "Report has $($pageFolders.Count) page(s)."
    foreach ($page in $pageFolders) {
        $pageJson = Read-PbiJsonSafe -Path (Join-Path $page.FullName 'page.json')
        $pageName = [string](Get-PbiProperty $pageJson.Value 'displayName' $page.Name)
        $visuals = [System.Collections.Generic.List[object]]::new()
        $visualsDirectory = Join-Path $page.FullName 'visuals'
        if (Test-Path -LiteralPath $visualsDirectory -PathType Container) {
            foreach ($visualFolder in @(Get-ChildItem -LiteralPath $visualsDirectory -Directory)) {
                $visualFile = Join-Path $visualFolder.FullName 'visual.json'
                $parsed = Read-PbiJsonSafe -Path $visualFile
                if (-not $parsed.Ok) {
                    continue
                }
                $container = $parsed.Value
                $visual = Get-PbiProperty $container 'visual'
                if ($null -eq $visual) {
                    continue
                }
                $relative = Get-PbiRelativePath -Path $visualFile -RepoRoot $root
                $type = [string](Get-PbiProperty $visual 'visualType' '')
                $label = "Visual '$type' on page '$pageName'"
                $containerObjects = Get-PbiProperty $visual 'visualContainerObjects'
                $objects = Get-PbiProperty $visual 'objects'
                if ($null -eq (Get-PbiProperty $containerObjects 'title') -and $null -eq (Get-PbiProperty $objects 'title')) {
                    Add-PbiFinding -List $findings -Check $check -Severity 'Info' -Path $relative -Message "$label has no title."
                }
                $hasAltText = $false
                foreach ($general in @(Get-PbiProperty $containerObjects 'general')) {
                    if ($null -ne (Get-PbiProperty (Get-PbiProperty $general 'properties') 'altText')) {
                        $hasAltText = $true
                    }
                }
                if (-not $hasAltText) {
                    Add-PbiFinding -List $findings -Check $check -Severity 'Warning' -Path $relative -Message "$label has no alt text (accessibility). Add visualContainerObjects.general[].properties.altText."
                }
                if (@('card', 'multiRowCard') -contains $type) {
                    Add-PbiFinding -List $findings -Check $check -Severity 'Warning' -Path $relative -Message "$label uses the legacy visual type '$type'; use cardVisual."
                }
                if (@('map', 'filledMap', 'qnaVisual') -contains $type) {
                    Add-PbiFinding -List $findings -Check $check -Severity 'Warning' -Path $relative -Message "$label uses the deprecated visual type '$type'; use azureMap or another supported visual."
                }
                $position = Get-PbiProperty $container 'position'
                $visuals.Add([pscustomobject]@{
                        Path   = $relative
                        Label  = $label
                        X      = [double](Get-PbiProperty $position 'x' 0)
                        Y      = [double](Get-PbiProperty $position 'y' 0)
                        Width  = [double](Get-PbiProperty $position 'width' 0)
                        Height = [double](Get-PbiProperty $position 'height' 0)
                    })
            }
        }
        if ($visuals.Count -gt $maxVisuals) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Warning' -Path $page.FullName -RepoRoot $root -Message "Page '$pageName' has $($visuals.Count) visuals (limit $maxVisuals). Split the page or use drill-through/tooltips."
        }
        for ($first = 0; $first -lt $visuals.Count; $first++) {
            for ($second = $first + 1; $second -lt $visuals.Count; $second++) {
                $one = $visuals[$first]
                $two = $visuals[$second]
                $overlapWidth = [Math]::Min($one.X + $one.Width, $two.X + $two.Width) - [Math]::Max($one.X, $two.X)
                $overlapHeight = [Math]::Min($one.Y + $one.Height, $two.Y + $two.Height) - [Math]::Max($one.Y, $two.Y)
                if ($overlapWidth -le 0 -or $overlapHeight -le 0) {
                    continue
                }
                $smallerArea = [Math]::Min($one.Width * $one.Height, $two.Width * $two.Height)
                if ($smallerArea -le 0) {
                    continue
                }
                if (($overlapWidth * $overlapHeight) -gt (0.1 * $smallerArea)) {
                    Add-PbiFinding -List $findings -Check $check -Severity 'Warning' -Path $one.Path -Message "$($one.Label) overlaps $($two.Label) ($($two.Path)). Move or resize one of them."
                }
            }
        }
    }
    return $findings.ToArray()
}

function Get-PbiFrontMatter {
    # Private: simple YAML front matter (text between the first two '---' lines; top-level 'key: value' lines only).
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )
    $lines = @((Read-PbiTextFile -Path $Path) -split '\r?\n')
    if ($lines.Count -eq 0 -or $lines[0].Trim() -ne '---') {
        return $null
    }
    $end = -1
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Trim() -eq '---') {
            $end = $index
            break
        }
    }
    if ($end -lt 0) {
        return $null
    }
    $result = [ordered]@{}
    $index = 1
    while ($index -lt $end) {
        $match = [regex]::Match($lines[$index], '^(?<key>[A-Za-z0-9_-]+)\s*:\s*(?<value>.*)$')
        if (-not $match.Success) {
            $index++
            continue
        }
        $key = $match.Groups['key'].Value
        $value = $match.Groups['value'].Value.Trim()
        $index++
        if ($value -match '^[|>][+-]?$') {
            $block = [System.Collections.Generic.List[string]]::new()
            while ($index -lt $end -and ($lines[$index] -match '^\s+\S' -or $lines[$index].Trim().Length -eq 0)) {
                $block.Add($lines[$index].Trim())
                $index++
            }
            $separator = ' '
            if ($value.StartsWith('|')) {
                $separator = "`n"
            }
            $value = (@($block | Where-Object { $_.Length -gt 0 }) -join $separator).Trim()
        } elseif ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $result[$key] = $value
    }
    return [pscustomobject]$result
}

function Test-PbiAgentAsset {
    <#
    .SYNOPSIS
        Lints the GitHub Copilot agent assets in .github/ (skills, custom agents, instructions, hooks).
    .DESCRIPTION
        - .github/skills/*/SKILL.md: YAML front matter; 'name' equals the folder name and matches ^[a-z0-9][a-z0-9-]{0,63}$;
          'description' present and at most 1024 characters.
        - .github/agents/*.agent.md: front matter with 'description'.
        - .github/instructions/*.instructions.md: front matter with 'applyTo'.
        - .github/hooks/*.json: valid JSON with "version": 1.
    .PARAMETER RepoRoot
        Repository root.
    .EXAMPLE
        Test-PbiAgentAsset -RepoRoot $root
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )
    $check = 'AgentAssets'
    $root = Resolve-PbiFullPath -Path $RepoRoot
    $findings = [System.Collections.Generic.List[object]]::new()
    $github = Join-Path $root '.github'
    $skillsDirectory = Join-Path $github 'skills'
    if (Test-Path -LiteralPath $skillsDirectory -PathType Container) {
        foreach ($skillFolder in @(Get-ChildItem -LiteralPath $skillsDirectory -Directory)) {
            $skillFile = Join-Path $skillFolder.FullName 'SKILL.md'
            if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Warning' -Path $skillFolder.FullName -RepoRoot $root -Message 'Skill folder has no SKILL.md.'
                continue
            }
            $frontMatter = Get-PbiFrontMatter -Path $skillFile
            if ($null -eq $frontMatter) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $skillFile -RepoRoot $root -Message 'SKILL.md has no YAML front matter (--- name/description ---).'
                continue
            }
            $name = [string](Get-PbiProperty $frontMatter 'name' '')
            if ([string]::IsNullOrWhiteSpace($name)) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $skillFile -RepoRoot $root -Message "Front matter 'name' is missing."
            } else {
                if ($name -cne $skillFolder.Name) {
                    Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $skillFile -RepoRoot $root -Message "Front matter name '$name' must equal the folder name '$($skillFolder.Name)'."
                }
                if ($name -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') {
                    Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $skillFile -RepoRoot $root -Message ("Skill name '$name' must use lowercase letters, digits and hyphens (" + '^[a-z0-9][a-z0-9-]{0,63}$' + ').')
                }
            }
            $description = [string](Get-PbiProperty $frontMatter 'description' '')
            if ([string]::IsNullOrWhiteSpace($description)) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $skillFile -RepoRoot $root -Message "Front matter 'description' is missing (it tells the agent when to use the skill)."
            } elseif ($description.Length -gt 1024) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $skillFile -RepoRoot $root -Message "Description has $($description.Length) characters; the limit is 1024."
            }
        }
    }
    $agentsDirectory = Join-Path $github 'agents'
    if (Test-Path -LiteralPath $agentsDirectory -PathType Container) {
        foreach ($agentFile in @(Get-ChildItem -LiteralPath $agentsDirectory -File -Filter '*.agent.md')) {
            $frontMatter = Get-PbiFrontMatter -Path $agentFile.FullName
            if ([string]::IsNullOrWhiteSpace([string](Get-PbiProperty $frontMatter 'description' ''))) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $agentFile.FullName -RepoRoot $root -Message "Custom agent needs YAML front matter with 'description'."
            }
        }
    }
    $instructionsDirectory = Join-Path $github 'instructions'
    if (Test-Path -LiteralPath $instructionsDirectory -PathType Container) {
        foreach ($instructionFile in @(Get-ChildItem -LiteralPath $instructionsDirectory -File -Filter '*.instructions.md')) {
            $frontMatter = Get-PbiFrontMatter -Path $instructionFile.FullName
            if ([string]::IsNullOrWhiteSpace([string](Get-PbiProperty $frontMatter 'applyTo' ''))) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $instructionFile.FullName -RepoRoot $root -Message "Instructions file needs YAML front matter with 'applyTo' (a glob)."
            }
        }
    }
    $hooksDirectory = Join-Path $github 'hooks'
    if (Test-Path -LiteralPath $hooksDirectory -PathType Container) {
        foreach ($hookFile in @(Get-ChildItem -LiteralPath $hooksDirectory -File -Filter '*.json')) {
            $parsed = Read-PbiJsonSafe -Path $hookFile.FullName
            if (-not $parsed.Ok) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $hookFile.FullName -RepoRoot $root -Message "Hook configuration is not valid JSON: $($parsed.Error)"
                continue
            }
            $version = Get-PbiProperty $parsed.Value 'version'
            if ($null -eq $version -or [string]$version -ne '1') {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $hookFile.FullName -RepoRoot $root -Message 'Hook configuration must have "version": 1.'
            }
        }
    }
    return $findings.ToArray()
}

function Test-PbiLocalMcpServer {
    # Private: $true for stdio/local MCP servers.
    param(
        [AllowNull()]
        [object] $Server
    )
    $type = [string](Get-PbiProperty $Server 'type' '')
    if ($type -eq 'stdio' -or $type -eq 'local') {
        return $true
    }
    return ([string]::IsNullOrEmpty($type) -and $null -ne (Get-PbiProperty $Server 'command'))
}

function Test-PbiMcpConfigParity {
    <#
    .SYNOPSIS
        Compares the MCP servers of VS Code (.vscode/mcp.json 'servers') and Copilot CLI (.github/mcp.json 'mcpServers').
    .DESCRIPTION
        Ignores 'github' (built into Copilot CLI). Every other server must exist in both files (Warning otherwise) and
        local/stdio servers must have identical 'args' arrays (Warning otherwise). Comments in the JSON files are
        tolerated.
    .PARAMETER RepoRoot
        Repository root.
    .EXAMPLE
        Test-PbiMcpConfigParity -RepoRoot $root
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )
    $check = 'McpParity'
    $root = Resolve-PbiFullPath -Path $RepoRoot
    $findings = [System.Collections.Generic.List[object]]::new()
    $vscodePath = Join-Path $root '.vscode' 'mcp.json'
    $cliPath = Join-Path $root '.github' 'mcp.json'
    $vscode = Read-PbiJsonSafe -Path $vscodePath -AllowComments
    $cli = Read-PbiJsonSafe -Path $cliPath -AllowComments
    if (-not $vscode.Exists -and -not $cli.Exists) {
        Add-PbiFinding -List $findings -Check $check -Severity 'Info' -Path '' -Message 'No MCP configuration found (.vscode/mcp.json, .github/mcp.json).'
        return $findings.ToArray()
    }
    foreach ($pair in @(@{ File = $vscode; Path = '.vscode/mcp.json' }, @{ File = $cli; Path = '.github/mcp.json' })) {
        if (-not $pair.File.Exists) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Warning' -Path $pair.Path -Message 'File is missing; VS Code and Copilot CLI should configure the same MCP servers.'
        } elseif (-not $pair.File.Ok) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $pair.Path -Message "Not valid JSON: $($pair.File.Error)"
        }
    }
    if (-not ($vscode.Ok -and $cli.Ok)) {
        return $findings.ToArray()
    }
    $vscodeServers = Get-PbiProperty $vscode.Value 'servers'
    $cliServers = Get-PbiProperty $cli.Value 'mcpServers'
    $vscodeNames = @(Get-PbiPropertyEntry -InputObject $vscodeServers | ForEach-Object { $_.Name } | Where-Object { $_ -ne 'github' })
    $cliNames = @(Get-PbiPropertyEntry -InputObject $cliServers | ForEach-Object { $_.Name } | Where-Object { $_ -ne 'github' })
    foreach ($name in $vscodeNames) {
        if ($cliNames -notcontains $name) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Warning' -Path '.github/mcp.json' -Message "MCP server '$name' is configured in .vscode/mcp.json but not in .github/mcp.json."
        }
    }
    foreach ($name in $cliNames) {
        if ($vscodeNames -notcontains $name) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Warning' -Path '.vscode/mcp.json' -Message "MCP server '$name' is configured in .github/mcp.json but not in .vscode/mcp.json."
        }
    }
    foreach ($name in $vscodeNames) {
        if ($cliNames -notcontains $name) {
            continue
        }
        $vscodeServer = Get-PbiProperty $vscodeServers $name
        $cliServer = Get-PbiProperty $cliServers $name
        if ((Test-PbiLocalMcpServer -Server $vscodeServer) -and (Test-PbiLocalMcpServer -Server $cliServer)) {
            $vscodeArgs = ConvertTo-Json -InputObject @(Get-PbiProperty $vscodeServer 'args') -Compress -Depth 10
            $cliArgs = ConvertTo-Json -InputObject @(Get-PbiProperty $cliServer 'args') -Compress -Depth 10
            if ($vscodeArgs -cne $cliArgs) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Warning' -Path '.github/mcp.json' -Message "MCP server '$name' has different args in .vscode/mcp.json and .github/mcp.json; keep them identical so both hosts run the same server version."
            }
        }
    }
    return $findings.ToArray()
}

#endregion Static checks

#region Quality gate engine

function Merge-PbiBpaRule {
    # Private: merges BPA rule files (arrays of rules); duplicate IDs keep the first occurrence (repo rules first).
    param(
        [Parameter(Mandatory)]
        [string[]] $Path
    )
    $byId = [ordered]@{}
    $anonymous = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $Path) {
        $content = @(Read-PbiJsonFile -Path $file -Description 'BPA rules file')
        if ($content.Count -eq 1 -and $null -ne (Get-PbiProperty $content[0] 'rules')) {
            $content = @(Get-PbiProperty $content[0] 'rules')
        }
        foreach ($rule in $content) {
            if ($null -eq $rule) {
                continue
            }
            $id = [string](Get-PbiProperty $rule 'ID' '')
            if ([string]::IsNullOrWhiteSpace($id)) {
                $anonymous.Add($rule)
                continue
            }
            if (-not $byId.Contains($id)) {
                $byId[$id] = $rule
            }
        }
    }
    foreach ($rule in $byId.Values) {
        $rule
    }
    foreach ($rule in $anonymous) {
        $rule
    }
}

function Find-PbiBpaRule {
    # Private: the rule whose ID or Name occurs in the text (longest match), or $null.
    param(
        [AllowEmptyCollection()]
        [object[]] $Rule = @(),

        [AllowEmptyString()]
        [string] $Text = ''
    )
    $best = $null
    $bestLength = 0
    foreach ($candidate in $Rule) {
        foreach ($key in @([string](Get-PbiProperty $candidate 'ID' ''), [string](Get-PbiProperty $candidate 'Name' ''))) {
            if ($key.Length -gt $bestLength -and $Text.IndexOf($key, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $best = $candidate
                $bestLength = $key.Length
            }
        }
    }
    return $best
}

function ConvertTo-PbiBpaSeverity {
    # Private: BPA rule severity (1 Info, 2 Warning, >= 3 Error), falling back to the TRX outcome.
    param(
        [AllowNull()]
        [object] $Rule,

        [AllowEmptyString()]
        [string] $Outcome = ''
    )
    if ($null -ne $Rule) {
        $raw = Get-PbiProperty $Rule 'Severity'
        $level = 0
        if ($null -ne $raw -and [int]::TryParse([string]$raw, [ref]$level)) {
            if ($level -ge 3) {
                return 'Error'
            }
            if ($level -eq 2) {
                return 'Warning'
            }
            return 'Info'
        }
    }
    if ($Outcome -eq 'Failed' -or $Outcome -eq 'Error') {
        return 'Error'
    }
    return 'Warning'
}

function Test-PbiModelBpa {
    <#
    .SYNOPSIS
        Runs the Best Practice Analyzer (Tabular Editor 2 CLI) on a TMDL semantic model and returns findings.
    .DESCRIPTION
        Windows only (Status Skipped elsewhere or when tools/.bin/te2/TabularEditor.exe is missing).
        Rules: -RulesPath, or config/quality/bpa-rules.json plus tools/.bin/bpa/BPARules.json (when present and
        tools/versions.json bpaRules.enabled). Because TE2 accepts one rules file, they are merged (deduplicated by ID,
        repository rules win) into tools/.bin/bpa/effective-rules.json. The model argument is
        <model>/definition/database.tmdl (tabularEditor2.modelArgument = databaseFile) or <model>/definition
        (definitionFolder). The TRX output (.evidence/bpa/) is parsed into findings; severities come from the rule
        (1 Info, 2 Warning, >= 3 Error). When the TRX cannot be read, the TE2 exit code is used instead.
        Returns { Status (Completed|Skipped), SkipReason, Findings, ErrorCount, WarningCount, InfoCount, ExitCode,
        TrxPath, LogPath, RulesPath, RuleCount }.
    .PARAMETER SemanticModelPath
        The *.SemanticModel folder.
    .PARAMETER RulesPath
        Rule files to use instead of the defaults.
    .PARAMETER RepoRoot
        Repository root.
    .EXAMPLE
        $bpa = Test-PbiModelBpa -SemanticModelPath 'src/SalesStarter/SalesStarter.SemanticModel'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SemanticModelPath,

        [string[]] $RulesPath,

        [string] $RepoRoot
    )
    $check = 'ModelBpa'
    $modelRoot = Resolve-PbiFullPath -Path $SemanticModelPath
    if (-not (Test-Path -LiteralPath (Join-Path $modelRoot 'definition') -PathType Container)) {
        throw "'$SemanticModelPath' is not a TMDL semantic model folder (no definition folder)."
    }
    $root = Resolve-PbiCheckRoot -Path $modelRoot -RepoRoot $RepoRoot
    $result = [ordered]@{
        Status       = 'Completed'
        SkipReason   = $null
        Findings     = @()
        ErrorCount   = 0
        WarningCount = 0
        InfoCount    = 0
        ExitCode     = $null
        TrxPath      = $null
        LogPath      = $null
        RulesPath    = $null
        RuleCount    = 0
    }
    if (-not $IsWindows) {
        $result.Status = 'Skipped'
        $result.SkipReason = 'Tabular Editor 2 (Best Practice Analyzer) runs on Windows only.'
        return [pscustomobject]$result
    }
    $te2 = Join-Path $root 'tools' '.bin' 'te2' 'TabularEditor.exe'
    if (-not (Test-Path -LiteralPath $te2 -PathType Leaf)) {
        $result.Status = 'Skipped'
        $result.SkipReason = 'Tabular Editor 2 is not installed (run scripts/bootstrap/Install-PbiTooling.ps1).'
        return [pscustomobject]$result
    }
    $versions = $null
    try {
        $versions = Get-PbiToolVersions -RepoRoot $root
    } catch {
        Write-Verbose "tools/versions.json could not be read: $($_.Exception.Message)"
    }
    $ruleFiles = [System.Collections.Generic.List[string]]::new()
    $requestedRules = @(Split-PbiListArgument $RulesPath)
    if ($requestedRules.Count -gt 0) {
        foreach ($rulePath in $requestedRules) {
            $fullRulePath = Resolve-PbiFullPath -Path $rulePath
            if (-not (Test-Path -LiteralPath $fullRulePath -PathType Leaf)) {
                throw "BPA rules file not found: $rulePath"
            }
            $ruleFiles.Add($fullRulePath)
        }
    } else {
        $repoRules = Join-Path $root 'config' 'quality' 'bpa-rules.json'
        if (Test-Path -LiteralPath $repoRules -PathType Leaf) {
            $ruleFiles.Add($repoRules)
        }
        $microsoftEnabled = Test-PbiTruthy -Value (Get-PbiProperty (Get-PbiProperty $versions 'bpaRules') 'enabled' $true)
        $microsoftRules = Join-Path $root 'tools' '.bin' 'bpa' 'BPARules.json'
        if ($microsoftEnabled -and (Test-Path -LiteralPath $microsoftRules -PathType Leaf)) {
            $ruleFiles.Add($microsoftRules)
        }
    }
    if ($ruleFiles.Count -eq 0) {
        $result.Status = 'Skipped'
        $result.SkipReason = 'No BPA rules found (config/quality/bpa-rules.json or tools/.bin/bpa/BPARules.json).'
        return [pscustomobject]$result
    }
    $rules = @(Merge-PbiBpaRule -Path $ruleFiles.ToArray())
    $effectivePath = Join-Path $root 'tools' '.bin' 'bpa' 'effective-rules.json'
    Write-PbiTextFile -Path $effectivePath -Content (ConvertTo-Json -InputObject $rules -Depth 20)
    $result.RulesPath = Get-PbiRelativePath -Path $effectivePath -RepoRoot $root
    $result.RuleCount = $rules.Count
    $modelArgumentMode = [string](Get-PbiProperty (Get-PbiProperty $versions 'tabularEditor2') 'modelArgument' 'databaseFile')
    if ($modelArgumentMode -eq 'definitionFolder') {
        $modelArgument = Join-Path $modelRoot 'definition'
    } else {
        $modelArgument = Join-Path $modelRoot 'definition' 'database.tmdl'
    }
    $evidenceDirectory = Join-Path $root '.evidence' 'bpa'
    $null = New-Item -ItemType Directory -Path $evidenceDirectory -Force
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    $safeName = (Split-Path -Path $modelRoot -Leaf) -replace '[^A-Za-z0-9._-]', '_'
    $trxPath = Join-Path $evidenceDirectory "$stamp-$safeName.trx"
    $logPath = Join-Path $evidenceDirectory "$stamp-$safeName.log"
    $errorLogPath = Join-Path $evidenceDirectory "$stamp-$safeName.err.log"
    $arguments = @(('"{0}"' -f $modelArgument), '-A', ('"{0}"' -f $effectivePath), '-T', ('"{0}"' -f $trxPath))
    Write-PbiLog ('Running the Best Practice Analyzer ({0} rules) on {1}...' -f $rules.Count, (Split-Path -Path $modelRoot -Leaf))
    $process = Start-Process -FilePath $te2 -ArgumentList $arguments -Wait -PassThru -NoNewWindow -RedirectStandardOutput $logPath -RedirectStandardError $errorLogPath
    $exitCode = $null
    try {
        $exitCode = $process.ExitCode
    } catch {
        $exitCode = $null
    }
    $result.ExitCode = $exitCode
    $result.TrxPath = Get-PbiRelativePath -Path $trxPath -RepoRoot $root
    $result.LogPath = Get-PbiRelativePath -Path $logPath -RepoRoot $root
    $modelRelative = Get-PbiRelativePath -Path $modelRoot -RepoRoot $root
    $findings = [System.Collections.Generic.List[object]]::new()
    $parsedTrx = $false
    if (Test-Path -LiteralPath $trxPath -PathType Leaf) {
        try {
            $trx = [xml](Get-Content -LiteralPath $trxPath -Raw)
            foreach ($node in @($trx.SelectNodes("//*[local-name()='UnitTestResult']"))) {
                $outcome = [string]$node.GetAttribute('outcome')
                if ($outcome -eq 'Passed') {
                    continue
                }
                $testName = [string]$node.GetAttribute('testName')
                $detail = ''
                $messageNode = $node.SelectSingleNode(".//*[local-name()='Message']")
                if ($null -ne $messageNode) {
                    $detail = $messageNode.InnerText.Trim()
                }
                $rule = Find-PbiBpaRule -Rule $rules -Text "$testName $detail"
                $severity = ConvertTo-PbiBpaSeverity -Rule $rule -Outcome $outcome
                $message = $testName
                if (-not [string]::IsNullOrWhiteSpace($detail) -and $detail -ne $testName) {
                    $message = "$testName - $detail"
                }
                if ($null -ne $rule) {
                    $message = '[{0}] {1}' -f [string](Get-PbiProperty $rule 'ID' ''), $message
                }
                $findings.Add((New-PbiFinding -Check $check -Severity $severity -Path $modelRelative -Message (Protect-PbiText -Text $message)))
            }
            $parsedTrx = $true
        } catch {
            Write-PbiWarning "Could not parse the Tabular Editor TRX file: $($_.Exception.Message)"
        }
    }
    if (-not $parsedTrx -and $null -ne $exitCode -and $exitCode -ne 0) {
        $findings.Add((New-PbiFinding -Check $check -Severity 'Error' -Path $modelRelative -Message ('Tabular Editor 2 exited with code {0} (Error-severity rule violations or a failure) and no TRX could be read. See {1}.' -f $exitCode, $result.LogPath)))
    }
    $result.Findings = $findings.ToArray()
    $result.ErrorCount = @($findings | Where-Object { $_.Severity -eq 'Error' }).Count
    $result.WarningCount = @($findings | Where-Object { $_.Severity -eq 'Warning' }).Count
    $result.InfoCount = @($findings | Where-Object { $_.Severity -eq 'Info' }).Count
    return [pscustomobject]$result
}

function Test-PbiSuperpowersManifest {
    <#
    .SYNOPSIS
        Verifies vendored Superpowers skills against .github/skills/superpowers.manifest.json.
    .DESCRIPTION
        Re-hashes every file listed in the manifest (SHA-256, line endings normalised) and reports missing or changed
        files, plus files in vendored skill folders that are not in the manifest. Returns findings (Errors on drift).
        Throws when the manifest does not exist.
    .PARAMETER RepoRoot
        Repository root.
    .EXAMPLE
        Test-PbiSuperpowersManifest -RepoRoot $root
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )
    $check = 'SuperpowersManifest'
    $root = Resolve-PbiFullPath -Path $RepoRoot
    $manifestPath = Join-Path $root '.github' 'skills' 'superpowers.manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'No vendored Superpowers manifest found (.github/skills/superpowers.manifest.json). Vendor it with scripts/bootstrap/Install-AgentPlugins.ps1 -VendorSuperpowers.'
    }
    $manifest = Read-PbiJsonFile -Path $manifestPath -Description 'Superpowers manifest'
    $findings = [System.Collections.Generic.List[object]]::new()
    $listed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $skillFolders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($entry in @(Get-PbiProperty $manifest 'files')) {
        $relative = [string](Get-PbiProperty $entry 'path' '')
        $expected = ([string](Get-PbiProperty $entry 'sha256' '')).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($relative)) {
            continue
        }
        $null = $listed.Add($relative)
        $skillMatch = [regex]::Match($relative, '^\.github/skills/(?<skill>[^/]+)/')
        if ($skillMatch.Success) {
            $null = $skillFolders.Add($skillMatch.Groups['skill'].Value)
        }
        $fullPath = Join-Path $root $relative
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $relative -Message 'Vendored Superpowers file is missing. Re-vendor with scripts/bootstrap/Install-AgentPlugins.ps1 -VendorSuperpowers.'
            continue
        }
        if ((Get-PbiContentHash -Path $fullPath) -ne $expected) {
            Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $relative -Message 'Vendored Superpowers file was modified (SHA-256 drift). Revert it or re-vendor; put repository-specific guidance in a pbi-* skill instead.'
        }
    }
    foreach ($skill in $skillFolders) {
        $folder = Join-Path $root '.github' 'skills' $skill
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            continue
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -Recurse -File -Force)) {
            $relative = Get-PbiRelativePath -Path $file.FullName -RepoRoot $root
            if (-not $listed.Contains($relative)) {
                Add-PbiFinding -List $findings -Check $check -Severity 'Error' -Path $relative -Message 'File is not part of the vendored Superpowers manifest (unexpected addition). Move it to a pbi-* skill or re-vendor.'
            }
        }
    }
    return $findings.ToArray()
}

function New-PbiCheckOutcome {
    # Private: outcome of one gate check.
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Passed', 'Failed', 'Warning', 'Skipped', 'NotApplicable')]
        [string] $Status,

        [Parameter(Mandatory)]
        [string] $Summary,

        [AllowEmptyCollection()]
        [object[]] $Findings = @(),

        [AllowEmptyCollection()]
        [object[]] $Details = @()
    )
    $skipReason = $null
    if ($Status -eq 'Skipped') {
        $skipReason = $Summary
    }
    return @{ Status = $Status; Summary = $Summary; Findings = $Findings; Details = $Details; SkipReason = $skipReason }
}

function Get-PbiCheckOutcome {
    # Private: maps findings to a status (any Error -> Failed, only Warnings -> Warning, otherwise Passed).
    param(
        [AllowEmptyCollection()]
        [object[]] $Findings = @(),

        [string] $PassedSummary = 'No findings.',

        [AllowEmptyCollection()]
        [object[]] $Details = @()
    )
    $errors = @($Findings | Where-Object { $_.Severity -eq 'Error' }).Count
    $warnings = @($Findings | Where-Object { $_.Severity -eq 'Warning' }).Count
    $infos = @($Findings | Where-Object { $_.Severity -eq 'Info' }).Count
    $status = 'Passed'
    $summary = $PassedSummary
    if ($errors -gt 0) {
        $status = 'Failed'
    } elseif ($warnings -gt 0) {
        $status = 'Warning'
    }
    if ($errors -gt 0 -or $warnings -gt 0) {
        $summary = '{0} error(s), {1} warning(s), {2} info.' -f $errors, $warnings, $infos
    } elseif ($infos -gt 0) {
        $summary = '{0} ({1} info)' -f $PassedSummary, $infos
    }
    return (New-PbiCheckOutcome -Status $status -Summary $summary -Findings $Findings -Details $Details)
}

function Get-PbiGateReportPath {
    # Private: all *.Report folders of the gate projects.
    param(
        [Parameter(Mandatory)]
        [hashtable] $Context
    )
    foreach ($project in @($Context.Projects)) {
        foreach ($reportPath in @($project.ReportPaths)) {
            $reportPath
        }
    }
}

function Get-PbiReportAuthorCommand {
    # Private: the powerbi-report-author CLI command, or $null.
    return (Get-Command -Name 'powerbi-report-author' -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Invoke-PbiGatePbirValidate {
    # Private: L0 PbirValidate.
    param(
        [Parameter(Mandatory)]
        [hashtable] $Context
    )
    $reports = @(Get-PbiGateReportPath -Context $Context)
    if ($reports.Count -eq 0) {
        return (New-PbiCheckOutcome -Status 'NotApplicable' -Summary 'No *.Report folders to validate.')
    }
    $cli = Get-PbiReportAuthorCommand
    if ($null -eq $cli) {
        return (New-PbiCheckOutcome -Status 'Skipped' -Summary 'powerbi-report-author CLI not found (run scripts/bootstrap/Install-PbiTooling.ps1).')
    }
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($report in $reports) {
        $run = Invoke-PbiNativeCommand -FilePath $cli.Source -ArgumentList @('validate', $report)
        if ($run.ExitCode -ne 0) {
            $lines = @(@($run.StdOut) + @($run.StdErr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 10)
            $text = ($lines | ForEach-Object { $_.Trim() }) -join ' | '
            Add-PbiFinding -List $findings -Check 'PbirValidate' -Severity 'Error' -Path $report -RepoRoot $Context.RepoRoot -Message (Protect-PbiText -Text ('powerbi-report-author validate failed (exit {0}): {1}' -f $run.ExitCode, $text))
        }
    }
    return (Get-PbiCheckOutcome -Findings $findings.ToArray() -PassedSummary ('{0} report(s) valid.' -f $reports.Count))
}

function Invoke-PbiGateModelBpa {
    # Private: L1 ModelBpa with the thresholds bpaMaxErrors / bpaMaxWarnings.
    param(
        [Parameter(Mandatory)]
        [hashtable] $Context
    )
    $models = @($Context.Projects | Where-Object { $null -ne $_.SemanticModelPath })
    if ($models.Count -eq 0) {
        return (New-PbiCheckOutcome -Status 'NotApplicable' -Summary 'No semantic models.')
    }
    $thresholds = Get-PbiProperty $Context.Gate 'thresholds'
    $maxErrors = [int](Get-PbiProperty $thresholds 'bpaMaxErrors' 0)
    $maxWarnings = [int](Get-PbiProperty $thresholds 'bpaMaxWarnings' 25)
    $findings = [System.Collections.Generic.List[object]]::new()
    $details = [System.Collections.Generic.List[object]]::new()
    $errors = 0
    $warnings = 0
    $infos = 0
    foreach ($model in $models) {
        $bpa = Test-PbiModelBpa -SemanticModelPath $model.SemanticModelPath -RepoRoot $Context.RepoRoot
        if ($bpa.Status -eq 'Skipped') {
            return (New-PbiCheckOutcome -Status 'Skipped' -Summary $bpa.SkipReason)
        }
        foreach ($finding in @($bpa.Findings)) {
            $findings.Add($finding)
        }
        $errors += $bpa.ErrorCount
        $warnings += $bpa.WarningCount
        $infos += $bpa.InfoCount
        $details.Add([pscustomobject]@{ Model = $model.RelativePath; Errors = $bpa.ErrorCount; Warnings = $bpa.WarningCount; Info = $bpa.InfoCount; Rules = $bpa.RuleCount; Trx = $bpa.TrxPath })
    }
    $summary = '{0} error(s) (max {1}), {2} warning(s) (max {3}), {4} info.' -f $errors, $maxErrors, $warnings, $maxWarnings, $infos
    $status = 'Passed'
    if ($errors -gt $maxErrors -or $warnings -gt $maxWarnings) {
        $status = 'Failed'
    } elseif ($errors -gt 0 -or $warnings -gt 0) {
        $status = 'Warning'
    }
    return (New-PbiCheckOutcome -Status $status -Summary $summary -Findings $findings.ToArray() -Details $details.ToArray())
}

function Invoke-PbiGateReportInspector {
    # Private: L1 ReportInspector (Fab Inspector, optional).
    param(
        [Parameter(Mandatory)]
        [hashtable] $Context
    )
    $reports = @(Get-PbiGateReportPath -Context $Context)
    if ($reports.Count -eq 0) {
        return (New-PbiCheckOutcome -Status 'NotApplicable' -Summary 'No *.Report folders.')
    }
    if (-not $IsWindows) {
        return (New-PbiCheckOutcome -Status 'Skipped' -Summary 'Fab Inspector runs on Windows only.')
    }
    $root = $Context.RepoRoot
    $inspectorRoot = Join-Path $root 'tools' '.bin' 'fab-inspector'
    $executable = $null
    if (Test-Path -LiteralPath $inspectorRoot -PathType Container) {
        $executable = Get-ChildItem -LiteralPath $inspectorRoot -Recurse -File -Filter '*.exe' | Where-Object { $_.Name -match 'Inspector' } | Sort-Object -Property Name | Select-Object -First 1
    }
    if ($null -eq $executable) {
        return (New-PbiCheckOutcome -Status 'Skipped' -Summary 'Fab Inspector is not installed (optional: set fabInspector.url in tools/versions.json and run scripts/bootstrap/Install-PbiTooling.ps1).')
    }
    $rulesFile = Join-Path $root 'config' 'quality' 'fab-inspector-rules.json'
    if (-not (Test-Path -LiteralPath $rulesFile -PathType Leaf)) {
        return (New-PbiCheckOutcome -Status 'Skipped' -Summary 'No Fab Inspector rules file (config/quality/fab-inspector-rules.json).')
    }
    $outputDirectory = Join-Path $root '.evidence' 'fab-inspector' $Context.Timestamp
    $null = New-Item -ItemType Directory -Path $outputDirectory -Force
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($report in $reports) {
        $run = Invoke-PbiNativeCommand -FilePath $executable.FullName -ArgumentList @('-fabricitem', $report, '-rules', $rulesFile, '-output', $outputDirectory, '-formats', 'JSON')
        if ($run.ExitCode -ne 0) {
            $text = (@(@($run.StdOut) + @($run.StdErr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 5) -join ' | ')
            Add-PbiFinding -List $findings -Check 'ReportInspector' -Severity 'Error' -Path $report -RepoRoot $root -Message (Protect-PbiText -Text ('Fab Inspector reported failures (exit {0}): {1} Results: {2}' -f $run.ExitCode, $text, (Get-PbiRelativePath -Path $outputDirectory -RepoRoot $root)))
        }
    }
    return (Get-PbiCheckOutcome -Findings $findings.ToArray() -PassedSummary ('{0} report(s) inspected.' -f $reports.Count))
}

function Invoke-PbiGateDaxTest {
    # Private: L2 DaxTests (Local = Power BI Desktop; DEV/TEST/PROD = deployed model).
    param(
        [Parameter(Mandatory)]
        [hashtable] $Context
    )
    $root = $Context.RepoRoot
    $target = $Context.Target
    $models = @($Context.Projects | Where-Object { $null -ne $_.SemanticModelPath })
    if ($models.Count -eq 0) {
        return (New-PbiCheckOutcome -Status 'NotApplicable' -Summary 'No semantic models.')
    }
    $maxDuration = [int](Get-PbiProperty (Get-PbiProperty $Context.Gate 'thresholds') 'daxTestMaxDurationMs' 5000)
    $withTests = @($models | Where-Object { @(Get-PbiDaxTestFile -SemanticModelPath $_.SemanticModelPath -Target $target).Count -gt 0 })
    if ($withTests.Count -eq 0) {
        return (New-PbiCheckOutcome -Status 'Warning' -Summary "No DAX test files for target $target (DAXQueries/*.ALL.Tests.dax or *.<scope>.Tests.dax).")
    }
    $results = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()
    if ($target -eq 'Local') {
        if (-not $IsWindows) {
            return (New-PbiCheckOutcome -Status 'Skipped' -Summary 'DAX tests against Power BI Desktop need Windows; run with -Target DEV to test a deployed model.')
        }
        foreach ($project in $withTests) {
            $projectName = $project.Name
            if (-not [string]::IsNullOrEmpty($project.PbipPath)) {
                $projectName = [System.IO.Path]::GetFileNameWithoutExtension($project.PbipPath)
            }
            try {
                $instance = Get-PbiDesktopInstance -ProjectName $projectName
            } catch {
                return (New-PbiCheckOutcome -Status 'Skipped' -Summary ("No running Power BI Desktop instance with '{0}' open: {1}" -f $projectName, $_.Exception.Message))
            }
            foreach ($testResult in @(Invoke-PbiDaxTestSuite -SemanticModelPath $project.SemanticModelPath -Target 'Local' -Port $instance.Port -MaxDurationMs $maxDuration -RepoRoot $root)) {
                $results.Add(($testResult | Add-Member -NotePropertyName 'Project' -NotePropertyValue $project.RelativePath -PassThru -Force))
            }
        }
    } else {
        $config = Get-PbiEnvironmentConfig -Environment $target -RepoRoot $root
        if ([string]::IsNullOrWhiteSpace($Context.TenantId)) {
            $null = Connect-PbiFabric
        } else {
            $null = Connect-PbiFabric -TenantId $Context.TenantId
        }
        $workspaceName = [string](Get-PbiProperty (Get-PbiProperty $config 'workspace') 'displayName' '')
        $workspace = Get-PbiWorkspace -DisplayName $workspaceName
        if ($null -eq $workspace) {
            return (New-PbiCheckOutcome -Status 'Failed' -Summary "Workspace '$workspaceName' does not exist; deploy to $target first (scripts/deploy/Deploy-PbiProject.ps1 -Environment $target).")
        }
        $workspaceId = [string](Get-PbiProperty $workspace 'id' '')
        foreach ($project in $withTests) {
            $entry = $null
            foreach ($candidate in @(Get-PbiProperty $config 'projects')) {
                $configuredPath = ([string](Get-PbiProperty $candidate 'path' '')).Replace('\', '/').TrimEnd('/')
                if ([string]::Equals($configuredPath, $project.RelativePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $entry = $candidate
                    break
                }
            }
            if ($null -eq $entry) {
                Add-PbiFinding -List $findings -Check 'DaxTests' -Severity 'Warning' -Path $project.RelativePath -Message "Project is not configured in config/environments/$($target.ToLowerInvariant()).json; its tests were not run."
                continue
            }
            $modelName = [string](Get-PbiProperty (Get-PbiProperty $entry 'semanticModel') 'displayName' '')
            $item = Get-PbiItem -WorkspaceId $workspaceId -Type 'SemanticModel' -DisplayName $modelName
            if ($null -eq $item) {
                Add-PbiFinding -List $findings -Check 'DaxTests' -Severity 'Error' -Path $project.RelativePath -Message "Semantic model '$modelName' is not deployed to $target."
                continue
            }
            $suiteParameters = @{
                SemanticModelPath = $project.SemanticModelPath
                Target            = $target
                WorkspaceId       = $workspaceId
                DatasetId         = [string](Get-PbiProperty $item 'id' '')
                MaxDurationMs     = $maxDuration
                RepoRoot          = $root
            }
            foreach ($testResult in @(Invoke-PbiDaxTestSuite @suiteParameters)) {
                $results.Add(($testResult | Add-Member -NotePropertyName 'Project' -NotePropertyValue $project.RelativePath -PassThru -Force))
            }
        }
    }
    $slowFiles = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($testResult in $results) {
        $testPath = $testResult.Project + '/' + $testResult.File
        if ($testResult.Skipped) {
            continue
        }
        if (-not $testResult.Passed) {
            if ($null -ne $testResult.Error) {
                $message = '{0}: {1}' -f $testResult.TestName, $testResult.Error
            } else {
                $message = '{0}: expected {1}, actual {2}' -f $testResult.TestName, [string]$testResult.ExpectedValue, [string]$testResult.ActualValue
            }
            Add-PbiFinding -List $findings -Check 'DaxTests' -Severity 'Error' -Path $testPath -Message (Protect-PbiText -Text $message)
        } elseif ($testResult.SlowQuery -and $slowFiles.Add($testPath)) {
            Add-PbiFinding -List $findings -Check 'DaxTests' -Severity 'Warning' -Path $testPath -Message ('Slow test query ({0} ms, limit {1} ms).' -f $testResult.DurationMs, $maxDuration)
        }
    }
    $passedCount = @($results | Where-Object { $_.Passed }).Count
    $skippedCount = @($results | Where-Object { $_.Skipped }).Count
    $failedCount = $results.Count - $passedCount - $skippedCount
    $summary = '{0} passed, {1} failed, {2} skipped of {3} test(s) ({4}).' -f $passedCount, $failedCount, $skippedCount, $results.Count, $target
    $outcome = Get-PbiCheckOutcome -Findings $findings.ToArray() -PassedSummary $summary -Details $results.ToArray()
    if ($outcome.Status -ne 'Failed' -and $skippedCount -gt 0) {
        return (New-PbiCheckOutcome -Status 'Skipped' -Summary ("{0} {1} test file(s) use '// @role:', which executeQueries cannot evaluate on {2}; run them with -Target Local." -f $summary, $skippedCount, $target) -Findings $findings.ToArray() -Details $results.ToArray())
    }
    if ($outcome.Status -ne 'Passed') {
        $outcome.Summary = '{0} {1}' -f $summary, $outcome.Summary
    }
    return $outcome
}

function Invoke-PbiGateScreenshot {
    # Private: L3 Screenshots (attended review).
    param(
        [Parameter(Mandatory)]
        [hashtable] $Context
    )
    $root = $Context.RepoRoot
    $reports = @(Get-PbiGateReportPath -Context $Context)
    if ($reports.Count -eq 0) {
        return (New-PbiCheckOutcome -Status 'NotApplicable' -Summary 'No *.Report folders.')
    }
    if ($Context.Target -ne 'Local') {
        return (New-PbiCheckOutcome -Status 'Skipped' -Summary 'Screenshots are captured from Power BI Desktop; run the gate with -Target Local.')
    }
    $cli = Get-PbiReportAuthorCommand
    if ($null -eq $cli) {
        return (New-PbiCheckOutcome -Status 'Skipped' -Summary 'powerbi-report-author CLI not found (run scripts/bootstrap/Install-PbiTooling.ps1).')
    }
    $folder = Join-Path $root '.evidence' 'screenshots' $Context.Timestamp
    $null = New-Item -ItemType Directory -Path $folder -Force
    $relativeFolder = Get-PbiRelativePath -Path $folder -RepoRoot $root
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($report in $reports) {
        $reportFolder = Join-Path $folder ((Split-Path -Path $report -Leaf) -replace '\.Report$', '')
        $run = Invoke-PbiNativeCommand -FilePath $cli.Source -ArgumentList @('preview', $report, '--host', 'desktop', '--screenshot', $reportFolder, '--all-pages')
        if ($run.ExitCode -ne 0) {
            $text = (@(@($run.StdOut) + @($run.StdErr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 5) -join ' | ')
            Add-PbiFinding -List $findings -Check 'Screenshots' -Severity 'Error' -Path $report -RepoRoot $root -Message (Protect-PbiText -Text ('Screenshot capture failed (exit {0}): {1}' -f $run.ExitCode, $text))
        }
    }
    if ($findings.Count -gt 0) {
        return (Get-PbiCheckOutcome -Findings $findings.ToArray())
    }
    if ($Context.AttendedConfirmed) {
        return (New-PbiCheckOutcome -Status 'Passed' -Summary "Attended: a human confirmed the screenshots ($relativeFolder).")
    }
    Add-PbiFinding -List $findings -Check 'Screenshots' -Severity 'Error' -Path $relativeFolder -Message 'Attended check: review the screenshots, then re-run with -AttendedConfirmed.'
    return (New-PbiCheckOutcome -Status 'Failed' -Summary "Attended: review screenshots in $relativeFolder then re-run with -AttendedConfirmed." -Findings $findings.ToArray())
}

function Invoke-PbiGateCheck {
    # Private: dispatches one gate check by name.
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [hashtable] $Context
    )
    $root = $Context.RepoRoot
    $projects = @($Context.Projects)
    if ($Name -eq 'RepoHygiene') {
        return (Get-PbiCheckOutcome -Findings @(Test-PbiRepoHygiene -RepoRoot $root))
    }
    if ($Name -eq 'PbipStructure') {
        if ($projects.Count -eq 0) {
            return (New-PbiCheckOutcome -Status 'NotApplicable' -Summary 'No projects under src/.')
        }
        $findings = @(foreach ($project in $projects) { Test-PbipProjectStructure -ProjectPath $project.Path -RepoRoot $root })
        return (Get-PbiCheckOutcome -Findings $findings -PassedSummary ('{0} project(s) checked.' -f $projects.Count))
    }
    if ($Name -eq 'TmdlConventions') {
        $models = @($projects | Where-Object { $null -ne $_.SemanticModelPath })
        if ($models.Count -eq 0) {
            return (New-PbiCheckOutcome -Status 'NotApplicable' -Summary 'No semantic models.')
        }
        $findings = @(foreach ($model in $models) { Test-PbiTmdlConvention -SemanticModelPath $model.SemanticModelPath -RepoRoot $root })
        return (Get-PbiCheckOutcome -Findings $findings -PassedSummary ('{0} model(s) checked.' -f $models.Count))
    }
    if ($Name -eq 'PbirValidate') {
        return (Invoke-PbiGatePbirValidate -Context $Context)
    }
    if ($Name -eq 'AgentAssets') {
        return (Get-PbiCheckOutcome -Findings @(Test-PbiAgentAsset -RepoRoot $root))
    }
    if ($Name -eq 'McpParity') {
        return (Get-PbiCheckOutcome -Findings @(Test-PbiMcpConfigParity -RepoRoot $root))
    }
    if ($Name -eq 'SuperpowersManifest') {
        if (-not (Test-Path -LiteralPath (Join-Path $root '.github' 'skills' 'superpowers.manifest.json') -PathType Leaf)) {
            return (New-PbiCheckOutcome -Status 'NotApplicable' -Summary 'Superpowers is not vendored (no .github/skills/superpowers.manifest.json).')
        }
        return (Get-PbiCheckOutcome -Findings @(Test-PbiSuperpowersManifest -RepoRoot $root) -PassedSummary 'Vendored Superpowers files match the manifest.')
    }
    if ($Name -eq 'ModelBpa') {
        return (Invoke-PbiGateModelBpa -Context $Context)
    }
    if ($Name -eq 'ReportConventions') {
        $reports = @(Get-PbiGateReportPath -Context $Context)
        if ($reports.Count -eq 0) {
            return (New-PbiCheckOutcome -Status 'NotApplicable' -Summary 'No *.Report folders.')
        }
        $findings = @(foreach ($report in $reports) { Test-PbiReportConvention -ReportPath $report -Gate $Context.Gate -RepoRoot $root })
        return (Get-PbiCheckOutcome -Findings $findings -PassedSummary ('{0} report(s) checked.' -f $reports.Count))
    }
    if ($Name -eq 'ReportInspector') {
        return (Invoke-PbiGateReportInspector -Context $Context)
    }
    if ($Name -eq 'DaxTests') {
        return (Invoke-PbiGateDaxTest -Context $Context)
    }
    if ($Name -eq 'Screenshots') {
        return (Invoke-PbiGateScreenshot -Context $Context)
    }
    throw "Unknown quality gate check '$Name'."
}

function Resolve-PbiCheckName {
    # Private: canonical check name from the registry (case-insensitive), or throws.
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )
    foreach ($known in @($script:PbiGateCheckRegistry.Keys)) {
        if ([string]::Equals([string]$known, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$known
        }
    }
    throw ("Unknown quality gate check '{0}'. Known checks: {1}." -f $Name, (@($script:PbiGateCheckRegistry.Keys) -join ', '))
}

function Test-PbiQualityGate {
    <#
    .SYNOPSIS
        Runs the quality gate checks of a profile (or of named levels/checks) and returns the result object.
    .DESCRIPTION
        Levels come from config/quality/gates.json profiles[<Profile>] unless -Level is given; -Check runs exactly the
        named checks. Check registry (level): RepoHygiene, PbipStructure, TmdlConventions, PbirValidate, AgentAssets,
        McpParity, SuperpowersManifest (L0); ModelBpa, ReportConventions, ReportInspector (L1); DaxTests (L2);
        Screenshots (L3). gates.json levels.<L>.checks overrides the level membership.
        Statuses: Passed, Failed, Warning (passes), Skipped, NotApplicable (passes). A Skipped check fails the gate
        when skippedCountsAsFailure is true, unless it is listed in optionalChecks or -AllowSkip. A check that
        throws is Failed. Configuration problems (unknown profile/level/check, bad project path) throw.
        Returns { Profile, Levels, Target, Outcome (Passed|Failed), StartedUtc, DurationMs, Projects, AllowSkip,
        Counts, Checks[] } where each check has Level, Check, Status, Summary, Blocking, Optional, AllowedSkip,
        SkipReason, DurationMs, Findings, Details.
    .PARAMETER Profile
        commit, pr, deploy-dev, deploy-test or release (any profile defined in gates.json).
    .PARAMETER Level
        Levels to run instead of the profile's levels (L0..L3).
    .PARAMETER Check
        Run exactly these checks (comma-separated values are accepted).
    .PARAMETER ProjectPath
        Restrict project checks to these project folders.
    .PARAMETER Target
        Local (Power BI Desktop) or DEV/TEST/PROD for DaxTests.
    .PARAMETER AllowSkip
        Checks that may be skipped without failing the gate.
    .PARAMETER AttendedConfirmed
        A human reviewed the screenshots (L3).
    .PARAMETER TenantId
        Tenant for service DAX tests.
    .PARAMETER RepoRoot
        Repository root.
    .EXAMPLE
        $gate = Test-PbiQualityGate -Profile commit -RepoRoot $root
        $gate.Outcome
    #>
    [CmdletBinding()]
    param(
        [string] $Profile = 'commit',

        [string[]] $Level,

        [string[]] $Check,

        [string[]] $ProjectPath,

        [ValidateSet('Local', 'DEV', 'TEST', 'PROD')]
        [string] $Target = 'Local',

        [string[]] $AllowSkip,

        [switch] $AttendedConfirmed,

        [string] $TenantId,

        [string] $RepoRoot
    )
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-PbiRepoRoot
    }
    $root = Resolve-PbiFullPath -Path $RepoRoot
    $gate = Get-PbiGateConfig -RepoRoot $root
    $levelsConfig = Get-PbiProperty $gate 'levels'
    $optionalChecks = @(Get-PbiProperty $gate 'optionalChecks')
    $skippedCountsAsFailure = Test-PbiTruthy -Value (Get-PbiProperty $gate 'skippedCountsAsFailure' $true)

    $levelChecks = [ordered]@{}
    foreach ($entry in @(Get-PbiPropertyEntry -InputObject $levelsConfig)) {
        $names = @(Get-PbiProperty $entry.Value 'checks' | ForEach-Object { Resolve-PbiCheckName -Name ([string]$_) })
        $levelChecks[$entry.Name] = $names
    }
    foreach ($known in @($script:PbiGateCheckRegistry.Keys)) {
        $registryLevel = $script:PbiGateCheckRegistry[$known]
        if (-not $levelChecks.Contains($registryLevel)) {
            $levelChecks[$registryLevel] = @($script:PbiGateCheckRegistry.Keys | Where-Object { $script:PbiGateCheckRegistry[$_] -eq $registryLevel })
        }
    }
    $checkLevel = @{}
    foreach ($levelName in @($levelChecks.Keys)) {
        foreach ($name in $levelChecks[$levelName]) {
            if (-not $checkLevel.ContainsKey($name)) {
                $checkLevel[$name] = [string]$levelName
            }
        }
    }
    foreach ($known in @($script:PbiGateCheckRegistry.Keys)) {
        if (-not $checkLevel.ContainsKey($known)) {
            $checkLevel[$known] = $script:PbiGateCheckRegistry[$known]
        }
    }

    $requestedChecks = @(Split-PbiListArgument $Check)
    $requestedLevels = @(Split-PbiListArgument $Level)
    $selected = [System.Collections.Generic.List[string]]::new()
    if ($requestedChecks.Count -gt 0) {
        foreach ($name in $requestedChecks) {
            $canonical = Resolve-PbiCheckName -Name $name
            if (-not $selected.Contains($canonical)) {
                $selected.Add($canonical)
            }
        }
        $levels = @($selected | ForEach-Object { $checkLevel[$_] } | Sort-Object -Unique)
    } else {
        if ($requestedLevels.Count -gt 0) {
            $levels = $requestedLevels
        } else {
            $levels = @(Get-PbiProperty (Get-PbiProperty $gate 'profiles') $Profile)
            if ($levels.Count -eq 0) {
                $known = @(Get-PbiPropertyEntry -InputObject (Get-PbiProperty $gate 'profiles') | ForEach-Object { $_.Name }) -join ', '
                throw "Unknown quality gate profile '$Profile' (config/quality/gates.json profiles: $known)."
            }
        }
        foreach ($levelName in $levels) {
            if (-not $levelChecks.Contains([string]$levelName)) {
                throw ("Unknown quality gate level '{0}' (known: {1})." -f $levelName, (@($levelChecks.Keys) -join ', '))
            }
            foreach ($name in $levelChecks[[string]$levelName]) {
                if (-not $selected.Contains($name)) {
                    $selected.Add($name)
                }
            }
        }
    }

    $projects = @(Get-PbiProject -RepoRoot $root -Path $ProjectPath)
    $allowed = @(Split-PbiListArgument $AllowSkip | ForEach-Object { Resolve-PbiCheckName -Name $_ })
    $startedUtc = [DateTime]::UtcNow
    $context = @{
        RepoRoot          = $root
        Gate              = $gate
        Projects          = $projects
        Target            = $Target
        AttendedConfirmed = [bool]$AttendedConfirmed
        TenantId          = $TenantId
        Timestamp         = $startedUtc.ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $results = [System.Collections.Generic.List[object]]::new()
    $overallWatch = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($name in $selected) {
        Write-PbiLog ('{0} {1}...' -f $checkLevel[$name], $name) -Level Step
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $outcome = Invoke-PbiGateCheck -Name $name -Context $context
        } catch {
            $outcome = New-PbiCheckOutcome -Status 'Failed' -Summary ('The check could not run: {0}' -f (Protect-PbiText -Text $_.Exception.Message))
        }
        $watch.Stop()
        $isOptional = $optionalChecks -contains $name
        $isAllowed = $allowed -contains $name
        $blocking = $false
        $summary = [string]$outcome.Summary
        if ($outcome.Status -eq 'Failed') {
            $blocking = $true
        } elseif ($outcome.Status -eq 'Skipped') {
            if ($isOptional) {
                $summary += ' (optional check)'
            } elseif ($isAllowed) {
                $summary += ' (skip allowed by -AllowSkip)'
            } elseif ($skippedCountsAsFailure) {
                $blocking = $true
                $summary += " (blocking: skipped checks fail the gate; fix the cause or pass -AllowSkip $name)"
            }
        }
        $results.Add([pscustomobject]@{
                Level       = $checkLevel[$name]
                Check       = $name
                Status      = [string]$outcome.Status
                Summary     = $summary
                Blocking    = $blocking
                Optional    = $isOptional
                AllowedSkip = $isAllowed
                SkipReason  = $outcome.SkipReason
                DurationMs  = [int]$watch.ElapsedMilliseconds
                Findings    = @(Get-PbiProperty $outcome 'Findings')
                Details     = @(Get-PbiProperty $outcome 'Details')
            })
    }
    $overallWatch.Stop()
    $checks = $results.ToArray()
    $outcomeText = 'Passed'
    if (@($checks | Where-Object { $_.Blocking }).Count -gt 0) {
        $outcomeText = 'Failed'
    }
    $counts = [ordered]@{}
    foreach ($statusName in @('Passed', 'Failed', 'Warning', 'Skipped', 'NotApplicable')) {
        $counts[$statusName] = @($checks | Where-Object { $_.Status -eq $statusName }).Count
    }
    [pscustomobject]@{
        Profile    = $Profile
        Levels     = @($levels)
        Target     = $Target
        Outcome    = $outcomeText
        StartedUtc = $startedUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        DurationMs = [int]$overallWatch.ElapsedMilliseconds
        Projects   = @($projects | ForEach-Object { $_.RelativePath })
        AllowSkip  = $allowed
        Counts     = $counts
        Checks     = $checks
    }
}

#endregion Quality gate engine

#region Evidence

function Protect-PbiText {
    <#
    .SYNOPSIS
        Masks GUIDs (as <id>) and e-mail addresses (as <email>) in text.
    .PARAMETER Text
        Text to mask ($null and empty strings are returned unchanged).
    .EXAMPLE
        Protect-PbiText -Text $message
    .EXAMPLE
        $lines | Protect-PbiText
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )
    process {
        if ([string]::IsNullOrEmpty($Text)) {
            return $Text
        }
        $masked = [regex]::Replace($Text, $script:PbiGuidPattern, '<id>')
        return [regex]::Replace($masked, $script:PbiEmailPattern, '<email>')
    }
}

function New-PbiEvidence {
    <#
    .SYNOPSIS
        Writes an evidence file to .evidence/ (git-ignored) and returns its path.
    .DESCRIPTION
        File name: .evidence/<yyyyMMdd-HHmmss>-<kind>[-<ENV>]-<ShortCommit>.json (UTC timestamp; a counter is inserted
        after the timestamp when the name already exists). Content:
        { schema: 'pbi-superpower/evidence/1.0', kind, createdUtc, environment, repository: { commit, branch, dirty },
          host: { os, pwsh }, data } serialised with depth 20.
    .PARAMETER Kind
        quality-gate, deployment, dax-tests or infrastructure.
    .PARAMETER Data
        Hashtable or object with the evidence details.
    .PARAMETER Environment
        DEV, TEST, PROD or LOCAL (optional).
    .PARAMETER RepoRoot
        Repository root.
    .PARAMETER GitContext
        Result of Get-PbiGitContext (computed with -SkipFetch when omitted).
    .EXAMPLE
        $path = New-PbiEvidence -Kind 'quality-gate' -Data @{ outcome = 'Passed' } -RepoRoot $root
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('quality-gate', 'deployment', 'dax-tests', 'infrastructure')]
        [string] $Kind,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Data,

        [string] $Environment,

        [string] $RepoRoot,

        [object] $GitContext
    )
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-PbiRepoRoot
    }
    if ($null -eq $GitContext) {
        $GitContext = Get-PbiGitContext -RepoRoot $RepoRoot -SkipFetch
    }
    $shortCommit = [string](Get-PbiProperty $GitContext 'ShortCommit' '')
    if ([string]::IsNullOrEmpty($shortCommit)) {
        $shortCommit = 'nocommit'
    }
    $environmentName = $null
    $suffix = "$Kind-$shortCommit"
    if (-not [string]::IsNullOrWhiteSpace($Environment)) {
        $environmentName = $Environment.ToUpperInvariant()
        $suffix = "$Kind-$environmentName-$shortCommit"
    }
    $now = [DateTime]::UtcNow
    $stamp = $now.ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    $directory = Join-Path $RepoRoot '.evidence'
    $null = New-Item -ItemType Directory -Path $directory -Force
    $path = Join-Path $directory "$stamp-$suffix.json"
    $counter = 1
    while (Test-Path -LiteralPath $path) {
        $counter++
        $path = Join-Path $directory "$stamp-$counter-$suffix.json"
    }
    $document = [ordered]@{
        schema      = 'pbi-superpower/evidence/1.0'
        kind        = $Kind
        createdUtc  = $now.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        environment = $environmentName
        repository  = [ordered]@{
            commit = Get-PbiProperty $GitContext 'Commit'
            branch = Get-PbiProperty $GitContext 'Branch'
            dirty  = Test-PbiTruthy -Value (Get-PbiProperty $GitContext 'IsDirty')
        }
        host        = [ordered]@{
            os   = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
            pwsh = $PSVersionTable.PSVersion.ToString()
        }
        data        = $Data
    }
    Write-PbiTextFile -Path $path -Content (ConvertTo-Json -InputObject $document -Depth 20)
    return $path
}

function Format-PbiMarkdownCell {
    # Private: masks identifiers and escapes a markdown table cell.
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )
    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }
    $masked = Protect-PbiText -Text $Text
    return $masked.Replace('|', '\|').Replace("`r`n", '<br>').Replace("`n", '<br>')
}

function ConvertTo-PbiEvidenceMarkdown {
    <#
    .SYNOPSIS
        Builds a masked markdown summary (for pull requests and release issues) from check results.
    .DESCRIPTION
        First line: **Outcome: Passed|Failed**. Then an optional title and a table | Level | Check | Status | Summary |.
        GUIDs are masked as <id> (and e-mail addresses as <email>). The outcome is Failed when any result has Status
        Failed, unless -Outcome is given.
    .PARAMETER Result
        Objects with Level, Check, Status and Summary properties.
    .PARAMETER Title
        Optional heading.
    .PARAMETER Outcome
        Passed or Failed (overrides the computed outcome).
    .EXAMPLE
        ConvertTo-PbiEvidenceMarkdown -Result $gate.Checks -Title 'Quality gate (pr)' -Outcome $gate.Outcome
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Result,

        [string] $Title,

        [ValidateSet('', 'Passed', 'Failed')]
        [string] $Outcome = ''
    )
    $effectiveOutcome = $Outcome
    if ([string]::IsNullOrEmpty($effectiveOutcome)) {
        $effectiveOutcome = 'Passed'
        foreach ($item in $Result) {
            if ([string](Get-PbiProperty $item 'Status' '') -eq 'Failed') {
                $effectiveOutcome = 'Failed'
                break
            }
        }
    }
    $builder = [System.Text.StringBuilder]::new()
    $null = $builder.AppendLine("**Outcome: $effectiveOutcome**")
    $null = $builder.AppendLine()
    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $null = $builder.AppendLine('### ' + (Format-PbiMarkdownCell -Text $Title))
        $null = $builder.AppendLine()
    }
    $null = $builder.AppendLine('| Level | Check | Status | Summary |')
    $null = $builder.AppendLine('| --- | --- | --- | --- |')
    foreach ($item in $Result) {
        $cells = foreach ($name in @('Level', 'Check', 'Status', 'Summary')) {
            Format-PbiMarkdownCell -Text ([string](Get-PbiProperty $item $name ''))
        }
        $null = $builder.AppendLine('| ' + ($cells -join ' | ') + ' |')
    }
    return $builder.ToString()
}

#endregion Evidence

#region GitHub CLI wrapper

function Invoke-PbiGh {
    <#
    .SYNOPSIS
        Runs the GitHub CLI (gh) with an argument array and returns stdout (or parsed JSON with -Json).
    .DESCRIPTION
        Arguments are passed as an array (no string concatenation). Prompts are disabled. A non-zero exit code throws
        with gh's error output.
    .PARAMETER Arguments
        gh arguments, one element per argument.
    .PARAMETER Json
        Parse stdout as JSON (arrays are returned unrolled; wrap the call in @()).
    .PARAMETER WorkingDirectory
        Directory to run in (gh resolves the repository from it).
    .EXAMPLE
        $issue = Invoke-PbiGh -Arguments @('issue', 'view', '42', '--json', 'labels,state') -Json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [switch] $Json,

        [string] $WorkingDirectory
    )
    $gh = Get-Command -Name 'gh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $gh) {
        throw "GitHub CLI (gh) was not found on PATH. Install it from https://cli.github.com and run 'gh auth login'."
    }
    $run = Invoke-PbiNativeCommand -FilePath $gh.Source -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -Environment @{ GH_PROMPT_DISABLED = '1'; GH_NO_UPDATE_NOTIFIER = '1' }
    if ($run.ExitCode -ne 0) {
        $commandText = @($Arguments | Select-Object -First 2) -join ' '
        $errorText = @(@($run.StdErr) + @($run.StdOut) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 15) -join ' '
        throw "gh $commandText failed (exit $($run.ExitCode)): $errorText"
    }
    $text = (@($run.StdOut) -join "`n").Trim()
    if ($Json) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            return
        }
        return (ConvertFrom-Json -InputObject $text -Depth 100)
    }
    return $text
}

#endregion GitHub CLI wrapper

Export-ModuleMember -Function @(
    'Set-PbiLogMode'
    'Write-PbiLog'
    'Write-PbiWarning'
    'Get-PbiLogWarning'
    'Split-PbiListArgument'
    'Invoke-PbiNativeCommand'
    'Read-PbiTextFile'
    'Write-PbiTextFile'
    'Read-PbiJsonFile'
    'Get-PbiRelativePath'
    'ConvertTo-PbiVersion'
    'Get-PbiContentHash'
    'Get-PbiRepoRoot'
    'Get-PbiProperty'
    'Expand-PbiPlaceholder'
    'Get-PbiEnvironmentConfig'
    'Get-PbiGateConfig'
    'Get-PbiToolVersions'
    'Get-PbiProject'
    'Get-PbiGitContext'
    'Assert-PbiDeploymentGuard'
    'Connect-PbiFabric'
    'Get-PbiAccessToken'
    'Invoke-PbiFabricApi'
    'Invoke-PbiFabricApiPaged'
    'Get-PbiCapacity'
    'Get-PbiWorkspace'
    'Deploy-PbiWorkspace'
    'Get-PbipDefinitionPart'
    'Set-PbipSemanticModelParameter'
    'Set-PbipReportBinding'
    'Get-PbiItem'
    'Publish-PbiSemanticModel'
    'Publish-PbiReport'
    'Invoke-PbiDatasetRefresh'
    'Invoke-PbiDaxQuery'
    'Get-PbiDesktopInstance'
    'Import-PbiAdomdClient'
    'Invoke-PbiLocalDaxQuery'
    'Get-PbiDaxTestFile'
    'Get-PbiDaxTestDirective'
    'Invoke-PbiDaxTestSuite'
    'New-PbiFinding'
    'Test-PbiRepoHygiene'
    'Test-PbipProjectStructure'
    'Test-PbiTmdlConvention'
    'Test-PbiReportConvention'
    'Test-PbiAgentAsset'
    'Test-PbiMcpConfigParity'
    'Test-PbiModelBpa'
    'Test-PbiSuperpowersManifest'
    'Test-PbiQualityGate'
    'New-PbiEvidence'
    'ConvertTo-PbiEvidenceMarkdown'
    'Protect-PbiText'
    'Invoke-PbiGh'
)
