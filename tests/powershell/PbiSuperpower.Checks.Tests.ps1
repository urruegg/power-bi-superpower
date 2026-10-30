#Requires -Version 7.4
# Pester 5 tests: static checks on TestDrive fixtures (offline).

BeforeAll {
    Import-Module "$PSScriptRoot/../../scripts/modules/PbiSuperpower/PbiSuperpower.psd1" -Force

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
}

Describe 'Test-PbiRepoHygiene' {
    BeforeAll {
        $script:repo = Join-Path $TestDrive 'hygiene'
        New-TestFile -Path (Join-Path $script:repo 'AGENTS.md') -Content '# fixture'
        New-TestFile -Path (Join-Path $script:repo 'config/environments/dev.json') -Content '{ "principalId": "9b6f2c1e-1234-4abc-8def-1234567890ab" }'
        New-TestFile -Path (Join-Path $script:repo 'config/zero.json') -Content '{ "id": "00000000-0000-0000-0000-000000000000" }'
        New-TestFile -Path (Join-Path $script:repo 'config/people.json') -Content '{ "owner": "someone@contoso.com" }'
        New-TestFile -Path (Join-Path $script:repo 'docs/allowed.md') -Content 'Sample id 9b6f2c1e-0000-4000-8000-000000000001 <!-- pbi-allow-guid -->'
        New-TestFile -Path (Join-Path $script:repo 'docs/key.md') -Content "-----BEGIN RSA PRIVATE KEY-----`nabc`n"
        New-TestFile -Path (Join-Path $script:repo 'scripts/bad.ps1') -Content "`$password = 'SuperSecret123'"
        New-TestFile -Path (Join-Path $script:repo 'scripts/ok.ps1') -Content "`$password = `$env:PBI_SECRET"
        New-TestFile -Path (Join-Path $script:repo '.env') -Content 'X=1'
        New-TestFile -Path (Join-Path $script:repo '.env.example') -Content 'X='
        New-TestFile -Path (Join-Path $script:repo 'certs/app.pfx') -Content 'binary'
        New-TestFile -Path (Join-Path $script:repo 'src/Sales/Sales.Report/definition.pbir') -Content '{ "datasetReference": { "byConnection": { "connectionString": "semanticmodelid=abc" } } }'
        New-TestFile -Path (Join-Path $script:repo 'src/Sales/Sales.SemanticModel/definition/tables/Sales.tmdl') -Content "table Sales`n`tlineageTag: 9b6f2c1e-1234-4abc-8def-1234567890ab`n"
        New-TestFile -Path (Join-Path $script:repo 'src/Sales/Sales.SemanticModel/.pbi/localSettings.json') -Content '{}'
        New-TestFile -Path (Join-Path $script:repo 'tests/fixtures/secret.json') -Content '{ "password": "SuperSecret123" }'
        $script:findings = @(Test-PbiRepoHygiene -RepoRoot $script:repo)
    }

    It 'flags GUIDs in config/ as identifiers' {
        $hit = @($script:findings | Where-Object { $_.Path -eq 'config/environments/dev.json' })
        $hit.Count | Should -Be 1
        $hit[0].Severity | Should -Be 'Error'
        $hit[0].Message | Should -BeLike '*identifier*'
        $hit[0].Message | Should -Not -BeLike '*9b6f2c1e*'
    }

    It 'allows the all-zero GUID and lines marked pbi-allow-guid' {
        @($script:findings | Where-Object { $_.Path -eq 'config/zero.json' }).Count | Should -Be 0
        @($script:findings | Where-Object { $_.Path -eq 'docs/allowed.md' }).Count | Should -Be 0
    }

    It 'detects secrets (password assignment, private key) but not environment variable references' {
        @($script:findings | Where-Object { $_.Path -eq 'scripts/bad.ps1' -and $_.Severity -eq 'Error' -and $_.Message -like '*secret*' }).Count | Should -Be 1
        @($script:findings | Where-Object { $_.Path -eq 'docs/key.md' -and $_.Severity -eq 'Error' }).Count | Should -Be 1
        @($script:findings | Where-Object { $_.Path -eq 'scripts/ok.ps1' }).Count | Should -Be 0
    }

    It 'flags tracked .env, certificate and local Power BI files but not .env.example' {
        @($script:findings | Where-Object { $_.Path -eq '.env' -and $_.Severity -eq 'Error' }).Count | Should -Be 1
        @($script:findings | Where-Object { $_.Path -eq 'certs/app.pfx' -and $_.Severity -eq 'Error' }).Count | Should -Be 1
        @($script:findings | Where-Object { $_.Path -eq 'src/Sales/Sales.SemanticModel/.pbi/localSettings.json' -and $_.Severity -eq 'Error' }).Count | Should -Be 1
        @($script:findings | Where-Object { $_.Path -eq '.env.example' }).Count | Should -Be 0
    }

    It 'flags service connections in src/ (reports must use byPath)' {
        $hit = @($script:findings | Where-Object { $_.Path -eq 'src/Sales/Sales.Report/definition.pbir' })
        $hit.Count | Should -Be 1
        $hit[0].Message | Should -BeLike '*byPath*'
    }

    It 'ignores lineageTag lines in src TMDL and test fixtures' {
        @($script:findings | Where-Object { $_.Path -like 'src/Sales/Sales.SemanticModel/definition/*' }).Count | Should -Be 0
        @($script:findings | Where-Object { $_.Path -like 'tests/*' }).Count | Should -Be 0
    }

    It 'warns about e-mail addresses in config/' {
        $hit = @($script:findings | Where-Object { $_.Path -eq 'config/people.json' })
        $hit.Count | Should -Be 1
        $hit[0].Severity | Should -Be 'Warning'
    }
}

Describe 'Test-PbiTmdlConvention' {
    BeforeAll {
        function New-TmdlModel {
            param(
                [string] $Root,
                [string[]] $SalesLines,
                [string] $Compatibility = '1702',
                [string[]] $References = @('Sales'),
                [string[]] $ExtraTables = @()
            )
            $definition = Join-Path $Root 'definition'
            New-TestFile -Path (Join-Path $definition 'database.tmdl') -Content ("database Fixture`n`tcompatibilityLevel: {0}`n" -f $Compatibility)
            $modelLines = @('model Model', "`tculture: en-US", '') + @($References | ForEach-Object { if ($_ -match '\s') { "ref table '$_'" } else { "ref table $_" } })
            New-TestFile -Path (Join-Path $definition 'model.tmdl') -Content (($modelLines -join "`n") + "`n")
            New-TestFile -Path (Join-Path $definition 'tables/Sales.tmdl') -Content (($SalesLines -join "`n") + "`n")
            foreach ($table in $ExtraTables) {
                New-TestFile -Path (Join-Path $definition "tables/$table.tmdl") -Content "table $table`n"
            }
        }
    }

    It 'passes a clean model' {
        $root = Join-Path $TestDrive 'Clean.SemanticModel'
        New-TmdlModel -Root $root -SalesLines @(
            'table Sales'
            "`tlineageTag: tag-1"
            ''
            "`t/// Sum of the sales amount."
            "`tmeasure 'Total Sales' = SUM(Sales[Amount])"
            "`t`tformatString: #,0.00"
            "`t`tlineageTag: tag-2"
            ''
            "`t/// Multi-line measure in a code block."
            "`tmeasure 'Margin %' = ``````"
            "`t`t`tVAR x = 1"
            '    RETURN x'
            "`t`t`t``````"
            "`t`tformatString: 0.0%"
            ''
            "`tcolumn Amount"
            "`t`tdataType: decimal"
        )
        $findings = @(Test-PbiTmdlConvention -SemanticModelPath $root -RepoRoot $TestDrive)
        $findings.Count | Should -Be 0
    }

    Context 'with convention violations' {
        BeforeAll {
            $script:badRoot = Join-Path $TestDrive 'Bad.SemanticModel'
            New-TmdlModel -Root $script:badRoot -Compatibility '1550' -References @('Sales', 'Missing Table') -ExtraTables @('Orphan') -SalesLines @(
                'table Sales'
                "`tlineageTag: tag-a"
                ''
                "`t/// Total sales"
                "`tmeasure 'Total Sales' = SUM(Sales[Amount])"
                "`t`tformatString: #,0"
                "`t`tlineageTag: tag-b"
                ''
                "`tmeasure 'No Format' = 1"
                "`t`tlineageTag: tag-c"
                ''
                "`t/// Uses spaces"
                "`tmeasure Spaced = 2"
                '        formatString: 0'
                "`t`tlineageTag: tag-a"
                ''
                "`tcolumn Amount"
                "`t`tdataType: decimal"
            )
            $script:badFindings = @(Test-PbiTmdlConvention -SemanticModelPath $script:badRoot -RepoRoot $TestDrive)
        }

        It 'reports a measure without formatString as an Error' {
            @($script:badFindings | Where-Object { $_.Severity -eq 'Error' -and $_.Message -like "*'No Format'*formatString*" }).Count | Should -Be 1
        }

        It 'reports a measure without a /// description as a Warning' {
            @($script:badFindings | Where-Object { $_.Severity -eq 'Warning' -and $_.Message -like "*'No Format'*description*" }).Count | Should -Be 1
            @($script:badFindings | Where-Object { $_.Message -like "*'Total Sales'*" }).Count | Should -Be 0
        }

        It 'reports ref table mismatches in both directions' {
            @($script:badFindings | Where-Object { $_.Severity -eq 'Error' -and $_.Message -like '*Missing Table*' }).Count | Should -Be 1
            @($script:badFindings | Where-Object { $_.Severity -eq 'Warning' -and $_.Path -like '*tables/Orphan.tmdl' }).Count | Should -Be 1
        }

        It 'reports space indentation, low compatibility level and duplicate lineage tags' {
            @($script:badFindings | Where-Object { $_.Severity -eq 'Warning' -and $_.Message -like '*spaces*' }).Count | Should -Be 1
            @($script:badFindings | Where-Object { $_.Severity -eq 'Error' -and $_.Message -like '*1550*' }).Count | Should -Be 1
            @($script:badFindings | Where-Object { $_.Severity -eq 'Error' -and $_.Message -like '*lineageTag*2 times*' }).Count | Should -Be 1
        }

        It 'does not flag the measure whose formatString is indented with spaces as missing a format' {
            @($script:badFindings | Where-Object { $_.Message -like '*Spaced*formatString*' }).Count | Should -Be 0
        }
    }
}

Describe 'Test-PbiReportConvention' {
    BeforeAll {
        $script:report = Join-Path $TestDrive 'Sales.Report'
        $pages = Join-Path $script:report 'definition/pages'
        New-TestFile -Path (Join-Path $pages 'pages.json') -Content '{ "pageOrder": ["page1"] }'
        New-TestFile -Path (Join-Path $pages 'page1/page.json') -Content '{ "displayName": "Overview", "width": 1280, "height": 720 }'
        New-TestFile -Path (Join-Path $pages 'page1/visuals/v1/visual.json') -Content @'
{ "name": "v1", "position": { "x": 0, "y": 0, "z": 1000, "width": 400, "height": 200 },
  "visual": { "visualType": "cardVisual",
    "visualContainerObjects": { "title": [ { "properties": { "text": { "expr": { "Literal": { "Value": "'KPIs'" } } } } } ],
                                "general": [ { "properties": { "altText": { "expr": { "Literal": { "Value": "'Key figures'" } } } } } ] } } }
'@
        New-TestFile -Path (Join-Path $pages 'page1/visuals/v2/visual.json') -Content @'
{ "name": "v2", "position": { "x": 100, "y": 50, "z": 2000, "width": 400, "height": 200 },
  "visual": { "visualType": "card" } }
'@
        New-TestFile -Path (Join-Path $pages 'page1/visuals/v3/visual.json') -Content @'
{ "name": "v3", "position": { "x": 800, "y": 400, "z": 3000, "width": 200, "height": 100 },
  "visual": { "visualType": "tableEx",
    "visualContainerObjects": { "title": [ { "properties": { } } ],
                                "general": [ { "properties": { "altText": { "expr": { "Literal": { "Value": "'Detail'" } } } } } ] } } }
'@
        $gate = [pscustomobject]@{ thresholds = [pscustomobject]@{ reportMaxVisualsPerPage = 2 } }
        $script:reportFindings = @(Test-PbiReportConvention -ReportPath $script:report -Gate $gate -RepoRoot $TestDrive)
    }

    It 'warns about overlapping visuals once' {
        $overlaps = @($script:reportFindings | Where-Object { $_.Message -like '*overlaps*' })
        $overlaps.Count | Should -Be 1
        $overlaps[0].Severity | Should -Be 'Warning'
    }

    It 'warns about the legacy card visual' {
        @($script:reportFindings | Where-Object { $_.Severity -eq 'Warning' -and $_.Message -like "*legacy*'card'*cardVisual*" }).Count | Should -Be 1
    }

    It 'warns about missing alt text and reports missing titles as Info' {
        $altText = @($script:reportFindings | Where-Object { $_.Message -like '*alt text*' })
        $altText.Count | Should -Be 1
        $altText[0].Path | Should -BeLike '*visuals/v2/visual.json'
        @($script:reportFindings | Where-Object { $_.Severity -eq 'Info' -and $_.Message -like '*no title*' }).Count | Should -Be 1
    }

    It 'warns when a page has more visuals than the threshold' {
        @($script:reportFindings | Where-Object { $_.Severity -eq 'Warning' -and $_.Message -like '*3 visuals*limit 2*' }).Count | Should -Be 1
    }
}

Describe 'Test-PbiAgentAsset' {
    BeforeAll {
        $script:assets = Join-Path $TestDrive 'assets'
        $github = Join-Path $script:assets '.github'
        New-TestFile -Path (Join-Path $github 'skills/good-skill/SKILL.md') -Content "---`nname: good-skill`ndescription: Use when testing the linter.`n---`n# Good`n"
        New-TestFile -Path (Join-Path $github 'skills/folded/SKILL.md') -Content "---`nname: folded`ndescription: >-`n  Use when the description`n  spans several lines.`nargument-hint: `"<x>`"`n---`n"
        New-TestFile -Path (Join-Path $github 'skills/BadName/SKILL.md') -Content "---`nname: BadName`ndescription: Upper-case name.`n---`n"
        New-TestFile -Path (Join-Path $github 'skills/mismatch/SKILL.md') -Content "---`nname: other-name`ndescription: Wrong name.`n---`n"
        New-TestFile -Path (Join-Path $github 'skills/nodesc/SKILL.md') -Content "---`nname: nodesc`n---`n"
        New-TestFile -Path (Join-Path $github 'skills/nofront/SKILL.md') -Content "# No front matter`n"
        $null = New-Item -ItemType Directory -Path (Join-Path $github 'skills/empty-folder') -Force
        New-TestFile -Path (Join-Path $github 'skills/SUPERPOWERS-LICENSE.txt') -Content 'MIT'
        New-TestFile -Path (Join-Path $github 'agents/ok.agent.md') -Content "---`nname: ok`ndescription: Does things.`ntools: ['read']`n---`n"
        New-TestFile -Path (Join-Path $github 'agents/bad.agent.md') -Content "# no front matter`n"
        New-TestFile -Path (Join-Path $github 'instructions/ok.instructions.md') -Content "---`napplyTo: '**/*.tmdl'`n---`n"
        New-TestFile -Path (Join-Path $github 'instructions/bad.instructions.md') -Content "---`ndescription: no applyTo`n---`n"
        New-TestFile -Path (Join-Path $github 'hooks/ok.json') -Content '{ "version": 1, "hooks": {} }'
        New-TestFile -Path (Join-Path $github 'hooks/v2.json') -Content '{ "version": 2, "hooks": {} }'
        New-TestFile -Path (Join-Path $github 'hooks/broken.json') -Content '{ "version": '
        $script:assetFindings = @(Test-PbiAgentAsset -RepoRoot $script:assets)
    }

    It 'accepts valid skills, agents, instructions and hooks' {
        foreach ($path in @('.github/skills/good-skill/SKILL.md', '.github/skills/folded/SKILL.md', '.github/agents/ok.agent.md', '.github/instructions/ok.instructions.md', '.github/hooks/ok.json')) {
            @($script:assetFindings | Where-Object { $_.Path -eq $path }).Count | Should -Be 0 -Because $path
        }
    }

    It 'reports skill naming and description problems' {
        @($script:assetFindings | Where-Object { $_.Path -eq '.github/skills/BadName/SKILL.md' -and $_.Severity -eq 'Error' }).Count | Should -BeGreaterOrEqual 1
        @($script:assetFindings | Where-Object { $_.Path -eq '.github/skills/mismatch/SKILL.md' -and $_.Message -like '*must equal the folder name*' }).Count | Should -Be 1
        @($script:assetFindings | Where-Object { $_.Path -eq '.github/skills/nodesc/SKILL.md' -and $_.Message -like '*description*' }).Count | Should -Be 1
        @($script:assetFindings | Where-Object { $_.Path -eq '.github/skills/nofront/SKILL.md' -and $_.Severity -eq 'Error' }).Count | Should -Be 1
        @($script:assetFindings | Where-Object { $_.Path -eq '.github/skills/empty-folder' -and $_.Severity -eq 'Warning' }).Count | Should -Be 1
    }

    It 'reports agents without description, instructions without applyTo and bad hook files' {
        @($script:assetFindings | Where-Object { $_.Path -eq '.github/agents/bad.agent.md' -and $_.Severity -eq 'Error' }).Count | Should -Be 1
        @($script:assetFindings | Where-Object { $_.Path -eq '.github/instructions/bad.instructions.md' -and $_.Severity -eq 'Error' }).Count | Should -Be 1
        @($script:assetFindings | Where-Object { $_.Path -eq '.github/hooks/v2.json' -and $_.Message -like '*version*' }).Count | Should -Be 1
        @($script:assetFindings | Where-Object { $_.Path -eq '.github/hooks/broken.json' -and $_.Severity -eq 'Error' }).Count | Should -Be 1
    }
}

Describe 'Test-PbiMcpConfigParity' {
    It 'ignores github, tolerates comments and reports missing servers and different args' {
        $root = Join-Path $TestDrive 'mcp'
        New-TestFile -Path (Join-Path $root '.vscode/mcp.json') -Content @'
{
  // VS Code allows comments
  "servers": {
    "same": { "type": "stdio", "command": "npx", "args": ["-y", "same@1"] },
    "drift": { "type": "stdio", "command": "npx", "args": ["-y", "drift@1"] },
    "github": { "type": "http", "url": "https://api.githubcopilot.com/mcp/" },
  }
}
'@
        New-TestFile -Path (Join-Path $root '.github/mcp.json') -Content @'
{
  "mcpServers": {
    "same": { "type": "local", "command": "npx", "args": ["-y", "same@1"] },
    "drift": { "type": "local", "command": "npx", "args": ["-y", "drift@2"] },
    "cli-only": { "type": "http", "url": "https://example.com/mcp" }
  }
}
'@
        $findings = @(Test-PbiMcpConfigParity -RepoRoot $root)
        @($findings | Where-Object { $_.Severity -eq 'Error' }).Count | Should -Be 0
        @($findings | Where-Object { $_.Message -like "*'drift'*different args*" }).Count | Should -Be 1
        @($findings | Where-Object { $_.Message -like "*'cli-only'*" }).Count | Should -Be 1
        @($findings | Where-Object { $_.Message -like "*'github'*" }).Count | Should -Be 0
        @($findings | Where-Object { $_.Message -like "*'same'*" }).Count | Should -Be 0
    }
}
