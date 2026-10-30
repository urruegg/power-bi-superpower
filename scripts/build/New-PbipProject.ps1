#Requires -Version 7.4
<#
.SYNOPSIS
    Creates a new PBIP project under src/<Name> from templates/ (TMDL semantic model + report blueprint).
.DESCRIPTION
    - Copies templates/semantic-model/ to src/<Name>/<Name>.SemanticModel/ and replaces the tokens __MODEL_NAME__,
      __LOGICAL_ID__ (new GUID), __DATABASE_ID__ (new GUID) and __DESCRIPTION__ in every text file (and file name).
    - Copies templates/report-blueprint.json to src/<Name>/report-blueprint.json (replacing __MODEL_NAME__).
    - Creates src/<Name>/README.md.
    - With -WithReport, scaffolds the report with scripts/build/New-PbipReport.ps1.
    Refuses when src/<Name> already exists. Exit codes: 0 success, 1 report scaffolding failed, 2 usage error.
.PARAMETER Name
    PascalCase project name matching ^[A-Z][A-Za-z0-9]{2,40}$ (for example SalesStarter).
.PARAMETER Description
    One-line description (README and the __DESCRIPTION__ token).
.PARAMETER WithReport
    Also scaffold the report from the blueprint (needs the powerbi-report-author CLI).
.EXAMPLE
    pwsh -NoProfile -File scripts/build/New-PbipProject.ps1 -Name FinanceOverview -Description 'Monthly finance KPIs'
.EXAMPLE
    pwsh -NoProfile -File scripts/build/New-PbipProject.ps1 -Name FinanceOverview -WithReport
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Name,

    [string] $Description = '',

    [switch] $WithReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'PbiSuperpower' 'PbiSuperpower.psd1') -Force
Set-PbiLogMode

$textExtensions = @('.tmdl', '.json', '.pbism', '.pbir', '.pbip', '.dax', '.md', '.txt', '.platform', '.m', '.yml', '.yaml', '')

function Copy-TemplateFile {
    <#
    .SYNOPSIS
        Copies one template file, replacing tokens in text files (encoding and BOM preserved).
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Source,

        [Parameter(Mandatory)]
        [string] $Destination,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Tokens
    )
    $directory = Split-Path -Path $Destination -Parent
    $null = New-Item -ItemType Directory -Path $directory -Force
    $extension = [System.IO.Path]::GetExtension($Source).ToLowerInvariant()
    $bytes = [System.IO.File]::ReadAllBytes($Source)
    $isText = ($textExtensions -contains $extension) -and ([Array]::IndexOf($bytes, [byte]0) -lt 0)
    if (-not $isText) {
        [System.IO.File]::WriteAllBytes($Destination, $bytes)
        return
    }
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
    foreach ($token in $Tokens.Keys) {
        $text = $text.Replace([string]$token, [string]$Tokens[$token])
    }
    [System.IO.File]::WriteAllText($Destination, $text, [System.Text.UTF8Encoding]::new($hasBom))
}

try {
    if ($Name -cnotmatch '^[A-Z][A-Za-z0-9]{2,40}$') {
        throw "Invalid project name '$Name'. Use PascalCase letters and digits, 3-41 characters, starting with an upper-case letter (for example SalesStarter)."
    }
    $repoRoot = Get-PbiRepoRoot -Path $PSScriptRoot
    $templateModel = Join-Path $repoRoot 'templates' 'semantic-model'
    $templateBlueprint = Join-Path $repoRoot 'templates' 'report-blueprint.json'
    if (-not (Test-Path -LiteralPath $templateModel -PathType Container)) {
        throw 'templates/semantic-model was not found.'
    }
    $projectFolder = Join-Path $repoRoot 'src' $Name
    if (Test-Path -LiteralPath $projectFolder) {
        throw "src/$Name already exists. Choose another name or edit the existing project."
    }
} catch {
    Write-PbiLog $_.Exception.Message -Level Error
    exit 2
}

$tokens = [ordered]@{
    '__MODEL_NAME__'  = $Name
    '__LOGICAL_ID__'  = [guid]::NewGuid().ToString()
    '__DATABASE_ID__' = [guid]::NewGuid().ToString()
    '__DESCRIPTION__' = $Description
}
$modelFolder = Join-Path $projectFolder "$Name.SemanticModel"
Write-PbiLog "Creating src/$Name from templates/semantic-model..." -Level Step
try {
    foreach ($file in @(Get-ChildItem -LiteralPath $templateModel -Recurse -File -Force)) {
        $relative = [System.IO.Path]::GetRelativePath($templateModel, $file.FullName)
        foreach ($token in $tokens.Keys) {
            $relative = $relative.Replace([string]$token, [string]$tokens[$token])
        }
        Copy-TemplateFile -Source $file.FullName -Destination (Join-Path $modelFolder $relative) -Tokens $tokens
    }
    if (Test-Path -LiteralPath $templateBlueprint -PathType Leaf) {
        Copy-TemplateFile -Source $templateBlueprint -Destination (Join-Path $projectFolder 'report-blueprint.json') -Tokens @{ '__MODEL_NAME__' = $Name }
    } else {
        Write-PbiWarning 'templates/report-blueprint.json was not found; no blueprint was created.'
    }
    $summaryLine = $Description
    if ([string]::IsNullOrWhiteSpace($summaryLine)) {
        $summaryLine = 'Describe the purpose, audience and data sources of this model.'
    }
    $readme = @"
# $Name

$summaryLine

| Item | Path |
| --- | --- |
| Semantic model (TMDL) | ``$Name.SemanticModel/`` |
| Report (PBIR) | ``$Name.Report/`` (scaffold with ``scripts/build/New-PbipReport.ps1 -ProjectPath src/$Name``) |
| Report blueprint | ``report-blueprint.json`` |
| DAX tests | ``$Name.SemanticModel/DAXQueries/*.Tests.dax`` |

## Work on it

1. Scaffold the report once: ``pwsh scripts/build/New-PbipReport.ps1 -ProjectPath src/$Name``
2. Open ``$Name.pbip`` in Power BI Desktop.
3. Write DAX tests first (``*.ALL.Tests.dax``), then measures; run ``pwsh scripts/quality/Invoke-PbiDaxTests.ps1 -ProjectPath src/$Name -Target Local``.
4. Before a pull request: ``pwsh scripts/quality/Invoke-PbiQualityGate.ps1 -Profile pr -Target Local``.
5. Add the project to ``config/environments/*.json`` to deploy it.
"@
    Write-PbiTextFile -Path (Join-Path $projectFolder 'README.md') -Content ($readme.Replace("`r`n", "`n") + "`n")
} catch {
    Write-PbiLog "Creating the project failed: $($_.Exception.Message). Remove src/$Name and try again." -Level Error
    exit 2
}
Write-PbiLog "Created src/$Name." -Level Success

if ($WithReport) {
    $global:LASTEXITCODE = 0
    $null = & (Join-Path $PSScriptRoot 'New-PbipReport.ps1') -ProjectPath $projectFolder
    $reportExit = $global:LASTEXITCODE
    if ($null -eq $reportExit) {
        $reportExit = 0
    }
    if ($reportExit -ne 0) {
        Write-PbiLog "The project was created but the report could not be scaffolded (exit $reportExit). Fix the cause and run scripts/build/New-PbipReport.ps1 -ProjectPath src/$Name." -Level Error
        exit 1
    }
}

Write-Host ''
Write-PbiLog 'Next steps' -Level Step
if (-not $WithReport) {
    Write-Host "  - Scaffold the report: pwsh scripts/build/New-PbipReport.ps1 -ProjectPath src/$Name"
}
Write-Host "  - Add src/$Name to config/environments/dev.json (projects[]) to deploy it."
Write-Host '  - Run the commit gate: pwsh scripts/quality/Invoke-PbiQualityGate.ps1 -Profile commit'
exit 0
