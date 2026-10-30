<#
.SYNOPSIS
    preToolUse hook for GitHub Copilot (CLI and VS Code agent mode): denies risky agent tool calls.
.DESCRIPTION
    Reads the hook payload (JSON) from stdin. Both input shapes are supported:
      Copilot CLI:              { "toolName": "...", "toolArgs": "<JSON string or object>", "cwd": "..." }
      VS Code / Claude-style:   { "tool_name": "...", "tool_input": { ... }, "cwd": "..." }
    The rules live in GuardrailRules.ps1 (R1-R7). When a rule denies the call the script prints ONE line of compact
    JSON {"permissionDecision":"deny","permissionDecisionReason":"..."} and appends an audit line (timestamp, tool,
    rule, reason, first 200 characters of the command with GUIDs masked) to .evidence/hook-audit.jsonl.
    When the call is allowed it prints nothing.
    The script always exits 0. On an unexpected error it writes a warning to stderr and prints nothing (fail-open
    by design: humans, CODEOWNERS, the main ruleset and the typed PROD confirmation remain the real controls).
    Compatible with Windows PowerShell 5.1 and PowerShell 7; output is ASCII-only JSON.
.EXAMPLE
    '{"toolName":"bash","toolArgs":"{\"command\":\"git push origin main\"}","cwd":"."}' | pwsh -NoProfile -File scripts/hooks/Test-PreToolUse.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-PbiHookJson {
    <#
    .SYNOPSIS
        Compact JSON with every non-ASCII character escaped as \uXXXX (safe for any console code page).
    .PARAMETER InputObject
        Object to serialise.
    #>
    [CmdletBinding()]
    param(
        $InputObject
    )
    $json = ConvertTo-Json -InputObject $InputObject -Compress -Depth 5
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $json.ToCharArray()) {
        if ([int]$character -gt 127) {
            $null = $builder.Append('\u').Append(([int]$character).ToString('x4'))
        } else {
            $null = $builder.Append($character)
        }
    }
    return $builder.ToString()
}

function Get-PbiHookValue {
    <#
    .SYNOPSIS
        Returns the value of the first property of the payload that exists (or $null).
    .PARAMETER InputObject
        Parsed payload.
    .PARAMETER Names
        Candidate property names.
    #>
    [CmdletBinding()]
    param(
        $InputObject,
        [string[]] $Names
    )
    if ($null -eq $InputObject) {
        return $null
    }
    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }
    return $null
}

function Write-PbiHookAudit {
    <#
    .SYNOPSIS
        Appends one JSON line to .evidence/hook-audit.jsonl (errors are ignored).
    .PARAMETER ToolName
        Tool name.
    .PARAMETER RuleId
        Rule that denied the call.
    .PARAMETER Reason
        Deny reason.
    .PARAMETER Subject
        Command, path or arguments that matched.
    #>
    [CmdletBinding()]
    param(
        [string] $ToolName,
        [string] $RuleId,
        [string] $Reason,
        [string] $Subject
    )
    try {
        $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
        $directory = Join-Path $repoRoot '.evidence'
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }
        $snippet = ''
        if ($null -ne $Subject) {
            $snippet = [regex]::Replace($Subject, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<id>')
        }
        if ($snippet.Length -gt 200) {
            $snippet = $snippet.Substring(0, 200)
        }
        $entry = New-Object System.Collections.Specialized.OrderedDictionary
        $entry['timestamp'] = (Get-Date).ToUniversalTime().ToString('o')
        $entry['toolName'] = $ToolName
        $entry['ruleId'] = $RuleId
        $entry['reason'] = $Reason
        $entry['command'] = $snippet
        $line = (ConvertTo-PbiHookJson -InputObject $entry) + "`n"
        [System.IO.File]::AppendAllText((Join-Path $directory 'hook-audit.jsonl'), $line, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        $null = $_
    }
}

try {
    $raw = ''
    try {
        if ([Console]::IsInputRedirected) {
            $raw = [Console]::In.ReadToEnd()
        }
    } catch {
        $raw = ''
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        exit 0
    }
    $payload = ConvertFrom-Json -InputObject $raw
    $toolName = [string](Get-PbiHookValue -InputObject $payload -Names @('toolName', 'tool_name'))
    $toolArgs = Get-PbiHookValue -InputObject $payload -Names @('toolArgs', 'tool_input', 'toolInput')
    if ($toolArgs -is [string]) {
        $trimmedArgs = $toolArgs.Trim()
        if ($trimmedArgs.StartsWith('{') -or $trimmedArgs.StartsWith('[')) {
            try {
                $toolArgs = ConvertFrom-Json -InputObject $toolArgs
            } catch {
                Write-Verbose 'toolArgs is not JSON; it is evaluated as text.'
            }
        }
    }
    $cwd = [string](Get-PbiHookValue -InputObject $payload -Names @('cwd'))
    if ([string]::IsNullOrEmpty($cwd)) {
        $cwd = (Get-Location).ProviderPath
    }
    . (Join-Path $PSScriptRoot 'GuardrailRules.ps1')
    $decision = Get-PbiToolUseDecision -ToolName $toolName -ToolArgs $toolArgs -Cwd $cwd
    if ($null -ne $decision) {
        $reason = [string]$decision['permissionDecisionReason']
        $output = New-Object System.Collections.Specialized.OrderedDictionary
        $output['permissionDecision'] = 'deny'
        $output['permissionDecisionReason'] = $reason
        [Console]::Out.WriteLine((ConvertTo-PbiHookJson -InputObject $output))
        Write-PbiHookAudit -ToolName $toolName -RuleId ([string]$decision['ruleId']) -Reason $reason -Subject ([string]$decision['subject'])
    }
    exit 0
} catch {
    try {
        [Console]::Error.WriteLine('pbi guardrail hook warning: ' + $_.Exception.Message + ' (the tool call was not evaluated; failing open).')
    } catch {
        $null = $_
    }
    exit 0
}
