#Requires -Version 7.4
# Pester 5 tests: Get-PbiProperty, Expand-PbiPlaceholder and Get-PbiEnvironmentConfig (offline).

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

    $script:testVariables = @(
        'PBI_TEST_ALPHA', 'PBI_TEST_BETA', 'PBI_TEST_MISSING_ONE', 'PBI_TEST_MISSING_TWO', 'PBI_TEST_OPTIONAL_UNSET',
        'PBI_TEST_CAPACITY', 'PBI_TEST_ADMIN', 'PBI_TEST_MEMBER_UNSET', 'PBI_TEST_EMPTY_CAPACITY'
    )
}

AfterAll {
    foreach ($name in $script:testVariables) {
        Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
    }
}

Describe 'Get-PbiProperty' {
    It 'reads a property of a PSCustomObject' {
        $object = [pscustomobject]@{ Name = 'Sales' }
        Get-PbiProperty $object 'Name' | Should -Be 'Sales'
    }

    It 'is case-insensitive' {
        $object = [pscustomobject]@{ displayName = 'Sales' }
        Get-PbiProperty -InputObject $object -Name 'DISPLAYNAME' | Should -Be 'Sales'
    }

    It 'returns the default for a missing property' {
        $object = [pscustomobject]@{ Name = 'Sales' }
        Get-PbiProperty $object 'Missing' 'fallback' | Should -Be 'fallback'
    }

    It 'returns nothing for a missing property without a default' {
        $object = [pscustomobject]@{ Name = 'Sales' }
        Get-PbiProperty $object 'Missing' | Should -BeNullOrEmpty
        @(Get-PbiProperty $object 'Missing').Count | Should -Be 0
    }

    It 'returns the default when the value is null' {
        $object = [pscustomobject]@{ Name = $null }
        Get-PbiProperty $object 'Name' 'fallback' | Should -Be 'fallback'
    }

    It 'returns the default when the input object is null' {
        Get-PbiProperty $null 'Name' 'fallback' | Should -Be 'fallback'
    }

    It 'reads hashtable and ordered dictionary keys' {
        Get-PbiProperty @{ Role = 'Admin' } 'role' | Should -Be 'Admin'
        Get-PbiProperty ([ordered]@{ Role = 'Viewer' }) 'Role' | Should -Be 'Viewer'
    }

    It 'returns arrays that can be wrapped with @() (empty and single-item arrays included)' {
        $object = ConvertFrom-Json -InputObject '{ "two": [1, 2], "one": ["x"], "none": [] }'
        @(Get-PbiProperty $object 'two').Count | Should -Be 2
        @(Get-PbiProperty $object 'one').Count | Should -Be 1
        @(Get-PbiProperty $object 'none').Count | Should -Be 0
        @(Get-PbiProperty $object 'missing').Count | Should -Be 0
    }

    It 'returns false and zero values (not the default)' {
        $object = [pscustomobject]@{ Flag = $false; Count = 0 }
        Get-PbiProperty $object 'Flag' $true | Should -BeFalse
        Get-PbiProperty $object 'Count' 5 | Should -Be 0
    }

    It 'does not fail under Set-StrictMode for missing properties' {
        Set-StrictMode -Version Latest
        $object = [pscustomobject]@{ Name = 'Sales' }
        { Get-PbiProperty $object 'Nope' } | Should -Not -Throw
    }
}

Describe 'Expand-PbiPlaceholder' {
    BeforeEach {
        $env:PBI_TEST_ALPHA = 'alpha-value'
        $env:PBI_TEST_BETA = 'beta'
        Remove-Item -Path 'Env:PBI_TEST_MISSING_ONE', 'Env:PBI_TEST_MISSING_TWO', 'Env:PBI_TEST_OPTIONAL_UNSET' -ErrorAction SilentlyContinue
        Mock -CommandName Write-Warning -ModuleName PbiSuperpower -MockWith { }
    }

    It 'replaces placeholders in strings, nested objects and arrays' {
        $config = ConvertFrom-Json -InputObject '{ "a": "${env:PBI_TEST_ALPHA}", "nested": { "b": "x-${env:PBI_TEST_BETA}-${env:PBI_TEST_ALPHA}" }, "list": ["${env:PBI_TEST_BETA}", 3, true] }'
        $result = Expand-PbiPlaceholder -Value $config
        $result.a | Should -Be 'alpha-value'
        $result.nested.b | Should -Be 'x-beta-alpha-value'
        $result.list[0] | Should -Be 'beta'
        $result.list[1] | Should -Be 3
        $result.list[2] | Should -BeTrue
    }

    It 'returns a new object and leaves the input unchanged' {
        $config = ConvertFrom-Json -InputObject '{ "a": "${env:PBI_TEST_ALPHA}", "list": ["${env:PBI_TEST_BETA}"] }'
        $result = Expand-PbiPlaceholder -Value $config
        $config.a | Should -Be '${env:PBI_TEST_ALPHA}'
        $config.list[0] | Should -Be '${env:PBI_TEST_BETA}'
        $result.a | Should -Be 'alpha-value'
    }

    It 'expands hashtables into new hashtables' {
        $result = Expand-PbiPlaceholder -Value @{ key = '${env:PBI_TEST_BETA}' }
        $result | Should -BeOfType [hashtable]
        $result['key'] | Should -Be 'beta'
    }

    It 'drops an optional array entry with an unresolved placeholder and warns' {
        $config = ConvertFrom-Json -InputObject '{ "roleAssignments": [ { "principalId": "${env:PBI_TEST_ALPHA}", "role": "Admin" }, { "principalId": "${env:PBI_TEST_OPTIONAL_UNSET}", "role": "Viewer", "optional": true } ] }'
        $result = Expand-PbiPlaceholder -Value $config
        @($result.roleAssignments).Count | Should -Be 1
        @($result.roleAssignments)[0].principalId | Should -Be 'alpha-value'
        Should -Invoke -CommandName Write-Warning -ModuleName PbiSuperpower -Times 1 -Exactly -ParameterFilter { $Message -like '*PBI_TEST_OPTIONAL_UNSET*' }
    }

    It 'keeps an optional entry when its placeholders resolve' {
        $config = ConvertFrom-Json -InputObject '{ "items": [ { "id": "${env:PBI_TEST_BETA}", "optional": true } ] }'
        $result = Expand-PbiPlaceholder -Value $config
        @($result.items).Count | Should -Be 1
        Should -Invoke -CommandName Write-Warning -ModuleName PbiSuperpower -Times 0 -Exactly
    }

    It 'throws one error that lists all missing variables' {
        $config = ConvertFrom-Json -InputObject '{ "a": "${env:PBI_TEST_MISSING_TWO}", "b": { "c": "${env:PBI_TEST_MISSING_ONE}" } }'
        { Expand-PbiPlaceholder -Value $config } | Should -Throw -ExpectedMessage '*PBI_TEST_MISSING_ONE, PBI_TEST_MISSING_TWO*'
    }

    It 'does not count missing variables inside dropped optional entries' {
        $config = ConvertFrom-Json -InputObject '{ "list": [ { "id": "${env:PBI_TEST_OPTIONAL_UNSET}", "optional": true } ], "a": "${env:PBI_TEST_MISSING_ONE}" }'
        { Expand-PbiPlaceholder -Value $config } | Should -Throw -ExpectedMessage '*PBI_TEST_MISSING_ONE*'
        try {
            Expand-PbiPlaceholder -Value $config
        } catch {
            $_.Exception.Message | Should -Not -BeLike '*PBI_TEST_OPTIONAL_UNSET*'
        }
    }

    It 'returns strings without placeholders unchanged' {
        Expand-PbiPlaceholder -Value 'plain text' | Should -Be 'plain text'
    }
}

Describe 'Get-PbiEnvironmentConfig' {
    BeforeEach {
        foreach ($name in $script:testVariables) {
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        }
        Mock -CommandName Write-Warning -ModuleName PbiSuperpower -MockWith { }
        $script:repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $script:repo 'AGENTS.md') -Content '# test repo'
        $devJson = @'
{
  "name": "DEV",
  "workspace": {
    "displayName": "WS [DEV]",
    "description": "base description",
    "capacityName": "${env:PBI_TEST_CAPACITY}",
    "roleAssignments": [
      { "principalId": "${env:PBI_TEST_ADMIN}", "principalType": "Group", "role": "Admin" },
      { "principalId": "${env:PBI_TEST_MEMBER_UNSET}", "principalType": "Group", "role": "Contributor", "optional": true }
    ]
  },
  "guards": { "allowedBranches": ["*"], "humanOnly": false },
  "projects": [
    { "path": "src/Sales", "semanticModel": { "folder": "Sales.SemanticModel", "displayName": "Sales", "parameters": { "Environment": "DEV" } }, "reports": [ { "folder": "Sales.Report", "displayName": "Sales" } ] }
  ],
  "postDeploy": { "runDaxTests": true }
}
'@
        New-TestFile -Path (Join-Path $script:repo 'config/environments/dev.json') -Content $devJson
        $dotEnv = @'
# local secrets and ids (never committed)
PBI_TEST_CAPACITY=cap-from-dotenv

PBI_TEST_ADMIN="admin-group"
'@
        New-TestFile -Path (Join-Path $script:repo '.env.local') -Content $dotEnv
    }

    It 'loads .env.local, expands placeholders and drops unresolved optional role assignments' {
        $config = Get-PbiEnvironmentConfig -Environment DEV -RepoRoot $script:repo
        $config.name | Should -Be 'DEV'
        $config.workspace.capacityName | Should -Be 'cap-from-dotenv'
        @($config.workspace.roleAssignments).Count | Should -Be 1
        @($config.workspace.roleAssignments)[0].principalId | Should -Be 'admin-group'
        @($config.projects)[0].semanticModel.parameters.Environment | Should -Be 'DEV'
        $env:PBI_TEST_ADMIN | Should -Be 'admin-group'
    }

    It 'deep-merges dev.local.json (local wins, arrays are replaced)' {
        $localJson = @'
{
  "workspace": {
    "description": "local description",
    "roleAssignments": [ { "principalId": "${env:PBI_TEST_ADMIN}", "principalType": "Group", "role": "Member" } ]
  },
  "guards": { "humanOnly": true }
}
'@
        New-TestFile -Path (Join-Path $script:repo 'config/environments/dev.local.json') -Content $localJson
        $config = Get-PbiEnvironmentConfig -Environment DEV -RepoRoot $script:repo
        $config.workspace.displayName | Should -Be 'WS [DEV]'
        $config.workspace.description | Should -Be 'local description'
        @($config.workspace.roleAssignments).Count | Should -Be 1
        @($config.workspace.roleAssignments)[0].role | Should -Be 'Member'
        $config.guards.humanOnly | Should -BeTrue
        @($config.guards.allowedBranches)[0] | Should -Be '*'
    }

    It 'resolves a variable declared empty in .env.local to an empty string' {
        $devJson = (Get-Content -LiteralPath (Join-Path $script:repo 'config/environments/dev.json') -Raw).Replace('PBI_TEST_CAPACITY', 'PBI_TEST_EMPTY_CAPACITY')
        New-TestFile -Path (Join-Path $script:repo 'config/environments/dev.json') -Content $devJson
        New-TestFile -Path (Join-Path $script:repo '.env.local') -Content ("PBI_TEST_ADMIN=admin-group`nPBI_TEST_EMPTY_CAPACITY=`n")
        $config = Get-PbiEnvironmentConfig -Environment DEV -RepoRoot $script:repo
        $config.workspace.capacityName | Should -Be ''
    }

    It 'reports every missing variable in one error' {
        Remove-Item -LiteralPath (Join-Path $script:repo '.env.local')
        { Get-PbiEnvironmentConfig -Environment DEV -RepoRoot $script:repo } | Should -Throw -ExpectedMessage '*PBI_TEST_ADMIN, PBI_TEST_CAPACITY*'
    }

    It 'validates required fields' {
        $invalid = '{ "name": "TEST", "workspace": { "description": "no name" }, "projects": [ { "path": "src/Sales", "semanticModel": { "folder": "Sales.SemanticModel" } } ] }'
        New-TestFile -Path (Join-Path $script:repo 'config/environments/test.json') -Content $invalid
        { Get-PbiEnvironmentConfig -Environment TEST -RepoRoot $script:repo } | Should -Throw -ExpectedMessage '*workspace.displayName*'
        { Get-PbiEnvironmentConfig -Environment TEST -RepoRoot $script:repo } | Should -Throw -ExpectedMessage '*projects`[0`].semanticModel.displayName*'
    }

    It 'fails with a clear message when the environment file is missing' {
        { Get-PbiEnvironmentConfig -Environment PROD -RepoRoot $script:repo } | Should -Throw -ExpectedMessage '*config/environments/prod.json*'
    }
}
