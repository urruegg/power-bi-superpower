#Requires -Version 7.4
# Pester 5 tests: agent guardrails (scripts/hooks/GuardrailRules.ps1) and the hook entry scripts (offline).

BeforeAll {
    . "$PSScriptRoot/../../scripts/hooks/GuardrailRules.ps1"

    function Get-RuleId {
        param(
            [string] $ToolName,
            $ToolArgs,
            [string] $Cwd
        )
        $decision = Get-PbiToolUseDecision -ToolName $ToolName -ToolArgs $ToolArgs -Cwd $Cwd
        if ($null -eq $decision) {
            return 'allow'
        }
        return $decision['ruleId']
    }

    function New-TestFile {
        param(
            [string] $Path,
            [string] $Content = ''
        )
        $directory = Split-Path -Path $Path -Parent
        if (-not (Test-Path -LiteralPath $directory)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }
        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    }

    $script:hooksSource = Resolve-Path -LiteralPath "$PSScriptRoot/../../scripts/hooks"
    $script:pwsh = (Get-Process -Id $PID).Path
}

Describe 'Get-PbiToolUseDecision' {
    It 'returns a deny decision with a reason that says what to do instead' {
        $decision = Get-PbiToolUseDecision -ToolName 'bash' -ToolArgs '{"command":"git push origin main"}'
        $decision['permissionDecision'] | Should -Be 'deny'
        $decision['permissionDecisionReason'] | Should -BeLike '*open a pull request*'
    }

    It 'R1 denies PROD deployments and capacity changes: <Command>' -TestCases @(
        @{ Command = 'pwsh scripts/deploy/Deploy-PbiProject.ps1 -Environment PROD -ReleaseIssue 4' }
        @{ Command = "./scripts/infra/Deploy-PbiInfrastructure.ps1 -Environment 'prod'" }
        @{ Command = './scripts/deploy/Deploy-PbiProject.ps1 -Environment:PROD' }
        @{ Command = './scripts/deploy/Deploy-PbiProject.ps1 -Env prod' }
        @{ Command = 'Deploy-PbiWorkspace -Config (Get-PbiEnvironmentConfig -Environment PROD)' }
        @{ Command = './scripts/infra/Set-FabricCapacityState.ps1 -SubscriptionId x -ResourceGroupName rg -Name cap -State Paused' }
        @{ Command = './scripts/infra/Deploy-FabricCapacity.ps1 -Name cap -Sku F4' }
        @{ Command = 'Suspend-AzFabricCapacity -ResourceGroupName rg -CapacityName cap' }
    ) {
        Get-RuleId -ToolName 'powershell' -ToolArgs @{ command = $Command } | Should -Be 'R1'
    }

    It 'R1 allows DEV/TEST deployments and reading PROD configuration: <Command>' -TestCases @(
        @{ Command = 'pwsh scripts/deploy/Deploy-PbiProject.ps1 -Environment DEV' }
        @{ Command = 'pwsh scripts/deploy/Deploy-PbiProject.ps1 -Environment TEST -WhatIf' }
        @{ Command = 'pwsh scripts/infra/Deploy-PbiInfrastructure.ps1 -Environment DEV -WhatIf' }
        @{ Command = 'Get-PbiEnvironmentConfig -Environment PROD' }
    ) {
        Get-RuleId -ToolName 'powershell' -ToolArgs @{ command = $Command } | Should -Be 'allow'
    }

    It 'R2 denies pushes to main and force pushes: <Command>' -TestCases @(
        @{ Command = 'git push origin main' }
        @{ Command = 'git push -u origin main' }
        @{ Command = 'git push origin HEAD:main' }
        @{ Command = 'git push origin feature/x:refs/heads/main' }
        @{ Command = 'git push --force origin feature/x' }
        @{ Command = 'git push --force-with-lease' }
        @{ Command = 'git push -f origin feature/x' }
        @{ Command = 'git push -fu origin feature/x' }
        @{ Command = 'git push origin +feature/x' }
    ) {
        Get-RuleId -ToolName 'bash' -ToolArgs @{ command = $Command } | Should -Be 'R2'
    }

    It 'R2 allows feature branch pushes: <Command>' -TestCases @(
        @{ Command = 'git push origin feature/x' }
        @{ Command = 'git push -u origin feature/main-menu' }
        @{ Command = 'git push origin main-fixes' }
        @{ Command = 'git push origin feature/x && git checkout main' }
        @{ Command = 'git push --follow-tags origin feature/x' }
    ) {
        Get-RuleId -ToolName 'bash' -ToolArgs @{ command = $Command } | Should -Be 'allow'
    }

    It 'R2 denies a plain git push while main is checked out (read from .git/HEAD)' {
        $onMain = Join-Path $TestDrive 'on-main'
        New-TestFile -Path (Join-Path $onMain '.git/HEAD') -Content "ref: refs/heads/main`n"
        $onFeature = Join-Path $TestDrive 'on-feature'
        New-TestFile -Path (Join-Path $onFeature '.git/HEAD') -Content "ref: refs/heads/feature/x`n"
        $null = New-Item -ItemType Directory -Path (Join-Path $onFeature 'src/sub') -Force
        Get-RuleId -ToolName 'bash' -ToolArgs @{ command = 'git push' } -Cwd $onMain | Should -Be 'R2'
        Get-RuleId -ToolName 'bash' -ToolArgs @{ command = 'git push' } -Cwd (Join-Path $onFeature 'src/sub') | Should -Be 'allow'
    }

    It 'R3 denies destructive remote calls: <Command>' -TestCases @(
        @{ Command = "Invoke-PbiFabricApi -Method Delete -Path 'workspaces/1'" }
        @{ Command = "Invoke-RestMethod -Method 'DELETE' -Uri `$u" }
        @{ Command = 'gh api --method DELETE repos/o/r/labels/x' }
        @{ Command = 'gh api -X DELETE repos/o/r/git/refs/heads/x' }
        @{ Command = 'az fabric capacity delete --name x' }
        @{ Command = 'Remove-AzFabricCapacity -Name x' }
        @{ Command = 'Remove-PbiWorkspace -Name x' }
        @{ Command = 'gh repo delete o/r --yes' }
    ) {
        Get-RuleId -ToolName 'powershell' -ToolArgs @{ command = $Command } | Should -Be 'R3'
    }

    It 'R3 allows reads: <Command>' -TestCases @(
        @{ Command = "Invoke-PbiFabricApi -Method Get -Path 'workspaces'" }
        @{ Command = 'gh api repos/o/r/rulesets' }
    ) {
        Get-RuleId -ToolName 'powershell' -ToolArgs @{ command = $Command } | Should -Be 'allow'
    }

    It 'R4 denies approval labels set by agents: <Tool>' -TestCases @(
        @{ Tool = 'bash'; Arguments = @{ command = 'gh issue edit 12 --add-label gate:spec-approved' } }
        @{ Tool = 'bash'; Arguments = @{ command = 'gh issue edit 12 --add-label "phase:plan,gate:plan-approved"' } }
        @{ Tool = 'bash'; Arguments = @{ command = 'gh pr edit 3 --add-label gate:release-approved' } }
        @{ Tool = 'bash'; Arguments = @{ command = 'gh api repos/o/r/issues/1/labels -f "labels[]=gate:spec-approved"' } }
        @{ Tool = 'github-mcp-server-issue_write'; Arguments = @{ method = 'update'; labels = @('gate:spec-approved') } }
        @{ Tool = 'add_labels_to_issue'; Arguments = '{"labels":["gate:release-approved"]}' }
    ) {
        Get-RuleId -ToolName $Tool -ToolArgs $Arguments | Should -Be 'R4'
    }

    It 'R4 allows reading labels and other label changes: <Tool>' -TestCases @(
        @{ Tool = 'bash'; Arguments = @{ command = 'gh issue list --label gate:spec-approved --json number' } }
        @{ Tool = 'bash'; Arguments = @{ command = 'gh issue edit 12 --add-label phase:plan' } }
        @{ Tool = 'github-mcp-server-list_issues'; Arguments = @{ labels = @('gate:spec-approved') } }
        @{ Tool = 'add_issue_comment'; Arguments = @{ body = 'Please apply gate:spec-approved' } }
        @{ Tool = 'search_issues'; Arguments = @{ query = 'label:gate:spec-approved' } }
    ) {
        Get-RuleId -ToolName $Tool -ToolArgs $Arguments | Should -Be 'allow'
    }

    It 'R4 allows issue and PR bodies that only mention gate labels: <Tool>' -TestCases @(
        @{ Tool = 'github-mcp-server-issue_write'; Arguments = @{ method = 'create'; title = 'Release: v0.2.0'; body = 'Release approver: apply gate:release-approved'; labels = @('type:release', 'phase:deploy') } }
        @{ Tool = 'create_pull_request'; Arguments = @{ title = 'feat: sales overview (#12)'; body = 'Needs gate:spec-approved before build' } }
    ) {
        Get-RuleId -ToolName $Tool -ToolArgs $Arguments | Should -Be 'allow'
    }

    It 'R4 allows re-sending a gate label that is already on the issue' {
        Mock Get-PbiGuardrailExistingLabel { @('type:feature', 'phase:spec', 'gate:spec-approved') }
        Get-RuleId -ToolName 'github-mcp-server-issue_write' -ToolArgs @{ method = 'update'; issue_number = 12; labels = @('type:feature', 'phase:plan', 'gate:spec-approved') } | Should -Be 'allow'
    }

    It 'R4 denies adding a gate label that is not yet on the issue' {
        Mock Get-PbiGuardrailExistingLabel { @('type:feature', 'phase:plan', 'gate:spec-approved') }
        Get-RuleId -ToolName 'github-mcp-server-issue_write' -ToolArgs @{ method = 'update'; issue_number = 12; labels = @('type:feature', 'phase:plan', 'gate:spec-approved', 'gate:plan-approved') } | Should -Be 'R4'
    }

    It 'R5 denies secret files: <Tool> <Arguments>' -TestCases @(
        @{ Tool = 'view'; Arguments = @{ path = '.env' } }
        @{ Tool = 'view'; Arguments = @{ path = 'C:\repo\.env.local' } }
        @{ Tool = 'edit'; Arguments = @{ path = '/repo/certs/app.pfx' } }
        @{ Tool = 'read_file'; Arguments = @{ filePath = '/home/u/.ssh/id_rsa' } }
        @{ Tool = 'Read'; Arguments = @{ file_path = '/repo/.env.production' } }
        @{ Tool = 'bash'; Arguments = @{ command = 'cat .env' } }
        @{ Tool = 'bash'; Arguments = @{ command = 'cp .env.example .env' } }
        @{ Tool = 'powershell'; Arguments = @{ command = 'Get-Content ./secrets/key.pem' } }
    ) {
        Get-RuleId -ToolName $Tool -ToolArgs $Arguments | Should -Be 'R5'
    }

    It 'R5 allows .env.example and ordinary files: <Tool> <Arguments>' -TestCases @(
        @{ Tool = 'view'; Arguments = @{ path = '.env.example' } }
        @{ Tool = 'bash'; Arguments = @{ command = 'cat .env.example' } }
        @{ Tool = 'powershell'; Arguments = @{ command = '$env:PBI_TENANT_ID; $h.GetEnumerator() | ForEach-Object { $_.Key }' } }
        @{ Tool = 'view'; Arguments = @{ path = 'docs/environments.md' } }
        @{ Tool = 'view'; Arguments = @{ path = 'config/environments/dev.json' } }
    ) {
        Get-RuleId -ToolName $Tool -ToolArgs $Arguments | Should -Be 'allow'
    }

    It 'R6 denies unrestricted Copilot sessions: <Command>' -TestCases @(
        @{ Command = 'copilot --allow-all-tools -p "do it"' }
        @{ Command = 'copilot --yolo' }
        @{ Command = 'copilot --allow-all' }
    ) {
        Get-RuleId -ToolName 'bash' -ToolArgs @{ command = $Command } | Should -Be 'R6'
    }

    It 'R6 allows restricted Copilot sessions' {
        Get-RuleId -ToolName 'bash' -ToolArgs @{ command = "copilot --allow-tool 'shell(git)' -p 'summarise'" } | Should -Be 'allow'
    }

    It 'R7 denies merging pull requests: <Tool>' -TestCases @(
        @{ Tool = 'bash'; Arguments = @{ command = 'gh pr merge 12 --squash' } }
        @{ Tool = 'powershell'; Arguments = @{ command = 'gh pr merge --auto 5' } }
        @{ Tool = 'merge_pull_request'; Arguments = @{ pullNumber = 3 } }
        @{ Tool = 'github-mcp-server-merge_pull_request'; Arguments = '{"pullNumber":3}' }
    ) {
        $decision = Get-PbiToolUseDecision -ToolName $Tool -ToolArgs $Arguments
        $decision['ruleId'] | Should -Be 'R7'
        $decision['permissionDecisionReason'] | Should -Be 'Merging is a human decision. Ask a maintainer to review and merge the pull request.'
    }

    It 'R7 allows other pull request commands: <Command>' -TestCases @(
        @{ Command = 'gh pr view 12 --json mergeable' }
        @{ Command = 'gh pr create --fill' }
    ) {
        Get-RuleId -ToolName 'bash' -ToolArgs @{ command = $Command } | Should -Be 'allow'
    }

    It 'allows normal work: <Command>' -TestCases @(
        @{ Command = 'pwsh scripts/quality/Invoke-PbiQualityGate.ps1 -Profile pr -Target Local' }
        @{ Command = 'pwsh scripts/quality/Invoke-PbiDaxTests.ps1 -ProjectPath src/SalesStarter -Target Local' }
        @{ Command = 'git commit -m "feat: add measure"' }
        @{ Command = 'npm install -g @microsoft/powerbi-report-authoring-cli@latest' }
    ) {
        Get-RuleId -ToolName 'bash' -ToolArgs @{ command = $Command } | Should -Be 'allow'
    }

    It 'accepts toolArgs as a JSON string, as a raw command string and as an object' {
        Get-RuleId -ToolName 'bash' -ToolArgs '{"command":"gh pr merge 1","description":"merge"}' | Should -Be 'R7'
        Get-RuleId -ToolName 'run_in_terminal' -ToolArgs 'gh pr merge 1' | Should -Be 'R7'
        Get-RuleId -ToolName 'Bash' -ToolArgs ([pscustomobject]@{ command = 'gh pr merge 1' }) | Should -Be 'R7'
    }

    It 'only evaluates the command field of shell tools' {
        Get-RuleId -ToolName 'create' -ToolArgs @{ path = 'docs/howto.md'; file_text = 'Never run: git push origin main' } | Should -Be 'allow'
    }

    It 'never throws on unexpected input' {
        { Get-PbiToolUseDecision -ToolName $null -ToolArgs $null } | Should -Not -Throw
        Get-PbiToolUseDecision -ToolName 'bash' -ToolArgs '{not json' | Should -BeNullOrEmpty
        Get-PbiToolUseDecision -ToolName '' -ToolArgs 42 | Should -BeNullOrEmpty
    }
}

Describe 'Hook entry scripts' {
    BeforeAll {
        $script:hookRepo = Join-Path $TestDrive 'hook-repo'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:hookRepo 'scripts/hooks') -Force
        foreach ($file in @('GuardrailRules.ps1', 'Test-PreToolUse.ps1', 'Invoke-SessionStart.ps1')) {
            Copy-Item -LiteralPath (Join-Path $script:hooksSource $file) -Destination (Join-Path $script:hookRepo 'scripts/hooks') -Force
        }
        $script:preToolUse = Join-Path $script:hookRepo 'scripts/hooks/Test-PreToolUse.ps1'
        $script:sessionStart = Join-Path $script:hookRepo 'scripts/hooks/Invoke-SessionStart.ps1'
    }

    It 'Test-PreToolUse prints one deny line for the Copilot CLI input shape and writes a masked audit line' {
        $payload = @{ toolName = 'bash'; toolArgs = '{"command":"gh issue edit 7 --add-label gate:spec-approved # 11111111-2222-3333-4444-555555555555"}'; cwd = $script:hookRepo } | ConvertTo-Json -Compress
        $output = @($payload | & $script:pwsh -NoProfile -NonInteractive -File $script:preToolUse)
        $LASTEXITCODE | Should -Be 0
        $output.Count | Should -Be 1
        $decision = $output[0] | ConvertFrom-Json
        $decision.permissionDecision | Should -Be 'deny'
        $decision.permissionDecisionReason | Should -BeLike 'Approval gates are set by humans only*'
        $audit = Get-Content -LiteralPath (Join-Path $script:hookRepo '.evidence/hook-audit.jsonl') -Raw
        $audit | Should -BeLike '*"ruleId":"R4"*'
        $audit | Should -BeLike '*<id>*'
        $audit | Should -Not -BeLike '*11111111-2222*'
    }

    It 'Test-PreToolUse supports the VS Code input shape' {
        $payload = @{ tool_name = 'run_in_terminal'; tool_input = @{ command = 'gh pr merge 3' }; cwd = $script:hookRepo } | ConvertTo-Json -Compress
        $output = @($payload | & $script:pwsh -NoProfile -NonInteractive -File $script:preToolUse)
        $LASTEXITCODE | Should -Be 0
        ($output[0] | ConvertFrom-Json).permissionDecision | Should -Be 'deny'
    }

    It 'Test-PreToolUse prints nothing for allowed calls and for invalid input' {
        $allowed = @(@{ toolName = 'bash'; toolArgs = '{"command":"git status"}' } | ConvertTo-Json -Compress | & $script:pwsh -NoProfile -NonInteractive -File $script:preToolUse)
        $LASTEXITCODE | Should -Be 0
        @($allowed | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count | Should -Be 0
        $invalid = @('this is not json' | & $script:pwsh -NoProfile -NonInteractive -File $script:preToolUse 2>$null)
        $LASTEXITCODE | Should -Be 0
        @($invalid | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count | Should -Be 0
    }

    It 'Invoke-SessionStart reports the current sprint as compact ASCII JSON' {
        New-TestFile -Path (Join-Path $script:hookRepo 'docs/sprints/current.json') -Content ('{ "number": 3, "goal": "Sales overview in TEST ' + [char]0x2013 + ' with RLS", "milestone": "Sprint 03", "startDate": "2026-11-02", "endDate": "2026-11-13" }')
        New-TestFile -Path (Join-Path $script:hookRepo '.github/skills/brainstorming/SKILL.md') -Content "---`nname: brainstorming`n---`n"
        $output = @('{}' | & $script:pwsh -NoProfile -NonInteractive -File $script:sessionStart)
        $LASTEXITCODE | Should -Be 0
        $output.Count | Should -Be 1
        $output[0] | Should -Not -Match '[^\x00-\x7F]'
        $context = ($output[0] | ConvertFrom-Json).additionalContext
        $context | Should -BeLike '*Sprint 3*Sprint 03*Sales overview in TEST*2026-11-13*'
        $context | Should -BeLike '*pbi-sprint-flow*'
        $context | Should -Not -BeLike '*Superpowers is not installed*'
        $context.Length | Should -BeLessOrEqual 1500
    }

    It 'Invoke-SessionStart says there is no sprint when current.json is missing' {
        Remove-Item -LiteralPath (Join-Path $script:hookRepo 'docs/sprints/current.json') -Force -ErrorAction SilentlyContinue
        $output = @('{}' | & $script:pwsh -NoProfile -NonInteractive -File $script:sessionStart)
        ($output[0] | ConvertFrom-Json).additionalContext | Should -BeLike '*none - run /pbi-sprint-start*'
    }
}
