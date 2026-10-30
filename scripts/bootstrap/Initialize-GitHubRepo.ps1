#Requires -Version 7.4
<#
.SYNOPSIS
    Creates (or connects) the GitHub repository and applies labels, the main-branch ruleset and optionally a project.
.DESCRIPTION
    Idempotent; safe to re-run. Requires an authenticated GitHub CLI (gh auth login).
      1. git init -b main when the folder is not a Git repository; git config core.hooksPath .githooks
         (and core.autocrlf true on Windows); an initial commit when there is none.
      2. gh repo create <owner>/<name> --<visibility> --source . --remote origin [--push]; when the repository already
         exists, adds the 'origin' remote if missing and pushes main (unless -SkipPush).
      3. Labels from config/github/labels.json ([{ name, color, description }]) via gh label create --force.
      4. Unless -SkipRuleset: creates the ruleset from config/github/ruleset-main.json when no ruleset with the same
         name exists (HTTP 403/422 -> warning: rulesets on private repositories need GitHub Pro/Team).
      5. With -CreateProject: creates the GitHub Project from config/github/project.json (title, single-select fields),
         links it to the repository and saves { owner, number } to config/github/project.local.json (git-ignored).
    Milestones are created by scripts/sprint/New-PbiSprint.ps1, not here. Supports -WhatIf for every remote change.
    Exit codes: 0 success, 1 a step failed, 2 missing prerequisite or invalid arguments.
.PARAMETER Owner
    GitHub user or organisation.
.PARAMETER Name
    Repository name (default power-bi-superpower).
.PARAMETER Visibility
    private (default), internal (organisations only) or public.
.PARAMETER CreateProject
    Also create and link the GitHub Project (needs the 'project' scope: gh auth refresh -s project).
.PARAMETER SkipRuleset
    Do not create the main-branch ruleset.
.PARAMETER SkipPush
    Do not push the local main branch.
.EXAMPLE
    pwsh -NoProfile -File scripts/bootstrap/Initialize-GitHubRepo.ps1 -Owner contoso -CreateProject
.EXAMPLE
    pwsh -NoProfile -File scripts/bootstrap/Initialize-GitHubRepo.ps1 -Owner my-user -Visibility private -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$')]
    [string] $Owner,

    [ValidatePattern('^[A-Za-z0-9._-]{1,100}$')]
    [string] $Name = 'power-bi-superpower',

    [ValidateSet('private', 'internal', 'public')]
    [string] $Visibility = 'private',

    [switch] $CreateProject,

    [switch] $SkipRuleset,

    [switch] $SkipPush
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'PbiSuperpower' 'PbiSuperpower.psd1') -Force
Set-PbiLogMode

$repoSlug = "$Owner/$Name"
$summary = [System.Collections.Generic.List[string]]::new()
$failures = [System.Collections.Generic.List[string]]::new()

function Invoke-RepoGit {
    <#
    .SYNOPSIS
        Runs git in the repository root and throws on failure.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )
    $run = Invoke-PbiNativeCommand -FilePath 'git' -ArgumentList (@('-C', $repoRoot) + $Arguments)
    if ($run.ExitCode -ne 0) {
        throw ("git {0} failed (exit {1}): {2}" -f ($Arguments -join ' '), $run.ExitCode, ((@($run.StdErr) + @($run.StdOut)) -join ' '))
    }
    return $run
}

try {
    $repoRoot = Get-PbiRepoRoot -Path $PSScriptRoot
    foreach ($tool in @('git', 'gh')) {
        if ($null -eq (Get-Command -Name $tool -CommandType Application -ErrorAction SilentlyContinue)) {
            throw "$tool is not on PATH. Run scripts/bootstrap/Test-Prerequisites.ps1 for install hints."
        }
    }
    $auth = Invoke-PbiNativeCommand -FilePath 'gh' -ArgumentList @('auth', 'status') -Environment @{ GH_PROMPT_DISABLED = '1' }
    if ($auth.ExitCode -ne 0) {
        throw "The GitHub CLI is not authenticated. Run 'gh auth login' (and 'gh auth refresh -s project' for -CreateProject)."
    }
    $labelsPath = Join-Path $repoRoot 'config' 'github' 'labels.json'
    $labels = @(Read-PbiJsonFile -Path $labelsPath -Description 'Label definitions config/github/labels.json')
    $rulesetPath = Join-Path $repoRoot 'config' 'github' 'ruleset-main.json'
    $projectConfigPath = Join-Path $repoRoot 'config' 'github' 'project.json'
} catch {
    Write-PbiLog $_.Exception.Message -Level Error
    exit 2
}

try {
    Write-PbiLog 'Local Git repository' -Level Step
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.git'))) {
        if ($PSCmdlet.ShouldProcess($repoRoot, 'git init -b main')) {
            $null = Invoke-RepoGit -Arguments @('init', '-b', 'main')
            $summary.Add('Initialised a Git repository (main).')
        }
    }
    if (Test-Path -LiteralPath (Join-Path $repoRoot '.git')) {
        $null = Invoke-RepoGit -Arguments @('config', 'core.hooksPath', '.githooks')
        if ($IsWindows) {
            $null = Invoke-RepoGit -Arguments @('config', 'core.autocrlf', 'true')
        }
        $head = Invoke-PbiNativeCommand -FilePath 'git' -ArgumentList @('-C', $repoRoot, 'rev-parse', '--verify', '-q', 'HEAD')
        if ($head.ExitCode -ne 0 -and $PSCmdlet.ShouldProcess($repoRoot, 'Create the initial commit')) {
            $null = Invoke-RepoGit -Arguments @('add', '-A')
            # Keep the Git hooks executable for macOS/Linux clones (Windows ignores the bit).
            $null = Invoke-PbiNativeCommand -FilePath 'git' -ArgumentList @('-C', $repoRoot, 'update-index', '--chmod=+x', '.githooks/pre-commit', '.githooks/pre-push')
            $commit = Invoke-PbiNativeCommand -FilePath 'git' -ArgumentList @('-C', $repoRoot, 'commit', '-m', 'chore: initial commit (power-bi-superpower)')
            if ($commit.ExitCode -ne 0) {
                throw ("The initial commit failed: {0}. Configure git user.name/user.email and fix any pre-commit gate findings, then re-run." -f ((@($commit.StdErr) + @($commit.StdOut)) -join ' '))
            }
            $summary.Add('Created the initial commit.')
        }
    }

    Write-PbiLog "GitHub repository $repoSlug" -Level Step
    $view = Invoke-PbiNativeCommand -FilePath 'gh' -ArgumentList @('repo', 'view', $repoSlug, '--json', 'name') -Environment @{ GH_PROMPT_DISABLED = '1' }
    if ($view.ExitCode -ne 0) {
        if ($PSCmdlet.ShouldProcess($repoSlug, "Create $Visibility GitHub repository")) {
            $createArguments = @('repo', 'create', $repoSlug, "--$Visibility", '--source', $repoRoot, '--remote', 'origin')
            if (-not $SkipPush) {
                $createArguments += '--push'
            }
            $null = Invoke-PbiGh -Arguments $createArguments -WorkingDirectory $repoRoot
            $summary.Add("Created $Visibility repository $repoSlug.")
        }
    } else {
        $remote = Invoke-PbiNativeCommand -FilePath 'git' -ArgumentList @('-C', $repoRoot, 'remote', 'get-url', 'origin')
        if ($remote.ExitCode -ne 0 -and $PSCmdlet.ShouldProcess('origin', "git remote add origin https://github.com/$repoSlug.git")) {
            $null = Invoke-RepoGit -Arguments @('remote', 'add', 'origin', "https://github.com/$repoSlug.git")
            $summary.Add('Added the origin remote.')
        }
        if (-not $SkipPush -and $PSCmdlet.ShouldProcess($repoSlug, 'git push -u origin main')) {
            $push = Invoke-PbiNativeCommand -FilePath 'git' -ArgumentList @('-C', $repoRoot, 'push', '-u', 'origin', 'main') -Environment @{ GIT_TERMINAL_PROMPT = '0' }
            if ($push.ExitCode -ne 0) {
                Write-PbiWarning ("git push -u origin main failed (the ruleset may already protect main): {0}" -f ((@($push.StdErr) + @($push.StdOut)) -join ' '))
            } else {
                $summary.Add('Pushed main.')
            }
        }
    }

    Write-PbiLog "Labels ($($labels.Count))" -Level Step
    foreach ($label in $labels) {
        $labelName = [string](Get-PbiProperty $label 'name' '')
        if ([string]::IsNullOrWhiteSpace($labelName)) {
            continue
        }
        $color = ([string](Get-PbiProperty $label 'color' 'ededed')).TrimStart('#')
        $description = [string](Get-PbiProperty $label 'description' '')
        if ($PSCmdlet.ShouldProcess($repoSlug, "gh label create $labelName")) {
            try {
                $null = Invoke-PbiGh -Arguments @('label', 'create', $labelName, '--color', $color, '--description', $description, '--force', '--repo', $repoSlug)
            } catch {
                $failures.Add("Label ${labelName}: $($_.Exception.Message)")
            }
        }
    }
    $summary.Add("Ensured $($labels.Count) label(s).")

    if (-not $SkipRuleset) {
        Write-PbiLog 'Main branch ruleset' -Level Step
        $ruleset = Read-PbiJsonFile -Path $rulesetPath -Description 'Ruleset config/github/ruleset-main.json'
        $rulesetName = [string](Get-PbiProperty $ruleset 'name' '')
        $existing = @()
        try {
            $existing = @(Invoke-PbiGh -Arguments @('api', "repos/$repoSlug/rulesets") -Json)
        } catch {
            Write-Verbose "Could not list rulesets: $($_.Exception.Message)"
        }
        $exists = @($existing | Where-Object { [string](Get-PbiProperty $_ 'name' '') -eq $rulesetName }).Count -gt 0
        if ($exists) {
            Write-PbiLog "Ruleset '$rulesetName' already exists."
        } elseif ($PSCmdlet.ShouldProcess($repoSlug, "Create ruleset '$rulesetName'")) {
            try {
                $null = Invoke-PbiGh -Arguments @('api', "repos/$repoSlug/rulesets", '--method', 'POST', '--input', $rulesetPath)
                $summary.Add("Created ruleset '$rulesetName'.")
            } catch {
                if ($_.Exception.Message -match 'HTTP 40[34]|HTTP 422') {
                    Write-PbiWarning "The ruleset could not be created ($($_.Exception.Message)). Rulesets on private repositories need GitHub Pro, Team or Enterprise; protect main manually or make the repository public."
                } else {
                    $failures.Add("Ruleset: $($_.Exception.Message)")
                }
            }
        }
    }

    if ($CreateProject) {
        Write-PbiLog 'GitHub Project' -Level Step
        $projectConfig = Read-PbiJsonFile -Path $projectConfigPath -Description 'Project definition config/github/project.json'
        $title = [string](Get-PbiProperty $projectConfig 'title' 'Power BI Superpower')
        $localProjectPath = Join-Path $repoRoot 'config' 'github' 'project.local.json'
        $number = 0
        if (Test-Path -LiteralPath $localProjectPath -PathType Leaf) {
            $number = [int](Get-PbiProperty (Read-PbiJsonFile -Path $localProjectPath) 'number' 0)
        }
        if ($number -le 0) {
            $projects = Invoke-PbiGh -Arguments @('project', 'list', '--owner', $Owner, '--format', 'json', '--limit', '100') -Json
            $match = @(Get-PbiProperty $projects 'projects' | Where-Object { [string](Get-PbiProperty $_ 'title' '') -eq $title }) | Select-Object -First 1
            if ($null -ne $match) {
                $number = [int](Get-PbiProperty $match 'number' 0)
                Write-PbiLog "Reusing project '$title' (#$number)."
            }
        }
        if ($number -le 0 -and $PSCmdlet.ShouldProcess($Owner, "gh project create '$title'")) {
            $created = Invoke-PbiGh -Arguments @('project', 'create', '--owner', $Owner, '--title', $title, '--format', 'json') -Json
            $number = [int](Get-PbiProperty $created 'number' 0)
            if ($number -le 0) {
                throw 'gh project create did not return a project number.'
            }
            $summary.Add("Created project '$title' (#$number).")
        }
        if ($number -gt 0) {
            $fieldList = Invoke-PbiGh -Arguments @('project', 'field-list', [string]$number, '--owner', $Owner, '--format', 'json', '--limit', '100') -Json
            $existingFields = @(Get-PbiProperty $fieldList 'fields' | ForEach-Object { [string](Get-PbiProperty $_ 'name' '') })
            foreach ($field in @(Get-PbiProperty $projectConfig 'fields')) {
                $fieldName = [string](Get-PbiProperty $field 'name' '')
                $dataType = [string](Get-PbiProperty $field 'dataType' 'SINGLE_SELECT')
                $options = @(Get-PbiProperty $field 'options' | ForEach-Object { [string]$_ })
                if ([string]::IsNullOrWhiteSpace($fieldName) -or $existingFields -contains $fieldName) {
                    continue
                }
                if ($PSCmdlet.ShouldProcess("project #$number", "Create field '$fieldName'")) {
                    $fieldArguments = @('project', 'field-create', [string]$number, '--owner', $Owner, '--name', $fieldName, '--data-type', $dataType)
                    if ($dataType -eq 'SINGLE_SELECT') {
                        $fieldArguments += @('--single-select-options', ($options -join ','))
                    }
                    try {
                        $null = Invoke-PbiGh -Arguments $fieldArguments
                        $summary.Add("Created project field '$fieldName'.")
                    } catch {
                        $failures.Add("Project field ${fieldName}: $($_.Exception.Message)")
                    }
                }
            }
            if ($PSCmdlet.ShouldProcess("project #$number", "Link to $repoSlug")) {
                try {
                    $null = Invoke-PbiGh -Arguments @('project', 'link', [string]$number, '--owner', $Owner, '--repo', $repoSlug)
                } catch {
                    Write-PbiWarning "Linking the project failed (it may already be linked): $($_.Exception.Message)"
                }
                Write-PbiTextFile -Path $localProjectPath -Content (ConvertTo-Json -InputObject ([ordered]@{ owner = $Owner; number = $number }))
                $summary.Add('Saved config/github/project.local.json (git-ignored).')
            }
        }
    }
} catch {
    $failures.Add($_.Exception.Message)
}

Write-Host ''
Write-PbiLog 'Summary' -Level Step
foreach ($line in $summary) {
    Write-Host "  - $line"
}
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-PbiLog $failure -Level Error
    }
    exit 1
}
Write-PbiLog "Repository $repoSlug is ready. Next: scripts/sprint/New-PbiSprint.ps1 -Number 1 -Goal '<goal>'." -Level Success
exit 0
