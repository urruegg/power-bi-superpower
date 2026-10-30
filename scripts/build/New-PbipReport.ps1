#Requires -Version 7.4
<#
.SYNOPSIS
    Scaffolds the PBIR report of a project with the official powerbi-report-author CLI and lays out the blueprint visuals.
.DESCRIPTION
    1. Requires powerbi-report-author on PATH (npm install -g @microsoft/powerbi-report-authoring-cli@latest).
    2. The report name defaults to the project folder name; <Name>.SemanticModel must exist.
    3. Refuses when <Name>.Report already exists (use -Force to re-scaffold).
    4. powerbi-report-author scaffold "<ProjectPath>" --name "<Name>" --model-path "../<Name>.SemanticModel"
       --page-name "<PageName>" [--force] [--offline].
    5. When a blueprint exists (-Blueprint or <ProjectPath>/report-blueprint.json), writes one visual.json per
       blueprint visual on the first page (pages.json pageOrder[0]). Folder name = first 20 hex characters of the
       SHA-1 of the blueprint visual id (deterministic). Layout: 12-column grid with margin 24 px and gutter 16 px;
       rowHeight = (pageHeight - 2 * margin) / grid.rows; z and tabOrder = (index + 1) * 1000. Kinds: card
       (cardVisual), columnChart / barChart / lineChart (clusteredColumnChart / clusteredBarChart / lineChart), table
       (tableEx) and slicer. Every visual gets a title, alt text and drillFilterOtherVisuals = true.
    6. powerbi-report-author validate "<ReportFolder>" (exit 1 when it fails).
    7. Prints the next steps.
    Exit codes: 0 success, 1 the CLI failed (scaffold or validate), 2 usage/prerequisite error.
.PARAMETER ProjectPath
    Project folder (for example src/SalesStarter).
.PARAMETER Name
    Report/model base name (default: the project folder name).
.PARAMETER PageName
    Name of the first page (default 'Overview', or page.displayName of the blueprint).
.PARAMETER Blueprint
    Path of a report-blueprint.json (default: <ProjectPath>/report-blueprint.json when present).
.PARAMETER Force
    Re-scaffold an existing report (passes --force to the CLI).
.PARAMETER Offline
    Pass --offline to the CLI.
.EXAMPLE
    pwsh -NoProfile -File scripts/build/New-PbipReport.ps1 -ProjectPath src/SalesStarter
.EXAMPLE
    pwsh -NoProfile -File scripts/build/New-PbipReport.ps1 -ProjectPath src/SalesStarter -Force -Offline
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ProjectPath,

    [string] $Name,

    [string] $PageName = 'Overview',

    [string] $Blueprint,

    [switch] $Force,

    [switch] $Offline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'PbiSuperpower' 'PbiSuperpower.psd1') -Force
Set-PbiLogMode

$supportedKinds = @{
    card        = 'cardVisual'
    columnChart = 'clusteredColumnChart'
    barChart    = 'clusteredBarChart'
    lineChart   = 'lineChart'
    table       = 'tableEx'
    slicer      = 'slicer'
}
$visualSchema = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definition/visualContainer/2.9.0/schema.json'

function Resolve-InputPath {
    <#
    .SYNOPSIS
        Resolves a path given relative to the current location or to the repository root.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $RepoRoot
    )
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    $fromCurrent = (Get-Location -PSProvider FileSystem).ProviderPath
    $candidate = Join-Path $fromCurrent $Path
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }
    return (Join-Path $RepoRoot $Path)
}

function ConvertTo-DaxLiteral {
    <#
    .SYNOPSIS
        PBIR literal text value: the text in single quotes with single quotes doubled.
    #>
    param(
        [AllowEmptyString()]
        [string] $Text
    )
    return "'" + $Text.Replace("'", "''") + "'"
}

function New-FieldReference {
    <#
    .SYNOPSIS
        PBIR field reference for a measure or column.
    #>
    param(
        [ValidateSet('Measure', 'Column')]
        [string] $Kind,

        [string] $Table,

        [string] $Property
    )
    $reference = [ordered]@{
        Expression = [ordered]@{ SourceRef = [ordered]@{ Entity = $Table } }
        Property   = $Property
    }
    $field = [ordered]@{}
    $field[$Kind] = $reference
    return $field
}

function New-Projection {
    <#
    .SYNOPSIS
        PBIR query projection for a measure or column.
    #>
    param(
        [ValidateSet('Measure', 'Column')]
        [string] $Kind,

        [string] $Table,

        [string] $Property,

        [switch] $Active
    )
    $projection = [ordered]@{
        field          = New-FieldReference -Kind $Kind -Table $Table -Property $Property
        queryRef       = "$Table.$Property"
        nativeQueryRef = $Property
    }
    if ($Active) {
        $projection['active'] = $true
    }
    return $projection
}

function Get-BlueprintFieldList {
    <#
    .SYNOPSIS
        Returns @{ Table; Name } entries of a blueprint field list (measures, category or columns).
    #>
    param(
        [AllowNull()]
        [object] $Visual,

        [string] $ListName,

        [string] $NameProperty
    )
    foreach ($entry in @(Get-PbiProperty $Visual $ListName)) {
        $table = [string](Get-PbiProperty $entry 'table' '')
        $fieldName = [string](Get-PbiProperty $entry $NameProperty '')
        if ([string]::IsNullOrWhiteSpace($table) -or [string]::IsNullOrWhiteSpace($fieldName)) {
            throw "Blueprint visual '$(Get-PbiProperty $Visual 'id' '?')': every entry of '$ListName' needs 'table' and '$NameProperty'."
        }
        @{ Table = $table; Name = $fieldName }
    }
}

function New-BlueprintVisual {
    <#
    .SYNOPSIS
        Builds the visual.json content of one blueprint visual.
    #>
    param(
        [Parameter(Mandatory)]
        [object] $Visual,

        [Parameter(Mandatory)]
        [string] $VisualName,

        [Parameter(Mandatory)]
        [hashtable] $Position
    )
    $id = [string](Get-PbiProperty $Visual 'id' '')
    $kind = [string](Get-PbiProperty $Visual 'kind' '')
    $title = [string](Get-PbiProperty $Visual 'title' $id)
    $altText = [string](Get-PbiProperty $Visual 'altText' $title)
    $measures = @(Get-BlueprintFieldList -Visual $Visual -ListName 'measures' -NameProperty 'measure')
    $categories = @(Get-BlueprintFieldList -Visual $Visual -ListName 'category' -NameProperty 'column')
    $columns = @(Get-BlueprintFieldList -Visual $Visual -ListName 'columns' -NameProperty 'column')
    $query = [ordered]@{}
    if ($kind -eq 'card') {
        if ($measures.Count -eq 0) {
            throw "Blueprint visual '$id' (card) needs at least one entry in 'measures'."
        }
        $query['queryState'] = [ordered]@{
            Data = [ordered]@{ projections = @($measures | ForEach-Object { New-Projection -Kind 'Measure' -Table $_.Table -Property $_.Name }) }
        }
    } elseif (@('columnChart', 'barChart', 'lineChart') -contains $kind) {
        if ($categories.Count -eq 0 -or $measures.Count -eq 0) {
            throw "Blueprint visual '$id' ($kind) needs 'category' and 'measures'."
        }
        $query['queryState'] = [ordered]@{
            Category = [ordered]@{ projections = @($categories | ForEach-Object { New-Projection -Kind 'Column' -Table $_.Table -Property $_.Name -Active }) }
            Y        = [ordered]@{ projections = @($measures | ForEach-Object { New-Projection -Kind 'Measure' -Table $_.Table -Property $_.Name }) }
        }
        if ([string](Get-PbiProperty $Visual 'sort' '') -eq 'category-asc') {
            $query['sortDefinition'] = [ordered]@{
                sort          = @([ordered]@{
                        field     = New-FieldReference -Kind 'Column' -Table $categories[0].Table -Property $categories[0].Name
                        direction = 'Ascending'
                    })
                isDefaultSort = $true
            }
        }
    } elseif ($kind -eq 'table') {
        if ($columns.Count -eq 0 -and $measures.Count -eq 0) {
            throw "Blueprint visual '$id' (table) needs 'columns' and/or 'measures'."
        }
        $projections = @($columns | ForEach-Object { New-Projection -Kind 'Column' -Table $_.Table -Property $_.Name }) +
            @($measures | ForEach-Object { New-Projection -Kind 'Measure' -Table $_.Table -Property $_.Name })
        $query['queryState'] = [ordered]@{ Values = [ordered]@{ projections = $projections } }
    } elseif ($kind -eq 'slicer') {
        if ($columns.Count -eq 0) {
            throw "Blueprint visual '$id' (slicer) needs one entry in 'columns'."
        }
        $query['queryState'] = [ordered]@{
            Values = [ordered]@{ projections = @(New-Projection -Kind 'Column' -Table $columns[0].Table -Property $columns[0].Name -Active) }
        }
    } else {
        throw "Blueprint visual '$id' has the unsupported kind '$kind' (supported: $(@($supportedKinds.Keys | Sort-Object) -join ', '))."
    }
    $titleObject = [ordered]@{
        properties = [ordered]@{
            show = [ordered]@{ expr = [ordered]@{ Literal = [ordered]@{ Value = 'true' } } }
            text = [ordered]@{ expr = [ordered]@{ Literal = [ordered]@{ Value = (ConvertTo-DaxLiteral -Text $title) } } }
        }
    }
    $generalObject = [ordered]@{
        properties = [ordered]@{
            altText = [ordered]@{ expr = [ordered]@{ Literal = [ordered]@{ Value = (ConvertTo-DaxLiteral -Text $altText) } } }
        }
    }
    return [ordered]@{
        '$schema' = $visualSchema
        name      = $VisualName
        position  = [ordered]@{
            x        = $Position.X
            y        = $Position.Y
            z        = $Position.Z
            height   = $Position.Height
            width    = $Position.Width
            tabOrder = $Position.Z
        }
        visual    = [ordered]@{
            visualType              = $supportedKinds[$kind]
            query                   = $query
            visualContainerObjects  = [ordered]@{
                title   = @($titleObject)
                general = @($generalObject)
            }
            drillFilterOtherVisuals = $true
        }
    }
}

try {
    $repoRoot = Get-PbiRepoRoot -Path $PSScriptRoot
    $cli = Get-Command -Name 'powerbi-report-author' -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $cli) {
        throw 'powerbi-report-author was not found on PATH. Install it with: npm install -g @microsoft/powerbi-report-authoring-cli@latest (or run scripts/bootstrap/Install-PbiTooling.ps1).'
    }
    $project = Resolve-InputPath -Path $ProjectPath -RepoRoot $repoRoot
    if (-not (Test-Path -LiteralPath $project -PathType Container)) {
        throw "Project folder not found: $ProjectPath"
    }
    $project = (Resolve-Path -LiteralPath $project).ProviderPath
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = Split-Path -Path $project -Leaf
    }
    $modelFolder = Join-Path $project "$Name.SemanticModel"
    if (-not (Test-Path -LiteralPath $modelFolder -PathType Container)) {
        throw "Semantic model folder '$Name.SemanticModel' not found in $ProjectPath. Create the project with scripts/build/New-PbipProject.ps1 or pass -Name."
    }
    $reportFolder = Join-Path $project "$Name.Report"
    if ((Test-Path -LiteralPath $reportFolder) -and -not $Force) {
        throw "'$Name.Report' already exists (already scaffolded). Use -Force to re-scaffold it."
    }
    $blueprintPath = $null
    if (-not [string]::IsNullOrWhiteSpace($Blueprint)) {
        $blueprintPath = Resolve-InputPath -Path $Blueprint -RepoRoot $repoRoot
        if (-not (Test-Path -LiteralPath $blueprintPath -PathType Leaf)) {
            throw "Blueprint not found: $Blueprint"
        }
    } elseif (Test-Path -LiteralPath (Join-Path $project 'report-blueprint.json') -PathType Leaf) {
        $blueprintPath = Join-Path $project 'report-blueprint.json'
    }
    $blueprintObject = $null
    if ($null -ne $blueprintPath) {
        $blueprintObject = Read-PbiJsonFile -Path $blueprintPath -Description 'Report blueprint'
        $blueprintPage = [string](Get-PbiProperty (Get-PbiProperty $blueprintObject 'page') 'displayName' '')
        if (-not $PSBoundParameters.ContainsKey('PageName') -and -not [string]::IsNullOrWhiteSpace($blueprintPage)) {
            $PageName = $blueprintPage
        }
        $ids = @(Get-PbiProperty $blueprintObject 'visuals' | ForEach-Object { [string](Get-PbiProperty $_ 'id' '') })
        if ($ids.Count -eq 0) {
            throw 'The blueprint has no visuals.'
        }
        if (@($ids | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw 'Every blueprint visual needs an id.'
        }
        $duplicates = @($ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        if ($duplicates.Count -gt 0) {
            throw "Duplicate blueprint visual id(s): $($duplicates -join ', ')."
        }
        foreach ($blueprintVisual in @(Get-PbiProperty $blueprintObject 'visuals')) {
            $blueprintKind = [string](Get-PbiProperty $blueprintVisual 'kind' '')
            if (-not $supportedKinds.ContainsKey($blueprintKind)) {
                throw ("Blueprint visual '{0}' has the unsupported kind '{1}' (supported: {2})." -f (Get-PbiProperty $blueprintVisual 'id' ''), $blueprintKind, (@($supportedKinds.Keys | Sort-Object) -join ', '))
            }
        }
    }
} catch {
    Write-PbiLog $_.Exception.Message -Level Error
    exit 2
}

Write-PbiLog "Scaffolding $Name.Report with powerbi-report-author..." -Level Step
$scaffoldArguments = @('scaffold', $project, '--name', $Name, '--model-path', "../$Name.SemanticModel", '--page-name', $PageName)
if ($Force) {
    $scaffoldArguments += '--force'
}
if ($Offline) {
    $scaffoldArguments += '--offline'
}
$scaffold = Invoke-PbiNativeCommand -FilePath $cli.Source -ArgumentList $scaffoldArguments
foreach ($line in @($scaffold.StdOut) + @($scaffold.StdErr)) {
    Write-Host "  $line"
}
if ($scaffold.ExitCode -ne 0) {
    Write-PbiLog "powerbi-report-author scaffold failed (exit $($scaffold.ExitCode))." -Level Error
    exit 1
}

if ($null -ne $blueprintObject) {
    try {
        Write-PbiLog "Applying blueprint $(Get-PbiRelativePath -Path $blueprintPath -RepoRoot $repoRoot)..." -Level Step
        $pagesDirectory = Join-Path $reportFolder 'definition' 'pages'
        $pageOrder = @(Get-PbiProperty (Read-PbiJsonFile -Path (Join-Path $pagesDirectory 'pages.json') -Description 'pages.json') 'pageOrder')
        $pageFolder = $null
        if ($pageOrder.Count -gt 0) {
            $pageFolder = Join-Path $pagesDirectory ([string]$pageOrder[0])
        } else {
            $firstFolder = Get-ChildItem -LiteralPath $pagesDirectory -Directory | Sort-Object -Property Name | Select-Object -First 1
            if ($null -ne $firstFolder) {
                $pageFolder = $firstFolder.FullName
            }
        }
        if ($null -eq $pageFolder -or -not (Test-Path -LiteralPath $pageFolder -PathType Container)) {
            throw 'The scaffolded report has no page folder.'
        }
        $page = Read-PbiJsonFile -Path (Join-Path $pageFolder 'page.json') -Description 'page.json'
        $pageWidth = [double](Get-PbiProperty $page 'width' 1280)
        $pageHeight = [double](Get-PbiProperty $page 'height' 720)
        $grid = Get-PbiProperty $blueprintObject 'grid'
        $columnCount = [int](Get-PbiProperty $grid 'columns' 12)
        $rowCount = [int](Get-PbiProperty $grid 'rows' 8)
        if ($columnCount -lt 1 -or $rowCount -lt 1) {
            throw 'grid.columns and grid.rows must be positive.'
        }
        $margin = 24
        $gutter = 16
        $columnWidth = ($pageWidth - 2 * $margin - ($columnCount - 1) * $gutter) / $columnCount
        $rowHeight = ($pageHeight - 2 * $margin) / $rowCount
        $visuals = @(Get-PbiProperty $blueprintObject 'visuals')
        for ($index = 0; $index -lt $visuals.Count; $index++) {
            $visual = $visuals[$index]
            $id = [string](Get-PbiProperty $visual 'id' '')
            $layout = Get-PbiProperty $visual 'layout'
            $column = [int](Get-PbiProperty $layout 'col' 0)
            $row = [int](Get-PbiProperty $layout 'row' 0)
            $columnSpan = [int](Get-PbiProperty $layout 'colSpan' 1)
            $rowSpan = [int](Get-PbiProperty $layout 'rowSpan' 1)
            if ($column -lt 0 -or $row -lt 0 -or $columnSpan -lt 1 -or $rowSpan -lt 1 -or ($column + $columnSpan) -gt $columnCount -or ($row + $rowSpan) -gt $rowCount) {
                throw "Blueprint visual '$id': layout {col $column, row $row, colSpan $columnSpan, rowSpan $rowSpan} does not fit the $columnCount x $rowCount grid."
            }
            $z = ($index + 1) * 1000
            $position = @{
                X      = [int][Math]::Round($margin + $column * ($columnWidth + $gutter), 0)
                Y      = [int][Math]::Round($margin + $row * $rowHeight, 0)
                Width  = [int][Math]::Round($columnSpan * $columnWidth + ($columnSpan - 1) * $gutter, 0)
                Height = [int][Math]::Round([Math]::Max(40, $rowSpan * $rowHeight - $gutter), 0)
                Z      = $z
            }
            $hash = [System.Security.Cryptography.SHA1]::HashData([System.Text.Encoding]::UTF8.GetBytes($id))
            $visualName = [System.Convert]::ToHexString($hash).ToLowerInvariant().Substring(0, 20)
            $content = New-BlueprintVisual -Visual $visual -VisualName $visualName -Position $position
            $visualFile = Join-Path $pageFolder 'visuals' $visualName 'visual.json'
            Write-PbiTextFile -Path $visualFile -Content (ConvertTo-Json -InputObject $content -Depth 50)
            Write-PbiLog ("  {0} ({1}) -> visuals/{2}" -f $id, (Get-PbiProperty $visual 'kind' ''), $visualName)
        }
    } catch {
        Write-PbiLog "Applying the blueprint failed: $($_.Exception.Message)" -Level Error
        exit 2
    }
}

Write-PbiLog 'Validating the report with powerbi-report-author...' -Level Step
$validation = Invoke-PbiNativeCommand -FilePath $cli.Source -ArgumentList @('validate', $reportFolder)
foreach ($line in @($validation.StdOut) + @($validation.StdErr)) {
    Write-Host "  $line"
}
if ($validation.ExitCode -ne 0) {
    Write-PbiLog "powerbi-report-author validate failed (exit $($validation.ExitCode)). Fix the reported files and run it again." -Level Error
    exit 1
}

$relativeProject = Get-PbiRelativePath -Path $project -RepoRoot $repoRoot
Write-PbiLog "Report $Name.Report is ready." -Level Success
Write-Host ''
Write-PbiLog 'Next steps' -Level Step
Write-Host "  - Open $relativeProject/$Name.pbip in Power BI Desktop to review the page."
Write-Host "  - Or preview it: powerbi-report-author preview `"$relativeProject/$Name.Report`" --host desktop"
Write-Host '  - Then run the gate: pwsh scripts/quality/Invoke-PbiQualityGate.ps1 -Profile commit'
exit 0
