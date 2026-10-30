#Requires -Version 7.4
# Pester 5 tests: DAX test file selection, directives, result normalisation and Passed parsing (offline, mocked queries).

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

Describe 'Get-PbiDaxTestFile' {
    BeforeAll {
        $script:model = Join-Path $TestDrive 'Sales.SemanticModel'
        foreach ($name in @('A.ALL.Tests.dax', 'B.LOCAL.Tests.dax', 'C.DEV.Tests.dax', 'D.TEST.Tests.dax', 'E.PROD.Tests.dax', 'F.dax', 'G.Tests.dax', 'notes.txt', 'H.ALL.Tests.dax')) {
            New-TestFile -Path (Join-Path $script:model "DAXQueries/$name") -Content 'EVALUATE ROW("x", 1)'
        }
    }

    It 'selects ALL plus the <Target> scope, sorted' -TestCases @(
        @{ Target = 'Local'; Expected = 'A.ALL.Tests.dax|B.LOCAL.Tests.dax|H.ALL.Tests.dax' }
        @{ Target = 'DEV'; Expected = 'A.ALL.Tests.dax|C.DEV.Tests.dax|H.ALL.Tests.dax' }
        @{ Target = 'TEST'; Expected = 'A.ALL.Tests.dax|D.TEST.Tests.dax|H.ALL.Tests.dax' }
        @{ Target = 'PROD'; Expected = 'A.ALL.Tests.dax|E.PROD.Tests.dax|H.ALL.Tests.dax' }
    ) {
        $names = @(Get-PbiDaxTestFile -SemanticModelPath $script:model -Target $Target | ForEach-Object { $_.Name })
        ($names -join '|') | Should -BeExactly $Expected
    }

    It 'returns nothing when the model has no DAXQueries folder' {
        @(Get-PbiDaxTestFile -SemanticModelPath (Join-Path $TestDrive 'Empty.SemanticModel') -Target Local).Count | Should -Be 0
    }
}

Describe 'Get-PbiDaxTestDirective' {
    It 'reads role and effective user name directives case-insensitively' {
        $query = "// Row-level security test`n// @Role: Sales Europe`n//@EFFECTIVEUSERNAME:  test.user@contoso.com `nEVALUATE ROW(`"x`", 1)"
        $directive = Get-PbiDaxTestDirective -Query $query
        $directive.Role | Should -Be 'Sales Europe'
        $directive.EffectiveUserName | Should -Be 'test.user@contoso.com'
    }

    It 'supports several roles and ignores other comments' {
        $directive = Get-PbiDaxTestDirective -Query "// @role: A`n// just a comment`n// @role: B, C`nEVALUATE {1}"
        $directive.Role | Should -Be 'A,B,C'
        @($directive.Roles).Count | Should -Be 3
        $directive.EffectiveUserName | Should -BeNullOrEmpty
    }

    It 'only reads the leading comment block' {
        $directive = Get-PbiDaxTestDirective -Query "EVALUATE {1}`n// @role: Late"
        $directive.Role | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-PbiDaxQuery result normalisation' {
    BeforeEach {
        Mock -CommandName Invoke-PbiFabricApi -ModuleName PbiSuperpower -MockWith {
            ConvertFrom-Json -InputObject @'
{ "results": [ { "tables": [ { "rows": [
  { "[TestName]": "Total equals 10", "[ExpectedValue]": 10, "Sales[ActualValue]": 10, "'Test Table'[Passed]": true },
  { "[TestName]": "Rows equal 3", "[ExpectedValue]": 3, "Sales[ActualValue]": 2, "'Test Table'[Passed]": false }
] } ] } ] }
'@
        }
    }

    It 'strips table prefixes and square brackets from column names' {
        $rows = @(Invoke-PbiDaxQuery -WorkspaceId 'ws' -DatasetId 'ds' -Query 'EVALUATE x')
        $rows.Count | Should -Be 2
        $rows[0].TestName | Should -Be 'Total equals 10'
        $rows[0].ExpectedValue | Should -Be 10
        $rows[0].ActualValue | Should -Be 10
        $rows[0].Passed | Should -BeTrue
        $rows[1].Passed | Should -BeFalse
    }

    It 'sends impersonatedUserName and includeNulls to executeQueries' {
        $null = Invoke-PbiDaxQuery -WorkspaceId 'ws' -DatasetId 'ds' -Query 'EVALUATE x' -ImpersonatedUserName 'test.user@contoso.com'
        Should -Invoke -CommandName Invoke-PbiFabricApi -ModuleName PbiSuperpower -Times 1 -Exactly -ParameterFilter {
            $Resource -eq 'PowerBI' -and $Path -eq 'groups/ws/datasets/ds/executeQueries' -and
            $Body.impersonatedUserName -eq 'test.user@contoso.com' -and $Body.serializerSettings.includeNulls -eq $true
        }
    }

    It 'throws the error returned in the results' {
        Mock -CommandName Invoke-PbiFabricApi -ModuleName PbiSuperpower -MockWith {
            ConvertFrom-Json -InputObject '{ "results": [ { "error": { "code": "DaxSyntax", "message": "The syntax is incorrect." } } ] }'
        }
        { Invoke-PbiDaxQuery -WorkspaceId 'ws' -DatasetId 'ds' -Query 'EVALUATE' } | Should -Throw -ExpectedMessage '*DAX query failed*syntax is incorrect*'
    }
}

Describe 'Invoke-PbiDaxTestSuite' {
    BeforeAll {
        $script:suiteModel = Join-Path $TestDrive 'Suite.SemanticModel'
        New-TestFile -Path (Join-Path $script:suiteModel 'DAXQueries/Measures.ALL.Tests.dax') -Content "// measure tests`nEVALUATE MeasuresTests"
        New-TestFile -Path (Join-Path $script:suiteModel 'DAXQueries/Rls.DEV.Tests.dax') -Content "// @role: Sales Europe`nEVALUATE RlsTests"
        New-TestFile -Path (Join-Path $script:suiteModel 'DAXQueries/User.DEV.Tests.dax') -Content "// @effectiveUserName: test.user@contoso.com`nEVALUATE UserTests"
        New-TestFile -Path (Join-Path $script:suiteModel 'DAXQueries/Broken.TEST.Tests.dax') -Content 'EVALUATE BrokenTests'
    }

    BeforeEach {
        Mock -CommandName Write-Warning -ModuleName PbiSuperpower -MockWith { }
        Mock -CommandName Invoke-PbiDaxQuery -ModuleName PbiSuperpower -MockWith {
            if ($Query -like '*BrokenTests*') {
                throw 'DAX query failed: Column Foo not found.'
            }
            if ($Query -like '*UserTests*') {
                return [pscustomobject]@{ TestName = 'User sees own rows'; ExpectedValue = 1; ActualValue = 1; Passed = $true }
            }
            [pscustomobject]@{ TestName = 'bool true'; ExpectedValue = 1; ActualValue = 1; Passed = $true }
            [pscustomobject]@{ TestName = 'string True'; ExpectedValue = 1; ActualValue = 1; Passed = 'True' }
            [pscustomobject]@{ TestName = 'number 1'; ExpectedValue = 1; ActualValue = 1; Passed = 1 }
            [pscustomobject]@{ TestName = 'number 0'; ExpectedValue = 1; ActualValue = 2; Passed = 0 }
            [pscustomobject]@{ TestName = 'string false'; ExpectedValue = 1; ActualValue = 2; Passed = 'false' }
            [pscustomobject]@{ TestName = 'null'; ExpectedValue = 1; ActualValue = $null; Passed = $null }
        }
    }

    It 'parses Passed as true only for true, "True" and 1' {
        $results = @(Invoke-PbiDaxTestSuite -SemanticModelPath $script:suiteModel -Target PROD -WorkspaceId 'ws' -DatasetId 'ds')
        $results.Count | Should -Be 6
        $byName = @{}
        foreach ($result in $results) {
            $byName[$result.TestName] = $result
        }
        $byName['bool true'].Passed | Should -BeTrue
        $byName['string True'].Passed | Should -BeTrue
        $byName['number 1'].Passed | Should -BeTrue
        $byName['number 0'].Passed | Should -BeFalse
        $byName['string false'].Passed | Should -BeFalse
        $byName['null'].Passed | Should -BeFalse
        $byName['bool true'].File | Should -Be 'Measures.ALL.Tests.dax'
        $byName['number 0'].Status | Should -Be 'Failed'
        $byName['bool true'].Status | Should -Be 'Passed'
        $byName['bool true'].Skipped | Should -BeFalse
    }

    It 'skips role tests on service targets instead of failing them' {
        $results = @(Invoke-PbiDaxTestSuite -SemanticModelPath $script:suiteModel -Target DEV -WorkspaceId 'ws' -DatasetId 'ds')
        $rls = @($results | Where-Object { $_.File -eq 'Rls.DEV.Tests.dax' })
        $rls.Count | Should -Be 1
        $rls[0].Skipped | Should -BeTrue
        $rls[0].Passed | Should -BeFalse
        $rls[0].Status | Should -Be 'Skipped'
        $rls[0].Error | Should -Be 'role directive not supported on service target'
        Should -Invoke -CommandName Invoke-PbiDaxQuery -ModuleName PbiSuperpower -Times 0 -Exactly -ParameterFilter { $Query -like '*RlsTests*' }
    }

    It 'maps @effectiveUserName to impersonatedUserName on service targets' {
        $results = @(Invoke-PbiDaxTestSuite -SemanticModelPath $script:suiteModel -Target DEV -WorkspaceId 'ws' -DatasetId 'ds')
        @($results | Where-Object { $_.File -eq 'User.DEV.Tests.dax' -and $_.Passed }).Count | Should -Be 1
        Should -Invoke -CommandName Invoke-PbiDaxQuery -ModuleName PbiSuperpower -Times 1 -Exactly -ParameterFilter { $ImpersonatedUserName -eq 'test.user@contoso.com' }
    }

    It 'turns a query error into one failed result for the file' {
        $results = @(Invoke-PbiDaxTestSuite -SemanticModelPath $script:suiteModel -Target TEST -WorkspaceId 'ws' -DatasetId 'ds')
        $broken = @($results | Where-Object { $_.File -eq 'Broken.TEST.Tests.dax' })
        $broken.Count | Should -Be 1
        $broken[0].Passed | Should -BeFalse
        $broken[0].Error | Should -BeLike '*Column Foo not found*'
    }

    It 'flags slow files with SlowQuery and keeps Passed' {
        Mock -CommandName Invoke-PbiDaxQuery -ModuleName PbiSuperpower -MockWith {
            Start-Sleep -Milliseconds 50
            [pscustomobject]@{ TestName = 'slow'; ExpectedValue = 1; ActualValue = 1; Passed = $true }
        }
        $results = @(Invoke-PbiDaxTestSuite -SemanticModelPath $script:suiteModel -Target PROD -WorkspaceId 'ws' -DatasetId 'ds' -MaxDurationMs 1)
        $results.Count | Should -Be 1
        $results[0].SlowQuery | Should -BeTrue
        $results[0].Passed | Should -BeTrue
        $results[0].Status | Should -Be 'Warning'
    }

    It 'passes @role and @effectiveUserName to the local connection' {
        Mock -CommandName Invoke-PbiLocalDaxQuery -ModuleName PbiSuperpower -MockWith {
            [pscustomobject]@{ TestName = 'local'; ExpectedValue = 1; ActualValue = 1; Passed = $true }
        }
        $localModel = Join-Path $TestDrive 'Local.SemanticModel'
        New-TestFile -Path (Join-Path $localModel 'DAXQueries/Rls.LOCAL.Tests.dax') -Content "// @role: Sales Europe`n// @effectiveUserName: test.user@contoso.com`nEVALUATE RlsTests"
        $results = @(Invoke-PbiDaxTestSuite -SemanticModelPath $localModel -Target Local -Port 51234)
        $results.Count | Should -Be 1
        $results[0].Passed | Should -BeTrue
        Should -Invoke -CommandName Invoke-PbiLocalDaxQuery -ModuleName PbiSuperpower -Times 1 -Exactly -ParameterFilter {
            $Port -eq 51234 -and $Role -eq 'Sales Europe' -and $EffectiveUserName -eq 'test.user@contoso.com'
        }
    }

    It 'requires a port for Local and ids for service targets' {
        { Invoke-PbiDaxTestSuite -SemanticModelPath $script:suiteModel -Target Local } | Should -Throw -ExpectedMessage '*Port*'
        { Invoke-PbiDaxTestSuite -SemanticModelPath $script:suiteModel -Target DEV } | Should -Throw -ExpectedMessage '*WorkspaceId*'
    }
}
