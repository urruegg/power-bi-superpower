<#
.SYNOPSIS
    Guardrail rules for the GitHub Copilot preToolUse hook (Copilot CLI and VS Code agent mode).
.DESCRIPTION
    Dot-source this file and call Get-PbiToolUseDecision. It returns $null (allow / no opinion) or a hashtable
    @{ permissionDecision = 'deny'; permissionDecisionReason = '...'; ruleId = 'Rn'; subject = '<text that matched>' }.
    Rules (case-insensitive, first match wins); every reason tells the agent what to do instead:
      R1  PROD deployments and capacity changes (they affect every environment) are human-only.
      R2  No force push and no push to main.
      R3  No destructive remote calls (HTTP DELETE, Remove-Pbi*, capacity deletion, gh ... delete).
      R4  Approval gate labels (gate:*) are applied by humans only.
      R5  No reading or writing of secret files (.env*, except .env.example; *.pfx, *.pem, *.key, *.publishsettings; id_rsa).
      R6  No unrestricted Copilot CLI sessions (--allow-all-tools, --allow-all, --yolo).
      R7  Merging pull requests is a human decision.
    Compatible with Windows PowerShell 5.1 and PowerShell 7. Must stay fast and must never throw: on an internal
    error the function returns $null (fail-open; humans, CODEOWNERS, the ruleset and the PROD confirmation remain
    the real controls).
.EXAMPLE
    . ./scripts/hooks/GuardrailRules.ps1
    Get-PbiToolUseDecision -ToolName 'bash' -ToolArgs '{"command":"git push origin main"}'
#>
[CmdletBinding()]
param()

function Get-PbiGuardrailField {
    <#
    .SYNOPSIS
        Returns the first non-empty value of the given fields of a tool argument object, as text.
    .PARAMETER InputObject
        Tool arguments (PSCustomObject or dictionary).
    .PARAMETER Names
        Candidate field names.
    #>
    [CmdletBinding()]
    param(
        $InputObject,
        [string[]] $Names
    )
    if ($null -eq $InputObject -or $InputObject -is [string]) {
        return ''
    }
    foreach ($name in $Names) {
        $value = $null
        if ($InputObject -is [System.Collections.IDictionary]) {
            if ($InputObject.Contains($name)) {
                $value = $InputObject[$name]
            }
        } else {
            $property = $InputObject.PSObject.Properties[$name]
            if ($null -ne $property) {
                $value = $property.Value
            }
        }
        if ($null -eq $value) {
            continue
        }
        if ($value -is [string]) {
            if ($value.Length -gt 0) {
                return $value
            }
            continue
        }
        $parts = @()
        foreach ($item in @($value)) {
            $parts += [string]$item
        }
        $joined = $parts -join ' '
        if ($joined.Length -gt 0) {
            return $joined
        }
    }
    return ''
}

function Get-PbiGuardrailBranch {
    <#
    .SYNOPSIS
        Returns the checked-out branch for a working directory by reading .git/HEAD (no git process), or ''.
    .PARAMETER Cwd
        Working directory of the tool call.
    #>
    [CmdletBinding()]
    param(
        [string] $Cwd
    )
    if ([string]::IsNullOrEmpty($Cwd)) {
        return ''
    }
    try {
        $directory = $Cwd
        for ($depth = 0; $depth -lt 16; $depth++) {
            if ([string]::IsNullOrEmpty($directory)) {
                break
            }
            $gitPath = Join-Path $directory '.git'
            $gitDirectory = $null
            if (Test-Path -LiteralPath $gitPath -PathType Container) {
                $gitDirectory = $gitPath
            } elseif (Test-Path -LiteralPath $gitPath -PathType Leaf) {
                $pointer = [System.IO.File]::ReadAllText($gitPath).Trim()
                if ($pointer -match '^gitdir:\s*(.+)$') {
                    $gitDirectory = $Matches[1].Trim()
                    if (-not [System.IO.Path]::IsPathRooted($gitDirectory)) {
                        $gitDirectory = Join-Path $directory $gitDirectory
                    }
                }
            }
            if ($null -ne $gitDirectory) {
                $headPath = Join-Path $gitDirectory 'HEAD'
                if (-not (Test-Path -LiteralPath $headPath -PathType Leaf)) {
                    return ''
                }
                $head = [System.IO.File]::ReadAllText($headPath).Trim()
                if ($head -match '^ref:\s*refs/heads/(.+)$') {
                    return $Matches[1].Trim()
                }
                return ''
            }
            $parent = Split-Path -Path $directory -Parent
            if ([string]::IsNullOrEmpty($parent) -or $parent -eq $directory) {
                break
            }
            $directory = $parent
        }
    } catch {
        return ''
    }
    return ''
}

function Test-PbiGuardrailSecretReference {
    <#
    .SYNOPSIS
        $true when the text references a secret file (.env*, except .env.example; *.pfx/.pem/.key/.publishsettings; id_rsa).
    .PARAMETER Text
        A file path or a shell command.
    #>
    [CmdletBinding()]
    param(
        [string] $Text
    )
    if ([string]::IsNullOrEmpty($Text)) {
        return $false
    }
    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $envPattern = '(?<=^|[\\/\s''"=])\.env(\.[\w-]+)?(?=[''"\s;|)&]|$)'
    foreach ($match in [regex]::Matches($Text, $envPattern, $options)) {
        if ($match.Groups[1].Value -ne '.example') {
            return $true
        }
    }
    $keyPattern = '(?<=^|[\s''"=/\\])[^\s''"$]*\.(pfx|pem|key|publishsettings)(?=[''"\s;|)&]|$)'
    if ([regex]::IsMatch($Text, $keyPattern, $options)) {
        return $true
    }
    return [regex]::IsMatch($Text, 'id_rsa', $options)
}

function Get-PbiGuardrailExistingLabel {
    <#
    .SYNOPSIS
        Returns the current labels (lower case) of the issue or pull request named in the tool arguments, using gh.
        Returns an empty array when the number is unknown, gh is missing or the lookup fails.
    .PARAMETER ArgsObject
        Tool arguments (fields issue_number / pull_number / number, optional owner and repo).
    #>
    [CmdletBinding()]
    param(
        $ArgsObject
    )
    # Native stderr must not become a terminating error (Windows PowerShell 5.1 with ErrorActionPreference Stop).
    $ErrorActionPreference = 'Continue'
    try {
        $number = Get-PbiGuardrailField -InputObject $ArgsObject -Names @('issue_number', 'issueNumber', 'pull_number', 'pullNumber', 'number')
        if ([string]::IsNullOrEmpty($number) -or $number -notmatch '^\d+$') {
            return @()
        }
        $gh = Get-Command -Name 'gh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $gh) {
            return @()
        }
        $owner = Get-PbiGuardrailField -InputObject $ArgsObject -Names @('owner')
        $repo = Get-PbiGuardrailField -InputObject $ArgsObject -Names @('repo', 'repository')
        $repoArguments = @()
        if (-not [string]::IsNullOrEmpty($owner) -and -not [string]::IsNullOrEmpty($repo)) {
            $repoArguments = @('--repo', ($owner + '/' + $repo))
        }
        foreach ($kind in @('issue', 'pr')) {
            $arguments = @($kind, 'view', $number, '--json', 'labels', '--jq', '.labels[].name') + $repoArguments
            $output = & $gh.Path @arguments 2>$null
            if ($LASTEXITCODE -eq 0) {
                $names = @()
                foreach ($line in @($output)) {
                    $name = ([string]$line).Trim().ToLowerInvariant()
                    if ($name.Length -gt 0) {
                        $names += $name
                    }
                }
                return $names
            }
        }
    } catch {
        return @()
    }
    return @()
}

function New-PbiGuardrailDenial {
    <#
    .SYNOPSIS
        Builds a deny decision.
    .PARAMETER RuleId
        Rule identifier (R1..R7).
    .PARAMETER Reason
        What was blocked and what to do instead.
    .PARAMETER Subject
        The command, path or arguments that matched (used for the audit log).
    #>
    [CmdletBinding()]
    param(
        [string] $RuleId,
        [string] $Reason,
        [string] $Subject
    )
    return @{
        permissionDecision       = 'deny'
        permissionDecisionReason = $Reason
        ruleId                   = $RuleId
        subject                  = $Subject
    }
}

function Get-PbiToolUseDecisionCore {
    <#
    .SYNOPSIS
        Evaluates the guardrail rules (see Get-PbiToolUseDecision). May throw; the wrapper catches.
    .PARAMETER ToolName
        Tool name.
    .PARAMETER ToolArgs
        Tool arguments.
    .PARAMETER Cwd
        Working directory.
    #>
    [CmdletBinding()]
    param(
        [string] $ToolName,
        $ToolArgs,
        [string] $Cwd
    )
    if ($null -eq $ToolName) {
        $ToolName = ''
    }
    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $argsObject = $null
    $argsText = ''
    if ($null -ne $ToolArgs) {
        if ($ToolArgs -is [string]) {
            $argsText = $ToolArgs
            $trimmedArgs = $ToolArgs.Trim()
            if ($trimmedArgs.StartsWith('{') -or $trimmedArgs.StartsWith('[')) {
                try {
                    $argsObject = ConvertFrom-Json -InputObject $ToolArgs -ErrorAction Stop
                } catch {
                    $argsObject = $null
                }
            }
        } else {
            $argsObject = $ToolArgs
            try {
                $argsText = ConvertTo-Json -InputObject $ToolArgs -Depth 20 -Compress -ErrorAction Stop
            } catch {
                $argsText = [string]$ToolArgs
            }
        }
    }
    $shellTool = [regex]::IsMatch($ToolName, '^(bash|powershell|pwsh|shell|execute|run_in_terminal|runInTerminal|terminal|run_command|write_bash|write_powershell)$', $options)
    $command = ''
    if ($shellTool) {
        $command = Get-PbiGuardrailField -InputObject $argsObject -Names @('command', 'input', 'cmd')
        if ([string]::IsNullOrEmpty($command) -and $null -eq $argsObject -and $ToolArgs -is [string]) {
            $command = $ToolArgs
        }
    }
    $path = Get-PbiGuardrailField -InputObject $argsObject -Names @('path', 'file_path', 'filePath')
    $hasCommand = -not [string]::IsNullOrEmpty($command)

    # R1 - PROD deployments and PROD capacity changes are human-only.
    if ($hasCommand) {
        $prodParameter = '(Deploy-Pbi(Project|Infrastructure)|Deploy-FabricCapacity|Set-FabricCapacityState)(\.ps1)?[^\r\n;&|]*-Env\w*[\s:=]+[''"]?prod'
        $prodMention = '(Deploy-Pbi\w+|Publish-Pbi\w+|Invoke-PbiDatasetRefresh)\b[^\r\n;&|]*\bprod\b|\bprod\b[^\r\n;&|]*(Deploy-Pbi\w+|Publish-Pbi\w+|Invoke-PbiDatasetRefresh)\b'
        if ([regex]::IsMatch($command, $prodParameter, $options) -or [regex]::IsMatch($command, $prodMention, $options)) {
            return (New-PbiGuardrailDenial -RuleId 'R1' -Subject $command -Reason 'PROD deployments are human-only (see AGENTS.md > Non-delegable work). Prepare the release issue and hand over to the release approver.')
        }
        $capacityChange = '(Deploy-FabricCapacity|Set-FabricCapacityState)(\.ps1)?\b|\b(New|Update|Suspend|Resume)-AzFabricCapacity\b|az\s+fabric\s+capacity\s+(create|update|suspend|resume)\b'
        if ([regex]::IsMatch($command, $capacityChange, $options)) {
            return (New-PbiGuardrailDenial -RuleId 'R1' -Subject $command -Reason 'Capacity changes affect every environment including PROD and are human-only (see AGENTS.md > Non-delegable work). Describe the needed change in the issue and ask a capacity admin to run it.')
        }
    }

    # R2 - no force push, no push to main.
    if ($hasCommand) {
        $forcePush = 'git\s+push\b[^\r\n;&|]*(--force|--force-with-lease|\s-[A-Za-z]*f[A-Za-z]*\b|\s\+[\w./-]+)'
        $mainPush = 'git\s+push\b[^\r\n;&|]*(\s(origin\s+)?(HEAD:)?(refs/heads/)?main(?![\w./-])|:(refs/heads/)?main(?![\w./-]))'
        $denyPush = [regex]::IsMatch($command, $forcePush, $options) -or [regex]::IsMatch($command, $mainPush, $options)
        if (-not $denyPush -and [regex]::IsMatch($command, 'git\s+push\b', $options)) {
            $denyPush = ((Get-PbiGuardrailBranch -Cwd $Cwd) -ceq 'main')
        }
        if ($denyPush) {
            return (New-PbiGuardrailDenial -RuleId 'R2' -Subject $command -Reason 'Never push to main or force-push. Push your feature branch and open a pull request.')
        }
    }

    # R3 - destructive remote calls.
    if ($hasCommand) {
        $destructive = '-Method[\s:]+[''"]?Delete\b|--method[\s=]+[''"]?delete\b|\s-X\s*[''"]?DELETE\b|\bRemove-Pbi\w+|az\s+fabric\s+capacity\s+delete|Remove-AzFabricCapacity|\bgh\s+(repo|release|label|issue|project|ruleset|secret|variable|cache|run)\s+delete\b'
        if ([regex]::IsMatch($command, $destructive, $options)) {
            return (New-PbiGuardrailDenial -RuleId 'R3' -Subject $command -Reason 'Destructive operations are human-only. Describe what should be removed in the issue or pull request and ask a maintainer to do it.')
        }
    }

    # R4 - approval gate labels are applied by humans only.
    # Shell: any attempt to add a gate:* label is denied. MCP/API tools: only the labels field is inspected (issue and
    # PR bodies may mention gate labels); a gate label that is already on the issue may be re-sent (label updates
    # replace the whole set), so the current labels are looked up with gh before denying.
    $gatePattern = 'gate:(spec|plan|release)-approved'
    $labelCommand = $hasCommand -and (
        [regex]::IsMatch($command, 'gh\s+(issue|pr)\s+(edit|create)\b[^\r\n;&|]*(--add-label|--label|-l)[\s=]+[^\r\n;&|]*gate:', $options) -or
        [regex]::IsMatch($command, '\bgh\s+api\b[^\r\n;&|]*\blabels\b[^\r\n;&|]*' + $gatePattern, $options))
    $labelTool = $false
    $readOrComment = [regex]::IsMatch($ToolName, '(^|[_\-./])(get|list|search|read)([_\-.]|$)|comment', $options)
    if ((-not $labelCommand) -and (-not $hasCommand) -and (-not $readOrComment) -and [regex]::IsMatch($ToolName, '(issue|label|pull_request)', $options)) {
        $labelValues = Get-PbiGuardrailField -InputObject $argsObject -Names @('labels', 'label', 'add_labels', 'labelsToAdd', 'labels_to_add')
        if ([string]::IsNullOrEmpty($labelValues) -and [regex]::IsMatch($ToolName, 'label', $options)) {
            $labelValues = Get-PbiGuardrailField -InputObject $argsObject -Names @('name', 'new_name')
            if ($null -eq $argsObject) {
                $labelValues = $argsText
            }
        }
        if ([regex]::IsMatch([string]$labelValues, $gatePattern, $options)) {
            $existing = @(Get-PbiGuardrailExistingLabel -ArgsObject $argsObject)
            foreach ($gate in [regex]::Matches([string]$labelValues, $gatePattern, $options)) {
                if ($existing -notcontains $gate.Value.ToLowerInvariant()) {
                    $labelTool = $true
                }
            }
        }
    }
    if ($labelCommand -or $labelTool) {
        $subject = $argsText
        if ($labelCommand) {
            $subject = $command
        }
        return (New-PbiGuardrailDenial -RuleId 'R4' -Subject $subject -Reason 'Approval gates are set by humans only. Ask the product owner / release approver to apply the label. To change phase labels on an approved issue, use: gh issue edit <n> --add-label phase:<new> --remove-label phase:<old>.')
    }

    # R5 - secret files.
    foreach ($candidate in @($path, $command)) {
        if (Test-PbiGuardrailSecretReference -Text $candidate) {
            return (New-PbiGuardrailDenial -RuleId 'R5' -Subject $candidate -Reason 'Reading or writing secret files is blocked. Use environment variables or a key vault.')
        }
    }

    # R6 - unrestricted Copilot sessions.
    if ($hasCommand -and [regex]::IsMatch($command, 'copilot\b[^\r\n;&|]*(--allow-all-tools|--allow-all\b|--yolo)', $options)) {
        return (New-PbiGuardrailDenial -RuleId 'R6' -Subject $command -Reason 'Unrestricted Copilot sessions are not allowed in this repository. Start copilot with explicit --allow-tool / --deny-tool lists instead.')
    }

    # R7 - merging pull requests is a human decision.
    $mergeCommand = $hasCommand -and ([regex]::IsMatch($command, 'gh\s+pr\s+merge\b', $options) -or [regex]::IsMatch($command, '\bgh\s+api\b[^\r\n;&|]*pulls/\d+/merge\b', $options))
    if ($mergeCommand -or [regex]::IsMatch($ToolName, 'merge_pull_request', $options)) {
        $subject = $argsText
        if ($mergeCommand) {
            $subject = $command
        }
        return (New-PbiGuardrailDenial -RuleId 'R7' -Subject $subject -Reason 'Merging is a human decision. Ask a maintainer to review and merge the pull request.')
    }
    return $null
}

function Get-PbiToolUseDecision {
    <#
    .SYNOPSIS
        Decides whether an agent tool call must be denied by the repository guardrails.
    .DESCRIPTION
        Normalises the arguments ($argsText = the string itself, or the compact JSON of an object), extracts the shell
        command (tools bash, powershell, Bash, shell, execute, run_in_terminal, ... field 'command') and the file path
        (fields path, file_path, filePath), then applies rules R1-R7 (see the file header). Returns $null to allow or
        a deny hashtable. Never throws.
    .PARAMETER ToolName
        Tool name, for example 'bash', 'powershell', 'run_in_terminal', 'view', 'edit' or an MCP tool name.
    .PARAMETER ToolArgs
        Tool arguments: a JSON string or an object.
    .PARAMETER Cwd
        Working directory of the call (used to detect 'git push' while main is checked out).
    .EXAMPLE
        Get-PbiToolUseDecision -ToolName 'powershell' -ToolArgs @{ command = 'gh pr merge 12' }
    #>
    [CmdletBinding()]
    param(
        [string] $ToolName,
        $ToolArgs,
        [string] $Cwd
    )
    Set-StrictMode -Version Latest
    try {
        return (Get-PbiToolUseDecisionCore -ToolName $ToolName -ToolArgs $ToolArgs -Cwd $Cwd)
    } catch {
        Write-Verbose ('Guardrail evaluation failed: ' + $_.Exception.Message)
        return $null
    }
}
